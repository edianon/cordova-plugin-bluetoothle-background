#!/usr/bin/env node
'use strict';
// Documented generated-registration change only. Parent sources are never patched.
const fs = require('node:fs');
const path = require('node:path');
const PARENT = 'com.randdusing.bluetoothle.BluetoothLePlugin';
const CLASS = 'com.hme.bluetoothle.background.BLEBackgroundPlugin';
function patchRegistration(xml, restore = false) {
    const visible = xml.replace(/<!--[\s\S]*?-->/g, value => ' '.repeat(value.length));
    const features = [...visible.matchAll(/<feature\b[^>]*>[\s\S]*?<\/feature\s*>/g)]
        .filter(match => /\bname\s*=\s*(['"])BluetoothLePlugin\1/.test(match[0].split('>')[0]));
    if (features.length !== 1) throw new Error('Expected exactly one BluetoothLePlugin feature in generated Android config.xml.');
    const feature = features[0];
    const params = [...feature[0].matchAll(/<param\b[^>]*\/?>/g)].filter(match => /\bname\s*=\s*(['"])android-package\1/.test(match[0]));
    if (params.length !== 1) throw new Error('Expected exactly one android-package parameter.');
    const param = params[0];
    const value = param[0].match(/\bvalue\s*=\s*(['"])(.*?)\1/);
    if (!value || ![PARENT, CLASS].includes(value[2])) throw new Error('BluetoothLePlugin is registered to another native class; refusing to overwrite it.');
    const changed = param[0].replace(value[0], value[0].replace(value[2], restore ? PARENT : CLASS));
    const position = feature.index + param.index;
    return xml.slice(0, position) + changed + xml.slice(position + param[0].length);
}
function configurePaths({ root, config, restore = false }) {
    const parent = [path.join(root, 'node_modules/cordova-plugin-bluetoothle/package.json'), path.join(root, 'plugins/cordova-plugin-bluetoothle/package.json')].find(fs.existsSync);
    if (!parent || JSON.parse(fs.readFileSync(parent, 'utf8')).version !== '6.7.4') throw new Error('Android background integration requires cordova-plugin-bluetoothle 6.7.4.');
    const original = fs.readFileSync(config, 'utf8');
    const changed = patchRegistration(original, restore);
    if (changed !== original) fs.writeFileSync(config, changed);
}
if (require.main === module) {
    if (process.env.CAPACITOR_PLATFORM_NAME && process.env.CAPACITOR_PLATFORM_NAME !== 'android') process.exit(0);
    const args = process.argv.slice(2);
    const argument = key => { const index = args.indexOf(key); if (index < 0) return undefined; if (!args[index + 1] || args[index + 1].startsWith('--')) throw new Error(key + ' requires a path.'); return args[index + 1]; };
    const root = path.resolve(argument('--root') || process.cwd());
    configurePaths({ root, config: path.resolve(root, argument('--config') || 'android/app/src/main/res/xml/config.xml'), restore: args.includes('--restore') });
    console.log('Configured Android BluetoothLE background subclass.');
}
module.exports = { patchRegistration, configurePaths };
