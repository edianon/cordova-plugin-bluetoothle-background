# Validation

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
