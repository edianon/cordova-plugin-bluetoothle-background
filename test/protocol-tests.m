#import <Foundation/Foundation.h>
#import "BLEBackgroundProtocol.h"

static NSUInteger checks = 0;
static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSDictionary *configuration(void) {
    return @{@"deviceId":@"00000000-0000-4000-8000-000000000001",
        @"serviceUuid":@"AB00", @"notifyCharacteristicUuid":@"AB01", @"writeCharacteristicUuid":@"AB02",
        @"packetLength":@8, @"checksum":@"sum8",
        @"rules":@[@{@"id":@"example", @"match":@{@"offset":@0, @"bytes":@[@0x42]},
            @"quietPeriodMs":@5000, @"acknowledgement":@{@"mode":@"echo", @"maxAttempts":@3}}]};
}
static NSMutableDictionary *mutableConfiguration(void) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:configuration() options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingMutableContainers error:nil];
}
static NSData *packet(uint8_t command) {
    uint8_t bytes[8] = { command, 0, 0, 0, 0, 0, 0, command };
    return [NSData dataWithBytes:bytes length:8];
}
static NSError *failure(void) { return [NSError errorWithDomain:@"Test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"mock failure"}]; }

@interface Harness : NSObject
@property(nonatomic) BLEBackgroundProtocol *engine;
@property(nonatomic) NSMutableArray<NSDictionary *> *events;
@property(nonatomic) NSMutableArray<NSData *> *writes;
@property(nonatomic) NSMutableArray *writeCompletions;
@property(nonatomic) NSMutableArray<NSDictionary *> *deliveries;
@property(nonatomic) NSMutableArray *deliveryCompletions;
- (instancetype)initWithConfiguration:(NSDictionary *)config;
- (void)receive:(NSData *)data time:(double)time;
- (NSArray<NSDictionary *> *)eventsNamed:(NSString *)name;
- (void)finishWrite:(NSError *)error;
@end
@implementation Harness
- (instancetype)initWithConfiguration:(NSDictionary *)config {
    self = [super init];
    if (!self) return nil;
    NSError *error;
    _engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:config error:&error];
    check(_engine != nil, error.localizedDescription ?: @"valid configuration");
    _events = [NSMutableArray array]; _writes = [NSMutableArray array]; _writeCompletions = [NSMutableArray array];
    _deliveries = [NSMutableArray array]; _deliveryCompletions = [NSMutableArray array];
    __weak Harness *weakSelf = self;
    _engine.recordEvent = ^(NSString *event, NSDictionary *details) {
        [weakSelf.events addObject:@{@"event":event, @"details":[details copy]}];
    };
    _engine.writePacket = ^(NSData *data, NSUInteger timeout, void (^completion)(NSError *)) {
        check(timeout == 3000, @"default write timeout passed to native writer");
        [weakSelf.writes addObject:[data copy]]; [weakSelf.writeCompletions addObject:[completion copy]];
    };
    _engine.deliverIncident = ^(NSDictionary *incident, void (^completion)(NSError *)) {
        [weakSelf.deliveries addObject:[incident copy]]; [weakSelf.deliveryCompletions addObject:[completion copy]];
    };
    return self;
}
- (void)receive:(NSData *)data time:(double)time {
    [self.engine receiveData:data atTime:time context:@{@"receivedAt":[NSString stringWithFormat:@"test-%g", time], @"receivedAppState":@"background"}];
}
- (NSArray<NSDictionary *> *)eventsNamed:(NSString *)name {
    return [self.events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) { return [event[@"event"] isEqual:name]; }]];
}
- (void)finishWrite:(NSError *)error {
    check(self.writeCompletions.count > 0, @"write completion exists");
    void (^completion)(NSError *) = self.writeCompletions.firstObject;
    [self.writeCompletions removeObjectAtIndex:0]; completion(error);
}
@end

static void testFraming(void) {
    Harness *h = [[Harness alloc] initWithConfiguration:configuration()];
    NSData *valid = packet(0x42);
    [h receive:[valid subdataWithRange:NSMakeRange(0, 3)] time:0];
    check(h.writes.count == 0, @"fragment alone is not a packet");
    NSMutableData *rest = [[valid subdataWithRange:NSMakeRange(3, 5)] mutableCopy];
    [rest appendData:valid]; [rest appendData:packet(0x21)];
    [h receive:rest time:1];
    check([h eventsNamed:@"notification_received"].count == 1, @"fragmented and concatenated frames recognized once");
    check([h eventsNamed:@"notification_repeated"].count == 1, @"concatenated duplicate belongs to same incident");
    check(h.writes.count == 1 && [h.writes.firstObject isEqual:valid], @"echo acknowledgement is byte-for-byte exact");
    check([h eventsNamed:@"delivery_skipped"].count == 1, @"without endpoint delivery is explicitly skipped");
    [h finishWrite:nil];
    NSMutableData *bad = [valid mutableCopy]; ((uint8_t *)bad.mutableBytes)[7]++;
    [bad appendData:valid]; [h receive:bad time:2];
    check([h eventsNamed:@"packet_rejected"].count == 1, @"invalid checksum rejected before matching");
    check(h.writes.count == 2, @"valid frame after rejected frame still parsed");
    [h finishWrite:nil];
    [h receive:packet(0x21) time:3];
    check(h.writes.count == 2, @"unrelated command is not handled as a matched event");
    [h receive:[valid subdataWithRange:NSMakeRange(0, 4)] time:4];
    [h.engine resetStream];
    [h receive:valid time:10];
    check([h eventsNamed:@"notification_received"].count == 2, @"stream reset discards partial frame without suppressing future incidents");
    [h finishWrite:nil];
}

static void testRetriesAndBoundaries(void) {
    Harness *h = [[Harness alloc] initWithConfiguration:configuration()];
    [h receive:packet(0x42) time:0];
    [h receive:packet(0x42) time:1];
    check(h.writes.count == 1, @"no overlapping acknowledgement for a repeated incident");
    [h finishWrite:failure()];
    [h receive:packet(0x42) time:2]; [h finishWrite:failure()];
    [h receive:packet(0x42) time:3]; [h finishWrite:nil];
    for (int time = 4; time < 20; time++) [h receive:packet(0x42) time:time];
    check(h.writes.count == 3, @"attempts remain bounded while retransmissions continue");
    check([h eventsNamed:@"acknowledgement_failed"].count == 2, @"both write failures visible");
    check([h eventsNamed:@"acknowledgement_written"].count == 1, @"successful write separate from receipt");
    check([h eventsNamed:@"notification_received"].count == 1, @"one active incident across repeated notifications");
    NSString *first = [h eventsNamed:@"notification_received"].firstObject[@"details"][@"incidentId"];
    check([[h eventsNamed:@"acknowledgement_written"].firstObject[@"details"][@"receivedAt"] isEqual:@"test-0"], @"retry retains original receipt context");
    [h receive:packet(0x42) time:24];
    NSString *second = [h eventsNamed:@"notification_received"].lastObject[@"details"][@"incidentId"];
    check(![first isEqual:second] && h.writes.count == 4, @"later separate event accepted after silence with fresh attempt budget");
    [h receive:packet(0x42) time:40];
    check([h eventsNamed:@"notification_received"].count == 2, @"long outstanding write prevents new incident overlap");
    [h finishWrite:nil];
}

static void testDelivery(void) {
    NSMutableDictionary *config = mutableConfiguration();
    config[@"reporting"] = @{@"url":@"https://example.invalid/events",
        @"headers":@{@"x-auth-token":@"private-test-header"}, @"body":@{@"subject":@"private-test-body"}};
    config[@"metadata"] = @{@"source":@"synthetic-test"}; config[@"includePayload"] = @YES;
    Harness *h = [[Harness alloc] initWithConfiguration:config];
    [h receive:packet(0x42) time:0];
    check(h.deliveries.count == 1 && h.writes.count == 1, @"delivery and acknowledgement start independently");
    check(h.writeCompletions.count == 1 && h.deliveryCompletions.count == 1, @"neither operation waits for the other's completion");
    check([h eventsNamed:@"acknowledgement_written"].count == 0 && [h eventsNamed:@"delivery_succeeded"].count == 0, @"started operations do not falsely report success");
    check([h.deliveries.firstObject[@"payload"] count] == 8 && [h.deliveries.firstObject[@"metadata"][@"source"] isEqual:@"synthetic-test"], @"opt-in packet and app metadata included");
    NSString *eventJSON = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:h.events options:0 error:nil] encoding:NSUTF8StringEncoding];
    check(![eventJSON containsString:@"private-test-header"] && ![eventJSON containsString:@"private-test-body"], @"configured headers and custom body do not enter event history");
    void (^failed)(NSError *) = h.deliveryCompletions.firstObject; failed(failure());
    [h finishWrite:nil]; [h receive:packet(0x42) time:1];
    check(h.deliveries.count == 1, @"retransmission never duplicates failed remote delivery");
    check([h eventsNamed:@"delivery_failed"].count == 1 && [h eventsNamed:@"delivery_succeeded"].count == 0, @"delivery failure stays separate from BLE success");
    [h finishWrite:nil]; [h receive:packet(0x42) time:7];
    void (^succeeded)(NSError *) = h.deliveryCompletions.lastObject; succeeded(nil);
    check(h.deliveries.count == 2 && [h eventsNamed:@"delivery_succeeded"].count == 1, @"later incident delivers separately");
    [h finishWrite:nil];
}

static void testRulesAndSerialization(void) {
    NSMutableDictionary *config = mutableConfiguration();
    config[@"rules"] = @[
        @{@"id":@"first", @"match":@{@"offset":@0, @"bytes":@[@0x40], @"mask":@[@0xF0]}, @"acknowledgement":@{@"mode":@"fixed", @"bytes":@[@0x10, @0x20]}},
        @{@"id":@"overlap", @"match":@{@"offset":@0, @"bytes":@[@0x42]}, @"acknowledgement":@{@"mode":@"echo"}},
        @{@"id":@"second", @"match":@{@"offset":@0, @"bytes":@[@0x21]}, @"acknowledgement":@{@"mode":@"echo"}},
        @{@"id":@"third", @"match":@{@"offset":@0, @"bytes":@[@0x31]}, @"acknowledgement":@{@"mode":@"none"}}
    ];
    Harness *h = [[Harness alloc] initWithConfiguration:config];
    [h receive:packet(0x42) time:0]; [h receive:packet(0x21) time:0]; [h receive:packet(0x31) time:0];
    check([h eventsNamed:@"notification_received"].count == 3, @"mask matching, first-match priority, independent rules");
    uint8_t fixed[] = { 0x10, 0x20 };
    check([h.writes.firstObject isEqual:[NSData dataWithBytes:fixed length:2]], @"configured fixed acknowledgement used without invented checksum");
    check(h.writes.count == 1, @"different rules serialize physical writes");
    void (^firstCompletion)(NSError *) = h.writeCompletions.firstObject;
    [h finishWrite:nil];
    check(h.writes.count == 2 && [h.writes.lastObject isEqual:packet(0x21)], @"next queued acknowledgement starts after prior completion");
    firstCompletion(failure());
    check([h eventsNamed:@"acknowledgement_failed"].count == 0 && h.writeCompletions.count == 1, @"duplicate native completion cannot corrupt write queue");
    [h finishWrite:nil];
    check([h eventsNamed:@"acknowledgement_written"].count == 2, @"no-ack rule performs no write");
    config = mutableConfiguration(); config[@"checksum"] = @"none";
    h = [[Harness alloc] initWithConfiguration:config];
    NSMutableData *unchecked = [packet(0x42) mutableCopy]; ((uint8_t *)unchecked.mutableBytes)[7] = 0;
    [h receive:unchecked time:0]; check(h.writes.count == 1, @"checksum disabled only by explicit configuration");
    [h finishWrite:nil];
}

static void testValidation(void) {
    NSArray *invalidOptions = @[
        @{@"deviceId":@"not-a-uuid"}, @{@"serviceUuid":@"unknown"}, @{@"notifyCharacteristicUuid":@42},
        @{@"packetLength":@0}, @{@"packetLength":@YES}, @{@"packetLength":@513}, @{@"packetLength":@3.5},
        @{@"checksum":@"crc"}, @{@"rules":@[]}, @{@"rules":@[@42]}, @{@"metadata":@[]}, @{@"includePayload":@1},
        @{@"maxEvents":@1}, @{@"maxConnectionFailures":@0}, @{@"reporting":@42},
        @{@"reporting":@{@"url":@"http://example.invalid"}}, @{@"reporting":@{@"url":@"https://user:secret@example.invalid"}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"headers":@{@"bad\nheader":@"x"}}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"timeoutMs":@0}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":@"{\"subject\":\"test\"}"}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":@[]}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":NSNull.null}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":@42}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":@{@"bad":@(NAN)}}},
        @{@"reporting":@{@"url":@"https://example.invalid", @"body":@{@"tooLarge":[@"x" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0]}}}
    ];
    for (NSDictionary *overrides in invalidOptions) {
        NSMutableDictionary *config = mutableConfiguration(); [config addEntriesFromDictionary:overrides];
        NSError *error; BLEBackgroundProtocol *engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:config error:&error];
        check(!engine && error != nil, [NSString stringWithFormat:@"reject malformed configuration %@", overrides]);
    }
    NSArray *badRules = @[
        @{@"id":@""}, @{@"match":@{@"offset":@7, @"bytes":@[@1, @2]}},
        @{@"match":@{@"offset":@0, @"bytes":@[@256]}}, @{@"match":@{@"offset":@0, @"bytes":@[@1], @"mask":@[@1, @2]}},
        @{@"quietPeriodMs":@0}, @{@"acknowledgement":@{@"mode":@"unsupported"}},
        @{@"acknowledgement":@{@"mode":@"fixed", @"bytes":@[]}}, @{@"acknowledgement":@{@"mode":@"echo", @"maxAttempts":@0}}
    ];
    for (NSDictionary *overrides in badRules) {
        NSMutableDictionary *config = mutableConfiguration(); [config[@"rules"][0] addEntriesFromDictionary:overrides];
        NSError *error; check([[BLEBackgroundProtocol alloc] initWithConfiguration:config error:&error] == nil && error != nil, @"reject invalid rule");
    }
    NSMutableDictionary *config = mutableConfiguration(); config[@"reporting"] = @{@"url":@"http://example.invalid/events", @"allowInsecureHttp":@YES};
    check([[BLEBackgroundProtocol alloc] initWithConfiguration:config error:nil] != nil, @"HTTP requires explicit opt in");
    config = mutableConfiguration(); NSError *error;
    BLEBackgroundProtocol *engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:config error:&error];
    config[@"rules"][0][@"id"] = @"mutated";
    check([engine.configuration[@"rules"][0][@"id"] isEqual:@"example"], @"configuration copied rather than sharing mutable app objects");

    config = mutableConfiguration();
    config[@"reporting"] = [@{@"url":@"https://example.invalid/actions",
        @"headers":[@{@"x-auth-token":@"original-test-token"} mutableCopy],
        @"body":[@{@"nested":[@{@"subject":@"original subject"} mutableCopy], @"attachment":NSNull.null} mutableCopy]} mutableCopy];
    engine = [[BLEBackgroundProtocol alloc] initWithConfiguration:config error:&error];
    check(engine != nil, @"custom JSON body and plain headers accepted");
    config[@"reporting"][@"headers"][@"x-auth-token"] = @"changed";
    config[@"reporting"][@"body"][@"nested"][@"subject"] = @"changed";
    check([engine.configuration[@"reporting"][@"headers"][@"x-auth-token"] isEqual:@"original-test-token"], @"headers are captured at configuration time");
    check([engine.configuration[@"reporting"][@"body"][@"nested"][@"subject"] isEqual:@"original subject"], @"custom body is a deep snapshot of foreground data");
}

int main(void) {
    @autoreleasepool {
        testFraming(); testRetriesAndBoundaries(); testDelivery(); testRulesAndSerialization(); testValidation();
        printf("Native packet/incident tests passed (%lu checks). No Bluetooth or network used.\n", (unsigned long)checks);
    }
    return 0;
}
