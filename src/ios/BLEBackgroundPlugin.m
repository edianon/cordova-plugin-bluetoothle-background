#import "BLEBackgroundPlugin.h"
#import "BLEBackgroundProtocol.h"
#import "BLEBackgroundReporting.h"
#import <UIKit/UIKit.h>
#import <os/log.h>

@interface BLEBackgroundPlugin () <NSURLSessionTaskDelegate>
@property(nonatomic) BOOL bgArmed;
@property(nonatomic) BOOL bgRunning;
@property(nonatomic) BOOL bgOwnsBluetooth;
@property(nonatomic) NSUUID *bgDeviceID;
@property(nonatomic) CBPeripheral *bgPeripheral;
@property(nonatomic) CBCharacteristic *bgNotifyCharacteristic;
@property(nonatomic) CBCharacteristic *bgWriteCharacteristic;
@property(nonatomic) NSMutableSet<NSUUID *> *bgDisconnecting;
@property(nonatomic) NSMutableArray<NSString *> *bgStopCallbacks;
@property(nonatomic) NSMutableArray<NSDictionary *> *bgEvents;
@property(nonatomic) BLEBackgroundProtocol *bgProtocol;
@property(nonatomic, copy) void (^bgWriteCompletion)(NSError *);
@property(nonatomic) NSUInteger bgWriteGeneration;
@property(nonatomic) NSUInteger bgConnectionFailures;
@property(nonatomic) NSURLSession *bgSession;
@property(nonatomic) UIBackgroundTaskIdentifier bgBackgroundTask;
@end

@implementation BLEBackgroundPlugin
- (void)pluginInitialize {
    [super pluginInitialize];
    self.bgDisconnecting = [NSMutableSet set];
    self.bgStopCallbacks = [NSMutableArray array];
    self.bgBackgroundTask = UIBackgroundTaskInvalid;
    NSData *saved = [NSData dataWithContentsOfURL:[self bgLogURL]];
    NSArray *events = saved ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
    self.bgEvents = [events isKindOfClass:NSArray.class] ? [events mutableCopy] : [NSMutableArray array];
    while (self.bgEvents.count > 1000) [self.bgEvents removeObjectAtIndex:0];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    self.bgSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(bgEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notifications addObserver:self selector:@selector(bgEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (NSError *)bgError:(NSString *)message {
    return [NSError errorWithDomain:@"BluetoothLEBackground" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

- (NSURL *)bgLogURL {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:@"bluetoothle-background-events.json"];
}

- (NSString *)bgAppState {
    switch (UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateBackground: return @"background";
        case UIApplicationStateInactive: return @"inactive";
        default: return @"foreground";
    }
}

- (void)bgRecord:(NSString *)event details:(NSDictionary *)details {
    NSMutableDictionary *entry = [details mutableCopy];
    entry[@"event"] = event;
    entry[@"eventAt"] = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    entry[@"eventAppState"] = [self bgAppState];
    if (self.bgDeviceID && !entry[@"deviceId"]) entry[@"deviceId"] = self.bgDeviceID.UUIDString;
    // Payload, metadata, device addresses and HTTP headers never go to public OS logs.
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[BLEBackground] event=%{public}@ state=%{public}@", event, entry[@"eventAppState"]);
    if ([event isEqual:@"notification_repeated"]) return;
    [self.bgEvents addObject:entry];
    NSUInteger maximum = [self.bgProtocol.configuration[@"maxEvents"] ?: @100 unsignedIntegerValue];
    while (self.bgEvents.count > maximum) [self.bgEvents removeObjectAtIndex:0];
    NSError *error;
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.bgEvents options:0 error:&error];
    if (json) [json writeToURL:[self bgLogURL] options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error];
    if (error) os_log_error(OS_LOG_DEFAULT, "[BLEBackground] Event persistence failed");
}

- (NSDictionary *)bgStatus {
    return @{@"available":@([self bgAvailable]), @"configured":@(self.bgProtocol != nil), @"armed":@(self.bgArmed),
        @"ownsBluetooth":@(self.bgOwnsBluetooth), @"monitoring":@(self.bgRunning && self.bgNotifyCharacteristic.isNotifying),
        @"restorationSupported":@NO, @"events":self.bgEvents};
}

- (BOOL)bgAvailable {
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    return NO;
#else
    if (@available(iOS 14.0, *)) {
        if (NSProcessInfo.processInfo.isiOSAppOnMac) return NO;
    }
    return YES;
#endif
}

- (void)bgReply:(CDVInvokedUrlCommand *)command error:(NSString *)error {
    CDVPluginResult *result = error ? [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error] :
        [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self bgStatus]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)backgroundConfigure:(CDVInvokedUrlCommand *)command {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.bgOwnsBluetooth) {
        [self bgReply:command error:@"Configure in the foreground after background ownership has ended."]; return;
    }
    NSError *error;
    BLEBackgroundProtocol *engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:command.arguments.firstObject error:&error];
    if (!engine) { [self bgReply:command error:error.localizedDescription]; return; }
    self.bgArmed = NO;
    self.bgProtocol = engine;
    self.bgDeviceID = [[NSUUID alloc] initWithUUIDString:engine.configuration[@"deviceId"]];
    NSDictionary *reporting = engine.configuration[@"reporting"];
    __weak typeof(self) weakSelf = self;
    engine.recordEvent = ^(NSString *event, NSDictionary *details) { [weakSelf bgRecord:event details:details]; };
    engine.writePacket = ^(NSData *packet, NSUInteger timeoutMs, void (^completion)(NSError *)) {
        [weakSelf bgWrite:packet timeoutMs:timeoutMs completion:completion];
    };
    engine.deliverIncident = ^(NSDictionary *incident, void (^completion)(NSError *)) {
        [weakSelf bgPost:incident reporting:reporting completion:^(NSError *error, NSInteger status) { completion(error); }];
    };
    [self bgRecord:@"configured" details:@{}];
    [self bgReply:command error:nil];
}

- (void)backgroundStart:(CDVInvokedUrlCommand *)command {
    if (![self bgAvailable]) { [self bgReply:command error:@"Background monitoring requires a physical iOS device; iOS apps on Mac, Catalyst and Simulator are unsupported."]; return; }
    if (!self.bgProtocol) { [self bgReply:command error:@"Configure notification handling first."]; return; }
    if (!centralManager || centralManager.state != CBManagerStatePoweredOn) {
        [self bgReply:command error:@"Initialize and enable Bluetooth through cordova-plugin-bluetoothle first."]; return;
    }
    self.bgArmed = YES;
    [self bgRecord:@"armed" details:@{}];
    [self bgEnterBackground];
    [self bgReply:command error:nil];
}

- (void)backgroundGetStatus:(CDVInvokedUrlCommand *)command { [self bgReply:command error:nil]; }

- (void)backgroundClearEvents:(CDVInvokedUrlCommand *)command {
    [self.bgEvents removeAllObjects];
    [self bgRecord:@"events_cleared" details:@{}];
    [self bgReply:command error:nil];
}

- (void)backgroundPreflight:(CDVInvokedUrlCommand *)command {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !self.bgProtocol.configuration[@"reporting"]) {
        [self bgReply:command error:@"Configure reporting and run preflight in the foreground."]; return;
    }
    [self bgPost:@{@"event":@"preflight"} reporting:self.bgProtocol.configuration[@"reporting"] completion:^(NSError *error, NSInteger status) {
        CDVPluginResult *result = error ? [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription] :
            [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"statusCode":@(status)}];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)backgroundStop:(CDVInvokedUrlCommand *)command {
    NSDictionary *options = command.arguments.firstObject;
    if ([options[@"disarm"] boolValue]) self.bgArmed = NO;
    if (!self.bgOwnsBluetooth) { [self bgReply:command error:nil]; return; }
    [self.bgStopCallbacks addObject:command.callbackId];
    [self bgEnterForeground];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (![self.bgStopCallbacks containsObject:command.callbackId]) return;
        // Reconcile an already-disconnected peripheral before timing out. Never
        // release an actually live native connection just to satisfy a JS timeout.
        [self bgEnterForeground];
        if (![self.bgStopCallbacks containsObject:command.callbackId]) return;
        [self.bgStopCallbacks removeObject:command.callbackId];
        [self bgReply:command error:@"Background teardown timed out; ownership is retained. Retry stop or inspect getStatus before restarting foreground BLE."];
    });
}

- (void)bgEnterBackground {
    if (!self.bgArmed || self.bgOwnsBluetooth || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) return;
    self.bgOwnsBluetooth = YES;
    self.bgRunning = YES;
    self.bgConnectionFailures = 0;
    [self bgRecord:@"background_handoff_started" details:@{}];
    self.bgBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Configured BLE background handoff" expirationHandler:^{
        [self bgRecord:@"handoff_expired" details:@{}];
        [self bgEnterForeground];
    }];
    if (centralManager.isScanning) [centralManager stopScan];
    // Reuse the superclass's manager. Wait for EVERY existing connection to end.
    // No JavaScript callback, timer, or second central manager is needed for takeover.
    for (NSDictionary *connection in connections.allValues) {
        CBPeripheral *peripheral = connection[@"peripheral"];
        if (peripheral && peripheral.state != CBPeripheralStateDisconnected) [self.bgDisconnecting addObject:peripheral.identifier];
    }
    for (NSDictionary *connection in connections.allValues) {
        CBPeripheral *peripheral = connection[@"peripheral"];
        if (peripheral && [self.bgDisconnecting containsObject:peripheral.identifier]) [centralManager cancelPeripheralConnection:peripheral];
    }
    if (self.bgDisconnecting.count == 0) [self bgConnect];
}

- (void)bgEndHandoffTime {
    if (self.bgBackgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.bgBackgroundTask];
        self.bgBackgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)bgConnect {
    if (!self.bgRunning || !self.bgArmed || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
        [self bgFinishStop]; return;
    }
    if (centralManager.state != CBManagerStatePoweredOn) {
        [self bgRecord:@"bluetooth_unavailable" details:@{}]; [self bgEndHandoffTime]; return;
    }
    NSArray *peripherals = [centralManager retrievePeripheralsWithIdentifiers:@[self.bgDeviceID]];
    if (peripherals.count == 0) {
        [self bgRecord:@"device_not_cached" details:@{}]; [self bgEnterForeground]; return;
    }
    self.bgPeripheral = peripherals.firstObject;
    self.bgPeripheral.delegate = self;
    writeQIsRunning = NO;
    [self.bgProtocol resetStream];
    [self bgRecord:@"device_connecting" details:@{}];
    [centralManager connectPeripheral:self.bgPeripheral options:nil];
    // Core Bluetooth maintains the pending connection while the app is suspended.
    [self bgEndHandoffTime];
}

- (void)bgEnterForeground {
    self.bgRunning = NO;
    self.bgNotifyCharacteristic = nil;
    self.bgWriteCharacteristic = nil;
    [self bgCompleteWrite:[self bgError:@"Background connection ended before acknowledgement completed."]];
    // A Bluetooth power change can leave no cancellation callback to wait for.
    for (NSUUID *identifier in self.bgDisconnecting.copy) {
        CBPeripheral *peripheral = connections[identifier][@"peripheral"];
        if (!peripheral || peripheral.state == CBPeripheralStateDisconnected) [self.bgDisconnecting removeObject:identifier];
    }
    if (self.bgPeripheral && self.bgPeripheral.state != CBPeripheralStateDisconnected) {
        [centralManager cancelPeripheralConnection:self.bgPeripheral];
    } else if (self.bgDisconnecting.count == 0) [self bgFinishStop];
}

- (void)bgFinishStop {
    BOOL wasOwner = self.bgOwnsBluetooth;
    self.bgOwnsBluetooth = NO;
    self.bgRunning = NO;
    self.bgPeripheral = nil;
    [self.bgProtocol resetStream];
    [self bgEndHandoffTime];
    if (wasOwner) [self bgRecord:@"background_monitor_stopped" details:@{}];
    for (NSString *callback in self.bgStopCallbacks) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self bgStatus]];
        [self.commandDelegate sendPluginResult:result callbackId:callback];
    }
    [self.bgStopCallbacks removeAllObjects];
}

- (void)bgWrite:(NSData *)packet timeoutMs:(NSUInteger)timeoutMs completion:(void (^)(NSError *))completion {
    if (!self.bgRunning || !self.bgWriteCharacteristic || self.bgPeripheral.state != CBPeripheralStateConnected) {
        completion([self bgError:@"Configured command characteristic is unavailable."]); return;
    }
    if (packet.length > [self.bgPeripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse]) {
        completion([self bgError:@"Acknowledgement exceeds this connection's maximum write length."]); return;
    }
    self.bgWriteCompletion = completion;
    NSUInteger generation = ++self.bgWriteGeneration;
    [self.bgPeripheral writeValue:packet forCharacteristic:self.bgWriteCharacteristic type:CBCharacteristicWriteWithResponse];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (generation != self.bgWriteGeneration || !self.bgWriteCompletion) return;
        // Retire this connection before another write can start after a timeout.
        self.bgNotifyCharacteristic = nil;
        self.bgWriteCharacteristic = nil;
        [self bgCompleteWrite:[self bgError:@"BLE acknowledgement timed out."]];
        [centralManager cancelPeripheralConnection:self.bgPeripheral];
    });
}

- (void)bgCompleteWrite:(NSError *)error {
    void (^completion)(NSError *) = self.bgWriteCompletion;
    self.bgWriteCompletion = nil;
    if (completion) completion(error);
}

- (void)bgPost:(NSDictionary *)payload reporting:(NSDictionary *)reporting completion:(void (^)(NSError *, NSInteger))completion {
    NSError *requestError;
    NSMutableURLRequest *request = [BLEBackgroundReporting requestForIncident:payload reporting:reporting
        sentAt:[NSISO8601DateFormatter.new stringFromDate:NSDate.date] appState:[self bgAppState] error:&requestError];
    if (!request) { completion(requestError, 0); return; }
    __block UIBackgroundTaskIdentifier backgroundTask = UIBackgroundTaskInvalid;
    NSURLSessionDataTask *task = [self.bgSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSInteger status = http.statusCode;
        if (!error && (status < 200 || status >= 300)) error = [self bgError:[NSString stringWithFormat:@"HTTP %ld", (long)status]];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error, status);
            if (backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:backgroundTask];
                backgroundTask = UIBackgroundTaskInvalid;
            }
        });
    }];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Bluetooth background POST" expirationHandler:^{
            [task cancel];
            if (backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:backgroundTask];
                backgroundTask = UIBackgroundTaskInvalid;
            }
        }];
    }
    [task resume];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Never redirect app-supplied reporting headers to another destination.
    completionHandler(nil);
}

// All foreground operations remain the installed plugin's implementation.
// Reject late JS operations during native ownership instead of silently hanging.
- (BOOL)bgBlockCommand:(CDVInvokedUrlCommand *)command {
    if (!self.bgOwnsBluetooth && !(self.bgArmed && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)) return NO;
    [self bgReply:command error:@"Bluetooth is owned by the native background monitor."];
    return YES;
}
#define BG_GUARD(method) - (void)method:(CDVInvokedUrlCommand *)command { if (![self bgBlockCommand:command]) [super method:command]; }
BG_GUARD(initialize)
BG_GUARD(startScan)
BG_GUARD(stopScan)
BG_GUARD(connect)
BG_GUARD(reconnect)
BG_GUARD(disconnect)
BG_GUARD(close)
BG_GUARD(discover)
BG_GUARD(services)
BG_GUARD(characteristics)
BG_GUARD(descriptors)
BG_GUARD(read)
BG_GUARD(subscribe)
BG_GUARD(unsubscribe)
BG_GUARD(write)
BG_GUARD(writeQ)
BG_GUARD(readDescriptor)
BG_GUARD(writeDescriptor)
BG_GUARD(rssi)
#undef BG_GUARD

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [super centralManagerDidUpdateState:central];
    if (self.bgRunning && central.state == CBManagerStatePoweredOn && !self.bgPeripheral && self.bgDisconnecting.count == 0) [self bgConnect];
    if (self.bgOwnsBluetooth && central.state != CBManagerStatePoweredOn) {
        [self bgRecord:@"bluetooth_unavailable" details:@{}];
        self.bgNotifyCharacteristic = nil;
        self.bgWriteCharacteristic = nil;
        [self bgCompleteWrite:[self bgError:@"Bluetooth became unavailable."]];
        // Powered-off/reset managers can omit individual disconnect callbacks.
        // Retain ownership while armed, but do not retain a stale peripheral
        // that would prevent reconnection on the next powered-on callback.
        if (central.state == CBManagerStatePoweredOff || central.state == CBManagerStateResetting ||
            central.state == CBManagerStateUnauthorized || central.state == CBManagerStateUnsupported) {
            self.bgPeripheral = nil;
            [self.bgDisconnecting removeAllObjects];
            [self bgEndHandoffTime];
            if (!self.bgRunning) [self bgFinishStop];
        }
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (peripheral == self.bgPeripheral && self.bgOwnsBluetooth) {
        if (!self.bgRunning) { [central cancelPeripheralConnection:peripheral]; return; }
        [self bgRecord:@"device_connected" details:@{}];
        [peripheral discoverServices:@[[CBUUID UUIDWithString:self.bgProtocol.configuration[@"serviceUuid"]]]];
        return;
    }
    [super centralManager:central didConnectPeripheral:peripheral];
    if ([self.bgDisconnecting containsObject:peripheral.identifier]) [central cancelPeripheralConnection:peripheral];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral == self.bgPeripheral && self.bgOwnsBluetooth) {
        self.bgConnectionFailures++;
        if (self.bgConnectionFailures >= [self.bgProtocol.configuration[@"maxConnectionFailures"] ?: @3 unsignedIntegerValue]) {
            self.bgRunning = NO;
            [self bgRecord:@"connection_retry_limit" details:@{}];
        }
    }
    if ((peripheral == self.bgPeripheral && self.bgOwnsBluetooth) || [self.bgDisconnecting containsObject:peripheral.identifier])
        [self centralManager:central didDisconnectPeripheral:peripheral error:error];
    else [super centralManager:central didFailToConnectPeripheral:peripheral error:error];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral == self.bgPeripheral && self.bgOwnsBluetooth) {
        [self bgRecord:@"device_disconnected" details:error ? @{@"error":error.localizedDescription} : @{}];
        self.bgNotifyCharacteristic = nil;
        self.bgWriteCharacteristic = nil;
        [self bgCompleteWrite:[self bgError:@"Device disconnected."]];
        self.bgPeripheral = nil;
        if (self.bgRunning && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) [self bgConnect];
        else [self bgFinishStop];
        return;
    }
    [super centralManager:central didDisconnectPeripheral:peripheral error:error];
    if ([self.bgDisconnecting containsObject:peripheral.identifier]) {
        [self.bgDisconnecting removeObject:peripheral.identifier];
        if (self.bgDisconnecting.count == 0) {
            if (self.bgRunning) [self bgConnect]; else [self bgFinishStop];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didDiscoverServices:error]; return; }
    if (!self.bgRunning) return;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"serviceUuid"]]] && !error) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:self.bgProtocol.configuration[@"notifyCharacteristicUuid"]], [CBUUID UUIDWithString:self.bgProtocol.configuration[@"writeCharacteristicUuid"]]] forService:service]; return;
        }
    }
    [self bgRecord:@"gatt_failed" details:@{@"error":error.localizedDescription ?: @"Configured service missing"}];
    [self bgEnterForeground];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didDiscoverCharacteristicsForService:service error:error]; return; }
    if (!self.bgRunning || ![service.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"serviceUuid"]]]) return;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"notifyCharacteristicUuid"]]]) self.bgNotifyCharacteristic = characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"writeCharacteristicUuid"]]]) self.bgWriteCharacteristic = characteristic;
    }
    if (error || !(self.bgNotifyCharacteristic.properties & CBCharacteristicPropertyNotify) || !(self.bgWriteCharacteristic.properties & CBCharacteristicPropertyWrite)) {
        [self bgRecord:@"gatt_failed" details:@{@"error":error.localizedDescription ?: @"Configured notify/write characteristics missing"}];
        [self bgEnterForeground]; return;
    }
    [peripheral setNotifyValue:YES forCharacteristic:self.bgNotifyCharacteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didUpdateNotificationStateForCharacteristic:characteristic error:error]; return; }
    if (!self.bgRunning || characteristic != self.bgNotifyCharacteristic) return;
    [self bgRecord:(!error && characteristic.isNotifying) ? @"notifications_enabled" : @"notifications_failed" details:error ? @{@"error":error.localizedDescription} : @{}];
    if (!error && characteristic.isNotifying) self.bgConnectionFailures = 0;
    if (error || !characteristic.isNotifying) [self bgEnterForeground];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:error]; return; }
    if (!self.bgRunning || error || characteristic != self.bgNotifyCharacteristic || !characteristic.isNotifying) return;
    NSDictionary *context = @{@"receivedAt":[NSISO8601DateFormatter.new stringFromDate:NSDate.date], @"receivedAppState":[self bgAppState], @"deviceId":self.bgDeviceID.UUIDString};
    [self.bgProtocol receiveData:characteristic.value atTime:NSProcessInfo.processInfo.systemUptime context:context];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didWriteValueForCharacteristic:characteristic error:error]; return; }
    if (characteristic == self.bgWriteCharacteristic) [self bgCompleteWrite:error];
}

- (void)onReset {
    self.bgArmed = NO;
    [self bgEnterForeground];
    [super onReset];
}

- (void)dispose {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.bgSession invalidateAndCancel];
    [super dispose];
}
@end
