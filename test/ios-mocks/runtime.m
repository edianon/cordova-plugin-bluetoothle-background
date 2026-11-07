#import "BluetoothLePlugin.h"
NSUInteger MockForegroundStateCallbacks;
NSUInteger MockForegroundInitializeCalls;
NSUInteger MockForegroundDiscoveries;
CBManagerState MockForegroundInitializeState;
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler { return 1; }
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier {}
@end
@implementation CDVPlugin
- (instancetype)initWithWebViewEngine:(WKWebView *)webView { return [self init]; }
- (void)pluginInitialize {}
- (void)onReset {}
- (void)dispose {}
- (void)sendPluginResult:(CDVPluginResult *)result callbackId:(NSString *)callback {}
@end
@implementation CDVPluginResult
+ (instancetype)resultWithStatus:(CDVCommandStatus)status messageAsString:(NSString *)message { return [self new]; }
+ (instancetype)resultWithStatus:(CDVCommandStatus)status messageAsDictionary:(NSDictionary *)message { return [self new]; }
@end
@implementation CDVInvokedUrlCommand
- (instancetype)initWithArguments:(NSArray *)arguments callbackId:(NSString *)callback className:(NSString *)className methodName:(NSString *)methodName {
    self = [super init]; if (self) { self.arguments = arguments; self.callbackId = callback; self.className = className; self.methodName = methodName; } return self;
}
- (id)argumentAtIndex:(NSUInteger)index withDefault:(id)value andClass:(Class)type { return index < self.arguments.count && [self.arguments[index] isKindOfClass:type] ? self.arguments[index] : value; }
@end
@implementation BluetoothLePlugin
#define COMMAND(name) - (void)name:(CDVInvokedUrlCommand *)command {}
COMMAND(startScan) COMMAND(stopScan) COMMAND(connect) COMMAND(reconnect)
COMMAND(disconnect) COMMAND(close) COMMAND(discover) COMMAND(services) COMMAND(characteristics)
COMMAND(descriptors) COMMAND(read) COMMAND(subscribe) COMMAND(unsubscribe) COMMAND(write) COMMAND(writeQ)
COMMAND(readDescriptor) COMMAND(writeDescriptor) COMMAND(rssi)
#undef COMMAND
- (void)initialize:(CDVInvokedUrlCommand *)command {
    MockForegroundInitializeCalls++;
    MockForegroundInitializeState = centralManager.state;
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central { MockForegroundStateCallbacks++; }
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI { MockForegroundDiscoveries++; }
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {}
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {}
@end
