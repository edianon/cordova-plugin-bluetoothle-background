#if __has_include(<CordovaPlugins/BluetoothLePlugin.h>)
#import <CordovaPlugins/BluetoothLePlugin.h>
#else
#import "BluetoothLePlugin.h"
#endif

// This replaces only the Cordova class registration, not the parent package.
// Its superclass owns the one CBCentralManager used by both modes.
@interface BLEBackgroundPlugin : BluetoothLePlugin
+ (void)restoreAtLaunch:(NSDictionary *)launchOptions NS_SWIFT_NAME(restore(atLaunch:));
- (void)backgroundSetSession:(CDVInvokedUrlCommand *)command;
- (void)backgroundPrepareAccessorySetup:(CDVInvokedUrlCommand *)command;
- (void)backgroundFinishAccessorySetup:(CDVInvokedUrlCommand *)command;
- (void)backgroundConfigure:(CDVInvokedUrlCommand *)command;
- (void)backgroundStart:(CDVInvokedUrlCommand *)command;
- (void)backgroundStop:(CDVInvokedUrlCommand *)command;
- (void)backgroundGetStatus:(CDVInvokedUrlCommand *)command;
- (void)backgroundClearEvents:(CDVInvokedUrlCommand *)command;
- (void)backgroundPreflight:(CDVInvokedUrlCommand *)command;
@end
