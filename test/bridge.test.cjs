'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const bridge = require('../www/bluetoothle-background.js');

test('all methods reuse the existing BluetoothLePlugin service', async () => {
    const calls = [];
    global.cordova = { exec(resolve, reject, service, method, args) {
        calls.push({ service, method, args }); resolve({ armed: true });
    } };
    const configuration = { deviceId: 'from-app' };
    await bridge.configure(configuration);
    await bridge.start();
    await bridge.stop();
    await bridge.suspend();
    await bridge.getStatus();
    await bridge.clearEvents();
    await bridge.preflight();
    assert.deepEqual(calls.map(call => call.service), Array(7).fill('BluetoothLePlugin'));
    assert.deepEqual(calls.map(call => call.method), ['backgroundConfigure', 'backgroundStart', 'backgroundStop', 'backgroundStop', 'backgroundGetStatus', 'backgroundClearEvents', 'backgroundPreflight']);
    assert.deepEqual(calls.map(call => call.args), [[configuration], [{}], [{ disarm: true }], [{ disarm: false }], [{}], [{}], [{}]]);
    delete global.cordova;
});

test('native failures and browser-only usage reject clearly', async () => {
    global.cordova = { exec(resolve, reject) { reject('native failed'); } };
    await assert.rejects(bridge.start(), /native failed/);
    global.cordova = { exec(resolve, reject) { reject({ error: 'busy' }); } };
    await assert.rejects(bridge.stop(), /busy/);
    delete global.cordova;
    await assert.rejects(bridge.getStatus(), /native iOS/);
});
