export interface Configuration {
    /** iOS: cached Core Bluetooth UUID. Android: Bluetooth address obtained through the existing plugin. */
    deviceId: string;
    serviceUuid: string;
    notifyCharacteristicUuid: string;
    writeCharacteristicUuid: string;
    packetLength: number;
    /** sum8 validates the last byte against the sum of every preceding byte. */
    checksum: 'sum8' | 'none';
    rules: NotificationRule[];
    /** Optional JSON metadata copied into received incidents. */
    metadata?: Record<string, unknown>;
    /** Default false. Received packet bytes can contain private device data. */
    includePayload?: boolean;
    /** Android foreground-service notification. Does not change iOS behavior. */
    android?: {
        notificationTitle?: string;
        notificationText?: string;
    };
    reporting?: {
        url: string;
        headers?: Record<string, string>;
        /** Optional complete JSON object sent unchanged instead of the incident envelope.
         * Prepared in the foreground; no interpolation or added event fields.
         * preflight() rejects without sending when this is supplied. */
        body?: Record<string, unknown>;
        /** Default false. The host must separately allow local HTTP in ATS / Android network security settings. */
        allowInsecureHttp?: boolean;
        /** Default 8000; 100–30000. One POST per incident, no automatic retries. */
        timeoutMs?: number;
    };
    /** Default 100; 10–1000. Event files exclude configuration/HTTP headers; opt-in iOS recovery stores them in Keychain. */
    maxEvents?: number;
    /** Default 3; 1–10. Consecutive failures reset when notifications are enabled. */
    maxConnectionFailures?: number;
    /** iOS only, opt-in device-only Keychain recovery. Must match setSession().
     * expiresAt is the prepared credential expiry in Unix seconds. */
    restoration?: Session;
}

export interface Session { accountId: string; expiresAt: number; }

export interface NotificationRule {
    id: string;
    match: { offset: number; bytes: number[]; mask?: number[] };
    /** Sliding silence boundary per rule. Default 5000; 100–300000. */
    quietPeriodMs?: number;
    acknowledgement:
        | { mode: 'none' }
        | { mode: 'echo'; maxAttempts?: number; timeoutMs?: number }
        | { mode: 'fixed'; bytes: number[]; maxAttempts?: number; timeoutMs?: number };
}

export interface BackgroundEvent {
    event: string;
    eventAt: string;
    eventAppState: 'foreground' | 'inactive' | 'background';
    incidentId?: string;
    ruleId?: string;
    deviceId?: string;
    receivedAt?: string;
    receivedAppState?: string;
    attempt?: number;
    error?: string;
    payload?: number[];
    metadata?: Record<string, unknown>;
}

export interface Status {
    /** iOS: remains true even after releasing the manager; migration must precede first initialization. */
    managerInitializedInProcess?: boolean;
    available: boolean;
    configured: boolean;
    armed: boolean;
    ownsBluetooth: boolean;
    monitoring: boolean;
    events: BackgroundEvent[];
    /** iOS supports native recovery. Eligibility and actual relaunch remain OS/device dependent. */
    restorationSupported: boolean;
    recoveryArmed?: boolean;
    restored?: boolean;
    /** Configured iOS peripheral identifier; no credentials or request body. */
    deviceId?: string;
}

export function configure(configuration: Configuration): Promise<Status>;
export function start(): Promise<Status>;
export function stop(): Promise<Status>;
/** Release native background ownership, keeping start() armed for the next background transition. */
export function suspend(): Promise<Status>;
export function getStatus(): Promise<Status>;
export function clearEvents(): Promise<Status>;
/** iOS only. Clear on logout/account invalidation. Does not arm monitoring. */
export function setSession(session?: Session): Promise<Status>;
/** iOS only. Disconnect and release the shared manager before accessory setup.
 * Host must hold its BLE lease and call finishAccessorySetup() after success or cancellation. */
export function prepareAccessorySetup(): Promise<Status>;
/** iOS only. Recreate the shared manager after the picker ends; waits for Bluetooth state. */
export function finishAccessorySetup(): Promise<Status>;
/** Optional foreground POST check for the default incident envelope.
 * Rejects without sending if reporting.body is configured. Does not start BLE. */
export function preflight(): Promise<{ statusCode: number }>;

declare global {
    interface Window { bluetoothleBackground: typeof import('./index'); }
}
