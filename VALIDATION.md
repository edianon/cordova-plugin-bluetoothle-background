# 0.3.0 iOS recovery — 2026-10-28

User subsequently confirmed **dashboard scan results and BP-watch detection/connection with SOS still OFF** on the foreground-cleanup correction below. Scanning no longer depends on enabling SOS. Actual measurements and SOS regression after that cleanup change remain separate checks; unapproved other devices still require ASK authorization.

Foreground scanning follow-up: **363 native checks passed** (220 protocol,31 HTTP,13 recovery policy,99 restoration/ownership). The mocked central rejects commands before powered-on, exercising delayed restored scan/orphan cleanup and foreground handoff, no repeated cancellations, no interruption of a later foreground scan, discovery forwarding to the original parent, and no ownership reclamation from a late inactive restoration callback after foreground entry. iOS sync/signed build/install passed. Physical PID5242 with recovery disabled requested one restored peripheral/scan cleanup after powered-on, then recorded scanning=true, delegate attached, zero pending cleanup and a real discovery callback at2026-10-28T01:22:05Z. Dashboard/watch connection confirmation is still pending. Evidence: `/private/tmp/urion-ios-foreground-scan-checkpoint.json`. ASK's authorized-device-only scan model is an independent host integration limitation.

**Latest physical result:** one complete user swipe-away run passed on iPhone 15 / iOS 27.0.1 with the corrected incident build. User toggled OFF/ON once to clear legacy state, backgrounded PID4809, then swiped away; absence was confirmed before user SOS. Replacement PID4814 logged native startup with no legacy hint, matched restoration/subscription, new incident `830FA940-359B-46B0-8A21-58919C30223A`, ACK attempt1, one HTTP start at 2026-10-27T23:45:18Z and HTTP success at 23:45:19Z. The user independently confirmed ACK and a new message on the existing server. Evidence is saved in `/private/tmp/urion-ios-incident-swipe-baseline.json` and `/private/tmp/urion-ios-incident-swipe-success.json`. Agent only read device logs/process state. Repeated later alerts across relaunch without resetting, measurements, OS termination/crash/reboot and other failure cases still require separate device checks. This single success is not a universal guarantee.

Physical scene-based launch test: user backgrounded Smarthealth, swiped it away, and triggered watch SOS after the process was confirmed absent. A new process (4802) recorded native startup without a legacy Bluetooth hint, matching restored accessory/subscription and ACK written. The user confirmed the watch acknowledged; no new server message appeared. Logs show that no HTTP was attempted because the old incident ID from a prior successful background delivery was reused. This validates that single launch/restoration/ACK sequence, not complete swipe-away delivery.

Incident completion follow-up: **352 native checks passed** (220 packet/incident, 31 HTTP, 13 policy, 88 restoration/ownership). Successful ACK completion is persisted. Tests cover later alerts after completed ACK with previous HTTP success/failure/unknown, immediate retransmission suppression across repeated relaunch, fresh ACK budgets, unresolved/legacy claims, uptime reset, completion-save failure, invalid markers, production native write callback persistence and deliberate disable/reconfigure reset. All new automated effects use mocks. The subsequent end-to-end physical result is recorded above. Android implementation/configuration are unchanged.

Scene-based startup follow-up: **259 native checks passed** (133 packet/incident, 31 HTTP, 13 recovery policy, 82 restoration/ownership), plus 12 Node tests and plugin TypeScript validation. The actual `+restoreAtLaunch:` entry is covered with nil/empty options, valid/disabled/expired/missing/mismatched-account snapshots, disarmed pending setup, legacy orphan cleanup, background/inactive native ACK and mocked delivery, reconnect/subscription recovery, single-manager reuse and foreground handoff. Early-manager initialization waits through unknown/resetting and transient powered-off; stable disabled behavior remains. Native effects are mocked; physical swipe-away reception remains unverified. This supersedes the older native counts below.

Unpublished local integration with Smarthealth. Verified against BluetoothLE 6.7.4, Capacitor iOS 6.2.1 and Xcode 27.1/iPhoneOS 27.1 SDK. User's intended physical-test OS: iOS 27.0.1.

- **204 native checks**: 133 framing/checksum/incident/ACK checks, 31 HTTP construction checks, 13 recovery-policy checks, 27 restoration/ownership checks. The restoration harness executes the production `BLEBackgroundPlugin.m` with mocked UIKit/Bluetooth/HTTP/Keychain objects. No physical Bluetooth or actual Keychain operations are exercised by those tests.
- Native cases cover cached subscribed peripherals, missing services/characteristics/subscriptions, pending connections, duplicate subscription gating, delegate binding before values, matching packets/identical ACK, independent HTTP failure, claims and ACK budget spanning process death, corrupt ledger, failed persistence, disabled/expired/different-account rejection, logout, WebView reset and late background-JS suspension rejection.
- **12 background-plugin Node tests**, **2 AccessorySetupKit bridge tests**, and **5 host setup-hook tests** pass. Plugin/app/spec types and production web build pass.
- Host authentication/lease/preference tests use synthetic credentials and mocked native bridges. The host has 93 passing focused tests; its build evidence is recorded in `smartcare2026/docs/urion-sos-background.md`.
- Unsigned arm64 iOS host compilation passes. Existing Pods target iOS 13; the command uses `IPHONEOS_DEPLOYMENT_TARGET=17.6`, matching the app's existing target. No deployment-target source change or signed install is performed.
- Generated native source copies match the local plugin sources. Android source/generated configuration are unchanged against the pre-task file hashes.

No real SOS, support ticket, emergency recipient, or test HTTP endpoint was contacted. The AccessorySetupKit picker/migration, actual Keychain recovery, OS background launch, user swipe-away relaunch, and foreground measurement regression require physical validation. At-most-once local claims can lose delivery if the process dies before POST; interrupted POST outcomes remain unknown. No backend idempotency, durable retry queue or exactly-once guarantee is claimed. See the host's coordinated test matrix and the README for Apple's eligibility conditions.

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

## Device startup follow-up — 2026-10-28

The host now persists its existing iOS 17.6 minimum across the Podfile/project/Pods, and a signed build passes without a command-line deployment override. Installed and launched on iPhone 15 / iOS 27.0.1; dashboard and running process verified. An empty optional company-identifier list caused ASK session initialization to terminate the first launch; the host now omits that unused key and the ASK plugin guards empty declarations. Nine host setup tests pass. No SOS or physical relaunch test was performed; those are left to the user. See the host documentation for details.
