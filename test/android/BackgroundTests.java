package com.hme.bluetoothle.background;

import org.json.*;
import java.util.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Deterministic JVM tests: synthetic BLE, controllable completions and mocked HTTP only. */
public final class BackgroundTests {
    private static int checks;
    private static final String DEVICE = "01:02:03:04:05:06";
    private static final UUID SERVICE = BLEBackgroundProtocol.uuid("AB00"), NOTIFY = BLEBackgroundProtocol.uuid("AB01");
    private static void check(boolean condition, String message) { checks++; if (!condition) throw new AssertionError(message); }
    private static JSONObject obj(Object... pairs) { return BLEBackgroundProtocol.object(pairs); }
    private static byte[] sos() { byte[] frame = new byte[16]; frame[0] = 0x51; frame[15] = 0x51; return frame; }
    private static JSONArray array(byte[] bytes) { JSONArray result = new JSONArray(); for (byte b : bytes) result.put(b & 255); return result; }
    private static JSONObject config() {
        return obj("deviceId", DEVICE, "serviceUuid", "AB00", "notifyCharacteristicUuid", "AB01", "writeCharacteristicUuid", "AB02",
            "packetLength", 16, "checksum", "sum8", "includePayload", true,
            "rules", new JSONArray().put(obj("id", "sos", "match", obj("offset", 0, "bytes", array(sos())), "quietPeriodMs", 10000,
                "acknowledgement", obj("mode", "echo", "maxAttempts", 3, "timeoutMs", 3000))),
            "reporting", obj("url", "https://example.invalid/actions", "headers", obj("x-auth-token", "mock-token", "CLIENT-ID", "test-client"),
                "body", obj("subject", "Test", "nested", obj("a", false), "attachment", JSONObject.NULL)));
    }
    private static final class Fake implements BLEBackgroundProtocol.Host {
        final List<String> events = new ArrayList<>(); final List<JSONObject> details = new ArrayList<>();
        final List<byte[]> writes = new ArrayList<>(); final List<BLEBackgroundProtocol.Done> ack = new ArrayList<>(), deliveries = new ArrayList<>();
        int activeWrites, maxActive;
        @Override public void event(String name, JSONObject value) { events.add(name); details.add(BLEBackgroundProtocol.copy(value)); }
        @Override public void write(byte[] bytes, int timeout, BLEBackgroundProtocol.Done done) {
            check(timeout == 3000, "ACK timeout"); writes.add(bytes); activeWrites++; maxActive = Math.max(maxActive, activeWrites);
            ack.add(error -> { activeWrites--; done.complete(error); });
        }
        @Override public void deliver(JSONObject incident, BLEBackgroundProtocol.Done done) { deliveries.add(done); }
        int count(String event) { return Collections.frequency(events, event); }
    }
    private static void receive(BLEBackgroundProtocol engine, byte[] bytes, long time) {
        engine.receive(bytes, time, DEVICE, SERVICE, NOTIFY, obj("receivedAt", "synthetic", "receivedAppState", "background"));
    }
    private static void invalid(JSONObject value, String message) {
        try { BLEBackgroundProtocol.validate(value); throw new AssertionError("Accepted " + message); }
        catch (JSONException expected) { checks++; }
    }
    private static void protocol() throws Exception {
        for (int split = 1; split < 16; split++) {
            Fake host = new Fake(); BLEBackgroundProtocol engine = new BLEBackgroundProtocol(config(), host);
            receive(engine, Arrays.copyOfRange(sos(), 0, split), 0);
            check(host.writes.isEmpty() && host.deliveries.isEmpty(), "Incomplete frame not accepted");
            receive(engine, Arrays.copyOfRange(sos(), split, 16), 1);
            check(host.writes.size() == 1 && Arrays.equals(host.writes.get(0), sos()), "Correct fragmented ACK");
            check(host.deliveries.size() == 1 && host.count("acknowledgement_written") == 0, "ACK and delivery independent");
            host.deliveries.get(0).complete("HTTP 500");
            check(host.count("delivery_failed") == 1 && host.count("acknowledgement_written") == 0, "Delivery failure does not complete BLE");
            host.ack.get(0).complete(null);
            check(host.count("acknowledgement_written") == 1, "BLE success after failed HTTP");
        }
        Fake host = new Fake(); BLEBackgroundProtocol engine = new BLEBackgroundProtocol(config(), host);
        byte[] combined = new byte[48]; System.arraycopy(sos(), 0, combined, 0, 16);
        byte[] command = new byte[16]; command[0] = 0x14; command[15] = 0x14;
        System.arraycopy(command, 0, combined, 16, 16); System.arraycopy(sos(), 0, combined, 32, 16);
        receive(engine, combined, 0);
        check(host.count("notification_received") == 1 && host.count("notification_repeated") == 1, "Concatenation and command separation");
        check(host.writes.size() == 1 && host.deliveries.size() == 1, "No overlapping ACK or duplicate POST");
        host.ack.get(0).complete("timeout");
        receive(engine, sos(), 1000); host.ack.get(1).complete("failure");
        receive(engine, sos(), 2000); host.ack.get(2).complete(null);
        for (int i = 3; i < 30; i++) receive(engine, sos(), i * 1000L);
        check(host.writes.size() == 3 && host.deliveries.size() == 1, "Bounded retransmission-driven ACK retries");
        check(host.maxActive == 1, "Only one ACK write active");
        receive(engine, sos(), 39000);
        check(host.writes.size() == 4 && host.deliveries.size() == 2, "Later separate incident accepted after sliding quiet period");
        receive(engine, sos(), 60000);
        check(host.deliveries.size() == 2, "Pending ACK prevents new incident despite silence");
        host.ack.get(3).complete(null);
        host.deliveries.get(0).complete(null);
        host.deliveries.get(0).complete("duplicate callback");
        check(host.count("delivery_succeeded") == 1 && host.count("delivery_failed") == 0, "Delivery completion exactly once");
        String first = host.details.get(host.events.indexOf("notification_received")).getString("incidentId");
        String later = host.details.get(host.events.lastIndexOf("notification_received")).getString("incidentId");
        check(!first.equals(later), "Independent local incident IDs");

        host = new Fake(); engine = new BLEBackgroundProtocol(config(), host);
        byte[] corrupted = sos(); corrupted[15] = 0;
        receive(engine, corrupted, 0);
        engine.receive(sos(), 0, "11:22:33:44:55:66", SERVICE, NOTIFY, obj());
        engine.receive(sos(), 0, DEVICE, BLEBackgroundProtocol.uuid("FFFF"), NOTIFY, obj());
        engine.receive(sos(), 0, DEVICE, SERVICE, BLEBackgroundProtocol.uuid("AB02"), obj());
        check(host.writes.isEmpty() && host.deliveries.isEmpty() && host.count("packet_rejected") == 4, "Checksum/device/service/characteristic rejection");
        receive(engine, Arrays.copyOfRange(sos(), 0, 8), 1); engine.resetStream();
        receive(engine, sos(), 2);
        check(host.writes.size() == 1, "Disconnect resets partial stream");

        invalid(obj(), "missing configuration");
        invalid(config().put("deviceId", "F8067739-AB01-4624-8994-000000000001"), "iOS UUID on Android");
        invalid(config().put("serviceUuid", "bad"), "invalid GATT UUID");
        invalid(config().put("packetLength", 1), "sum8 one-byte packet");
        invalid(config().put("packetLength", 16.5), "fractional packet length");
        invalid(config().put("includePayload", "true"), "nonboolean option");
        invalid(config().put("reporting", obj("url", "https://user:pass@example.invalid/a")), "URL credentials");
        invalid(config().put("reporting", obj("url", "http://example.invalid/a")), "implicit HTTP");
        invalid(config().put("reporting", obj("url", "https://example.invalid/a", "body", "{}")), "serialized body");
        invalid(config().put("reporting", obj("url", "https://example.invalid/a", "headers", obj("x", "a\r\nb"))), "header injection");
        JSONObject overrun = config(); overrun.getJSONArray("rules").getJSONObject(0).getJSONObject("match").put("offset", 1); invalid(overrun, "match overrun");
        JSONObject duplicate = config(); duplicate.getJSONArray("rules").put(duplicate.getJSONArray("rules").getJSONObject(0)); invalid(duplicate, "duplicate rule IDs");
        check(BLEBackgroundProtocol.uuid("180A").equals(BLEBackgroundProtocol.uuid("0000180a-0000-1000-8000-00805f9b34fb")), "Short/full UUID equivalence");
        // Two configured rules queue independent ACKs through the same serialized writer.
        JSONObject multi = config();
        JSONObject rule = BLEBackgroundProtocol.copy(multi.getJSONArray("rules").getJSONObject(0));
        rule.put("id", "other").getJSONObject("match").put("bytes", array(command)); multi.getJSONArray("rules").put(rule);
        host = new Fake(); engine = new BLEBackgroundProtocol(multi, host);
        receive(engine, sos(), 0); receive(engine, command, 0);
        check(host.writes.size() == 1 && host.deliveries.size() == 2, "Multiple rules share write queue");
        host.ack.get(0).complete(null);
        check(host.writes.size() == 2 && Arrays.equals(host.writes.get(1), command) && host.maxActive == 1, "Queued ACK advances after completion only");

        JSONObject fixed = config(); fixed.getJSONArray("rules").getJSONObject(0).getJSONObject("acknowledgement").put("mode", "fixed").put("bytes", new JSONArray().put(0x42).put(0x42));
        host = new Fake(); engine = new BLEBackgroundProtocol(fixed, host); receive(engine, sos(), 0);
        check(Arrays.equals(host.writes.get(0), new byte[]{0x42, 0x42}), "Generic fixed ACK sent unchanged");
        JSONObject noAck = config(); noAck.getJSONArray("rules").getJSONObject(0).getJSONObject("acknowledgement").put("mode", "none");
        host = new Fake(); engine = new BLEBackgroundProtocol(noAck, host); receive(engine, sos(), 0); receive(engine, sos(), 1000);
        check(host.writes.isEmpty() && host.deliveries.size() == 1, "Explicit no-ACK mode retains incident deduplication");
        JSONObject masked = config(); masked.put("checksum", "none");
        masked.getJSONArray("rules").getJSONObject(0).put("match", obj("offset", 0, "bytes", new JSONArray().put(0x50), "mask", new JSONArray().put(0xf0)));
        host = new Fake(); engine = new BLEBackgroundProtocol(masked, host); receive(engine, corrupted, 0);
        check(host.writes.size() == 1, "Explicit no-checksum and masked matching supported");
        JSONObject snapshot = config(); host = new Fake(); engine = new BLEBackgroundProtocol(snapshot, host);
        snapshot.put("deviceId", "11:22:33:44:55:66"); snapshot.getJSONObject("reporting").put("body", obj("changed", true));
        receive(engine, sos(), 0);
        check(host.deliveries.size() == 1 && !engine.configuration.getJSONObject("reporting").getJSONObject("body").has("changed"), "Deep configuration snapshot");
        check(host.details.stream().noneMatch(value -> value.toString().contains("mock-token") || value.has("headers") || value.has("body")), "Request headers/body absent from events");
    }
    private static final class OwnerHost implements BLEBackgroundOwnership.Host {
        final List<BLEBackgroundProtocol.Done> retire = new ArrayList<>(), stop = new ArrayList<>();
        int connects, failures;
        @Override public void retireParent(BLEBackgroundProtocol.Done done) { retire.add(done); }
        @Override public void connectNative() { connects++; }
        @Override public void stopNative(BLEBackgroundProtocol.Done done) { stop.add(done); }
        @Override public void failure(String error) { failures++; }
    }
    private static void ownership() {
        OwnerHost host = new OwnerHost(); BLEBackgroundOwnership owner = new BLEBackgroundOwnership(host);
        owner.pause(); check(host.retire.isEmpty(), "Disabled pause does not take ownership");
        owner.arm(); check(host.connects == 0, "Foreground arming leaves measurement connection alone");
        owner.pause(); check(owner.ownsBluetooth && host.connects == 0, "Gate acquired before retirement");
        host.retire.get(0).complete(null); check(host.connects == 1, "Connect only after parent retired");
        final List<String> results = new ArrayList<>(); owner.suspend(false, results::add);
        check(owner.ownsBluetooth && owner.armed, "Keep gate held during asynchronous suspension");
        check(host.retire.size() == 1 && host.stop.size() == 1, "Successful handoff needs no parent operations at release, including when Bluetooth is disabled");
        host.stop.get(0).complete("close failed"); check(owner.ownsBluetooth && results.get(0) != null, "Failed close retains gate");
        owner.suspend(false, results::add); host.stop.get(1).complete(null);
        check(!owner.ownsBluetooth && owner.armed, "Retry releases gate, preserving next background arming");
        owner.pause(); host.retire.get(1).complete("disconnect timeout");
        check(owner.ownsBluetooth && host.connects == 1, "Handoff failure never competes with parent");
        owner.suspend(true, results::add); host.retire.get(2).complete(null); host.stop.get(2).complete(null);
        check(!owner.armed && !owner.ownsBluetooth, "Disarm releases ownership");

        host = new OwnerHost(); owner = new BLEBackgroundOwnership(host); owner.arm(); owner.pause();
        owner.suspend(false, results::add);
        owner.suspend(false, results::add);
        check(host.retire.size() == 1, "Resume coalesces pending retirement");
        host.retire.get(0).complete(null);
        check(host.connects == 0 && host.stop.size() == 1, "Resume cancels late background connect");
        owner.pause(); host.stop.get(0).complete(null);
        check(owner.ownsBluetooth && host.retire.size() == 2, "Rapid second pause waits for release then reacquires");
        host.retire.get(1).complete(null); check(host.connects == 1, "Rapid pause resumes safe monitoring");

        host = new OwnerHost(); owner = new BLEBackgroundOwnership(host); owner.arm(); owner.pause();
        owner.suspend(true, results::add); host.retire.get(0).complete("parent close failed");
        check(host.connects == 0 && host.stop.size() == 1 && !owner.armed, "Disarm stops native monitor even when parent retirement fails");
        host.stop.get(0).complete(null);
        check(owner.ownsBluetooth && results.get(results.size() - 1) != null, "Parent retirement failure cannot release foreground gate");
    }
    private static final class MockConnection extends HttpURLConnection {
        final ByteArrayOutputStream output = new ByteArrayOutputStream();
        final Map<String, String> headers = new HashMap<>();
        int code = 201; boolean disconnected;
        MockConnection(URL url) { super(url); }
        @Override public void disconnect() { disconnected = true; }
        @Override public boolean usingProxy() { return false; }
        @Override public void connect() { }
        @Override public void setRequestProperty(String key, String value) { headers.put(key, value); }
        @Override public OutputStream getOutputStream() { return output; }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(new byte[0]); }
        @Override public InputStream getErrorStream() { return getInputStream(); }
        @Override public int getResponseCode() { return code; }
    }
    private static void reporting() throws Exception {
        JSONObject r = config().getJSONObject("reporting");
        byte[] body = BLEBackgroundReporting.body(r, obj("incidentId", "must-not-be-added"), "background");
        JSONObject sent = new JSONObject(new String(body, StandardCharsets.UTF_8));
        check(sent.similar(r.getJSONObject("body")) && !sent.has("incidentId") && sent.isNull("attachment"), "Exact custom body without injected fields");
        try { BLEBackgroundReporting.body(r, obj("event", "preflight"), "foreground"); throw new AssertionError("Preflight accepted"); } catch (JSONException expected) { checks++; }
        MockConnection connection = new MockConnection(new URL(r.getString("url")));
        BLEBackgroundReporting.request(r, body, url -> connection);
        check("POST".equals(connection.getRequestMethod()) && !connection.getInstanceFollowRedirects(), "POST with redirects disabled");
        check("mock-token".equals(connection.headers.get("x-auth-token")) && "test-client".equals(connection.headers.get("CLIENT-ID")), "Plain headers preserved");
        check(connection.getConnectTimeout() == 8000 && connection.getReadTimeout() == 8000, "HTTP timeouts configured");
        check(BLEBackgroundReporting.send(connection, body) == 201 && Arrays.equals(connection.output.toByteArray(), body) && connection.disconnected, "Mock HTTP success writes exact bytes and closes");
        MockConnection failed = new MockConnection(new URL(r.getString("url"))); failed.code = 503;
        BLEBackgroundReporting.request(r, body, url -> failed);
        check(BLEBackgroundReporting.send(failed, body) == 503 && failed.disconnected, "HTTP failure exposed without retries");
        JSONObject envelope = new JSONObject(new String(BLEBackgroundReporting.body(obj("url", r.getString("url")), obj("incidentId", "local"), "background"), StandardCharsets.UTF_8));
        check(envelope.has("sentAt") && "local".equals(envelope.getString("incidentId")), "Default envelope compatibility");
    }
    public static void main(String[] args) throws Exception {
        protocol(); ownership(); reporting();
        System.out.println(checks + " Android protocol/ownership/mocked HTTP checks passed; no Bluetooth or external requests.");
    }
}
