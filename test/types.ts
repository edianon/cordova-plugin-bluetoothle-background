import * as background from '../types';

const configuration: background.Configuration = {
    deviceId: '00000000-0000-4000-8000-000000000001',
    serviceUuid: 'AB00', notifyCharacteristicUuid: 'AB01', writeCharacteristicUuid: 'AB02',
    packetLength: 8, checksum: 'sum8',
    rules: [{ id: 'example', match: { offset: 0, bytes: [0x42] }, acknowledgement: { mode: 'echo' } }],
    reporting: {
        url: 'https://example.invalid/actions',
        headers: { 'Content-Type': 'application/json', 'x-auth-token': 'synthetic-token' },
        body: { subject: 'Synthetic test', attachment: null, enabled: false, nested: { values: [1, 'two'] } }
    }
};

const invalidReporting: NonNullable<background.Configuration['reporting']> = {
    url: 'https://example.invalid/actions',
    // @ts-expect-error Pass an object, not JSON.stringify(payload).
    body: '{"subject":"test"}'
};
void invalidReporting;

async function example() {
    await background.configure(configuration);
    await window.bluetoothleBackground.start();
    const status: background.Status = await background.suspend();
    const events: background.BackgroundEvent[] = status.events;
    await background.stop();
    await background.clearEvents();
    const response: { statusCode: number } = await background.preflight();
    return { events, response };
}
void example;
