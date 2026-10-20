import * as background from '../types';

const configuration: background.Configuration = {
    deviceId: '00000000-0000-4000-8000-000000000001',
    serviceUuid: 'AB00', notifyCharacteristicUuid: 'AB01', writeCharacteristicUuid: 'AB02',
    packetLength: 8, checksum: 'sum8',
    rules: [{ id: 'example', match: { offset: 0, bytes: [0x42] }, acknowledgement: { mode: 'echo' } }]
};

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
