package com.hme.bluetoothle.background;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.*;
import android.security.NetworkSecurityPolicy;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** A process-local, non-restarting connectedDevice service. All BLE state uses the main looper. */
public final class BLEBackgroundService extends Service {
    public interface Events { void record(String name, JSONObject details); String appState(); }
    public final class LocalBinder extends Binder { BLEBackgroundService service() { return BLEBackgroundService.this; } }
    private static final String CHANNEL = "bluetoothle_background";
    private static final int NOTIFICATION = 0x424c45;
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<BLEBackgroundProtocol.Done> stopWaiters = new ArrayList<>();
    private final ThreadPoolExecutor network = new ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<>(32));
    private final ThreadPoolExecutor cancellations = new ThreadPoolExecutor(0, 1, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(32), new ThreadPoolExecutor.DiscardPolicy());
    private final Set<HttpJob> httpJobs = new HashSet<>();
    private JSONObject configuration;
    private BLEBackgroundProtocol protocol;
    private Events events;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic notifyCharacteristic, writeCharacteristic;
    private BLEBackgroundProtocol.Done writeCompletion;
    private boolean running, stopping;
    public boolean monitoring;
    public String startupError;
    private int failures;
    private PowerManager.WakeLock wakeLock;

    @Override public void onCreate() {
        super.onCreate();
        try {
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Background Bluetooth", NotificationManager.IMPORTANCE_LOW));
            Notification notification = notification(null);
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
            else startForeground(NOTIFICATION, notification);
            PowerManager power = getSystemService(PowerManager.class);
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, getPackageName() + ":BluetoothLEBackground");
            wakeLock.setReferenceCounted(false);
            IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(adapterChanges, filter, Context.RECEIVER_EXPORTED);
            else registerReceiver(adapterChanges, filter);
        } catch (RuntimeException error) { startupError = "Could not start connected-device service: " + error.getClass().getSimpleName(); stopSelf(); }
    }
    private Notification notification(JSONObject config) {
        JSONObject options = config == null ? null : config.optJSONObject("android");
        String title = options == null ? "Background Bluetooth" : options.optString("notificationTitle", "Background Bluetooth");
        String text = options == null ? "Bluetooth monitoring is enabled" : options.optString("notificationText", "Bluetooth monitoring is enabled");
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
            .setSmallIcon(getResources().getIdentifier("ble_background_notification", "drawable", getPackageName()))
            .setContentTitle(title).setContentText(text).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false).setOnlyAlertOnce(true);
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        return builder.build();
    }
    @Override public IBinder onBind(Intent intent) { return new LocalBinder(); }
    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_NOT_STICKY; }
    public void configure(JSONObject options, Events sink) throws Exception {
        if (running || gatt != null || stopping) throw new IllegalStateException("Suspend native ownership before configuring.");
        configuration = BLEBackgroundProtocol.validate(options); events = sink;
        protocol = new BLEBackgroundProtocol(configuration, new BLEBackgroundProtocol.Host() {
            @Override public void event(String name, JSONObject details) { record(name, details); }
            @Override public void write(byte[] bytes, int timeout, BLEBackgroundProtocol.Done done) { writeAck(bytes, timeout, done); }
            @Override public void deliver(JSONObject incident, BLEBackgroundProtocol.Done done) { post(configuration.optJSONObject("reporting"), incident, done); }
        });
        getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(configuration));
    }
    private void record(String name, JSONObject details) {
        // Only matched incidents / bounded ACK retries need a CPU allowance; unrelated notifications do not hold it.
        if (("notification_received".equals(name) || "acknowledgement_queued".equals(name)) && wakeLock != null) wakeLock.acquire(35000);
        if (events != null) events.record(name, details);
    }
    private BluetoothAdapter adapter() { BluetoothManager manager = getSystemService(BluetoothManager.class); return manager == null ? null : manager.getAdapter(); }
    private boolean canConnect() { return Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED; }
    public void activate() { if (protocol == null || stopping) return; running = true; failures = 0; connect(); }
    private void connect() {
        if (!running || stopping || gatt != null) return;
        try {
            if (!canConnect() || adapter() == null || !adapter().isEnabled()) { record("bluetooth_unavailable", new JSONObject()); return; }
            record("device_connecting", new JSONObject());
            BluetoothGatt next = adapter().getRemoteDevice(configuration.optString("deviceId")).connectGatt(this, false, callbacks, BluetoothDevice.TRANSPORT_LE);
            if (next == null) { connectionFailed("connectGatt returned no connection."); return; }
            gatt = next;
            main.postDelayed(() -> { if (gatt == next && !monitoring && !stopping) connectionFailed("Connection/subscription timed out."); }, 15000);
        } catch (RuntimeException error) { connectionFailed("Bluetooth connection failed: " + error.getClass().getSimpleName()); }
    }
    private void connectionFailed(String error) {
        record("gatt_failed", BLEBackgroundProtocol.object("error", error));
        try { closeGatt(error); } catch (RuntimeException failure) { record("teardown_failed", BLEBackgroundProtocol.object("error", "Could not close GATT.")); return; }
        if (stopping) { finishStop(null); return; }
        failures++;
        if (running && failures < configuration.optInt("maxConnectionFailures", 3)) main.postDelayed(this::connect, 2000);
        else if (running) record("connection_retry_limit", new JSONObject());
    }
    private void closeGatt(String error) {
        BluetoothGatt previous = gatt;
        // close() disposes the client before any queued ACK may advance or ownership is released.
        if (previous != null) previous.close();
        gatt = null; monitoring = false; notifyCharacteristic = null; writeCharacteristic = null;
        if (protocol != null) protocol.resetStream();
        BLEBackgroundProtocol.Done done = writeCompletion; writeCompletion = null;
        if (done != null) done.complete(error);
    }
    public void suspend(BLEBackgroundProtocol.Done done) {
        running = false; stopWaiters.add(done);
        if (stopping) return;
        stopping = true;
        if (gatt == null) { finishStop(null); return; }
        BluetoothGatt previous = gatt;
        try {
            previous.disconnect();
            main.postDelayed(() -> {
                if (!stopping || gatt != previous) return;
                try { closeGatt("Monitoring suspended."); finishStop(null); }
                catch (RuntimeException error) { finishStop("Native GATT close failed. Retry suspend before foreground BLE."); }
            }, 5000);
        } catch (RuntimeException error) {
            try { closeGatt("Monitoring suspended."); finishStop(null); }
            catch (RuntimeException failure) { finishStop("Native GATT close failed. Retry suspend before foreground BLE."); }
        }
    }
    private void finishStop(String error) {
        stopping = false;
        record("background_monitor_stopped", error == null ? new JSONObject() : BLEBackgroundProtocol.object("error", error));
        List<BLEBackgroundProtocol.Done> callbacks = new ArrayList<>(stopWaiters); stopWaiters.clear();
        for (BLEBackgroundProtocol.Done callback : callbacks) callback.complete(error);
    }
    private void writeAck(byte[] bytes, int timeout, BLEBackgroundProtocol.Done done) {
        if (!running || stopping || !monitoring || gatt == null || writeCharacteristic == null) { done.complete("Notifications are not ready."); return; }
        if (writeCompletion != null) { done.complete("Another native GATT write is pending."); return; }
        BluetoothGatt current = gatt; writeCompletion = done;
        try {
            boolean accepted;
            if (Build.VERSION.SDK_INT >= 33) accepted = current.writeCharacteristic(writeCharacteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS;
            else { writeCharacteristic.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); writeCharacteristic.setValue(bytes); accepted = current.writeCharacteristic(writeCharacteristic); }
            if (!accepted) { connectionFailed("Acknowledgement write was rejected."); return; }
            main.postDelayed(() -> {
                if (gatt == current && writeCompletion == done) connectionFailed("Acknowledgement write timed out; connection retired before retry.");
            }, timeout);
        } catch (RuntimeException error) { connectionFailed("Acknowledgement write failed: " + error.getClass().getSimpleName()); }
    }
    private boolean current(BluetoothGatt value) { return value == gatt; }
    private final BluetoothGattCallback callbacks = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt value, int status, int state) { main.post(() -> {
            if (!current(value)) return;
            if (stopping && state == BluetoothProfile.STATE_DISCONNECTED) {
                try { closeGatt("Monitoring suspended."); finishStop(null); } catch (RuntimeException error) { finishStop("Could not close native GATT."); } return;
            }
            if (!running || stopping) return;
            if (status != BluetoothGatt.GATT_SUCCESS || state == BluetoothProfile.STATE_DISCONNECTED) { record("device_disconnected", BLEBackgroundProtocol.object("status", status)); connectionFailed("GATT disconnected (status " + status + ")."); return; }
            if (state == BluetoothProfile.STATE_CONNECTED) {
                record("device_connected", new JSONObject());
                try { if (!value.discoverServices()) connectionFailed("Service discovery rejected."); }
                catch (RuntimeException error) { connectionFailed("Service discovery unavailable."); }
            }
        }); }
        @Override public void onServicesDiscovered(BluetoothGatt value, int status) { main.post(() -> {
            if (!current(value) || !running || stopping) return;
            try {
                BluetoothGattService service = value.getService(BLEBackgroundProtocol.uuid(configuration.optString("serviceUuid")));
                if (status != BluetoothGatt.GATT_SUCCESS || service == null) { connectionFailed("Configured service not found."); return; }
                notifyCharacteristic = service.getCharacteristic(BLEBackgroundProtocol.uuid(configuration.optString("notifyCharacteristicUuid")));
                writeCharacteristic = service.getCharacteristic(BLEBackgroundProtocol.uuid(configuration.optString("writeCharacteristicUuid")));
                if (notifyCharacteristic == null || writeCharacteristic == null || (writeCharacteristic.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE) == 0) { connectionFailed("Configured characteristics require notifications and Write with response."); return; }
                int properties = notifyCharacteristic.getProperties();
                byte[] enable = (properties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0 ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
                BluetoothGattDescriptor descriptor = notifyCharacteristic.getDescriptor(CCCD);
                if ((properties & (BluetoothGattCharacteristic.PROPERTY_NOTIFY | BluetoothGattCharacteristic.PROPERTY_INDICATE)) == 0 || descriptor == null || !value.setCharacteristicNotification(notifyCharacteristic, true)) { connectionFailed("Cannot enable notifications."); return; }
                boolean accepted;
                if (Build.VERSION.SDK_INT >= 33) accepted = value.writeDescriptor(descriptor, enable) == BluetoothStatusCodes.SUCCESS;
                else { descriptor.setValue(enable); accepted = value.writeDescriptor(descriptor); }
                if (!accepted) connectionFailed("Subscription write rejected.");
            } catch (RuntimeException error) { connectionFailed("Service/subscription setup failed: " + error.getClass().getSimpleName()); }
        }); }
        @Override public void onDescriptorWrite(BluetoothGatt value, BluetoothGattDescriptor descriptor, int status) { main.post(() -> {
            if (!current(value) || !running || stopping || descriptor.getCharacteristic() != notifyCharacteristic || !CCCD.equals(descriptor.getUuid())) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { connectionFailed("Subscription failed (status " + status + ")."); return; }
            monitoring = true; failures = 0; record("notifications_enabled", new JSONObject());
        }); }
        @Override public void onCharacteristicWrite(BluetoothGatt value, BluetoothGattCharacteristic characteristic, int status) { main.post(() -> {
            if (!current(value) || characteristic != writeCharacteristic || writeCompletion == null) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { connectionFailed("Acknowledgement failed (status " + status + ")."); return; }
            BLEBackgroundProtocol.Done done = writeCompletion; writeCompletion = null; done.complete(null);
        }); }
        @Override public void onCharacteristicChanged(BluetoothGatt value, BluetoothGattCharacteristic characteristic) {
            // API 26–32: copy before posting because characteristic values are mutable.
            byte[] bytes = characteristic.getValue(); if (bytes != null) receive(value, characteristic, bytes.clone());
        }
        @Override public void onCharacteristicChanged(BluetoothGatt value, BluetoothGattCharacteristic characteristic, byte[] bytes) { receive(value, characteristic, bytes.clone()); }
    };
    private void receive(BluetoothGatt value, BluetoothGattCharacteristic characteristic, byte[] bytes) { main.post(() -> {
        if (!current(value) || !running || stopping || !monitoring || characteristic != notifyCharacteristic) return;
        try {
            protocol.receive(bytes, SystemClock.elapsedRealtime(), value.getDevice().getAddress(), characteristic.getService().getUuid(), characteristic.getUuid(),
                BLEBackgroundProtocol.object("receivedAt", Instant.now().toString(), "receivedAppState", "background"));
        } catch (RuntimeException error) { record("packet_rejected", BLEBackgroundProtocol.object("reason", "Bluetooth permission or context unavailable.")); }
    }); }
    private final BroadcastReceiver adapterChanges = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (!BluetoothAdapter.ACTION_STATE_CHANGED.equals(intent.getAction()) || !running) return;
            try {
                if (canConnect() && adapter() != null && adapter().isEnabled()) { failures = 0; connect(); }
                else { closeGatt("Bluetooth disabled or permission unavailable."); record("bluetooth_unavailable", new JSONObject()); }
            } catch (RuntimeException error) { record("bluetooth_unavailable", new JSONObject()); }
        }
    };
    private final class HttpJob {
        volatile HttpURLConnection connection;
        Future<?> work;
        boolean finished;
        BLEBackgroundProtocol.Done completion;
        void finish(String error) { if (finished) return; finished = true; httpJobs.remove(this); completion.complete(error); }
        void cancel(String error) {
            if (work != null) work.cancel(true);
            HttpURLConnection current = connection;
            // disconnect() may contend with a socket read; it must never hold up BLE callbacks on main.
            if (current != null) cancellations.execute(current::disconnect);
            finish(error);
        }
    }
    public void post(JSONObject reporting, JSONObject incident, BLEBackgroundProtocol.Done completion) {
        if (reporting == null) { completion.complete("Reporting is not configured."); return; }
        final byte[] body;
        try { body = BLEBackgroundReporting.body(reporting, incident, events == null ? "foreground" : events.appState()); }
        catch (Exception error) { completion.complete("Preflight is unavailable with reporting.body."); return; }
        HttpJob job = new HttpJob(); job.completion = completion; httpJobs.add(job);
        main.postDelayed(() -> { if (!job.finished) job.cancel("HTTP request timed out; delivery is unconfirmed."); }, reporting.optInt("timeoutMs", 8000));
        try {
            job.work = network.submit(() -> {
                String error = null;
                try {
                    job.connection = BLEBackgroundReporting.request(reporting, body, url -> {
                        if ("http".equalsIgnoreCase(url.getProtocol()) && !NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(url.getHost())) throw new SecurityException("Cleartext networking not permitted.");
                        return (HttpURLConnection)url.openConnection();
                    });
                    if (Thread.currentThread().isInterrupted()) { job.connection.disconnect(); return; }
                    int code = BLEBackgroundReporting.send(job.connection, body);
                    if (code < 200 || code >= 300) error = "HTTP " + code;
                } catch (Exception failure) { error = "HTTP delivery failed: " + failure.getClass().getSimpleName(); }
                final String result = error; main.post(() -> job.finish(result));
            });
        } catch (RejectedExecutionException error) { job.finish("HTTP delivery capacity exceeded."); }
    }
    @Override public void onDestroy() {
        running = false;
        try { closeGatt("Service stopped."); finishStop(null); } catch (RuntimeException error) { finishStop("Native GATT close failed."); }
        for (HttpJob job : new ArrayList<>(httpJobs)) job.cancel("Service stopped; delivery is unconfirmed.");
        network.shutdownNow(); cancellations.shutdown(); main.removeCallbacksAndMessages(null);
        try { unregisterReceiver(adapterChanges); } catch (IllegalArgumentException ignored) { }
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
}
