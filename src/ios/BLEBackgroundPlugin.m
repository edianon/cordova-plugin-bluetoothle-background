#import "BLEBackgroundPlugin.h"
#import "BLEBackgroundProtocol.h"
#import "BLEBackgroundReporting.h"
#import "BLEBackgroundStore.h"
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <math.h>

@interface BLEBackgroundPlugin () <NSURLSessionTaskDelegate>
@property(nonatomic) BOOL bgInitialized;
@property(nonatomic) BLEBackgroundStore *bgStore;
@property(nonatomic) NSMutableDictionary *bgSaved;
@property(nonatomic) BOOL bgRestored;
@property(nonatomic) NSMutableSet<CBPeripheral *> *bgRestoredToCancel;
@property(nonatomic) BOOL bgRestoredScanToStop;
@property(nonatomic) BOOL bgForegroundScanObserved;
@property(nonatomic) NSUInteger bgDiscoveryStage;
@property(nonatomic) BOOL bgSubscriptionPending;
@property(nonatomic) BOOL bgAccessorySetup;
@property(nonatomic) BOOL bgManagerInitializedInProcess;
@property(nonatomic) NSUInteger bgManagerStateRevision;
@property(nonatomic) NSMutableArray<NSString *> *bgManagerCallbacks;
@property(nonatomic) CDVInvokedUrlCommand *bgInitializeCommand;
@property(nonatomic) BOOL bgLaunchHandled;
@property(nonatomic) BOOL bgRecoveringAtLaunch;
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
@property(nonatomic) NSMutableSet<NSURLSessionTask *> *bgRequests;
@property(nonatomic) UIBackgroundTaskIdentifier bgBackgroundTask;
@end

static NSString *const BGRestoreIdentifier = @"cordova.bluetoothle-background.central.v1";
static BLEBackgroundPlugin *BGSharedPlugin;

@implementation BLEBackgroundPlugin
+ (instancetype)sharedPlugin {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BGSharedPlugin = [[self alloc] init];
        [BGSharedPlugin pluginInitialize];
    });
    return BGSharedPlugin;
}

// The launch entry point and the Cordova registration must bind the SAME object.
// Otherwise two managers can claim the same restoration identifier and peripheral.
- (instancetype)initWithWebViewEngine:(WKWebView *)webView {
    BLEBackgroundPlugin *plugin = [BLEBackgroundPlugin sharedPlugin];
    plugin.webViewEngine = webView;
    return plugin;
}

+ (void)restoreAtLaunch:(NSDictionary *)launchOptions {
    NSArray *identifiers = launchOptions[UIApplicationLaunchOptionsBluetoothCentralsKey];
    BLEBackgroundPlugin *plugin = [self sharedPlugin];
    if (plugin.bgLaunchHandled) return;
    plugin.bgLaunchHandled = YES;
    BOOL legacyHint = [identifiers containsObject:BGRestoreIdentifier];
    BOOL recover = plugin.bgArmed && plugin.bgProtocol &&
        [BLEBackgroundStore canRestore:plugin.bgSaved now:NSDate.date.timeIntervalSince1970];
    [plugin bgRecord:@"native_startup" details:@{@"legacyBluetoothHint":@(legacyHint),
        @"recoveryEnabled":@(recover), @"processId":@(NSProcessInfo.processInfo.processIdentifier)}];
    // Scene-based apps receive nil launch options. Recreate the SAME central
    // from valid saved intent on every launch, before any WebView is required.
    // Disarmed/pending accessory migration must not initialize a global manager.
    if (plugin.bgAccessorySetup || (!recover && !legacyHint)) return;
    plugin.bgRecoveringAtLaunch = recover && UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    if (plugin.bgRecoveringAtLaunch) {
        plugin.bgOwnsBluetooth = YES;
        plugin.bgRunning = YES;
    }
    // A legacy hint also permits cancelling orphan restored work when disarmed.
    [plugin bgCreateManager];
    [plugin bgRecord:@"recovery_manager_initialized" details:@{@"recoveryEnabled":@(recover)}];
}

- (void)bgCreateManager {
    if (centralManager) return;
    self.bgManagerInitializedInProcess = YES;
    connections = [NSMutableDictionary dictionary];
    centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:@{
        CBCentralManagerOptionRestoreIdentifierKey:BGRestoreIdentifier,
        CBCentralManagerOptionShowPowerAlertKey:@NO}];
}

- (void)pluginInitialize {
    if (self.bgInitialized) return;
    self.bgInitialized = YES;
    [super pluginInitialize];
    self.bgStore = [BLEBackgroundStore new];
    NSError *recoveryError;
    self.bgSaved = [[self.bgStore load:&recoveryError] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.bgDisconnecting = [NSMutableSet set];
    self.bgRestoredToCancel = [NSMutableSet set];
    self.bgStopCallbacks = [NSMutableArray array];
    self.bgManagerCallbacks = [NSMutableArray array];
    self.bgBackgroundTask = UIBackgroundTaskInvalid;
    NSData *saved = [NSData dataWithContentsOfURL:[self bgLogURL]];
    NSArray *events = saved ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
    self.bgEvents = [events isKindOfClass:NSArray.class] ? [events mutableCopy] : [NSMutableArray array];
    while (self.bgEvents.count > 1000) [self.bgEvents removeObjectAtIndex:0];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    self.bgSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    self.bgRequests = [NSMutableSet set];
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(bgEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notifications addObserver:self selector:@selector(bgEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    if (@available(iOS 13.0, *)) {
        [notifications addObserver:self selector:@selector(bgEnterBackground) name:UISceneDidEnterBackgroundNotification object:nil];
        [notifications addObserver:self selector:@selector(bgEnterForeground) name:UISceneWillEnterForegroundNotification object:nil];
    }
    if ([BLEBackgroundStore canRestore:self.bgSaved now:NSDate.date.timeIntervalSince1970]) {
        NSError *error;
        if ([self bgInstallConfiguration:self.bgSaved[@"configuration"] error:&error]) self.bgArmed = YES;
        else { self.bgSaved[@"armed"] = @NO; [self.bgStore invalidate:nil]; }
    }
    if (recoveryError) [self bgRecord:@"recovery_unavailable" details:@{}];
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
        @"restorationSupported":@YES, @"restored":@(self.bgRestored), @"deviceId":self.bgDeviceID.UUIDString ?: @"", @"managerInitializedInProcess":@(self.bgManagerInitializedInProcess), @"recoveryArmed":@([BLEBackgroundStore canRestore:self.bgSaved now:NSDate.date.timeIntervalSince1970]), @"events":self.bgEvents};
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
    if (![self bgInstallConfiguration:command.arguments.firstObject error:&error]) {
        [self bgReply:command error:error.localizedDescription]; return;
    }
    self.bgArmed = NO;
    self.bgSaved[@"armed"] = @NO;
    self.bgSaved[@"configuration"] = self.bgProtocol.configuration;
    if (!self.bgProtocol.configuration[@"restoration"]) [self.bgStore invalidate:nil];
    if (self.bgProtocol.configuration[@"restoration"] && ![self.bgStore save:self.bgSaved error:&error]) {
        self.bgProtocol = nil;
        [self bgReply:command error:error.localizedDescription ?: @"Could not save recovery configuration."]; return;
    }
    [self bgRecord:@"configured" details:@{}];
    [self bgReply:command error:nil];
}

- (BOOL)bgInstallConfiguration:(NSDictionary *)configuration error:(NSError **)error {
    BLEBackgroundProtocol *engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:configuration error:error];
    if (!engine) return NO;
    NSDictionary *scope = configuration[@"restoration"];
    if (scope && (![scope isKindOfClass:NSDictionary.class] ||
        ![scope[@"accountId"] isEqual:self.bgSaved[@"session"][@"accountId"]] ||
        ![scope[@"expiresAt"] isKindOfClass:NSNumber.class] ||
        [scope[@"expiresAt"] doubleValue] <= NSDate.date.timeIntervalSince1970 ||
        [scope[@"expiresAt"] doubleValue] > [self.bgSaved[@"session"][@"expiresAt"] doubleValue])) {
        if (error) *error = [self bgError:@"Recovery requires a matching signed-in session with an unexpired credential."];
        return NO;
    }
    NSDictionary *previous = self.bgProtocol.configuration ?: self.bgSaved[@"configuration"];
    BOOL sameProtocol = self.bgSaved[@"configuration"] && [previous[@"deviceId"] isEqual:configuration[@"deviceId"]] &&
        [previous[@"rules"] isEqual:configuration[@"rules"]] &&
        [previous[@"serviceUuid"] isEqual:configuration[@"serviceUuid"]] &&
        [previous[@"notifyCharacteristicUuid"] isEqual:configuration[@"notifyCharacteristicUuid"]] &&
        [previous[@"writeCharacteristicUuid"] isEqual:configuration[@"writeCharacteristicUuid"]] &&
        [previous[@"packetLength"] isEqual:configuration[@"packetLength"]] &&
        [previous[@"checksum"] isEqual:configuration[@"checksum"]] &&
        [previous[@"restoration"][@"accountId"] isEqual:scope[@"accountId"]];
    NSDictionary *incidents = sameProtocol ? (self.bgProtocol ? [self.bgProtocol incidentSnapshot] : self.bgSaved[@"incidents"]) : nil;
    if (incidents && ![engine restoreIncidents:incidents afterRelaunch:self.bgProtocol == nil]) {
        if (error) *error = [self bgError:@"Recovery incident ledger is invalid. Disable SOS and configure again."]; return NO;
    }
    self.bgProtocol = engine;
    self.bgDeviceID = [[NSUUID alloc] initWithUUIDString:engine.configuration[@"deviceId"]];
    self.bgSaved[@"incidents"] = [engine incidentSnapshot];
    NSDictionary *reporting = engine.configuration[@"reporting"];
    __weak typeof(self) weakSelf = self;
    engine.recordEvent = ^(NSString *event, NSDictionary *details) { [weakSelf bgRecord:event details:details]; };
    engine.writePacket = ^(NSData *packet, NSUInteger timeoutMs, void (^completion)(NSError *)) {
        [weakSelf bgWrite:packet timeoutMs:timeoutMs completion:completion];
    };
    engine.deliverIncident = ^(NSDictionary *incident, void (^completion)(NSError *)) {
        [weakSelf bgPost:incident reporting:reporting completion:^(NSError *error, NSInteger status) { completion(error); }];
    };
    if (scope) engine.persistIncidents = ^BOOL(NSDictionary *snapshot) {
        BLEBackgroundPlugin *plugin = weakSelf;
        if (!plugin || ![plugin bgRecoveryValid]) return NO;
        plugin.bgSaved[@"incidents"] = snapshot;
        return [plugin.bgStore save:plugin.bgSaved error:nil];
    };
    return YES;
}

- (BOOL)bgRecoveryValid {
    return !self.bgProtocol.configuration[@"restoration"] ||
        [BLEBackgroundStore canRestore:self.bgSaved now:NSDate.date.timeIntervalSince1970];
}

- (void)backgroundSetSession:(CDVInvokedUrlCommand *)command {
    NSDictionary *session = [command argumentAtIndex:0 withDefault:@{} andClass:NSDictionary.class];
    NSString *account = session[@"accountId"];
    BOOL valid = [account isKindOfClass:NSString.class] && account.length &&
        [session[@"expiresAt"] isKindOfClass:NSNumber.class] &&
        isfinite([session[@"expiresAt"] doubleValue]) && [session[@"expiresAt"] doubleValue] > NSDate.date.timeIntervalSince1970;
    BOOL sameAccount = valid && [account isEqual:self.bgSaved[@"session"][@"accountId"]];
    NSError *error;
    if (!sameAccount) {
        self.bgArmed = NO;
        for (NSURLSessionTask *task in self.bgRequests.copy) [task cancel];
        [self.bgStore invalidate:&error];
        self.bgSaved = [NSMutableDictionary dictionary];
        [self bgEnterForeground];
        self.bgProtocol = nil;
    }
    if (valid) {
        self.bgSaved[@"session"] = @{@"accountId":account, @"expiresAt":session[@"expiresAt"]};
        if (self.bgArmed && self.bgProtocol.configuration[@"restoration"] &&
            ![BLEBackgroundStore canRestore:self.bgSaved now:NSDate.date.timeIntervalSince1970]) {
            self.bgArmed = NO;
            self.bgSaved[@"armed"] = @NO;
            [self bgEnterForeground];
        }
        if (!error) [self.bgStore save:self.bgSaved error:&error];
    }
    [self bgReply:command error:error.localizedDescription];
}

- (void)backgroundStart:(CDVInvokedUrlCommand *)command {
    if (![self bgAvailable]) { [self bgReply:command error:@"Background monitoring requires a physical iOS device; iOS apps on Mac, Catalyst and Simulator are unsupported."]; return; }
    if (!self.bgProtocol) { [self bgReply:command error:@"Configure notification handling first."]; return; }
    if (!centralManager || centralManager.state != CBManagerStatePoweredOn) {
        [self bgReply:command error:@"Initialize and enable Bluetooth through cordova-plugin-bluetoothle first."]; return;
    }
    if (self.bgProtocol.configuration[@"restoration"]) {
        self.bgSaved[@"armed"] = @YES;
        NSError *error;
        if (![BLEBackgroundStore canRestore:self.bgSaved now:NSDate.date.timeIntervalSince1970] || ![self.bgStore save:self.bgSaved error:&error]) {
            self.bgSaved[@"armed"] = @NO;
            [self bgReply:command error:error.localizedDescription ?: @"Recovery session expired."]; return;
        }
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
    // A cold background launch can construct the WebView while native recovery
    // is already receiving. Its stale startup/resume JS must not suspend SOS.
    // Explicit disable/logout may still disarm from any application state.
    if (![options[@"disarm"] boolValue] && self.bgArmed && self.bgRunning &&
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self bgReply:command error:@"Wait for the foreground before suspending the native background monitor."]; return;
    }
    if ([options[@"disarm"] boolValue]) {
        self.bgArmed = NO;
        for (NSURLSessionTask *task in self.bgRequests.copy) [task cancel];
        self.bgSaved[@"armed"] = @NO;
        NSError *error;
        if (![self.bgStore invalidate:&error]) [self bgRecord:@"recovery_clear_failed" details:@{}];
        // Retain the session in memory for a deliberate new configuration, but
        // discard credentials/configuration from durable recovery on disable.
        [self.bgSaved removeObjectForKey:@"configuration"];
        [self.bgSaved removeObjectForKey:@"incidents"];
    }
    if (self.bgAccessorySetup && !centralManager && self.bgDisconnecting.count == 0) {
        [self backgroundFinishAccessorySetup:command]; return;
    }
    // Explicit teardown after a failed prepare cancels the setup reservation.
    self.bgAccessorySetup = NO;
    if (!self.bgOwnsBluetooth) { [self bgReply:command error:nil]; return; }
    [self bgWaitForStop:command];
}

- (void)bgWaitForStop:(CDVInvokedUrlCommand *)command {
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

- (void)backgroundPrepareAccessorySetup:(CDVInvokedUrlCommand *)command {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self bgReply:command error:@"Accessory setup requires the foreground."]; return;
    }
    if (self.bgAccessorySetup || self.bgManagerCallbacks.count) {
        [self bgReply:command error:@"Accessory setup or Bluetooth restart is already in progress."]; return;
    }
    self.bgAccessorySetup = YES;
    self.bgOwnsBluetooth = YES;
    self.bgRunning = NO;
    if (centralManager.isScanning) [centralManager stopScan];
    for (NSDictionary *connection in connections.allValues) {
        CBPeripheral *peripheral = connection[@"peripheral"];
        if (peripheral && peripheral.state != CBPeripheralStateDisconnected) [self.bgDisconnecting addObject:peripheral.identifier];
    }
    for (NSDictionary *connection in connections.allValues) {
        CBPeripheral *peripheral = connection[@"peripheral"];
        if ([self.bgDisconnecting containsObject:peripheral.identifier]) [centralManager cancelPeripheralConnection:peripheral];
    }
    // The caller holds its foreground BLE lease until the system picker dismisses.
    [self bgWaitForStop:command];
}

- (void)backgroundFinishAccessorySetup:(CDVInvokedUrlCommand *)command {
    if (self.bgAccessorySetup && (centralManager || self.bgDisconnecting.count)) {
        [self bgReply:command error:@"Accessory setup teardown is incomplete. Use Disable before retrying."]; return;
    }
    if (!self.bgAccessorySetup && self.bgManagerCallbacks.count == 0) {
        [self bgReply:command error:nil]; return;
    }
    self.bgAccessorySetup = NO;
    [self.bgManagerCallbacks addObject:command.callbackId];
    [self bgCreateManager];
    [self bgReplyManagerReady];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (![self.bgManagerCallbacks containsObject:command.callbackId]) return;
        [self.bgManagerCallbacks removeObject:command.callbackId];
        [self bgReply:command error:@"Bluetooth restart timed out after accessory setup. Use Disable to recover before taking measurements."];
    });
}

- (void)bgReplyManagerReady {
    if (self.bgManagerCallbacks.count == 0 || centralManager.state == CBManagerStateUnknown || centralManager.state == CBManagerStateResetting) return;
    self.bgOwnsBluetooth = NO;
    NSString *error = centralManager.state == CBManagerStatePoweredOn ? nil : @"Bluetooth is unavailable after accessory setup. Turn Bluetooth on, then retry Enable.";
    for (NSString *callback in self.bgManagerCallbacks.copy) {
        CDVPluginResult *result = error ? [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error] :
            [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self bgStatus]];
        [self.commandDelegate sendPluginResult:result callbackId:callback];
    }
    [self.bgManagerCallbacks removeAllObjects];
}

- (void)bgEnterBackground {
    if (!self.bgArmed || self.bgOwnsBluetooth || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) return;
    if (![self bgRecoveryValid]) { self.bgArmed = NO; [self bgRecord:@"recovery_expired" details:@{}]; return; }
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
    if (!self.bgRunning || !self.bgArmed || ![self bgRecoveryValid] || (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground && !self.bgRecoveringAtLaunch)) {
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
    self.bgRecoveringAtLaunch = NO;
    self.bgRunning = NO;
    self.bgDiscoveryStage = 0;
    self.bgSubscriptionPending = NO;
    self.bgNotifyCharacteristic = nil;
    self.bgWriteCharacteristic = nil;
    [self bgCompleteWrite:[self bgError:@"Background connection ended before acknowledgement completed."]];
    // A Bluetooth power change can leave no cancellation callback to wait for.
    for (NSUUID *identifier in self.bgDisconnecting.copy) {
        CBPeripheral *peripheral = connections[identifier][@"peripheral"];
        if (!peripheral || peripheral.state == CBPeripheralStateDisconnected) [self.bgDisconnecting removeObject:identifier];
    }
    if (self.bgPeripheral && self.bgPeripheral.state != CBPeripheralStateDisconnected) {
        if (centralManager.state == CBManagerStatePoweredOn) [centralManager cancelPeripheralConnection:self.bgPeripheral];
        else {
            [self.bgRestoredToCancel addObject:self.bgPeripheral];
            self.bgPeripheral = nil;
            if (self.bgDisconnecting.count == 0) [self bgFinishStop];
        }
    } else if (self.bgDisconnecting.count == 0) [self bgFinishStop];
}

- (void)bgFinishStop {
    BOOL wasOwner = self.bgOwnsBluetooth;
    self.bgOwnsBluetooth = self.bgAccessorySetup;
    self.bgRunning = NO;
    self.bgPeripheral = nil;
    [self.bgProtocol resetStream];
    [self bgEndHandoffTime];
    if (self.bgAccessorySetup) {
        // Stopping scans/connections is insufficient for AccessorySetupKit:
        // no manager with global permission may remain alive during the picker.
        for (NSDictionary *connection in connections.allValues) {
            CBPeripheral *peripheral = connection[@"peripheral"];
            peripheral.delegate = nil;
        }
        centralManager.delegate = nil;
        centralManager = nil;
        [connections removeAllObjects];
        writeQIsRunning = NO;
        [self bgRecord:@"accessory_setup_manager_released" details:@{}];
    }
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
        self.bgDiscoveryStage = 0;
        self.bgSubscriptionPending = NO;
        self.bgNotifyCharacteristic = nil;
        self.bgWriteCharacteristic = nil;
        [self bgCompleteWrite:[self bgError:@"BLE acknowledgement timed out."]];
        [self->centralManager cancelPeripheralConnection:self.bgPeripheral];
    });
}

- (void)bgCompleteWrite:(NSError *)error {
    void (^completion)(NSError *) = self.bgWriteCompletion;
    self.bgWriteCompletion = nil;
    if (completion) completion(error);
}

- (void)bgPost:(NSDictionary *)payload reporting:(NSDictionary *)reporting completion:(void (^)(NSError *, NSInteger))completion {
    if (![self bgRecoveryValid]) { completion([self bgError:@"Recovery session expired or disabled."], 0); return; }
    NSError *requestError;
    NSMutableURLRequest *request = [BLEBackgroundReporting requestForIncident:payload reporting:reporting
        sentAt:[NSISO8601DateFormatter.new stringFromDate:NSDate.date] appState:[self bgAppState] error:&requestError];
    if (!request) { completion(requestError, 0); return; }
    __block UIBackgroundTaskIdentifier backgroundTask = UIBackgroundTaskInvalid;
    __block NSURLSessionDataTask *task;
    task = [self.bgSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSInteger status = http.statusCode;
        if (!error && (status < 200 || status >= 300)) error = [self bgError:[NSString stringWithFormat:@"HTTP %ld", (long)status]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.bgRequests removeObject:task];
            completion(error, status);
            if (backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:backgroundTask];
                backgroundTask = UIBackgroundTaskInvalid;
            }
        });
    }];
    [self.bgRequests addObject:task];
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
- (void)initialize:(CDVInvokedUrlCommand *)command {
    if ([self bgBlockCommand:command]) return;
    self.bgManagerInitializedInProcess = YES;
    NSMutableDictionary *options = [[command argumentAtIndex:0 withDefault:@{} andClass:NSDictionary.class] mutableCopy];
    options[@"restoreKey"] = BGRestoreIdentifier;
    statusReceiver = options[@"statusReceiver"] ?: @YES;
    CDVInvokedUrlCommand *initialization = [[CDVInvokedUrlCommand alloc] initWithArguments:@[options]
        callbackId:command.callbackId className:command.className methodName:command.methodName];
    // The launch bootstrap can create this manager before JavaScript arrives.
    // The parent immediately rejects initialize() for an existing unknown or
    // resetting manager, so register its callback only once state has settled.
    if (centralManager && centralManager.state != CBManagerStatePoweredOn) {
        self.bgInitializeCommand = initialization;
        if (centralManager.state != CBManagerStateUnknown && centralManager.state != CBManagerStateResetting) {
            CBCentralManager *manager = centralManager;
            NSUInteger revision = self.bgManagerStateRevision;
            [self bgAfterManagerStateSettles:^{
                if (self.bgInitializeCommand && manager == self->centralManager && revision == self.bgManagerStateRevision)
                    [self bgReportManagerState:manager];
            }];
        }
        return;
    }
    self.bgInitializeCommand = nil;
    [super initialize:initialization];
}
- (void)startScan:(CDVInvokedUrlCommand *)command {
    if ([self bgBlockCommand:command]) return;
    self.bgForegroundScanObserved = NO;
    [super startScan:command];
    [self bgRecord:@"foreground_scan_state" details:@{@"scanning":@(centralManager.isScanning),
        @"state":@(centralManager.state), @"delegateAttached":@(centralManager.delegate == self),
        @"restoredCancellationsPending":@(self.bgRestoredToCancel.count)}];
}
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

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary *)state {
    self.bgRestored = YES;
    self.bgRestoredScanToStop = YES;
    BOOL recover = self.bgArmed && self.bgProtocol && [self bgRecoveryValid] &&
        (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground ||
            self.bgRecoveringAtLaunch || self.bgOwnsBluetooth);
    for (CBPeripheral *peripheral in state[CBCentralManagerRestoredStatePeripheralsKey]) {
        peripheral.delegate = self;
        if (recover && [peripheral.identifier isEqual:self.bgDeviceID] && !self.bgPeripheral) {
            self.bgPeripheral = peripheral;
            self.bgOwnsBluetooth = YES;
            self.bgRunning = YES;
            // Bind cached characteristic objects before returning: value callbacks
            // may arrive before the next powered-on callback or JavaScript startup.
            [self bgBindCharacteristics];
        } else if (peripheral.state != CBPeripheralStateDisconnected) [self.bgRestoredToCancel addObject:peripheral];
    }
    [self bgCancelRestoredWork:central];
    [self bgRecord:@"state_restored" details:@{@"matchedAccessory":@(self.bgPeripheral != nil)}];
    if (recover) {
        self.bgOwnsBluetooth = YES; self.bgRunning = YES;
        if (central.state == CBManagerStatePoweredOn) {
            if (self.bgPeripheral) [self bgResumePeripheral]; else [self bgConnect];
        }
    }
}

- (void)bgCancelRestoredWork:(CBCentralManager *)central {
    // willRestoreState precedes the powered-on callback. Commands issued while
    // state is unknown are rejected, leaving an orphan connection alive and
    // its watch unavailable to foreground advertisement scanning.
    if (central.state != CBManagerStatePoweredOn) return;
    BOOL stoppedScan = self.bgRestoredScanToStop && central.isScanning;
    self.bgRestoredScanToStop = NO;
    if (stoppedScan) [central stopScan];
    NSArray<CBPeripheral *> *peripherals = self.bgRestoredToCancel.allObjects;
    [self.bgRestoredToCancel removeAllObjects];
    for (CBPeripheral *peripheral in peripherals) {
        if (peripheral.state != CBPeripheralStateDisconnected) [central cancelPeripheralConnection:peripheral];
    }
    if (stoppedScan || peripherals.count) [self bgRecord:@"restored_work_cancellation_requested" details:@{
        @"peripheralCount":@(peripherals.count), @"stoppedScan":@(stoppedScan)}];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    if (!self.bgForegroundScanObserved) {
        self.bgForegroundScanObserved = YES;
        [self bgRecord:@"foreground_scan_result" details:@{}];
    }
    [super centralManager:central didDiscoverPeripheral:peripheral advertisementData:advertisementData RSSI:RSSI];
}

- (void)bgBindCharacteristics {
    for (CBService *service in self.bgPeripheral.services) {
        if (![service.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"serviceUuid"]]]) continue;
        for (CBCharacteristic *characteristic in service.characteristics) {
            if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"notifyCharacteristicUuid"]]]) self.bgNotifyCharacteristic = characteristic;
            if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:self.bgProtocol.configuration[@"writeCharacteristicUuid"]]]) self.bgWriteCharacteristic = characteristic;
        }
    }
}

- (void)bgResumePeripheral {
    if (!self.bgRunning || ![self bgRecoveryValid]) { [self bgEnterForeground]; return; }
    CBPeripheral *peripheral = self.bgPeripheral;
    peripheral.delegate = self;
    if (peripheral.state == CBPeripheralStateDisconnected) { [centralManager connectPeripheral:peripheral options:nil]; return; }
    if (peripheral.state != CBPeripheralStateConnected) return; // Pending connection remains owned by Core Bluetooth.
    [self bgBindCharacteristics];
    if (!self.bgNotifyCharacteristic || !self.bgWriteCharacteristic) {
        if (self.bgDiscoveryStage) return;
        self.bgDiscoveryStage = 1;
        [peripheral discoverServices:@[[CBUUID UUIDWithString:self.bgProtocol.configuration[@"serviceUuid"]]]]; return;
    }
    if (!(self.bgNotifyCharacteristic.properties & CBCharacteristicPropertyNotify) || !(self.bgWriteCharacteristic.properties & CBCharacteristicPropertyWrite)) {
        [self bgRecord:@"gatt_failed" details:@{}]; [self bgEnterForeground]; return;
    }
    [self bgEnableNotifications];
}

- (void)bgEnableNotifications {
    if (self.bgNotifyCharacteristic.isNotifying) {
        self.bgConnectionFailures = 0;
        [self bgRecord:@"notifications_restored" details:@{}];
    } else if (!self.bgSubscriptionPending) {
        self.bgSubscriptionPending = YES;
        [self.bgPeripheral setNotifyValue:YES forCharacteristic:self.bgNotifyCharacteristic];
    }
}

- (void)bgReportManagerState:(CBCentralManager *)central {
    if (self.bgInitializeCommand) {
        CDVInvokedUrlCommand *command = self.bgInitializeCommand;
        self.bgInitializeCommand = nil;
        [super initialize:command];
    } else [super centralManagerDidUpdateState:central];
    [self bgReplyManagerReady];
}

- (void)bgAfterManagerStateSettles:(void (^)(void))completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), completion);
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self bgRecord:@"bluetooth_state_changed" details:@{@"state":@(central.state)}];
    NSUInteger revision = ++self.bgManagerStateRevision;
    if (central.state == CBManagerStatePoweredOn) {
        [self bgCancelRestoredWork:central];
        [self bgReportManagerState:central];
    }
    else if (central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting) {
        // A newly created manager can report powered-off immediately before
        // powered-on. Do not fail the foreground promise on that stale state.
        [self bgAfterManagerStateSettles:^{
            if (revision == self.bgManagerStateRevision && central == self->centralManager)
                [self bgReportManagerState:central];
        }];
    }
    if (self.bgRunning && central.state == CBManagerStatePoweredOn && self.bgDisconnecting.count == 0) {
        if (!self.bgPeripheral) [self bgConnect];
        else if (self.bgPeripheral.state == CBPeripheralStateConnected) [self bgResumePeripheral];
        else if (self.bgPeripheral.state == CBPeripheralStateDisconnected) [central connectPeripheral:self.bgPeripheral options:nil];
    }
    if (self.bgOwnsBluetooth && central.state != CBManagerStatePoweredOn) {
        [self bgRecord:@"bluetooth_unavailable" details:@{}];
        self.bgDiscoveryStage = 0;
        self.bgSubscriptionPending = NO;
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
        [self bgResumePeripheral];
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
        self.bgDiscoveryStage = 0;
        self.bgSubscriptionPending = NO;
        self.bgNotifyCharacteristic = nil;
        self.bgWriteCharacteristic = nil;
        [self bgCompleteWrite:[self bgError:@"Device disconnected."]];
        self.bgPeripheral = nil;
        if (self.bgRunning && (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground || self.bgRecoveringAtLaunch)) [self bgConnect];
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
            if (self.bgDiscoveryStage == 2) return;
            self.bgDiscoveryStage = 2;
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
    self.bgDiscoveryStage = 0;
    [self bgEnableNotifications];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didUpdateNotificationStateForCharacteristic:characteristic error:error]; return; }
    if (!self.bgRunning || characteristic != self.bgNotifyCharacteristic) return;
    self.bgSubscriptionPending = NO;
    [self bgRecord:(!error && characteristic.isNotifying) ? @"notifications_enabled" : @"notifications_failed" details:error ? @{@"error":error.localizedDescription} : @{}];
    if (!error && characteristic.isNotifying) self.bgConnectionFailures = 0;
    if (error || !characteristic.isNotifying) [self bgEnterForeground];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didUpdateValueForCharacteristic:characteristic error:error]; return; }
    if (!self.bgRunning || error || characteristic != self.bgNotifyCharacteristic || !characteristic.isNotifying) return;
    if (![self bgRecoveryValid]) {
        self.bgArmed = NO; [self.bgStore invalidate:nil];
        [self bgRecord:@"recovery_expired" details:@{}]; [self bgEnterForeground]; return;
    }
    NSDictionary *context = @{@"receivedAt":[NSISO8601DateFormatter.new stringFromDate:NSDate.date], @"receivedAppState":[self bgAppState], @"deviceId":self.bgDeviceID.UUIDString};
    [self.bgProtocol receiveData:characteristic.value atTime:NSProcessInfo.processInfo.systemUptime context:context];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.bgPeripheral || !self.bgOwnsBluetooth) { [super peripheral:peripheral didWriteValueForCharacteristic:characteristic error:error]; return; }
    if (characteristic == self.bgWriteCharacteristic) [self bgCompleteWrite:error];
}

- (void)onReset {
    if (!self.bgOwnsBluetooth) [super onReset];
}

- (void)dispose {
    // The process-wide native owner survives webview teardown. A deliberate stop
    // or account invalidation, not WebView lifecycle, disarms recovery.
    self.commandDelegate = nil;
    self.webView = nil;
    self.viewController = nil;
}
@end
