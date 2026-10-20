export interface Configuration {
    /** Cached Core Bluetooth device UUID obtained through the existing plugin. */
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
    reporting?: {
        url: string;
        headers?: Record<string, string>;
        /** Default false. The app must separately configure ATS for local HTTP. */
        allowInsecureHttp?: boolean;
        /** Default 8000; 100–30000. One POST per incident, no automatic retries. */
        timeoutMs?: number;
    };
    /** Default 100; 10–1000. Configuration and HTTP headers are never persisted. */
    maxEvents?: number;
    /** Default 3; 1–10. Consecutive failures reset when notifications are enabled. */
    maxConnectionFailures?: number;
}

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
    available: boolean;
    configured: boolean;
    armed: boolean;
    ownsBluetooth: boolean;
    monitoring: boolean;
    events: BackgroundEvent[];
    /** This version supports background execution, not process restoration. */
    restorationSupported: false;
}

export function configure(configuration: Configuration): Promise<Status>;
export function start(): Promise<Status>;
export function stop(): Promise<Status>;
/** Release native background ownership, keeping start() armed for the next background transition. */
export function suspend(): Promise<Status>;
export function getStatus(): Promise<Status>;
export function clearEvents(): Promise<Status>;
/** Optional foreground HTTP reachability check; does not start BLE monitoring. */
export function preflight(): Promise<{ statusCode: number }>;

declare global {
    interface Window { bluetoothleBackground: typeof import('./index'); }
}
