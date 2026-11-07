# Changelog

## 0.3.0 — iOS native recovery (unpublished)

- Add native launch bootstrap and a process-wide Cordova/shared-manager instance with a stable Core Bluetooth restoration identifier.
- Recreate the shared central from valid armed recovery on scene-based launches with nil/empty launch options; retain native ownership during inactive recovery and await settled early-manager state before foreground initialization.
- Persist successful ACK completion so later alerts after the quiet interval receive a new incident/HTTP claim across relaunch, while unresolved and immediate repeated packets remain deduplicated. Explicit disable/reconfigure resets the previous ledger.
- Defer restored scan/peripheral cleanup until powered-on state so disabled SOS cannot leave a rejected orphan connection cancellation. Protect foreground handoff from late inactive restoration and record foreground scan/discovery checkpoints.
- Restore matching peripheral delegates, cached GATT state, pending connections and subscriptions; gate duplicate discovery/subscription requests and protect native ownership from cold background WebView startup.
- Add opt-in device-only Keychain configuration/incident recovery, account and credential-expiry scoping, disable/logout revocation, and durable at-most-once local submission claims with bounded ACK attempts across relaunch.
- Expose iOS session synchronization and shared-manager quiescence for a separate AccessorySetupKit integration. No AccessorySetupKit or device-specific configuration is embedded in this plugin.
- Add mocked native restoration/ownership and recovery-policy tests. Android source and configuration are unchanged. Physical relaunch validation remains pending.


## 0.2.0 — Android background monitoring

- Add Android native configurable framing, incident deduplication, serialized bounded ACK writes, and one HTTP POST per incident with the existing JavaScript API. Keep all iOS native sources unchanged.
- Start a connectedDevice foreground service while the host is visible; native lifecycle transitions activate background monitoring and await teardown before releasing foreground ownership.
- Integrate through a documented public parent-plugin subclass and generated registration helper, using public disconnect/close actions only. No parent source patch or private-state reflection.
- Accept Android Bluetooth addresses and provide optional generic notification wording. Request Bluetooth connection permission and handle notification denial independently.
- Retain exact prepared JSON body/headers, reject custom-body preflight without sending, disable redirects, and keep delivery outcomes separate from BLE ACK success.
- Add JVM protocol/ownership/mocked HTTP tests and Android Cordova/Capacitor setup tests. No automatic force-stop, reboot or process-death restoration; no physical Android validation yet.

## 0.1.1

- Add optional `reporting.body` for an app-prepared JSON object sent as the complete native POST body, using the existing URL, headers and timeout configuration.
- Preserve the incident envelope when no custom body is configured, and retain independent acknowledgement, incident deduplication and delivery outcome events.
- Reject preflight without sending when a custom body is configured, avoiding actions caused by a connectivity-test POST.
- Validate and snapshot the body with the configuration; keep request bodies and headers out of event history.
- Add native request-construction tests, custom-body regression checks and TypeScript coverage. No device-specific API or recipient is embedded.

## 0.1.0

- Initial iOS companion for `cordova-plugin-bluetoothle` 6.7.4.
- Configurable fixed-length packet matching, optional sum8 validation, and echo/fixed/no acknowledgement.
- Native background handoff using the parent's existing Bluetooth manager.
- Per-rule incident deduplication, serialized bounded acknowledgement attempts, and optional HTTPS reporting.
- Persistent event history, JavaScript Promise API, TypeScript definitions, and Cordova/Capacitor configuration scripts.
- Background execution only. Android and process restoration are outside this version.
