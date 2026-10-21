'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
// JVM org.json is needed because android.jar contains runtime stubs. No SDK/device/network is used.
function jars(directory) {
    if (!fs.existsSync(directory)) return [];
    return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
        const file = path.join(directory, entry.name);
        return entry.isDirectory() ? jars(file) : /^json-[0-9][^.]*\.jar$/.test(entry.name) && !entry.name.includes('sources') && !entry.name.includes('javadoc') ? [file] : [];
    });
}
const json = process.env.BLE_BACKGROUND_JSON_JAR || jars(path.join(os.homedir(), '.gradle/caches/modules-2/files-2.1/org.json/json'))[0];
if (!json) throw new Error('Set BLE_BACKGROUND_JSON_JAR to an org.json:json JVM jar (for example 20231013).');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ble-background-android-'));
function run(command, args) {
    const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(command + ' failed with status ' + result.status);
}
try {
    run('javac', ['-Xlint:all', '-Werror', '-cp', json, '-d', directory,
        ...['Protocol', 'Reporting', 'Ownership'].map(name => 'src/android/BLEBackground' + name + '.java'), 'test/android/BackgroundTests.java']);
    run('java', ['-ea', '-cp', directory + path.delimiter + json, 'com.hme.bluetoothle.background.BackgroundTests']);
} finally { fs.rmSync(directory, { recursive: true, force: true }); }
