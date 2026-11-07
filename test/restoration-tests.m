#import "BLEBackgroundPlugin.h"
#import "BLEBackgroundStore.h"

static NSUInteger checks;
extern NSUInteger MockForegroundStateCallbacks;
extern NSUInteger MockForegroundInitializeCalls;
extern CBManagerState MockForegroundInitializeState;
extern NSUInteger MockForegroundDiscoveries;
static void check(BOOL condition, NSString *message) { checks++; if (!condition) { NSLog(@"FAIL: %@", message); exit(1); } }
@interface BLEBackgroundPlugin (Testing)
+ (instancetype)sharedPlugin;
- (BOOL)bgInstallConfiguration:(NSDictionary *)configuration error:(NSError **)error;
- (NSDictionary *)bgStatus;
- (void)bgEnterForeground;
- (void)bgRecord:(NSString *)event details:(NSDictionary *)details;
- (void)bgPost:(NSDictionary *)incident reporting:(NSDictionary *)reporting completion:(void (^)(NSError *, NSInteger))completion;
@end
@interface MemoryStore : BLEBackgroundStore
@property(nonatomic) NSDictionary *state;
@property(nonatomic) BOOL fail;
@end
@implementation MemoryStore
- (BOOL)save:(NSDictionary *)state error:(NSError **)error { if (self.fail) return NO; self.state = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] options:0 error:nil]; return YES; }
- (BOOL)invalidate:(NSError **)error { self.state = nil; return YES; }
@end
@interface FakeCharacteristic : NSObject
@property(nonatomic) CBUUID *UUID;
@property(nonatomic) CBCharacteristicProperties properties;
@property(nonatomic, getter=isNotifying) BOOL notifying;
@property(nonatomic) NSData *value;
@end
@implementation FakeCharacteristic @end
@interface FakeService : NSObject
@property(nonatomic) CBUUID *UUID;
@property(nonatomic) NSArray *characteristics;
@end
@implementation FakeService @end
@interface FakePeripheral : NSObject
@property(nonatomic) NSUUID *identifier;
@property(nonatomic) CBPeripheralState state;
@property(nonatomic) id delegate;
@property(nonatomic) NSArray *services;
@property(nonatomic) NSUInteger discoveries;
@property(nonatomic) NSUInteger characteristicDiscoveries;
@property(nonatomic) NSUInteger subscriptions;
@property(nonatomic) NSMutableArray *writes;
@end
@implementation FakePeripheral
- (void)discoverServices:(NSArray *)services { self.discoveries++; }
- (void)discoverCharacteristics:(NSArray *)characteristics forService:(CBService *)service { self.characteristicDiscoveries++; }
- (void)setNotifyValue:(BOOL)value forCharacteristic:(FakeCharacteristic *)characteristic { self.subscriptions++; }
- (NSUInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return 512; }
- (void)writeValue:(NSData *)value forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type { [self.writes addObject:value]; }
@end
@interface FakeCentral : NSObject
@property(nonatomic) id delegate;
@property(nonatomic) BOOL deferDisconnect;
@property(nonatomic) CBManagerState state;
@property(nonatomic, getter=isScanning) BOOL scanning;
@property(nonatomic) NSUInteger cancellations;
@property(nonatomic) NSUInteger prematureCommands;
@property(nonatomic) NSUInteger connects;
@property(nonatomic) NSArray *cached;
@end
@implementation FakeCentral
- (void)stopScan { if (self.state != CBManagerStatePoweredOn) { self.prematureCommands++; return; } self.scanning = NO; }
- (void)cancelPeripheralConnection:(FakePeripheral *)peripheral {
    if (self.state != CBManagerStatePoweredOn) { self.prematureCommands++; return; }
    self.cancellations++; peripheral.state = self.deferDisconnect ? CBPeripheralStateDisconnecting : CBPeripheralStateDisconnected;
}
- (void)connectPeripheral:(FakePeripheral *)peripheral options:(NSDictionary *)options { self.connects++; peripheral.state = CBPeripheralStateConnecting; }
- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray *)identifiers { return self.cached ?: @[]; }
@end
@interface TestPlugin : BLEBackgroundPlugin
@property(nonatomic) NSMutableArray *testEvents;
@property(nonatomic) NSMutableArray *posts;
@property(nonatomic) BOOL httpFailure;
@property(nonatomic) FakeCentral *recreatedManager;
@property(nonatomic) NSUInteger managerCreations;
@property(nonatomic, copy) void (^settledState)(void);
- (void)prepare:(NSDictionary *)saved store:(MemoryStore *)store central:(FakeCentral *)central;
- (BOOL)hasManager;
- (void)addForegroundPeripheral:(FakePeripheral *)peripheral;
@end
static TestPlugin *launchPlugin;
@implementation TestPlugin
+ (instancetype)sharedPlugin { return launchPlugin; }
- (void)prepare:(NSDictionary *)saved store:(MemoryStore *)store central:(FakeCentral *)central {
    self.testEvents = [NSMutableArray array]; self.posts = [NSMutableArray array];
    [self setValue:store forKey:@"bgStore"];
    [self setValue:saved.mutableCopy forKey:@"bgSaved"];
    [self setValue:[NSMutableSet set] forKey:@"bgDisconnecting"];
    [self setValue:[NSMutableSet set] forKey:@"bgRestoredToCancel"];
    [self setValue:[NSMutableArray array] forKey:@"bgStopCallbacks"];
    [self setValue:[NSMutableArray array] forKey:@"bgManagerCallbacks"];
    [self setValue:[NSMutableArray array] forKey:@"bgEvents"];
    [self setValue:@(UIBackgroundTaskInvalid) forKey:@"bgBackgroundTask"];
    centralManager = (id)central; connections = [NSMutableDictionary dictionary];
    NSError *error;
    BOOL valid = [BLEBackgroundStore canRestore:saved now:NSDate.date.timeIntervalSince1970];
    if (valid) check([self bgInstallConfiguration:saved[@"configuration"] error:&error], @"valid recovered engine");
    [self setValue:@(valid) forKey:@"bgArmed"];
}
- (BOOL)hasManager { return centralManager != nil; }
- (void)addForegroundPeripheral:(FakePeripheral *)peripheral { connections[peripheral.identifier] = @{@"peripheral":peripheral}; }
- (void)bgCreateManager {
    if (centralManager) return;
    self.managerCreations++;
    self.recreatedManager = [FakeCentral new];
    self.recreatedManager.state = CBManagerStateUnknown;
    centralManager = (id)self.recreatedManager;
}
- (void)bgRecord:(NSString *)event details:(NSDictionary *)details { [self.testEvents addObject:@{@"event":event, @"details":details}]; }
- (void)bgAfterManagerStateSettles:(void (^)(void))completion { self.settledState = completion; }
- (void)bgPost:(NSDictionary *)incident reporting:(NSDictionary *)reporting completion:(void (^)(NSError *, NSInteger))completion {
    [self.posts addObject:incident];
    completion(self.httpFailure ? [NSError errorWithDomain:@"MockHTTP" code:503 userInfo:nil] : nil, self.httpFailure ? 503 : 200);
}
@end
static NSDictionary *savedState(void) {
    NSDictionary *scope = @{@"accountId":@"synthetic-patient", @"expiresAt":@4000000000};
    NSDictionary *config = @{@"deviceId":@"00000000-0000-4000-8000-000000000001", @"serviceUuid":@"AB00",
        @"notifyCharacteristicUuid":@"AB01", @"writeCharacteristicUuid":@"AB02", @"packetLength":@8, @"checksum":@"sum8",
        @"rules":@[@{@"id":@"event", @"match":@{@"offset":@0, @"bytes":@[@0x42]}, @"acknowledgement":@{@"mode":@"echo", @"maxAttempts":@3}}],
        @"reporting":@{@"url":@"https://example.invalid/test"}, @"restoration":scope};
    return @{@"armed":@YES, @"session":scope, @"configuration":config};
}
static FakePeripheral *peripheral(BOOL subscribed) {
    FakeCharacteristic *notify = [FakeCharacteristic new]; notify.UUID = [CBUUID UUIDWithString:@"AB01"]; notify.properties = CBCharacteristicPropertyNotify; notify.notifying = subscribed;
    uint8_t bytes[] = {0x42, 0, 0, 0, 0, 0, 0, 0x42}; notify.value = [NSData dataWithBytes:bytes length:8];
    FakeCharacteristic *write = [FakeCharacteristic new]; write.UUID = [CBUUID UUIDWithString:@"AB02"]; write.properties = CBCharacteristicPropertyWrite;
    FakeService *service = [FakeService new]; service.UUID = [CBUUID UUIDWithString:@"AB00"]; service.characteristics = @[notify, write];
    FakePeripheral *device = [FakePeripheral new]; device.identifier = [[NSUUID alloc] initWithUUIDString:savedState()[@"configuration"][@"deviceId"]];
    device.state = CBPeripheralStateConnected; device.services = @[service]; device.writes = [NSMutableArray array]; return device;
}
static FakeCentral *central(void) { FakeCentral *central = [FakeCentral new]; central.state = CBManagerStatePoweredOn; central.scanning = YES; return central; }
static void restore(TestPlugin *plugin, FakeCentral *central, FakePeripheral *peripheral) {
    [plugin centralManager:(id)central willRestoreState:@{CBCentralManagerRestoredStatePeripheralsKey:@[peripheral]}];
}
static void receive(TestPlugin *plugin, FakePeripheral *device) {
    [plugin peripheral:(id)device didUpdateValueForCharacteristic:((FakeService *)device.services[0]).characteristics[0] error:nil];
}
int main(void) {
    @autoreleasepool {
        CDVInvokedUrlCommand *startupInitialize = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{}] callbackId:@"startup" className:@"BluetoothLePlugin" methodName:@"initialize"];
        CDVInvokedUrlCommand *startupSuspend = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{@"disarm":@NO}] callbackId:@"startupStop" className:@"BluetoothLePlugin" methodName:@"backgroundStop"];
        for (NSNumber *appState in @[@(UIApplicationStateBackground), @(UIApplicationStateInactive)]) {
            UIApplication.sharedApplication.applicationState = appState.integerValue;
            TestPlugin *startup = [TestPlugin new];
            [startup prepare:savedState() store:[MemoryStore new] central:nil];
            launchPlugin = startup;
            [TestPlugin restoreAtLaunch:appState.integerValue == UIApplicationStateBackground ? nil : @{}];
            check(startup.managerCreations == 1 && [startup.bgStatus[@"ownsBluetooth"] boolValue], @"nil/empty scene launch options start native recovery");
            NSDictionary *event = startup.testEvents.firstObject;
            check([event[@"event"] isEqual:@"native_startup"] && [event[@"details"][@"recoveryEnabled"] boolValue] &&
                ![event[@"details"][@"legacyBluetoothHint"] boolValue] && event[@"details"][@"processId"], @"startup diagnostics identify saved recovery without inventing a launch reason");
            [TestPlugin restoreAtLaunch:@{}];
            check(startup.managerCreations == 1, @"repeated launch entry does not create another central");
            FakePeripheral *restoredDevice = peripheral(YES);
            restore(startup, startup.recreatedManager, restoredDevice);
            check(restoredDevice.subscriptions == 0 && startup.recreatedManager.connects == 0, @"scene startup reuses the restored subscription and connection");
            [startup backgroundStop:startupSuspend];
            NSUInteger initializations = MockForegroundInitializeCalls;
            [startup initialize:startupInitialize];
            check([startup.bgStatus[@"monitoring"] boolValue] && startup.recreatedManager.cancellations == 0 &&
                MockForegroundInitializeCalls == initializations, @"inactive/background startup JS cannot take native recovery ownership");
            receive(startup, restoredDevice);
            check(restoredDevice.writes.count == 1 && startup.posts.count == 1, @"scene launch handles restored ACK and mock delivery without JavaScript readiness");
            // A real foreground transition releases recovery, even while the
            // application is still inactive on its way to becoming active.
            UIApplication.sharedApplication.applicationState = UIApplicationStateInactive;
            [startup bgEnterForeground];
            [startup centralManager:(id)startup.recreatedManager didDisconnectPeripheral:(id)restoredDevice error:nil];
            check(![startup.bgStatus[@"ownsBluetooth"] boolValue], @"foreground entry hands the shared manager back to measurements");
            check(startup.recreatedManager.prematureCommands == 0, @"foreground handoff also defers cancellation until powered-on");
            UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
            startup.recreatedManager.state = CBManagerStateUnknown;
            [startup initialize:startupInitialize];
            check(MockForegroundInitializeCalls == initializations, @"foreground initialize waits for the early manager's unknown state");
            startup.recreatedManager.state = CBManagerStateResetting;
            [startup centralManagerDidUpdateState:(id)startup.recreatedManager];
            check(MockForegroundInitializeCalls == initializations, @"resetting cannot reject pending foreground initialization");
            startup.recreatedManager.state = CBManagerStatePoweredOff;
            [startup centralManagerDidUpdateState:(id)startup.recreatedManager];
            void (^staleInitialization)(void) = startup.settledState;
            check(MockForegroundInitializeCalls == initializations, @"transient powered-off does not reject pending initialization");
            startup.recreatedManager.state = CBManagerStatePoweredOn;
            [startup centralManagerDidUpdateState:(id)startup.recreatedManager];
            staleInitialization();
            check(MockForegroundInitializeCalls == initializations + 1 && MockForegroundInitializeState == CBManagerStatePoweredOn,
                @"settled powered-on registers the pending parent callback once");
            [startup initialize:startupInitialize];
            check(MockForegroundInitializeCalls == initializations + 2 && startup.managerCreations == 1, @"foreground initialization reuses the native launch manager");
        }
        UIApplication.sharedApplication.applicationState = UIApplicationStateBackground;
        for (NSString *mode in @[@"missing", @"disabled", @"expired", @"account", @"pendingSetup"]) {
            NSMutableDictionary *state = savedState().mutableCopy;
            if ([mode isEqual:@"missing"]) state = [NSMutableDictionary dictionary];
            if ([mode isEqual:@"disabled"] || [mode isEqual:@"pendingSetup"]) state[@"armed"] = @NO;
            if ([mode isEqual:@"expired"]) state[@"session"] = @{@"accountId":@"synthetic-patient", @"expiresAt":@1};
            if ([mode isEqual:@"account"]) state[@"session"] = @{@"accountId":@"another-patient", @"expiresAt":@4000000000};
            TestPlugin *blockedStartup = [TestPlugin new];
            [blockedStartup prepare:state store:[MemoryStore new] central:nil];
            launchPlugin = blockedStartup;
            [TestPlugin restoreAtLaunch:@{}];
            check(![blockedStartup hasManager] && ![blockedStartup.bgStatus[@"ownsBluetooth"] boolValue], [mode stringByAppendingString:@" prevents early global manager creation"]);
        }
        TestPlugin *legacy = [TestPlugin new];
        [legacy prepare:@{} store:[MemoryStore new] central:nil]; launchPlugin = legacy;
        [TestPlugin restoreAtLaunch:@{UIApplicationLaunchOptionsBluetoothCentralsKey:@[@"cordova.bluetoothle-background.central.v1"]}];
        FakePeripheral *orphan = peripheral(YES);
        legacy.recreatedManager.scanning = YES;
        restore(legacy, legacy.recreatedManager, orphan); receive(legacy, orphan);
        check(legacy.recreatedManager.cancellations == 0 && legacy.recreatedManager.prematureCommands == 0 &&
            legacy.recreatedManager.isScanning, @"disabled restoration defers scan stop and orphan cancellation until powered-on");
        legacy.recreatedManager.state = CBManagerStatePoweredOn;
        [legacy centralManagerDidUpdateState:(id)legacy.recreatedManager];
        check(legacy.managerCreations == 1 && legacy.recreatedManager.cancellations == 1 && orphan.writes.count == 0 && legacy.posts.count == 0,
            @"legacy launch hint cancels disarmed orphan work without restoring effects");
        check(!legacy.recreatedManager.isScanning && legacy.recreatedManager.prematureCommands == 0, @"restored scan is stopped with a valid powered-on manager");
        [legacy centralManagerDidUpdateState:(id)legacy.recreatedManager];
        check(legacy.recreatedManager.cancellations == 1, @"a second state update does not repeat orphan cancellation");
        CDVInvokedUrlCommand *scanCommand = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{@"services":@[]}] callbackId:@"scan" className:@"BluetoothLePlugin" methodName:@"startScan"];
        legacy.recreatedManager.scanning = YES;
        [legacy startScan:scanCommand];
        [legacy centralManagerDidUpdateState:(id)legacy.recreatedManager];
        check(legacy.recreatedManager.isScanning, @"later foreground scan is not stopped by stale restoration cleanup");
        NSUInteger discoveries = MockForegroundDiscoveries;
        [legacy centralManager:(id)legacy.recreatedManager didDiscoverPeripheral:(id)orphan advertisementData:@{} RSSI:@(-50)];
        [legacy centralManager:(id)legacy.recreatedManager didDiscoverPeripheral:(id)orphan advertisementData:@{} RSSI:@(-51)];
        check(MockForegroundDiscoveries == discoveries + 2, @"disabled SOS forwards all foreground discoveries to the original plugin");
        NSArray *scanEvents = [legacy.testEvents filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
            return [entry[@"event"] isEqual:@"foreground_scan_result"];
        }]];
        check(scanEvents.count == 1, @"foreground discovery diagnostics record once per scan without suppressing callbacks");
        UIApplication.sharedApplication.applicationState = UIApplicationStateInactive;
        TestPlugin *foregroundRestoration = [TestPlugin new]; FakeCentral *foregroundRestorationManager = central(); foregroundRestorationManager.state = CBManagerStateUnknown;
        [foregroundRestoration prepare:savedState() store:[MemoryStore new] central:foregroundRestorationManager];
        [foregroundRestoration bgEnterForeground];
        FakePeripheral *foregroundOrphan = peripheral(YES);
        restore(foregroundRestoration, foregroundRestorationManager, foregroundOrphan);
        check(![foregroundRestoration.bgStatus[@"ownsBluetooth"] boolValue] && foregroundRestorationManager.prematureCommands == 0,
            @"late inactive restoration cannot reclaim ownership after foreground entry");
        foregroundRestorationManager.state = CBManagerStatePoweredOn;
        [foregroundRestoration centralManagerDidUpdateState:(id)foregroundRestorationManager];
        check(foregroundRestorationManager.cancellations == 1 && foregroundRestorationManager.connects == 0,
            @"foreground restoration retires the old connection without enabling SOS");
        UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
        TestPlugin *foregroundStartup = [TestPlugin new];
        [foregroundStartup prepare:savedState() store:[MemoryStore new] central:nil]; launchPlugin = foregroundStartup;
        [TestPlugin restoreAtLaunch:@{}];
        check(foregroundStartup.managerCreations == 1 && ![foregroundStartup.bgStatus[@"ownsBluetooth"] boolValue], @"already active launch creates the manager without claiming background ownership");
        [foregroundStartup initialize:startupInitialize];
        NSUInteger waiting = MockForegroundInitializeCalls;
        foregroundStartup.recreatedManager.state = CBManagerStatePoweredOff;
        [foregroundStartup centralManagerDidUpdateState:(id)foregroundStartup.recreatedManager];
        foregroundStartup.settledState();
        check(MockForegroundInitializeCalls == waiting + 1 && MockForegroundInitializeState == CBManagerStatePoweredOff, @"stable disabled state resolves the pending parent initialization with its normal error");
        [foregroundStartup initialize:startupInitialize];
        check(MockForegroundInitializeCalls == waiting + 1, @"initialize on an already off launch manager also waits for a settled result");
        foregroundStartup.settledState();
        check(MockForegroundInitializeCalls == waiting + 2 && MockForegroundInitializeState == CBManagerStatePoweredOff, @"already off manager retains the normal parent initialization error");
        UIApplication.sharedApplication.applicationState = UIApplicationStateInactive;
        TestPlugin *reconnectStartup = [TestPlugin new];
        MemoryStore *reconnectStore = [MemoryStore new];
        [reconnectStartup prepare:savedState() store:reconnectStore central:nil]; launchPlugin = reconnectStartup;
        [TestPlugin restoreAtLaunch:nil];
        FakePeripheral *cachedDevice = peripheral(NO); cachedDevice.state = CBPeripheralStateDisconnected;
        reconnectStartup.recreatedManager.cached = @[cachedDevice];
        reconnectStartup.recreatedManager.state = CBManagerStatePoweredOn;
        [reconnectStartup centralManagerDidUpdateState:(id)reconnectStartup.recreatedManager];
        check(reconnectStartup.recreatedManager.connects == 1 && cachedDevice.delegate == reconnectStartup, @"inactive launch reconnects the saved watch without a restoration callback or JavaScript");
        cachedDevice.state = CBPeripheralStateConnected;
        [reconnectStartup centralManager:(id)reconnectStartup.recreatedManager didConnectPeripheral:(id)cachedDevice];
        check(cachedDevice.subscriptions == 1, @"native startup restores a missing subscription after reconnect");
        CDVInvokedUrlCommand *disableStartup = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{@"disarm":@YES}] callbackId:@"disable" className:@"BluetoothLePlugin" methodName:@"backgroundStop"];
        [reconnectStartup backgroundStop:disableStartup];
        check(![reconnectStartup.bgStatus[@"armed"] boolValue] && reconnectStore.state == nil && reconnectStartup.recreatedManager.cancellations == 1, @"explicit disable still revokes and tears down inactive startup recovery");
        launchPlugin = nil;
        UIApplication.sharedApplication.applicationState = UIApplicationStateBackground;
        MemoryStore *store = [MemoryStore new]; TestPlugin *plugin = [TestPlugin new]; FakeCentral *manager = central(); FakePeripheral *device = peripheral(YES);
        [plugin prepare:savedState() store:store central:manager]; plugin.httpFailure = YES; restore(plugin, manager, device);
        check(device.delegate == plugin, @"delegate bound before notification callback");
        check([plugin.bgStatus[@"monitoring"] boolValue], @"restored subscription is immediately usable");
        check(device.subscriptions == 0 && manager.connects == 0, @"no competing connection or duplicate subscription");
        check(!manager.scanning, @"foreground scan is stopped");
        CDVInvokedUrlCommand *lateStartup = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{@"disarm":@NO}] callbackId:@"mock" className:@"BluetoothLePlugin" methodName:@"backgroundStop"];
        [plugin backgroundStop:lateStartup];
        check([plugin.bgStatus[@"monitoring"] boolValue] && manager.cancellations == 0, @"cold background JavaScript startup cannot suspend native recovery");
        receive(plugin, device);
        check(device.writes.count == 1 && plugin.posts.count == 1, @"restored notification ACK and HTTP are native");
        check([device.writes[0] isEqual:((FakeCharacteristic *)((FakeService *)device.services[0]).characteristics[0]).value], @"ACK echoes identical bytes");
        check(store.state[@"incidents"] != nil, @"native handler commits ledger");
        check([plugin.testEvents.lastObject[@"event"] isEqual:@"delivery_failed"], @"HTTP failure is distinct from ACK");
        TestPlugin *relaunched = [TestPlugin new]; FakeCentral *otherManager = central(); FakePeripheral *otherDevice = peripheral(YES);
        [relaunched prepare:store.state store:store central:otherManager]; restore(relaunched, otherManager, otherDevice); receive(relaunched, otherDevice);
        check(relaunched.posts.count == 0 && otherDevice.writes.count == 1, @"relaunch deduplicates HTTP and resumes ACK");
        [relaunched onReset]; check([relaunched.bgStatus[@"ownsBluetooth"] boolValue], @"WebView reset does not stop native recovery");
        CDVInvokedUrlCommand *logout = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{}] callbackId:@"mock" className:@"BluetoothLePlugin" methodName:@"backgroundSetSession"];
        [relaunched backgroundSetSession:logout];
        check(store.state == nil && ![relaunched.bgStatus[@"recoveryArmed"] boolValue], @"logout clears durable recovery without a dashboard");
        receive(relaunched, otherDevice);
        check(relaunched.posts.count == 0, @"late notification cannot deliver after logout");

        TestPlugin *partial = [TestPlugin new]; FakeCentral *partialManager = central(); FakePeripheral *partialDevice = peripheral(NO);
        NSArray *services = partialDevice.services; partialDevice.services = @[];
        [partial prepare:savedState() store:[MemoryStore new] central:partialManager]; restore(partial, partialManager, partialDevice);
        check(partialDevice.discoveries == 1, @"missing services resume discovery");
        partialDevice.services = services;
        [partial peripheral:(id)partialDevice didDiscoverServices:nil];
        check(partialDevice.characteristicDiscoveries == 1, @"discovered service resumes characteristics");
        [partial peripheral:(id)partialDevice didDiscoverCharacteristicsForService:services[0] error:nil];
        check(partialDevice.subscriptions == 1, @"missing subscription is enabled once");
        [partial centralManagerDidUpdateState:(id)partialManager];
        [partial peripheral:(id)partialDevice didDiscoverCharacteristicsForService:services[0] error:nil];
        check(partialDevice.subscriptions == 1, @"overlapping restoration callbacks do not duplicate a pending subscription");

        TestPlugin *pending = [TestPlugin new]; FakeCentral *pendingManager = central(); FakePeripheral *pendingDevice = peripheral(NO); pendingDevice.state = CBPeripheralStateConnecting;
        [pending prepare:savedState() store:[MemoryStore new] central:pendingManager]; restore(pending, pendingManager, pendingDevice);
        check(pendingManager.connects == 0 && pendingDevice.discoveries == 0, @"pending restored connection is retained");

        for (NSString *mode in @[@"disabled", @"expired", @"account", @"foreground"]) {
            NSMutableDictionary *state = savedState().mutableCopy;
            if ([mode isEqual:@"disabled"]) state[@"armed"] = @NO;
            if ([mode isEqual:@"expired"]) state[@"session"] = @{@"accountId":@"synthetic-patient", @"expiresAt":@1};
            if ([mode isEqual:@"account"]) state[@"session"] = @{@"accountId":@"another-patient", @"expiresAt":@4000000000};
            UIApplication.sharedApplication.applicationState = [mode isEqual:@"foreground"] ? UIApplicationStateActive : UIApplicationStateBackground;
            TestPlugin *blocked = [TestPlugin new]; FakeCentral *blockedManager = central(); FakePeripheral *blockedDevice = peripheral(YES);
            [blocked prepare:state store:[MemoryStore new] central:blockedManager]; restore(blocked, blockedManager, blockedDevice); receive(blocked, blockedDevice);
            check(blockedManager.cancellations == 1 && blocked.posts.count == 0 && blockedDevice.writes.count == 0, [mode stringByAppendingString:@" prevents restored effects"]);
        }
        UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
        TestPlugin *history = [TestPlugin new];
        [history prepare:@{} store:[MemoryStore new] central:nil];
        check(![history.bgStatus[@"managerInitializedInProcess"] boolValue], @"fresh process has not initialized Bluetooth");
        CDVInvokedUrlCommand *initialize = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{}] callbackId:@"initialize" className:@"BluetoothLePlugin" methodName:@"initialize"];
        [history initialize:initialize];
        check([history.bgStatus[@"managerInitializedInProcess"] boolValue], @"foreground initialization records migration ordering history");
        FakeCentral *startingManager = central();
        [history prepare:@{} store:[MemoryStore new] central:startingManager];
        NSUInteger previousCallbacks = MockForegroundStateCallbacks;
        startingManager.state = CBManagerStateUnknown;
        [history centralManagerDidUpdateState:(id)startingManager];
        startingManager.state = CBManagerStateResetting;
        [history centralManagerDidUpdateState:(id)startingManager];
        check(MockForegroundStateCallbacks == previousCallbacks, @"temporary manager states do not fail foreground initialization");
        startingManager.state = CBManagerStatePoweredOn;
        [history centralManagerDidUpdateState:(id)startingManager];
        startingManager.state = CBManagerStatePoweredOff;
        [history centralManagerDidUpdateState:(id)startingManager];
        check(MockForegroundStateCallbacks == previousCallbacks + 1, @"initial powered-off waits briefly before failing startup");
        void (^staleOff)(void) = history.settledState;
        startingManager.state = CBManagerStatePoweredOn;
        [history centralManagerDidUpdateState:(id)startingManager];
        staleOff();
        check(MockForegroundStateCallbacks == previousCallbacks + 2, @"powered-on invalidates a stale powered-off initialization result");
        startingManager.state = CBManagerStatePoweredOff;
        [history centralManagerDidUpdateState:(id)startingManager];
        history.settledState();
        check(MockForegroundStateCallbacks == previousCallbacks + 3, @"stable powered-off retains the parent callback behavior");
        TestPlugin *setup = [TestPlugin new]; FakeCentral *setupManager = central();
        [setup prepare:savedState() store:[MemoryStore new] central:setupManager];
        setupManager.delegate = setup; setupManager.deferDisconnect = YES;
        FakePeripheral *foregroundDevice = peripheral(YES);
        [setup addForegroundPeripheral:foregroundDevice];
        CDVInvokedUrlCommand *prepareSetup = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{}] callbackId:@"setup" className:@"BluetoothLePlugin" methodName:@"backgroundPrepareAccessorySetup"];
        [setup backgroundPrepareAccessorySetup:prepareSetup];
        check([setup hasManager] && [setup.bgStatus[@"ownsBluetooth"] boolValue], @"setup retains ownership until foreground disconnection completes");
        foregroundDevice.state = CBPeripheralStateDisconnected;
        [setup centralManager:(id)setupManager didDisconnectPeripheral:(id)foregroundDevice error:nil];
        check(![setup hasManager] && setupManager.delegate == nil, @"setup releases the global manager instead of only stopping its scan");
        check([setup.bgStatus[@"ownsBluetooth"] boolValue] && setup.managerCreations == 0, @"picker reservation blocks legacy BLE and does not create a competing manager");
        CDVInvokedUrlCommand *finishSetup = [[CDVInvokedUrlCommand alloc] initWithArguments:@[@{}] callbackId:@"finish" className:@"BluetoothLePlugin" methodName:@"backgroundFinishAccessorySetup"];
        [setup backgroundFinishAccessorySetup:finishSetup];
        check([setup hasManager] && setup.managerCreations == 1, @"picker completion recreates one shared manager");
        check([setup.bgStatus[@"ownsBluetooth"] boolValue], @"recreated manager must report a ready state before foreground ownership is released");
        setup.recreatedManager.state = CBManagerStatePoweredOn;
        [setup centralManagerDidUpdateState:(id)setup.recreatedManager];
        check(![setup.bgStatus[@"ownsBluetooth"] boolValue] && [setup.bgStatus[@"armed"] boolValue], @"powered-on callback releases setup ownership while preserving SOS arming");
        [setup backgroundFinishAccessorySetup:finishSetup];
        check(setup.managerCreations == 1, @"repeated setup completion does not create another manager");
        UIApplication.sharedApplication.applicationState = UIApplicationStateBackground;
        MemoryStore *completedStore = [MemoryStore new];
        TestPlugin *completedPlugin = [TestPlugin new]; FakeCentral *completedManager = central(); FakePeripheral *completedDevice = peripheral(YES);
        [completedPlugin prepare:savedState() store:completedStore central:completedManager];
        restore(completedPlugin, completedManager, completedDevice); receive(completedPlugin, completedDevice);
        [completedPlugin peripheral:(id)completedDevice didWriteValueForCharacteristic:((FakeService *)completedDevice.services[0]).characteristics[1] error:nil];
        check([completedStore.state[@"incidents"][@"event"][@"acknowledged"] boolValue], @"real native write callback persists ACK completion into recovery storage");
        NSString *completedID = completedStore.state[@"incidents"][@"event"][@"incidentId"];
        NSMutableDictionary *laterState = completedStore.state.mutableCopy;
        NSMutableDictionary *laterIncidents = [laterState[@"incidents"] mutableCopy];
        NSMutableDictionary *laterIncident = [laterIncidents[@"event"] mutableCopy];
        laterIncident[@"lastReceived"] = @(NSProcessInfo.processInfo.systemUptime - 20);
        laterIncidents[@"event"] = laterIncident; laterState[@"incidents"] = laterIncidents;
        TestPlugin *laterPlugin = [TestPlugin new]; FakeCentral *laterManager = central(); FakePeripheral *laterDevice = peripheral(YES);
        [laterPlugin prepare:laterState store:[MemoryStore new] central:laterManager];
        restore(laterPlugin, laterManager, laterDevice); receive(laterPlugin, laterDevice);
        check(laterPlugin.posts.count == 1 && ![laterPlugin.posts[0][@"incidentId"] isEqual:completedID], @"native restored later SOS delivers once with a new incident identity");
        [laterPlugin backgroundStop:disableStartup];
        [laterPlugin centralManager:(id)laterManager didDisconnectPeripheral:(id)laterDevice error:nil];
        UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
        CDVInvokedUrlCommand *configureAgain = [[CDVInvokedUrlCommand alloc] initWithArguments:@[savedState()[@"configuration"]] callbackId:@"configureAgain" className:@"BluetoothLePlugin" methodName:@"backgroundConfigure"];
        [laterPlugin backgroundConfigure:configureAgain];
        NSDictionary *configuredIncidents = [laterPlugin valueForKey:@"bgSaved"][@"incidents"];
        check(configuredIncidents.count == 0, @"explicit disable and reconfigure discard the previous in-memory incident ledger");
        check(laterPlugin.posts.count == 1, @"resetting the disabled monitor never replays a request");
        printf("Native restoration/ownership passed (%lu checks), using mocked UIKit/Bluetooth/HTTP/Keychain.\n", (unsigned long)checks);
    }
}
