import * as background from 'cordova-plugin-bluetoothle-background';

// Call after deviceready, Bluetooth initialization and foreground device discovery.
// All identifiers and packet details must come from your device's own protocol.
export async function armBackgroundSession(deviceId: string) {
    await background.configure({
        deviceId,
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
        // Reporting is intentionally absent. No network request is made.
        // If needed, configure reporting.url for an endpoint you control.
    });
    return background.start();
}

// In your existing foreground/resume handler, wait before resuming normal BLE.
export async function releaseBackgroundSession() {
    const status = await background.suspend();
    console.log(status.events.map(event => JSON.stringify(event)).join('\n\n'));
    // Existing foreground Bluetooth connection/communication can restart here.
    return status;
}

export async function disarmBackgroundSession() {
    return background.stop();
}
