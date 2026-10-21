package com.hme.bluetoothle.background;

import com.randdusing.bluetoothle.BluetoothLePlugin;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.PluginResult;
import org.json.*;
import android.Manifest;
import android.bluetooth.BluetoothManager;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.util.AtomicFile;
import android.util.Log;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** Extends only public parent APIs. No reflection, copied parent implementation or private GATT access. */
public final class BLEBackgroundPlugin extends BluetoothLePlugin implements BLEBackgroundService.Events {
    private static final int PERMISSIONS = 60421;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<String> addresses = new LinkedHashSet<>();
    private final List<JSONObject> events = new ArrayList<>();
    private final List<CallbackContext> stopCallbacks = new ArrayList<>();
    private final Set<CallbackContext> foregroundCallbacks = new HashSet<>();
    private final ThreadPoolExecutor logWriter = new ThreadPoolExecutor(0, 1, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(16), new ThreadPoolExecutor.DiscardOldestPolicy());
    private JSONObject configuration;
    private BLEBackgroundService service;
    private boolean visible = true, bound, destroyed, stopDisarms;
    private int callbackEpoch;
    private CallbackContext startCallback;
    private BLEBackgroundOwnership ownership;
    private AtomicFile eventFile;

    @Override protected void pluginInitialize() {
        super.pluginInitialize();
        eventFile = new AtomicFile(new File(cordova.getContext().getFilesDir(), "bluetoothle-background-events.json"));
        try (InputStream input = eventFile.openRead()) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) != -1 && bytes.size() <= 1048576) bytes.write(buffer, 0, count);
            JSONArray saved = new JSONArray(bytes.toString("UTF-8"));
            for (int i = Math.max(0, saved.length() - 1000); i < saved.length(); i++) events.add(saved.getJSONObject(i));
        } catch (Exception ignored) { }
        ownership = new BLEBackgroundOwnership(new BLEBackgroundOwnership.Host() {
            @Override public void retireParent(BLEBackgroundProtocol.Done done) { retireConnections(done); }
            @Override public void connectNative() {
                record("background_handoff_started", new JSONObject());
                if (service == null) { failure("Prepared foreground service is unavailable."); return; }
                service.activate();
            }
            @Override public void stopNative(BLEBackgroundProtocol.Done done) { if (service == null) done.complete(null); else service.suspend(done); }
            @Override public void failure(String error) { record("handoff_failed", BLEBackgroundProtocol.object("error", error)); }
        });
    }
    @Override public boolean execute(String action, JSONArray args, CallbackContext callback) throws JSONException {
        // Parent operations and lifecycle ownership transitions share one main-loop gate.
        main.post(() -> {
            if (destroyed) { callback.error("Bluetooth plugin was destroyed."); return; }
            try {
                if (action.startsWith("background")) { background(action, args.optJSONObject(0), callback); return; }
                if (ownership.ownsBluetooth) { callback.error("Background Bluetooth owns the connection. Await suspend() before foreground operations."); return; }
                JSONObject parameters = args.optJSONObject(0);
                if (("connect".equals(action) || "reconnect".equals(action)) && parameters != null &&
                    parameters.optString("address").matches("(?i)([0-9a-f]{2}:){5}[0-9a-f]{2}")) addresses.add(parameters.getString("address").toUpperCase(Locale.US));
                int epoch = callbackEpoch;
                foregroundCallbacks.add(callback);
                CallbackContext guarded = new CallbackContext(callback.getCallbackId(), webView) {
                    @Override public void sendPluginResult(PluginResult result) { main.post(() -> {
                        // Parent command responses never receive background SOS or drive stale retries.
                        if (epoch == callbackEpoch && !ownership.ownsBluetooth) callback.sendPluginResult(result);
                        if (!result.getKeepCallback()) foregroundCallbacks.remove(callback);
                    }); }
                };
                if (!BLEBackgroundPlugin.super.execute(action, args, guarded)) callback.sendPluginResult(new PluginResult(PluginResult.Status.INVALID_ACTION));
            } catch (Exception error) { callback.error("Bluetooth operation failed: " + error.getMessage()); }
        });
        return true;
    }
    private boolean supported() {
        BluetoothManager manager = (BluetoothManager)cordova.getContext().getSystemService(Context.BLUETOOTH_SERVICE);
        return Build.VERSION.SDK_INT >= 26 && cordova.getContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) && manager != null && manager.getAdapter() != null;
    }
    private JSONObject status() {
        return BLEBackgroundProtocol.object("available", supported(), "configured", configuration != null, "armed", ownership.armed,
            "ownsBluetooth", ownership.ownsBluetooth, "monitoring", service != null && service.monitoring,
            "restorationSupported", false, "events", new JSONArray(events));
    }
    private void background(String action, JSONObject options, CallbackContext callback) throws Exception {
        switch (action) {
            case "backgroundConfigure":
                if (!visible || ownership.ownsBluetooth || startCallback != null || !stopCallbacks.isEmpty()) throw new IllegalStateException("Configure in the foreground after ownership has ended.");
                JSONObject validated = BLEBackgroundProtocol.validate(options);
                if (service != null) service.configure(validated, this);
                configuration = validated; record("configured", new JSONObject()); callback.success(status()); break;
            case "backgroundStart":
                if (!visible || !supported() || configuration == null || ownership.ownsBluetooth || !stopCallbacks.isEmpty()) throw new IllegalStateException("Start while visible with Bluetooth configured and ownership released.");
                if (startCallback != null) throw new IllegalStateException("Service preparation is already pending.");
                startCallback = callback;
                List<String> required = new ArrayList<>();
                if (Build.VERSION.SDK_INT >= 31 && !cordova.hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) required.add(Manifest.permission.BLUETOOTH_CONNECT);
                if (Build.VERSION.SDK_INT >= 33 && !cordova.hasPermission(Manifest.permission.POST_NOTIFICATIONS)) required.add(Manifest.permission.POST_NOTIFICATIONS);
                if (!required.isEmpty()) cordova.requestPermissions(this, PERMISSIONS, required.toArray(new String[0])); else startService();
                break;
            case "backgroundStop":
                if (!visible && (options == null || !options.optBoolean("disarm"))) throw new IllegalStateException("Suspend foreground ownership while the app is visible.");
                cancelStart("Monitoring preparation was cancelled.");
                stopDisarms |= options != null && options.optBoolean("disarm");
                stopCallbacks.add(callback);
                if (stopCallbacks.size() > 1) { if (stopDisarms) ownership.armed = false; return; }
                ownership.suspend(stopDisarms, error -> {
                    if (error == null && stopDisarms) releaseService();
                    List<CallbackContext> replies = new ArrayList<>(stopCallbacks); stopCallbacks.clear(); stopDisarms = false;
                    record(error == null ? "suspended" : "teardown_failed", error == null ? new JSONObject() : BLEBackgroundProtocol.object("error", error));
                    for (CallbackContext reply : replies) { if (error == null) reply.success(status()); else reply.error(error); }
                });
                break;
            case "backgroundGetStatus": callback.success(status()); break;
            case "backgroundClearEvents": events.clear(); record("events_cleared", new JSONObject()); callback.success(status()); break;
            case "backgroundPreflight":
                if (!visible || configuration == null || !configuration.has("reporting")) throw new IllegalStateException("Configure reporting in the foreground first.");
                JSONObject reporting = configuration.getJSONObject("reporting");
                byte[] body = BLEBackgroundReporting.body(reporting, BLEBackgroundProtocol.object("event", "preflight"), "foreground");
                cordova.getThreadPool().execute(() -> {
                    try {
                        int code = BLEBackgroundReporting.send(BLEBackgroundReporting.request(reporting, body, url -> (java.net.HttpURLConnection)url.openConnection()), body);
                        if (code >= 200 && code < 300) callback.success(BLEBackgroundProtocol.object("statusCode", code)); else callback.error("HTTP " + code);
                    } catch (Exception error) { callback.error("Preflight failed: " + error.getClass().getSimpleName()); }
                });
                break;
            default: callback.sendPluginResult(new PluginResult(PluginResult.Status.INVALID_ACTION));
        }
    }
    @Override public void onRequestPermissionResult(int code, String[] permissions, int[] results) throws JSONException {
        if (code != PERMISSIONS) { super.onRequestPermissionResult(code, permissions, results); return; }
        main.post(() -> {
            if (startCallback == null) return;
            if (Build.VERSION.SDK_INT >= 31 && !cordova.hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) { cancelStart("Bluetooth permission is required."); return; }
            // Denied POST_NOTIFICATIONS does not prohibit an FGS; Android still shows Active apps.
            startService();
        });
    }
    private void startService() {
        if (!visible || startCallback == null || destroyed) { cancelStart("Start monitoring while the app is visible."); return; }
        CallbackContext request = startCallback;
        parent("isInitialized", new JSONObject(), (initialized, success) -> {
            if (startCallback != request) return;
            if (!success || !initialized.optBoolean("isInitialized")) { cancelStart("Initialize foreground Bluetooth before arming background monitoring."); return; }
            parent("isEnabled", new JSONObject(), (enabled, enabledOK) -> {
                if (startCallback != request) return;
                if (!enabledOK || !enabled.optBoolean("isEnabled")) { cancelStart("Enable Bluetooth before arming background monitoring."); return; }
                if (!visible || destroyed) { cancelStart("Start monitoring while the app is visible."); return; }
                if (service != null) { ownership.arm(); startCallback = null; request.success(status()); return; }
                launchService();
            });
        });
    }
    private void launchService() {
        if (!visible || startCallback == null || destroyed) { cancelStart("Start monitoring while the app is visible."); return; }
        if (bound) return;
        CallbackContext request = startCallback;
        try {
            Intent intent = new Intent(cordova.getContext(), BLEBackgroundService.class);
            cordova.getContext().startForegroundService(intent);
            bound = cordova.getContext().bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE);
            if (!bound) { cancelStart("Could not bind the foreground service."); return; }
            main.postDelayed(() -> { if (startCallback == request) cancelStart("Foreground service preparation timed out."); }, 10000);
        } catch (RuntimeException error) { cancelStart("Foreground service could not start: " + error.getClass().getSimpleName()); }
    }
    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((BLEBackgroundService.LocalBinder)binder).service();
            if (!visible || startCallback == null || destroyed || service.startupError != null) { cancelStart(service.startupError == null ? "Service preparation was interrupted." : service.startupError); return; }
            try {
                service.configure(configuration, BLEBackgroundPlugin.this);
                ownership.arm(); record("armed", new JSONObject());
                CallbackContext callback = startCallback; startCallback = null; callback.success(status());
            } catch (Exception error) { cancelStart("Native configuration failed: " + error.getMessage()); }
        }
        @Override public void onServiceDisconnected(ComponentName name) { service = null; ownership.armed = false; record("service_stopped", new JSONObject()); }
        @Override public void onBindingDied(ComponentName name) { onServiceDisconnected(name); }
    };
    private void cancelStart(String error) {
        if (startCallback == null) return;
        CallbackContext callback = startCallback; startCallback = null;
        ownership.armed = false; releaseService(); callback.error(error);
    }
    private void releaseService() {
        if (bound) { cordova.getContext().unbindService(serviceConnection); bound = false; }
        cordova.getContext().stopService(new Intent(cordova.getContext(), BLEBackgroundService.class)); service = null;
    }
    private interface ParentResult { void complete(JSONObject result, boolean success); }
    private void parent(String action, JSONObject parameters, ParentResult completion) {
        final boolean[] settledCallback = {false};
        CallbackContext callback = new CallbackContext("background-internal", webView) {
            @Override public void sendPluginResult(PluginResult result) { main.post(() -> {
                if (settledCallback[0]) return;
                JSONObject value;
                try { value = new JSONObject(result.getMessage()); } catch (JSONException error) { value = BLEBackgroundProtocol.object("error", "invalidParentResult"); }
                // Disconnect callbacks can remain open; only a confirmed disconnected result is useful.
                if (result.getStatus() == PluginResult.Status.OK.ordinal() && "disconnect".equals(action) && !"disconnected".equals(value.optString("status"))) return;
                settledCallback[0] = true; completion.complete(value, result.getStatus() == PluginResult.Status.OK.ordinal());
            }); }
        };
        main.postDelayed(() -> { if (!settledCallback[0]) { settledCallback[0] = true; completion.complete(BLEBackgroundProtocol.object("error", "parentTimeout"), false); } }, 6000);
        try { super.execute(action, new JSONArray().put(parameters), callback); }
        catch (Exception error) { if (!settledCallback[0]) { settledCallback[0] = true; completion.complete(BLEBackgroundProtocol.object("error", "parentException"), false); } }
    }
    private void retireConnections(BLEBackgroundProtocol.Done done) {
        callbackEpoch++;
        PluginResult interrupted = new PluginResult(PluginResult.Status.ERROR, BLEBackgroundProtocol.object("error", "backgroundOwnership", "message", "Foreground BLE callbacks retired for background handoff."));
        for (CallbackContext callback : foregroundCallbacks) callback.sendPluginResult(interrupted);
        foregroundCallbacks.clear();
        parent("stopScan", new JSONObject(), (result, success) -> {
            if (!success && !"stopScan".equals(result.optString("error"))) { done.complete("Could not stop the foreground BLE scan: " + result.optString("error")); return; }
            List<String> snapshot = new ArrayList<>(addresses);
            if (configuration != null && !snapshot.contains(configuration.optString("deviceId"))) snapshot.add(configuration.optString("deviceId"));
            retireNext(snapshot, 0, done);
        });
    }
    private void retireNext(List<String> snapshot, int index, BLEBackgroundProtocol.Done done) {
        if (index == snapshot.size()) { done.complete(null); return; }
        String address = snapshot.get(index); JSONObject parameters = BLEBackgroundProtocol.object("address", address);
        parent("disconnect", parameters, (result, success) -> {
            String error = result.optString("error");
            if (!success && "neverConnected".equals(error)) { addresses.remove(address); retireNext(snapshot, index + 1, done); return; }
            if (!success && !"isDisconnected".equals(error)) { done.complete("Foreground BLE disconnect failed: " + error); return; }
            parent("close", parameters, (closed, closedOK) -> {
                if (!closedOK && !"neverConnected".equals(closed.optString("error"))) { done.complete("Foreground BLE close failed: " + closed.optString("error")); return; }
                addresses.remove(address); retireNext(snapshot, index + 1, done);
            });
        });
    }
    @Override public void onPause(boolean multitasking) {
        visible = false; cancelStart("Backgrounding interrupted service preparation."); ownership.pause(); super.onPause(multitasking);
    }
    @Override public void onResume(boolean multitasking) {
        visible = true;
        ownership.suspend(false, error -> { if (error != null) record("teardown_failed", BLEBackgroundProtocol.object("error", error)); });
        super.onResume(multitasking);
    }
    @Override public void onReset() {
        cancelStart("WebView reset.");
        ownership.suspend(true, error -> { if (error == null) releaseService(); });
        super.onReset();
    }
    @Override public void onDestroy() {
        destroyed = true; cancelStart("Plugin destroyed.");
        ownership.suspend(true, error -> { if (error == null) releaseService(); });
        super.onDestroy();
    }
    @Override public String appState() { return visible ? "foreground" : "background"; }
    @Override public void record(String name, JSONObject details) {
        Log.i("BLEBackground", "event=" + name + " state=" + appState());
        if ("notification_repeated".equals(name)) return;
        JSONObject entry = BLEBackgroundProtocol.copy(details);
        try {
            entry.put("event", name).put("eventAt", Instant.now().toString()).put("eventAppState", appState());
            if (configuration != null && !entry.has("deviceId")) entry.put("deviceId", configuration.optString("deviceId"));
        } catch (JSONException error) { throw new IllegalStateException(error); }
        events.add(entry);
        int max = configuration == null ? 100 : configuration.optInt("maxEvents", 100);
        while (events.size() > max) events.remove(0);
        persistEvents();
    }
    private void persistEvents() {
        byte[] snapshot = new JSONArray(events).toString().getBytes(StandardCharsets.UTF_8);
        // Disk flushes must not hold up an ACK on the BLE/main loop. Latest snapshots contain the full bounded history.
        logWriter.execute(() -> {
            FileOutputStream output = null;
            try { output = eventFile.startWrite(); output.write(snapshot); eventFile.finishWrite(output); }
            catch (IOException error) { if (output != null) eventFile.failWrite(output); Log.w("BLEBackground", "Could not persist event history."); }
        });
    }
}
