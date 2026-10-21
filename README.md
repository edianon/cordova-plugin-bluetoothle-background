# cordova-plugin-bluetoothle-background

A native iOS and Android companion for **`cordova-plugin-bluetoothle` 6.7.4**. It handles configured BLE notifications, acknowledgements and HTTP reporting while the app is backgrounded. Foreground BLE continues through the original plugin. iOS reuses its Bluetooth manager; Android retires the parent's GATT clients before the foreground service opens its exclusive GATT client.

The app supplies the device UUID, GATT UUIDs, packet format, matching rules, acknowledgement bytes, retry limits, and optional HTTP destination. The package contains no device-specific protocol or recipient configuration.

This is an initial implementation. Automated protocol tests and native compile checks are available; the standalone package still needs physical iPhone testing in a host app before release.

## iOS behavior

1. Discover/connect to the chosen peripheral through the existing BluetoothLE plugin in the foreground. Initialize Bluetooth before arming this companion.
2. Call `configure(...)`, then `start()`. `start()` arms the next background session; it does not immediately take the foreground connection.
3. On entering the background, native code stops the parent's central scan and cancels **all** its existing central connections. It waits for disconnection callbacks, then connects the configured cached peripheral through that same central manager.
4. Native code discovers the configured service/characteristics and enables notifications. There is a reception gap during this handoff. `armed: true` does not mean notifications are ready; `monitoring: true` means they have been enabled.
5. Matching packets create incidents. Acknowledgement and optional reporting start independently. No JavaScript timer or network completion is needed to acknowledge the device.
6. Returning to the foreground automatically suspends native monitoring and cancels its connection. The app must **await `suspend()`** before restarting normal foreground BLE operations. Arming is retained for the next background transition. `stop()` also disarms.

Late foreground commands are rejected during native ownership. Takeover disconnects pending foreground requests rather than passing matched notifications into their response callbacks. The app should cancel its own pending transactions and reconnect loops on pause, and restart them only after `suspend()` resolves. A failed `suspend()` means ownership may still be retained; inspect status or retry before restarting foreground BLE.

Only one configured peripheral is monitored. This companion does not coexist with another custom subclass registered as `BluetoothLePlugin`, another background owner, or another BLE plugin trying to control the same peripheral. The original plugin source is not patched, forked or copied. Version 6.7.4 is deliberately pinned because the subclass uses its protected native connection state.

## Install in Cordova

From your app directory, with this repository alongside it:

```sh
cordova plugin add cordova-plugin-bluetoothle@6.7.4
cordova plugin add ../cordova-plugin-bluetoothle-background
cordova prepare ios
```

The iOS `after_prepare` hook changes only the generated `BluetoothLePlugin` registration to `BLEBackgroundPlugin` and ensures `UIBackgroundModes` includes `bluetooth-central`. Source files are installed by `plugin.xml`. Other background modes are preserved. The hook refuses to overwrite an existing custom native class.

Ensure the host app has an appropriate `NSBluetoothAlwaysUsageDescription` in its Info.plist. This package does not invent permission wording on the app's behalf. Rebuild the native app after installation; a web reload is insufficient.

## Install in Ionic/Capacitor

```sh
npm install --save-exact cordova-plugin-bluetoothle@6.7.4
npm install ../cordova-plugin-bluetoothle-background
npx cap sync ios
npx bluetoothle-background-configure
```

Capacitor includes Cordova sources in its generated native plugin target, but [does not run Cordova configuration hooks](https://capacitorjs.com/docs/plugins/cordova#variables-and-hooks). Keep the registration applied after **both copy and sync**, because each can regenerate `config.xml`. Add to the host app's `package.json`, preserving existing hook commands with `&&`:

```json
{
  "scripts": {
    "capacitor:copy:after": "bluetoothle-background-configure",
    "capacitor:sync:after": "bluetoothle-background-configure"
  }
}
```

The script skips other platforms when run as a Capacitor hook. Defaults are `ios/App/App/config.xml` and `ios/App/App/Info.plist`. For a renamed target or different layout:

```sh
npx bluetoothle-background-configure --config ios/Example/Example/config.xml --plist ios/Example/Example/Info.plist
```

Pass `--root path/to/app` when invoking outside the app directory. The script requires XML Info.plist format and validates both files before editing. It never edits Xcode project identifiers, networking exceptions, entitlements, or unrelated app source. Verify the final app target has Background Modes → Uses Bluetooth LE accessories enabled and Bluetooth permission wording.

The installer intentionally rejects an app already using a custom Bluetooth subclass. Migrate that integration first rather than running two background owners. Installation instructions assume Capacitor's CocoaPods integration; Swift Package Manager integration has not been verified.

## Android setup and behavior

Uses standard Android APIs across phone brands/models; there are no manufacturer checks or private device APIs. Requires Android API 26+ and a host compiling against SDK 34+ (the integration host uses min 26 and compile/target 36). All Java and Android resources live in this plugin. No host-owned Java/Kotlin or edits to the installed parent plugin are needed.

For Capacitor, install this package and run `npx cap sync android`. Add `bluetoothle-background-configure-android` to **both** `capacitor:copy:after` and `capacitor:sync:after`, preserving existing commands. Run it once after sync if hooks were not yet installed. It replaces only the generated `BluetoothLePlugin` android-package registration with `com.hme.bluetoothle.background.BLEBackgroundPlugin`; it rejects another custom subclass and parent versions other than 6.7.4. It skips iOS when `CAPACITOR_PLATFORM_NAME=ios`. Cordova's `after_prepare` applies the same registration automatically.

The plugin manifest supplies a non-exported `connectedDevice` service, foreground-service permissions, Bluetooth connection permission, notification permission, Internet permission, and a bounded partial-wake-lock permission. It supplies its own notification icon. No boot receiver, sticky service restart, background-location permission or battery-exemption request is added. Android background code connects to the configured Bluetooth address without scanning.

1. Initialize the existing parent Bluetooth plugin in the foreground. Supply the selected Android Bluetooth address and the same generic packet/rule/reporting options to `configure()`.
2. Call and **await `start()` while the app is visible**. It checks parent initialization and Bluetooth state, requests missing connection/notification permissions, starts and promotes the foreground service immediately, binds it and snapshots configuration in memory. The ongoing low-importance notification is present while armed, including foreground preparation. Optional `android.notificationTitle` / `android.notificationText` customize its wording. Denying notification permission does not falsely imply Bluetooth permission denial: Android may still run the service and show it in Active apps.
3. Native `onPause` acquires the ownership gate before any takeover. It invalidates old foreground callbacks, rejects subsequent parent operations, stops the parent's scan and disconnects/closes every tracked parent address using its **public actions**. Only successful retirement permits the service's own GATT connection. A failed/timeout handoff retains ownership and does not start a competing connection. Host JavaScript must also invalidate its pending command/reconnect loops on pause, as the example coordinator does.
4. Service discovery and the notification CCCD write must complete before `monitoring: true`. Only notifications from the current GATT client and configured device/service/characteristic enter the protocol engine. ACKs use Write with response. An ACK failure/timeout retires the GATT client before another write can start. Additional ACK attempts require retransmissions; the engine does not run a repeating ACK timer. Consecutive connection failures are bounded by `maxConnectionFailures` (default three), with two seconds between attempts and a 15-second connect/subscription deadline. Bluetooth re-enable can retry an active session.
5. Native `onResume` suspends monitoring; the host must still **await `suspend()`** before resuming ordinary BLE. Resume during a handoff and overlapping suspend calls coalesce; a rapid second pause reacquires ownership after release. Successful parent retirement is retained for the duration of ownership, so disabling Bluetooth does not require calls back into a disabled parent just to release the native client. Native disconnect is awaited; after five seconds, closing the native GATT client disposes it before ownership is released. Close failures retain the gate for retry.
6. `suspend()` keeps arming and the already-started service for the next background transition. `stop()` disarms and stops/unbinds the service after ownership is released. Android request configuration remains in memory; only the bounded event history is persisted in private app storage. Disk flushes run off the BLE/main loop, and retransmissions do not evict incident/delivery results from the ring. Service shutdown cancels outstanding delivery as unconfirmed; a server may already have accepted a timed-out/cancelled POST.

Receipt, ACK completion and HTTP delivery have the same separate events and quiet-period heuristic as iOS. HTTP work uses a bounded executor, per-request timeout and an overall deadline, does not follow redirects, does not add fields to a configured JSON body, and has no plugin POST retry. A bounded CPU wake lock allows immediate receipt/ACK/HTTP work; it is **not** a Doze/network exemption or an indefinitely held wake lock. An HTTP diagnostic URL additionally requires the host's domain-specific Android network-security policy; the plugin does not enable cleartext globally. Normal configured HTTPS reporting needs no such exception.

Start restrictions and background BLE guidance: [foreground service launch](https://developer.android.com/develop/background-work/services/fgs/launch), [connectedDevice service type](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device), [background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

Screen-lock monitoring is intended while connected/subscribed; it still needs physical validation. Doze and vendor battery management can affect CPU/network timing. Removing an app from Recents is not equivalent to Settings Force stop or Android Active apps Stop, and behavior is device-dependent. No reception or automatic recovery is promised after process death, force-stop, crash, reboot or power-off. `START_NOT_STICKY` deliberately avoids claiming process restoration. The host can restore its preference and prepare a fresh request after a normal user relaunch. Do not test physical notifications against an action endpoint without coordination; a configured ACK can dismiss the peripheral's alert screen before HTTP succeeds.

## Simple TypeScript usage

After the platform/device-ready event and the existing plugin's Bluetooth initialization:

```ts
import * as background from 'cordova-plugin-bluetoothle-background';

await background.configure({
    deviceId: selectedDevice.address, // iOS: cached UUID; Android: Bluetooth address
    serviceUuid: 'AB00',
    notifyCharacteristicUuid: 'AB01',
    writeCharacteristicUuid: 'AB02',
    packetLength: 8,
    checksum: 'sum8',
    rules: [{
        id: 'example-notification',
        match: { offset: 0, bytes: [0x42] },
        quietPeriodMs: 5000,
        acknowledgement: { mode: 'echo', maxAttempts: 3, timeoutMs: 3000 }
    }]
});
await background.start();

// In the existing foreground/resume handler:
const status = await background.suspend();
console.log(status.events.map(event => JSON.stringify(event)).join('\n\n'));
// Restart existing foreground connection/communication here.

// When the user disables monitoring:
await background.stop();
```

The UUIDs and eight-byte command above are **synthetic examples**, not a supported device protocol. Replace them using your peripheral's specification. A complete shallow example is in [examples/background-session.ts](examples/background-session.ts). Plain Cordova JavaScript can use `window.bluetoothleBackground` after `deviceready`; existing BLE methods remain on `window.bluetoothle`.

No external request occurs without explicit `reporting` configuration. UI presentation and decisions about whom to contact belong in the host app. Native events can be read through `getStatus()` when JavaScript is running; there is no promise that the WebView will execute callbacks while suspended.

## Configuration

See [types/index.d.ts](types/index.d.ts) for the complete API.

| Setting | Meaning |
| --- | --- |
| `deviceId` | iOS: cached UUID. Android: Bluetooth address. Obtain it through the existing plugin; no name-based selection or scanning is performed here. |
| `serviceUuid`, `notifyCharacteristicUuid`, `writeCharacteristicUuid` | One GATT service and notification/command characteristics. Accepts 16-, 32-, or 128-bit Bluetooth UUID strings. |
| `packetLength` | Fixed frame length, 1–512 bytes. |
| `checksum` | `sum8`: final byte must equal the sum of all preceding bytes, masked to 8 bits. `none`: explicitly disables checksum validation. |
| `rules` | 1–16 rules. First matching rule owns the frame. Put specific matches first. |
| `rules[].match` | Byte `offset`, expected `bytes`, optional same-length `mask`. Matching uses `(actual & mask) == (expected & mask)`. |
| `rules[].quietPeriodMs` | Sliding silence boundary per rule, default 5000; range 100–300000 ms. |
| `rules[].acknowledgement` | `echo` sends the received frame unchanged; `fixed` sends configured `bytes`; `none` does not write. Fixed bytes include any checksum required by the device. |
| Acknowledgement `maxAttempts`, `timeoutMs` | Default 3 attempts (1–10), 3000 ms per write (100–30000). Retries require another matching notification. |
| `metadata` | Optional JSON object copied into incident events/reports. |
| `includePayload` | Default false. Opts into storing/reporting received packet bytes. |
| `maxEvents` | Persisted event ring limit, default 100; range 10–1000. |
| `maxConnectionFailures` | Default 3; range 1–10 consecutive failed connection attempts. Reset after notification enablement. |

The first version requires the configured notification characteristic to support **Notify** and the command characteristic to support **Write with response**, even for configurations with no acknowledgement. It does not support indication-only characteristics or write-without-response acknowledgement. The OS's successful write callback records BLE acceptance; it cannot prove the peripheral acted on the packet.

The stream assembler accepts fragmented or concatenated frames. It starts on the first notification byte after connection and consumes fixed-length frames; bad checksums discard that frame. It cannot recover alignment after missing/extra bytes without a new connection and does not implement variable-length framing, a start delimiter, CRC algorithms, or JavaScript-defined background parsers. Nonmatching packets are ignored by the companion; it does not run the app's ordinary measurements while backgrounded.

All native state runs on the existing manager's main queue. Do not call the packet engine directly from another queue.

## Incidents and acknowledgements

Each rule gets a locally generated `incidentId`. Repeated matching packets within its sliding quiet period belong to the same incident, even if payload bytes change. They do not repeat delivery. A rule has one pending acknowledgement at a time, and all rules share one serialized physical write queue.

A repeat may request another acknowledgement after the previous write finishes, whether that write failed or succeeded, up to `maxAttempts`. This covers retransmissions when the peripheral did not act on an apparently successful write. No immediate timer-based retransmission is sent. After a timeout, the native connection is retired before another write can use it.

After at least `quietPeriodMs` without that rule's packets and no pending acknowledgement, the next match creates a new incident and a fresh attempt budget. Stream resets preserve deduplication state; reconfiguration or process death clears it.

**This is a heuristic, not a protocol event ID.** A disconnect or radio gap longer than the quiet period can cause one physical incident to be treated as two; separate incidents close together can be merged. Choose a boundary appropriate to the actual peripheral. The host backend should use the local `incidentId` for idempotency when suitable, but it cannot identify the same physical incident across reconfiguration/process death. There is no durable delivery queue or automatic delivery retry in this version.

## Optional HTTP reporting

Only configure a destination you own and have explicitly selected:

```ts
reporting: {
    url: 'https://your-service.example/events',
    headers: { Authorization: 'Bearer APP_SUPPLIED_TOKEN' },
    timeoutMs: 8000
}
```

This adds one native JSON POST per new incident, independently of acknowledgement. The body contains `event: "notification_received"`, local `incidentId`, `ruleId`, `deviceId`, `receivedAt`, `receivedAppState`, `sentAt`, `sentAppState`, and optional configured metadata/payload. `preflight()` sends a separate `event: "preflight"` request from the foreground without arming Bluetooth. Use an endpoint that treats preflight as a test.

### Custom request body (0.1.1)

If an existing endpoint expects its own JSON fields, prepare its URL, plain headers and body while the app is in the foreground:

```ts
const reporting = {
    url: 'https://your-service.example/actions',
    headers: {
        'Content-Type': 'application/json',
        'x-auth-token': 'APP_SUPPLIED_TOKEN'
    },
    body: {
        subject: 'Device notification',
        description: 'A configured device event was received.',
        attachment: null
    },
    timeoutMs: 8000
};

await background.configure({ ...deviceConfiguration, reporting });
// Skip preflight() when reporting.body is supplied.
await background.start();
```

Here `background` is the plugin import and `deviceConfiguration` contains the usual device, GATT, framing and rule settings. Configuring or arming does not send this request. The native handler sends it once per new incident, independently of acknowledgement, without needing JavaScript to execute at notification time.

`reporting.body` must be a JSON object, including an empty object if desired. Nested objects, arrays, booleans and null values are supported; the entire configuration still has the 64 KiB limit. Do not pass `JSON.stringify(payload)` or an Angular `HttpHeaders` instance. Convert headers to a plain `Record<string, string>` first. The plugin serializes the body once and sends only those fields: it does not wrap the body, append timestamps or IDs, or substitute event data. With no `body`, the existing incident envelope remains unchanged.

**With a custom body, `preflight()` rejects without sending any request.** A POST to an action endpoint could perform the action just by testing connectivity. Skip that call in the host app; check connectivity separately only through a backend-defined safe mechanism. Default-envelope preflight behavior is unchanged.

The complete configuration is a deep snapshot taken by `configure()`. Request headers and custom body stay in memory and are not added to status events, persisted event history or public OS logs. Changes to the original JavaScript object do not update native configuration; configure again from the foreground after background ownership has ended. The plugin sends the supplied authentication as-is and does not run the app's login/token refresh workflow. No service-specific endpoint, recipient or payload is built into this plugin.

`delivery_started` means the request was initiated. `delivery_succeeded` means an HTTP **2xx response** was received. It does not mean a caregiver received an alert or an emergency service was contacted. An HTTP failure, timeout, cancellation, or expiration records `delivery_failed`. With no destination, `delivery_skipped` is recorded. HTTP redirects are rejected so configured headers cannot be forwarded to another destination. On iOS, requests use an ephemeral session and a bounded background execution assertion. Android uses the foreground service and a bounded HTTP executor. Neither is a guaranteed delivery queue.

HTTPS is required by default. A local diagnostic HTTP endpoint also needs `allowInsecureHttp: true` and app-owned ATS/local-network configuration on iOS or domain-specific network-security settings on Android. This package does not weaken ATS or choose a diagnostic hostname automatically. Configuration and authentication headers stay in memory; they are not written to the event file. Do not put secrets into metadata, payloads, or URL query strings.

## Status and logs

`getStatus()` returns `available`, `configured`, `armed`, `ownsBluetooth`, `monitoring`, `restorationSupported: false`, and persisted `events`. Important event names distinguish the stages:

- `armed`, `background_handoff_started`, `device_connected`, `notifications_enabled`
- `notification_received`
- `acknowledgement_queued`, `acknowledgement_started`, `acknowledgement_written`, `acknowledgement_failed`
- `delivery_started`, `delivery_succeeded`, `delivery_failed`, `delivery_skipped`
- `packet_rejected`, `gatt_failed`, `bluetooth_unavailable`, `connection_retry_limit`, `background_monitor_stopped`

Repeated-notification diagnostics are emitted to the OS log but omitted from the persisted ring so they cannot evict important outcomes. Xcode/device Console logs use `[BLEBackground]` and include event name and app state; read the full details through `getStatus()`. The ring persists across launches in private Application Support on iOS (protected until first unlock) or private app files on Android. Android flushes the ring asynchronously. `clearEvents()` clears the ring and records `events_cleared`. Review metadata/payload sensitivity in the host UI and backend.

## iOS execution limits

Apple's [Core Bluetooth background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) describes Bluetooth event wakeups when `bluetooth-central` is enabled. This is event-driven native work, not continuous JavaScript execution. Reception needs a connected peripheral with notifications enabled, Bluetooth permission, and an in-range device. Pending connections may reconnect when the peripheral returns; reception is unavailable during that gap.

This version does **not** implement Core Bluetooth state restoration or AccessorySetupKit. It does not restore configuration or arming after process termination. Do not promise reception after swiping the app away, OS termination, a crash, reboot, or power-off, regardless of iOS version. The user must relaunch, configure and arm again. See Apple's [state-restoration relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) for a possible future lifecycle extension.

Use a physical iPhone/iPad for background testing. Simulator, Mac Catalyst, and iOS apps running on a Mac report `available: false`. Android is implemented separately above; web monitoring is unavailable.

## Testing and removal

From this repository:

```sh
npm install
npm test
npm run test:native
npm run test:android
npm run check:types
npm pack --dry-run
```

Native iOS tests require macOS and Xcode/Command Line Tools. Android JVM tests require JDK 17+ and an `org.json:json` JVM jar; `scripts/test-android.cjs` accepts `BLE_BACKGROUND_JSON_JAR` or finds an existing Gradle-cache copy. Tests use synthetic packets and mocked delivery; they do not use Bluetooth hardware or contact any endpoint. They cover checksums, fragmented/concatenated frames, matching, deduplication boundaries, echo/fixed/no acknowledgements, serialized writes, bounded retries, delivery outcomes, config validation, bridge routing, and installer conflicts/idempotence. Request-construction tests cover the default envelope, exact custom JSON bodies, headers, timeout, snapshot behavior and rejection of custom-body preflight. Host lifecycle and physical BLE behavior need separate device testing.

For a device test, first configure **without reporting**. Initialize the existing BLE plugin, select/cache the peripheral, arm, background the app, trigger the configured device event, and inspect `[BLEBackground]` logs. Confirm acknowledgement behavior with the peripheral manufacturer; it may dismiss a device alert. Return to foreground, await `suspend()`, inspect event history and resume ordinary communication. Only then test an explicitly selected diagnostic server. Also test Bluetooth off/on, disconnect/reconnect and foreground transitions without Xcode attached.

For Capacitor removal, disarm and restore registration **before** removing the package. Remove the two package hook commands before running sync:

```sh
npx bluetoothle-background-configure --restore
# Remove the package's copy/sync hook commands from the app's package.json here.
npm uninstall cordova-plugin-bluetoothle-background
npx cap sync ios
```

`--restore` preserves background modes because other features may use them; remove `bluetooth-central` manually only if no longer needed. For Cordova, remove the plugin and run `cordova prepare ios` to regenerate the parent registration. Rebuild after either removal.

To publish on GitHub, put this directory's contents in your chosen repository, including tests and examples. No remote URL or account name is embedded. The package is MIT licensed; review the license and version before making a public release.


## Versions

v0.2.0
feat(android): add native background BLE monitoring and SOS support

- Add connected-device foreground service with exclusive BLE handoff
- Handle configurable packets, bounded acknowledgements and HTTP delivery
- Add Android setup helpers, tests and documentation
- Preserve existing iOS behavior
- Bump version to 0.2.0