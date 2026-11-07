#!/usr/bin/env node
'use strict';

// Only generated iOS registration and the background-mode plist are changed.
// The original BluetoothLE plugin and its manager remain the foreground owner.
const fs = require('node:fs');
const path = require('node:path');

function attribute(tag, name) {
    const match = tag.match(new RegExp('\\b' + name + '\\s*=\\s*([\'"])(.*?)\\1'));
    return match && match[2];
}

function patchRegistration(xml, restore = false) {
    // Ignore comments so an example/comment cannot become the selected feature.
    const visible = xml.replace(/<!--[\s\S]*?-->/g, match => ' '.repeat(match.length));
    const features = [...visible.matchAll(/<feature\b[^>]*>[\s\S]*?<\/feature\s*>/g)]
        .filter(match => attribute(match[0].split('>')[0], 'name') === 'BluetoothLePlugin');
    if (features.length !== 1) throw new Error('Expected exactly one BluetoothLePlugin feature in the generated iOS config.xml.');
    const feature = features[0];
    const params = [...feature[0].matchAll(/<param\b[^>]*\/?\s*>/g)]
        .filter(match => attribute(match[0], 'name') === 'ios-package');
    if (params.length !== 1) throw new Error('Expected one ios-package parameter for BluetoothLePlugin.');
    const param = params[0];
    const current = attribute(param[0], 'value');
    if (!['BluetoothLePlugin', 'BLEBackgroundPlugin'].includes(current)) {
        throw new Error('BluetoothLePlugin already uses another native class (' + current + '). Remove or migrate that integration before installing this companion.');
    }
    const start = feature.index + param.index;
    const original = xml.slice(start, start + param[0].length);
    const changed = original.replace(/(\bvalue\s*=\s*)(['"])(.*?)\2/, (_, prefix, quote) =>
        prefix + quote + (restore ? 'BluetoothLePlugin' : 'BLEBackgroundPlugin') + quote);
    let result = xml.slice(0, start) + changed + xml.slice(start + original.length);
    // Native initialization runs when the bridge is constructed, before JS. The
    // AppDelegate launch entry point handles an even earlier Bluetooth relaunch.
    const onload = '<param name="onload" value="true" data-ble-background="startup" />';
    if (restore) result = result.replace(/\s*<param name="onload" value="true" data-ble-background="startup" \/>/, '');
    else if (!/name\s*=\s*['"]onload['"]/.test(feature[0])) {
        const closing = result.indexOf('</feature', feature.index);
        result = result.slice(0, closing) + onload + result.slice(closing);
    }
    return result;
}

function patchAppDelegate(source) {
    const marker = '// BLEBackground native restoration startup';
    if (source.includes(marker)) return source;
    if (!/func application\(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions:/.test(source)) {
        throw new Error('Expected the Swift application didFinishLaunchingWithOptions method. Add BLEBackgroundPlugin.restoreAtLaunch manually for another host.');
    }
    const pattern = /(func application\(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions:[^\n]*\{)/;
    const changed = source.replace(pattern, '$1\n        ' + marker + '\n        BLEBackgroundPlugin.restore(atLaunch: launchOptions ?? [:])');
    if (changed === source) throw new Error('Cannot find the native launch body.');
    return changed.includes('import CordovaPlugins') ? changed : changed.replace('import UIKit', 'import UIKit\nimport CordovaPlugins');
}

function ensureBluetoothMode(plist) {
    if (!/^\s*(?:<\?xml[^>]*>\s*)?(?:<!DOCTYPE[^>]*>\s*)?<plist\b/.test(plist)) {
        throw new Error('Expected an XML Info.plist. Convert binary plists to XML before configuring.');
    }
    const modes = /(<key>UIBackgroundModes<\/key>\s*<array\s*>)([\s\S]*?)(<\/array>)/;
    if (modes.test(plist)) return plist.replace(modes, (all, open, values, close) =>
        /<string>bluetooth-central<\/string>/.test(values) ? all : open + values + '\n\t\t<string>bluetooth-central</string>\n\t' + close);
    // An existing malformed/unsupported value is a conflict, not permission to overwrite it.
    if (/<key>UIBackgroundModes<\/key>/.test(plist)) {
        const empty = /(<key>UIBackgroundModes<\/key>\s*)<array\s*\/>/;
        if (empty.test(plist)) return plist.replace(empty, '$1<array><string>bluetooth-central</string></array>');
        throw new Error('UIBackgroundModes must be an array.');
    }
    const end = plist.lastIndexOf('</dict>');
    if (end < 0) throw new Error('Info.plist has no root dictionary.');
    return plist.slice(0, end) + '\t<key>UIBackgroundModes</key>\n\t<array><string>bluetooth-central</string></array>\n' + plist.slice(end);
}

function verifyParent(root) {
    const candidates = [
        path.join(root, 'node_modules/cordova-plugin-bluetoothle/package.json'),
        path.join(root, 'plugins/cordova-plugin-bluetoothle/package.json')
    ].filter(file => fs.existsSync(file));
    if (candidates.length === 0) throw new Error('Install cordova-plugin-bluetoothle@6.7.4 first.');
    for (const file of candidates) {
        const version = JSON.parse(fs.readFileSync(file, 'utf8')).version;
        if (version !== '6.7.4') throw new Error('This companion requires cordova-plugin-bluetoothle 6.7.4; found ' + version + ' in ' + file);
    }
}

function configurePaths({ root, config, plist, restore = false }) {
    if (!restore) verifyParent(root);
    // Validate both files before writing either one. Repeated copy/sync is safe.
    const registration = fs.readFileSync(config, 'utf8');
    const changedRegistration = patchRegistration(registration, restore);
    const originalPlist = restore ? null : fs.readFileSync(plist, 'utf8');
    const changedPlist = restore ? null : ensureBluetoothMode(originalPlist);
    if (registration !== changedRegistration) fs.writeFileSync(config, changedRegistration);
    if (!restore && originalPlist !== changedPlist) fs.writeFileSync(plist, changedPlist);
    return { config, plist, restore };
}

function main(args) {
    if (process.env.CAPACITOR_PLATFORM_NAME && process.env.CAPACITOR_PLATFORM_NAME !== 'ios') return;
    const options = { root: process.cwd(), restore: false };
    for (let index = 0; index < args.length; index++) {
        const option = args[index];
        if (option === '--restore') options.restore = true;
        else if (['--root', '--config', '--plist'].includes(option) && args[index + 1] && !args[index + 1].startsWith('--')) {
            options[option.slice(2)] = args[++index];
        } else throw new Error('Usage: bluetoothle-background-configure [--root app-directory] [--config ios-config.xml] [--plist Info.plist] [--restore]');
    }
    options.root = path.resolve(options.root);
    options.config = path.resolve(options.root, options.config || 'ios/App/App/config.xml');
    options.plist = path.resolve(options.root, options.plist || 'ios/App/App/Info.plist');
    configurePaths(options);
    console.log('BluetoothLE Background: ' + (options.restore ? 'restored parent registration in ' : 'configured ') + options.config);
}

module.exports = { patchRegistration, patchAppDelegate, ensureBluetoothMode, configurePaths };
if (require.main === module) {
    try { main(process.argv.slice(2)); }
    catch (error) { console.error('BluetoothLE Background: ' + error.message); process.exitCode = 1; }
}
