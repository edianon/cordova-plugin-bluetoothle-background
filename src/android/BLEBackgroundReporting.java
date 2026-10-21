package com.hme.bluetoothle.background;

import org.json.JSONObject;
import org.json.JSONException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Iterator;

/** One POST, no redirects, automatic retries, response logging or payload augmentation. */
public final class BLEBackgroundReporting {
    public interface Transport { HttpURLConnection open(URL url) throws Exception; }
    public static byte[] body(JSONObject reporting, JSONObject incident, String appState) throws JSONException {
        if (reporting.has("body")) {
            if ("preflight".equals(incident.optString("event"))) throw new JSONException("Preflight is unavailable with reporting.body; it could perform the configured action.");
            return reporting.getJSONObject("body").toString().getBytes(StandardCharsets.UTF_8);
        }
        JSONObject envelope = BLEBackgroundProtocol.copy(incident);
        if (!envelope.has("event")) envelope.put("event", "notification_received");
        envelope.put("sentAt", Instant.now().toString()).put("sentAppState", appState);
        return envelope.toString().getBytes(StandardCharsets.UTF_8);
    }
    public static HttpURLConnection request(JSONObject reporting, byte[] body, Transport transport) throws Exception {
        HttpURLConnection connection = transport.open(new URL(reporting.getString("url")));
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(reporting.optInt("timeoutMs", 8000));
        connection.setReadTimeout(reporting.optInt("timeoutMs", 8000));
        connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setUseCaches(false);
        connection.setRequestProperty("Content-Type", "application/json");
        JSONObject headers = reporting.optJSONObject("headers");
        if (headers != null) { Iterator<String> keys = headers.keys(); while (keys.hasNext()) { String key = keys.next(); connection.setRequestProperty(key, headers.getString(key)); } }
        connection.setFixedLengthStreamingMode(body.length);
        return connection;
    }
    public static int send(HttpURLConnection connection, byte[] body) throws Exception {
        try {
            try (OutputStream stream = connection.getOutputStream()) { stream.write(body); }
            int code = connection.getResponseCode();
            // Do not consume or log potentially sensitive/unbounded response bodies.
            InputStream response = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (response != null) response.close();
            return code;
        } finally { connection.disconnect(); }
    }
}
