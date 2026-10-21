'use strict';

function call(method, options) {
    return new Promise(function (resolve, reject) {
        var root = typeof window !== 'undefined' ? window : globalThis;
        if (!root.cordova || typeof root.cordova.exec !== 'function') {
            reject(new Error('BluetoothLE Background requires a native iOS or Android Cordova/Capacitor app. Wait for deviceready.'));
            return;
        }
        root.cordova.exec(resolve, function (error) {
            reject(new Error(typeof error === 'string' ? error : JSON.stringify(error)));
        }, 'BluetoothLePlugin', method, [options || {}]);
    });
}

// Configuration is validated again in native code. No watch data or packet
// constants are supplied here. Normal foreground BLE uses window.bluetoothle.
exports.configure = function (configuration) { return call('backgroundConfigure', configuration); };
exports.start = function () { return call('backgroundStart'); };
exports.stop = function () { return call('backgroundStop', { disarm: true }); };
exports.suspend = function () { return call('backgroundStop', { disarm: false }); };
exports.getStatus = function () { return call('backgroundGetStatus'); };
exports.clearEvents = function () { return call('backgroundClearEvents'); };
exports.preflight = function () { return call('backgroundPreflight'); };
