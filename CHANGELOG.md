# Changelog

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
