'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { configurePaths } = require('../scripts/configure-ios.cjs');

module.exports = function (context) {
    if (!context.opts.platforms.includes('ios')) return;
    const root = context.opts.projectRoot;
    const ios = path.join(root, 'platforms/ios');
    const candidates = fs.readdirSync(ios, { withFileTypes: true })
        .filter(entry => entry.isDirectory() && !['CordovaLib', 'Pods', 'build', 'cordova', 'platform_www', 'www'].includes(entry.name))
        .map(entry => path.join(ios, entry.name))
        .filter(directory => fs.existsSync(path.join(directory, 'config.xml')));
    if (candidates.length !== 1) throw new Error('BluetoothLE Background: cannot identify one Cordova iOS app directory. Configure generated config.xml and Info.plist explicitly with bluetoothle-background-configure.');
    const directory = candidates[0];
    const plists = fs.readdirSync(directory).filter(name => name.endsWith('-Info.plist'));
    if (plists.length !== 1) throw new Error('BluetoothLE Background: cannot identify one iOS Info.plist.');
    configurePaths({ root, config: path.join(directory, 'config.xml'), plist: path.join(directory, plists[0]) });
};
