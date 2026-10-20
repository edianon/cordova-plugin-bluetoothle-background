'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { patchRegistration, ensureBluetoothMode, configurePaths } = require('../scripts/configure-ios.cjs');
const hook = require('../hooks/after-prepare.cjs');
const xml = '<widget><feature name="Other"><param name="ios-package" value="Unchanged" /></feature>\n<feature name="BluetoothLePlugin"><param name="ios-package" value="BluetoothLePlugin" /></feature></widget>';
const plist = '<?xml version="1.0"?><plist version="1.0"><dict><key>UIBackgroundModes</key><array><string>audio</string></array><key>Other</key><true/></dict></plist>';

test('registration changes only the parent class, is repeatable and reversible', () => {
    const changed = patchRegistration(xml);
    assert.equal(changed, xml.replace('value="BluetoothLePlugin"', 'value="BLEBackgroundPlugin"'));
    assert.equal(patchRegistration(changed), changed);
    assert.equal(patchRegistration(changed, true), xml);
    assert.equal(patchRegistration(xml.replaceAll('"', "'")), changed.replaceAll('"', "'"));
    const commented = '<!-- <feature name="BluetoothLePlugin"><param name="ios-package" value="Example"/></feature> -->' + xml;
    assert.ok(patchRegistration(commented).startsWith('<!--'));
});

test('ambiguous registration and another custom subclass are rejected', () => {
    assert.throws(() => patchRegistration(xml + xml), /exactly one/);
    assert.throws(() => patchRegistration('<widget/>'), /exactly one/);
    assert.throws(() => patchRegistration(xml.replace('value="BluetoothLePlugin"', 'value="AnotherCustomClass"')), /another native class/);
    assert.throws(() => patchRegistration(xml.replace('name="ios-package" value="BluetoothLePlugin"', 'name="android-package" value="BluetoothLePlugin"')), /ios-package/);
});

test('background mode preserves existing modes and other plist data', () => {
    const changed = ensureBluetoothMode(plist);
    assert.match(changed, /<string>audio<\/string>/);
    assert.match(changed, /<key>Other<\/key><true\/>/);
    assert.equal((changed.match(/bluetooth-central/g) || []).length, 1);
    assert.equal(ensureBluetoothMode(changed), changed);
    assert.match(ensureBluetoothMode('<plist><dict></dict></plist>'), /bluetooth-central/);
    assert.match(ensureBluetoothMode('<plist><dict><key>UIBackgroundModes</key><array/></dict></plist>'), /bluetooth-central/);
    assert.throws(() => ensureBluetoothMode('bplist00'), /XML/);
    assert.throws(() => ensureBluetoothMode(plist.replace('<array><string>audio</string></array>', '<string>bad</string>')), /must be an array/);
});

test('file installer validates before writing, pins parent version, and restores registration', t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ble-background-installer-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const parent = path.join(root, 'node_modules/cordova-plugin-bluetoothle');
    fs.mkdirSync(parent, { recursive: true });
    fs.writeFileSync(path.join(parent, 'package.json'), JSON.stringify({ version: '6.7.4' }));
    const config = path.join(root, 'config.xml'), info = path.join(root, 'Info.plist');
    fs.writeFileSync(config, xml);
    fs.writeFileSync(info, 'bad plist');
    assert.throws(() => configurePaths({ root, config, plist: info }), /XML/);
    assert.equal(fs.readFileSync(config, 'utf8'), xml);
    fs.writeFileSync(info, plist);
    configurePaths({ root, config, plist: info });
    assert.equal(fs.readFileSync(config, 'utf8'), patchRegistration(xml));
    configurePaths({ root, config, plist: info, restore: true });
    assert.equal(fs.readFileSync(config, 'utf8'), xml);
    assert.match(fs.readFileSync(info, 'utf8'), /bluetooth-central/);
    fs.writeFileSync(path.join(parent, 'package.json'), JSON.stringify({ version: '7.0.0' }));
    assert.throws(() => configurePaths({ root, config, plist: info }), /requires.*6.7.4/);
});

test('Cordova prepare finds generated app and leaves other platforms alone', t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ble-background-hook-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    hook({ opts: { platforms: ['android'], projectRoot: root } });
    const app = path.join(root, 'platforms/ios/Example');
    const parent = path.join(root, 'plugins/cordova-plugin-bluetoothle');
    fs.mkdirSync(app, { recursive: true });
    fs.mkdirSync(parent, { recursive: true });
    fs.writeFileSync(path.join(parent, 'package.json'), '{"version":"6.7.4"}');
    fs.writeFileSync(path.join(app, 'config.xml'), xml);
    fs.writeFileSync(path.join(app, 'Example-Info.plist'), plist);
    hook({ opts: { platforms: ['ios'], projectRoot: root } });
    assert.equal(fs.readFileSync(path.join(app, 'config.xml'), 'utf8'), patchRegistration(xml));
});

test('CLI runs on custom paths and skips Capacitor Android hooks', t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ble-background-cli-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const script = path.resolve(__dirname, '../scripts/configure-ios.cjs');
    const parent = path.join(root, 'node_modules/cordova-plugin-bluetoothle');
    fs.mkdirSync(parent, { recursive: true });
    fs.writeFileSync(path.join(parent, 'package.json'), '{"version":"6.7.4"}');
    fs.writeFileSync(path.join(root, 'custom.xml'), xml);
    fs.writeFileSync(path.join(root, 'custom.plist'), plist);
    const args = [script, '--root', root, '--config', 'custom.xml', '--plist', 'custom.plist'];
    const environment = { ...process.env, CAPACITOR_PLATFORM_NAME: 'ios' };
    const configured = spawnSync(process.execPath, args, { env: environment, encoding: 'utf8' });
    assert.equal(configured.status, 0, configured.stderr);
    assert.equal(fs.readFileSync(path.join(root, 'custom.xml'), 'utf8'), patchRegistration(xml));
    const restored = spawnSync(process.execPath, [...args, '--restore'], { env: environment, encoding: 'utf8' });
    assert.equal(restored.status, 0, restored.stderr);
    assert.equal(fs.readFileSync(path.join(root, 'custom.xml'), 'utf8'), xml);
    const skipped = spawnSync(process.execPath, [script, '--root', root], { env: { ...environment, CAPACITOR_PLATFORM_NAME: 'android' } });
    assert.equal(skipped.status, 0);
    assert.equal(fs.readFileSync(path.join(root, 'custom.xml'), 'utf8'), xml);
});
