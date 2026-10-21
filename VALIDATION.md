# Validation

## 0.2.0 — Android implementation — 2026-10-21

| Check | Result |
| --- | --- |
| Android native protocol/ownership/HTTP | **154 checks passed** with synthetic BLE packets, controlled write/lifecycle callbacks and mocked HttpURLConnection; no Bluetooth or external requests. |
| iOS native regression | **101 protocol/incident + 31 HTTP construction checks passed**. All iOS native source files are unchanged. |
| Node bridge/installers | **11 tests passed**, covering Android and iOS registration, conflicts, repeatability, public bridge routing and custom bodies. |
| Plugin TypeScript definitions | Passed, including Android notification options and the unchanged iOS API. |
| Host Angular/Jasmine | **76 focused tests passed**, including Android MAC validation/version guard/start failure, preference restoration, Emergency controls and existing iOS/lease/parser behavior. |
| Host setup hooks | **5 tests passed**, including Android generation and iOS preservation. |
| Host TypeScript / production web build | App/spec checks and Angular production build passed; existing Sass/CommonJS warnings remain. |
| Android host builds | **Debug and unsigned minified release APK builds passed** with min SDK 26 and compile/target SDK 36. Release R8 retained the plugin/service names; the shrunk APK retained the notification icon. |
| Native package integration | All five generated Java sources exactly match this plugin, and generated parent Java matches the installed 6.7.4 parent. APK manifest declares the connectedDevice service and required permissions. |
| npm package contents | Dry run passed for local 0.2.0, including all Android sources/resource and setup helper. Nothing published. |

Android tests cover every split of the configured frame, concatenation with command responses, checksum and device/service/characteristic rejection, incident/retransmission deduplication, correct echo/fixed/no ACK, serialized writes, bounded retries, independent delivery failure/success, later incidents, masks, configuration snapshots, headers/body preservation, preflight rejection and redirects disabled. Ownership tests cover arming without foreground takeover, retirement before connection, teardown failure/retry, overlapping suspension, resume during handoff, rapid pause/resume and fail-closed retirement.

The host's old single-microtask storage test failed because its mocked storage write had not started when it tried to complete it. It now awaits an explicit write-start signal and verifies the save remains pending. Production GlobalService storage code was not changed.

No app-owned Java/Kotlin, parent source patch, brand/model branch, boot receiver, sticky restart, or process-restoration mechanism was added. No physical Android test, installation on a phone, real support POST or watch SOS was performed. Screen locking, prolonged idle, permission/adapter changes and foreground measurement after handoff still require coordinated device validation. Recents removal varies by device; force-stop/process-death/reboot recovery is not implemented. An ACK may dismiss the peripheral's alert even when delivery fails.

The host uses the unpublished sibling plugin through a local file dependency. No Git commit, GitHub push or npm publication was performed. Build logs are local to the integration workspace session; the host documentation records the integration and its changed-file inventory.

## 0.1.1 — 2026-10-20

| Check | Result |
| --- | --- |
| `npm test` | 9 Node tests passed, including forwarding plain URL/headers/body through the existing Cordova service without sending a request. |
| `npm run test:native` | 101 packet/incident checks and 31 native HTTP request-construction checks passed. Synthetic packets and mocked delivery only; no Bluetooth or network. |
| `npm run check:types` | Passed using TypeScript 5.6.3, including custom-body configuration and rejection of a serialized string body. |
| iOS native compile/link | All three Objective-C implementations compiled and linked into an arm64 iOS dynamic library using the iPhoneOS 27 SDK and existing BluetoothLE 6.7.4/Cordova frameworks built for iOS 17.6. Warnings treated as errors, excluding unused callback parameters, upstream deprecations and the existing implicit-self capture warning. This is not a host app build or archive. |
| `npm pack --dry-run` | Passed; package version 0.1.1 includes the new reporting header/implementation and updated types and documentation. |

New checks cover exact custom JSON object bodies (nested objects/arrays, null, booleans and unicode), no double encoding, URL/headers/timeouts, default-envelope compatibility, default preflight compatibility, custom-body preflight rejection before request creation, malformed/oversized body rejection, configuration snapshots, and keeping custom bodies/authentication headers out of event history. Existing acknowledgement independence, delivery failure, deduplication and later-incident checks run with custom-body reporting configured.

No application sources or installed plugin copies were changed during this update. No support ticket or other live request was sent. Physical iPhone testing of this version, live endpoint delivery, fresh Cordova/Capacitor installation and a complete host app build were not performed; these remain host validation steps after installing 0.1.1. The host must skip `preflight()` when supplying `reporting.body`.

## Initial 0.1.0 validation — 2026-10-20

The standalone package was checked separately from the existing host application. That application's native registration, sources and UI were not migrated or modified during this extraction.

| Check | Result |
| --- | --- |
| `npm test` | 8 Node tests passed: bridge routing/errors, registration preservation/conflicts/restore, plist modes, Cordova hook, CLI custom paths and Capacitor platform filtering. |
| `npm run test:native` | 91 checks passed against the actual Foundation packet/incident engine, with mock BLE writes and delivery. No hardware or network. |
| `npm run check:types` | Passed using TypeScript 5.6.3. The compiler was supplied from an existing local installation. |
| iOS source syntax | Passed for arm64/iOS 13 using the iPhoneOS 27 SDK, actual BluetoothLE 6.7.4 header and Cordova framework. |
| iOS native compile/link | Both new Objective-C implementations compiled and linked into an arm64 iOS dynamic library against existing BluetoothLE/Cordova frameworks built for iOS 17.6. Warnings treated as errors, excluding unused callback parameters and upstream Cordova deprecations. This is not a complete host app archive. |
| Capacitor integration fixture | A separate temporary Capacitor 6.2.1 CocoaPods-template host discovered both Cordova plugins. Two real `cap copy ios` runs regenerated config and ran the host post-copy hook successfully; registration remained `BLEBackgroundPlugin` and Info.plist contained `bluetooth-central`. No original app files were edited. |
| `npm pack --dry-run` | Passed; inspected package contents for standalone sources, types, hooks, documentation and generic examples. |

Native checks cover valid recognition, checksum rejection, fragmented/concatenated frames, unrelated commands, stream reset, one incident across retransmissions, exact echo and fixed acknowledgement bytes, acknowledgement failures/retry limits, later incidents, pending-write deduplication, serialized writes across rules, duplicate completion protection, masks/priority, explicit no-checksum/no-ack configuration, delivery failure without false success, optional payload/metadata and malformed configuration rejection.

Not performed: a complete fresh CocoaPods sync or Xcode app archive of the standalone package, Cordova end-to-end device installation, runtime native lifecycle fault injection, physical iPhone testing, Android testing, force-quit/reboot restoration, or any live endpoint delivery. Earlier tests of a host-specific implementation do not substitute for physical testing of this configurable package.

Before release, install this package in a test host without another custom Bluetooth subclass. Run the physical-device steps in the README, including foreground handoff, disconnection, Bluetooth toggling, acknowledgement failures and testing without the debugger. Keep external reporting disabled until a safe diagnostic endpoint is deliberately configured.
