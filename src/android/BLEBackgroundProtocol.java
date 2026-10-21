package com.hme.bluetoothle.background;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Serialized by the host's main looper. No Android, device-family or backend dependency. */
public final class BLEBackgroundProtocol {
    public interface Done { void complete(String error); }
    public interface Host {
        void event(String name, JSONObject details);
        void write(byte[] bytes, int timeoutMs, Done completion);
        void deliver(JSONObject incident, Done completion);
    }
    private static final class Incident {
        String id = UUID.randomUUID().toString();
        long lastReceived;
        int attempts;
        boolean pending;
        JSONObject context;
    }
    private static final class Write {
        byte[] bytes;
        int timeout;
        Incident incident;
        JSONObject details;
    }
    public final JSONObject configuration;
    private final Host host;
    private final Map<String, Incident> incidents = new HashMap<>();
    private final ArrayDeque<Write> writes = new ArrayDeque<>();
    private byte[] pending = new byte[0];
    private boolean writing;

    public BLEBackgroundProtocol(JSONObject options, Host host) throws JSONException {
        configuration = validate(options);
        this.host = host;
    }
    static JSONObject object(Object... pairs) {
        JSONObject result = new JSONObject();
        try { for (int i = 0; i < pairs.length; i += 2) result.put((String)pairs[i], pairs[i + 1]); }
        catch (JSONException e) { throw new IllegalArgumentException(e); }
        return result;
    }
    static JSONObject copy(JSONObject value) {
        try { return new JSONObject(value.toString()); }
        catch (JSONException e) { throw new IllegalArgumentException(e); }
    }
    private static void require(boolean value, String message) throws JSONException {
        if (!value) throw new JSONException(message);
    }
    private static int integer(JSONObject o, String key, int min, int max, int fallback) throws JSONException {
        if (!o.has(key)) { require(fallback >= min, key + " is required."); return fallback; }
        Object v = o.get(key);
        require(v instanceof Number && Double.isFinite(((Number)v).doubleValue()) &&
            ((Number)v).doubleValue() == ((Number)v).intValue() && ((Number)v).intValue() >= min &&
            ((Number)v).intValue() <= max, key + " must be an integer from " + min + " to " + max + ".");
        return ((Number)v).intValue();
    }
    private static void bytes(JSONArray values, int max) throws JSONException {
        require(values != null && values.length() > 0 && values.length() <= max, "Invalid byte array.");
        for (int i = 0; i < values.length(); i++) integer(object("byte", values.get(i)), "byte", 0, 255, -1);
    }
    public static UUID uuid(String value) {
        if (value.matches("(?i)[0-9a-f]{4}")) value = "0000" + value;
        if (value.matches("(?i)[0-9a-f]{8}")) value += "-0000-1000-8000-00805f9b34fb";
        if (!value.matches("(?i)[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")) throw new IllegalArgumentException("Invalid Bluetooth UUID.");
        return UUID.fromString(value);
    }
    public static JSONObject validate(JSONObject options) throws JSONException {
        require(options != null && options.toString().getBytes(StandardCharsets.UTF_8).length <= 65536, "Configuration must be at most 64 KiB.");
        JSONObject o = copy(options);
        require(o.opt("deviceId") instanceof String && o.getString("deviceId").matches("(?i)([0-9a-f]{2}:){5}[0-9a-f]{2}"), "deviceId must be an Android Bluetooth address.");
        o.put("deviceId", o.getString("deviceId").toUpperCase(Locale.US));
        for (String key : Arrays.asList("serviceUuid", "notifyCharacteristicUuid", "writeCharacteristicUuid")) {
            require(o.opt(key) instanceof String, key + " must be a Bluetooth UUID.");
            try { uuid(o.getString(key)); } catch (IllegalArgumentException e) { throw new JSONException(key + ": " + e.getMessage()); }
        }
        int length = integer(o, "packetLength", 1, 512, -1);
        require("none".equals(o.opt("checksum")) || "sum8".equals(o.opt("checksum")), "checksum must be sum8 or none.");
        require(!"sum8".equals(o.opt("checksum")) || length >= 2, "sum8 needs at least two bytes.");
        integer(o, "maxEvents", 10, 1000, 100);
        integer(o, "maxConnectionFailures", 1, 10, 3);
        require(!o.has("includePayload") || o.opt("includePayload") instanceof Boolean, "includePayload must be boolean.");
        require(!o.has("metadata") || o.opt("metadata") instanceof JSONObject, "metadata must be an object.");
        JSONArray rules = o.optJSONArray("rules");
        require(rules != null && rules.length() > 0 && rules.length() <= 16, "Provide 1–16 rules.");
        Set<String> ids = new HashSet<>();
        for (int i = 0; i < rules.length(); i++) {
            JSONObject rule = rules.getJSONObject(i);
            require(rule.opt("id") instanceof String && rule.getString("id").length() > 0 && rule.getString("id").length() <= 64 && ids.add(rule.getString("id")), "Rule IDs must be unique strings of 1–64 characters.");
            JSONObject match = rule.getJSONObject("match");
            int offset = integer(match, "offset", 0, length - 1, -1);
            JSONArray values = match.optJSONArray("bytes"); bytes(values, length);
            require(offset + values.length() <= length, "Match extends past packet.");
            if (match.has("mask")) { bytes(match.optJSONArray("mask"), length); require(match.getJSONArray("mask").length() == values.length(), "Mask length must match bytes."); }
            integer(rule, "quietPeriodMs", 100, 300000, 5000);
            JSONObject ack = rule.getJSONObject("acknowledgement");
            require(Arrays.asList("none", "echo", "fixed").contains(ack.opt("mode")), "Invalid acknowledgement mode.");
            if ("fixed".equals(ack.opt("mode"))) bytes(ack.optJSONArray("bytes"), 512);
            integer(ack, "maxAttempts", 1, 10, 3); integer(ack, "timeoutMs", 100, 30000, 3000);
        }
        if (o.has("android")) {
            JSONObject android = o.getJSONObject("android");
            for (String key : Arrays.asList("notificationTitle", "notificationText"))
                require(!android.has(key) || android.opt(key) instanceof String && android.getString(key).length() > 0 && android.getString(key).length() <= 200, key + " must be a string of 1–200 characters.");
        }
        if (o.has("reporting")) {
            JSONObject r = o.getJSONObject("reporting");
            require(!r.has("allowInsecureHttp") || r.opt("allowInsecureHttp") instanceof Boolean, "allowInsecureHttp must be boolean.");
            try {
                URI uri = new URI(r.getString("url"));
                require(("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme()) && r.optBoolean("allowInsecureHttp")) &&
                    uri.getHost() != null && uri.getUserInfo() == null && uri.getFragment() == null, "Use HTTPS, or explicitly allow HTTP; no embedded credentials or fragment.");
            } catch (java.net.URISyntaxException e) { throw new JSONException("Invalid reporting URL."); }
            integer(r, "timeoutMs", 100, 30000, 8000);
            require(!r.has("body") || r.opt("body") instanceof JSONObject, "reporting.body must be a JSON object.");
            if (r.has("headers")) {
                JSONObject h = r.getJSONObject("headers");
                Iterator<String> keys = h.keys();
                while (keys.hasNext()) {
                    String key = keys.next(); Object value = h.get(key);
                    require(key.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+") && value instanceof String && !((String)value).contains("\r") && !((String)value).contains("\n"), "Headers must be plain strings without newlines.");
                }
            }
        }
        return o;
    }
    public void resetStream() { pending = new byte[0]; }
    private boolean matches(JSONObject rule, byte[] frame) throws JSONException {
        JSONObject m = rule.getJSONObject("match"); JSONArray values = m.getJSONArray("bytes"), mask = m.optJSONArray("mask");
        for (int i = 0; i < values.length(); i++) {
            int bits = mask == null ? 255 : mask.getInt(i);
            if ((frame[m.getInt("offset") + i] & bits) != (values.getInt(i) & bits)) return false;
        }
        return true;
    }
    public void receive(byte[] data, long now, String device, UUID service, UUID characteristic, JSONObject context) {
        if (!configuration.optString("deviceId").equalsIgnoreCase(device) || !uuid(configuration.optString("serviceUuid")).equals(service) ||
            !uuid(configuration.optString("notifyCharacteristicUuid")).equals(characteristic)) {
            host.event("packet_rejected", object("reason", "context")); return;
        }
        int length = configuration.optInt("packetLength");
        // Buffer at most one incomplete frame; process arbitrarily concatenated notifications.
        int position = 0;
        while (position < data.length) {
            int count = Math.min(length - pending.length, data.length - position);
            byte[] next = Arrays.copyOf(pending, pending.length + count);
            System.arraycopy(data, position, next, pending.length, count); position += count; pending = next;
            if (pending.length != length) continue;
            byte[] frame = pending; pending = new byte[0];
            int sum = 0; for (int i = 0; i < length - 1; i++) sum += frame[i] & 255;
            if ("sum8".equals(configuration.optString("checksum")) && (sum & 255) != (frame[length - 1] & 255)) {
                host.event("packet_rejected", object("reason", "checksum")); continue;
            }
            try {
                JSONArray rules = configuration.getJSONArray("rules");
                for (int i = 0; i < rules.length(); i++) {
                    JSONObject rule = rules.getJSONObject(i);
                    if (matches(rule, frame)) { accept(rule, frame, now, context); break; }
                }
            } catch (JSONException e) { throw new IllegalStateException(e); }
        }
    }
    private void accept(JSONObject rule, byte[] frame, long now, JSONObject context) throws JSONException {
        String id = rule.getString("id"); Incident old = incidents.get(id);
        boolean fresh = old == null || now - old.lastReceived >= rule.optInt("quietPeriodMs", 5000) && !old.pending;
        final Incident incident = fresh ? new Incident() : old;
        if (fresh) { incident.context = copy(context); incidents.put(id, incident); }
        incident.lastReceived = now;
        JSONObject details = copy(incident.context);
        details.put("deviceId", configuration.getString("deviceId")).put("ruleId", id).put("incidentId", incident.id);
        if (configuration.has("metadata")) details.put("metadata", configuration.getJSONObject("metadata"));
        if (configuration.optBoolean("includePayload")) { JSONArray payload = new JSONArray(); for (byte b : frame) payload.put(b & 255); details.put("payload", payload); }
        host.event(fresh ? "notification_received" : "notification_repeated", details);
        JSONObject ack = rule.getJSONObject("acknowledgement");
        if (!"none".equals(ack.getString("mode")) && !incident.pending && incident.attempts < ack.optInt("maxAttempts", 3)) {
            incident.pending = true; incident.attempts++;
            Write job = new Write(); job.bytes = frame.clone(); job.incident = incident;
            if ("fixed".equals(ack.getString("mode"))) { JSONArray values = ack.getJSONArray("bytes"); job.bytes = new byte[values.length()]; for (int i = 0; i < values.length(); i++) job.bytes[i] = (byte)values.getInt(i); }
            job.timeout = ack.optInt("timeoutMs", 3000); job.details = copy(details); job.details.put("attempt", incident.attempts);
            host.event("acknowledgement_queued", job.details); writes.add(job); pump();
        }
        if (fresh) {
            if (configuration.has("reporting")) {
                host.event("delivery_started", details);
                final boolean[] completed = {false};
                host.deliver(copy(details), error -> { if (completed[0]) return; completed[0] = true;
                    JSONObject result = copy(details); if (error != null) result = withError(result, error);
                    host.event(error == null ? "delivery_succeeded" : "delivery_failed", result);
                });
            } else host.event("delivery_skipped", details);
        }
    }
    static JSONObject withError(JSONObject value, String error) {
        JSONObject result = copy(value); try { result.put("error", error); } catch (JSONException e) { throw new IllegalStateException(e); } return result;
    }
    private void pump() {
        if (writing || writes.isEmpty()) return;
        writing = true; Write job = writes.peek(); final boolean[] completed = {false};
        host.event("acknowledgement_started", job.details);
        host.write(job.bytes.clone(), job.timeout, error -> {
            if (completed[0]) return; completed[0] = true; job.incident.pending = false;
            host.event(error == null ? "acknowledgement_written" : "acknowledgement_failed", error == null ? job.details : withError(job.details, error));
            writes.remove(); writing = false; pump();
        });
    }
}
