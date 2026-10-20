#import "BLEBackgroundProtocol.h"
#import <math.h>

static NSError *configurationError(NSString *message) {
    return [NSError errorWithDomain:@"BluetoothLEBackground.Configuration" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static BOOL integerBetween(id value, NSUInteger minimum, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number && number >= minimum && number <= maximum;
}

static BOOL byteArray(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSArray.class] || [value count] == 0 || [value count] > maximum) return NO;
    for (id byte in value) if (!integerBetween(byte, 0, 255)) return NO;
    return YES;
}

static BOOL booleanOption(id value) { return !value || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(); }

@interface BLEBackgroundProtocol ()
@property(nonatomic, readwrite) NSDictionary *configuration;
@property(nonatomic) NSMutableData *pendingBytes;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *incidents;
@property(nonatomic) NSMutableArray<NSDictionary *> *writeQueue;
@property(nonatomic) BOOL writing;
@end

@implementation BLEBackgroundProtocol
- (instancetype)initWithConfiguration:(NSDictionary *)options error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *problem = nil;
    if (![options isKindOfClass:NSDictionary.class]) problem = @"Configuration must be an object.";
    else if (![options[@"deviceId"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:options[@"deviceId"]]) problem = @"deviceId must be a cached iOS device UUID.";
    else if (!integerBetween(options[@"packetLength"], 1, 512)) problem = @"packetLength must be an integer from 1 to 512.";
    else if (![@[@"sum8", @"none"] containsObject:options[@"checksum"]]) problem = @"checksum must be sum8 or none.";
    else if ([options[@"checksum"] isEqual:@"sum8"] && [options[@"packetLength"] unsignedIntegerValue] < 2) problem = @"sum8 needs at least two packet bytes.";
    else if (![options[@"rules"] isKindOfClass:NSArray.class] || [options[@"rules"] count] < 1 || [options[@"rules"] count] > 16) problem = @"Provide 1–16 notification rules.";
    else if (options[@"maxEvents"] && !integerBetween(options[@"maxEvents"], 10, 1000)) problem = @"maxEvents must be 10–1000.";
    else if (options[@"maxConnectionFailures"] && !integerBetween(options[@"maxConnectionFailures"], 1, 10)) problem = @"maxConnectionFailures must be 1–10.";
    else if (!booleanOption(options[@"includePayload"])) problem = @"includePayload must be a boolean.";
    else if (options[@"metadata"] && ![options[@"metadata"] isKindOfClass:NSDictionary.class]) problem = @"metadata must be an object.";
    if (!problem) {
        for (NSString *key in @[@"serviceUuid", @"notifyCharacteristicUuid", @"writeCharacteristicUuid"]) {
            id uuid = options[key];
            // Core Bluetooth accepts 16-bit, 32-bit and full UUID strings.
            NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$" options:0 error:nil];
            if (![uuid isKindOfClass:NSString.class] || [pattern numberOfMatchesInString:uuid options:0 range:NSMakeRange(0, [uuid length])] != 1) {
                problem = [key stringByAppendingString:@" must be a Bluetooth UUID string."]; break;
            }
        }
    }
    NSMutableSet *identifiers = [NSMutableSet set];
    if (!problem) for (id value in options[@"rules"]) {
        if (![value isKindOfClass:NSDictionary.class]) { problem = @"Each rule must be an object."; break; }
        NSDictionary *rule = value;
        NSString *identifier = rule[@"id"];
        NSDictionary *match = rule[@"match"];
        NSDictionary *ack = rule[@"acknowledgement"];
        NSUInteger length = [options[@"packetLength"] unsignedIntegerValue];
        if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 || identifier.length > 64 || [identifiers containsObject:identifier]) { problem = @"Rule IDs must be unique strings of 1–64 characters."; break; }
        [identifiers addObject:identifier];
        if (![match isKindOfClass:NSDictionary.class] || !integerBetween(match[@"offset"], 0, length - 1) || !byteArray(match[@"bytes"], length)) { problem = @"Each rule needs match.offset and match.bytes within the packet."; break; }
        if ([match[@"offset"] unsignedIntegerValue] + [match[@"bytes"] count] > length) { problem = @"Match extends past the packet."; break; }
        if (match[@"mask"] && (!byteArray(match[@"mask"], length) || [match[@"mask"] count] != [match[@"bytes"] count])) { problem = @"Match mask must contain one byte per match byte."; break; }
        if (rule[@"quietPeriodMs"] && !integerBetween(rule[@"quietPeriodMs"], 100, 300000)) { problem = @"quietPeriodMs must be 100–300000."; break; }
        if (![ack isKindOfClass:NSDictionary.class] || ![@[@"none", @"echo", @"fixed"] containsObject:ack[@"mode"]]) { problem = @"acknowledgement.mode must be none, echo, or fixed."; break; }
        if ([ack[@"mode"] isEqual:@"fixed"] && !byteArray(ack[@"bytes"], 512)) { problem = @"Fixed acknowledgement needs 1–512 bytes."; break; }
        if (ack[@"maxAttempts"] && !integerBetween(ack[@"maxAttempts"], 1, 10)) { problem = @"maxAttempts must be 1–10."; break; }
        if (ack[@"timeoutMs"] && !integerBetween(ack[@"timeoutMs"], 100, 30000)) { problem = @"timeoutMs must be 100–30000."; break; }
    }
    if (!problem && options[@"reporting"]) {
        NSDictionary *reporting = options[@"reporting"];
        if (![reporting isKindOfClass:NSDictionary.class] || ![reporting[@"url"] isKindOfClass:NSString.class]) problem = @"reporting.url is required when reporting is configured.";
        else {
            NSURL *url = [NSURL URLWithString:reporting[@"url"]];
            BOOL https = [url.scheme.lowercaseString isEqual:@"https"];
            BOOL http = [url.scheme.lowercaseString isEqual:@"http"] && [reporting[@"allowInsecureHttp"] isEqual:@YES];
            if ((!https && !http) || !url.host.length || url.user || url.password || url.fragment) problem = @"Use an HTTPS reporting URL, or explicitly allow HTTP. Credentials and fragments are not accepted in the URL.";
            else if (!booleanOption(reporting[@"allowInsecureHttp"])) problem = @"allowInsecureHttp must be a boolean.";
            else if (reporting[@"timeoutMs"] && !integerBetween(reporting[@"timeoutMs"], 100, 30000)) problem = @"reporting.timeoutMs must be 100–30000.";
            else if (reporting[@"body"] && ![reporting[@"body"] isKindOfClass:NSDictionary.class]) problem = @"reporting.body must be a JSON object, not a serialized string.";
            else if (reporting[@"headers"] && ![reporting[@"headers"] isKindOfClass:NSDictionary.class]) problem = @"reporting.headers must be an object.";
            else for (id key in reporting[@"headers"]) {
                id header = reporting[@"headers"][key];
                NSCharacterSet *newline = NSCharacterSet.newlineCharacterSet;
                if (![key isKindOfClass:NSString.class] || ![header isKindOfClass:NSString.class] || [key length] == 0 || [key rangeOfCharacterFromSet:newline].location != NSNotFound || [header rangeOfCharacterFromSet:newline].location != NSNotFound) {
                    problem = @"Reporting headers must be strings without newlines."; break;
                }
            }
        }
    }
    NSData *json = !problem && [NSJSONSerialization isValidJSONObject:options] ? [NSJSONSerialization dataWithJSONObject:options options:0 error:nil] : nil;
    if (!problem && (!json || json.length > 65536)) problem = @"Configuration must be JSON and at most 64 KiB.";
    if (problem) { if (error) *error = configurationError(problem); return nil; }
    _configuration = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    _pendingBytes = [NSMutableData data];
    _incidents = [NSMutableDictionary dictionary];
    _writeQueue = [NSMutableArray array];
    return self;
}

- (void)resetStream { [self.pendingBytes setLength:0]; }

- (BOOL)matchesRule:(NSDictionary *)rule packet:(NSData *)packet {
    NSDictionary *match = rule[@"match"];
    const uint8_t *bytes = packet.bytes;
    NSUInteger offset = [match[@"offset"] unsignedIntegerValue];
    NSArray *expected = match[@"bytes"], *mask = match[@"mask"];
    for (NSUInteger index = 0; index < expected.count; index++) {
        uint8_t bits = mask ? [mask[index] unsignedCharValue] : 255;
        if ((bytes[offset + index] & bits) != ([expected[index] unsignedCharValue] & bits)) return NO;
    }
    return YES;
}

- (void)pumpWrites {
    if (self.writing || self.writeQueue.count == 0) return;
    self.writing = YES;
    NSDictionary *job = self.writeQueue.firstObject;
    self.recordEvent(@"acknowledgement_started", job[@"details"]);
    __block BOOL completed = NO;
    self.writePacket(job[@"packet"], [job[@"timeout"] unsignedIntegerValue], ^(NSError *error) {
        if (completed) return;
        completed = YES;
        void (^completion)(NSError *) = job[@"completion"];
        completion(error);
        [self.writeQueue removeObjectAtIndex:0];
        self.writing = NO;
        [self pumpWrites];
    });
}

- (void)receiveData:(NSData *)data atTime:(NSTimeInterval)time context:(NSDictionary *)context {
    [self.pendingBytes appendData:data];
    NSUInteger length = [self.configuration[@"packetLength"] unsignedIntegerValue];
    while (self.pendingBytes.length >= length) {
        NSData *packet = [self.pendingBytes subdataWithRange:NSMakeRange(0, length)];
        [self.pendingBytes replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        const uint8_t *bytes = packet.bytes;
        if ([self.configuration[@"checksum"] isEqual:@"sum8"]) {
            uint8_t checksum = 0;
            for (NSUInteger index = 0; index + 1 < length; index++) checksum += bytes[index];
            if (checksum != bytes[length - 1]) { self.recordEvent(@"packet_rejected", @{@"reason":@"checksum"}); continue; }
        }
        // First matching rule owns the frame. Put more specific rules first.
        for (NSDictionary *rule in self.configuration[@"rules"]) {
            if (![self matchesRule:rule packet:packet]) continue;
            NSString *ruleID = rule[@"id"];
            NSMutableDictionary *state = self.incidents[ruleID];
            NSTimeInterval quiet = [rule[@"quietPeriodMs"] ?: @5000 doubleValue] / 1000.0;
            BOOL fresh = !state || (time - [state[@"lastReceived"] doubleValue] >= quiet && ![state[@"pending"] boolValue]);
            if (fresh) {
                state = [@{@"incidentId":NSUUID.UUID.UUIDString, @"attempts":@0, @"pending":@NO, @"context":[context copy]} mutableCopy];
                self.incidents[ruleID] = state;
            }
            state[@"lastReceived"] = @(time);
            NSMutableDictionary *details = [state[@"context"] mutableCopy];
            details[@"deviceId"] = self.configuration[@"deviceId"];
            details[@"ruleId"] = ruleID;
            details[@"incidentId"] = state[@"incidentId"];
            if (self.configuration[@"metadata"]) details[@"metadata"] = self.configuration[@"metadata"];
            if ([self.configuration[@"includePayload"] boolValue]) {
                NSMutableArray *values = [NSMutableArray array];
                for (NSUInteger index = 0; index < length; index++) [values addObject:@(bytes[index])];
                details[@"payload"] = values;
            }
            self.recordEvent(fresh ? @"notification_received" : @"notification_repeated", details);
            NSDictionary *ack = rule[@"acknowledgement"];
            NSUInteger attempts = [state[@"attempts"] unsignedIntegerValue];
            if (![ack[@"mode"] isEqual:@"none"] && ![state[@"pending"] boolValue] && attempts < [ack[@"maxAttempts"] ?: @3 unsignedIntegerValue]) {
                state[@"pending"] = @YES;
                state[@"attempts"] = @(attempts + 1);
                NSMutableData *ackPacket = [packet mutableCopy];
                if ([ack[@"mode"] isEqual:@"fixed"]) {
                    [ackPacket setLength:0];
                    for (NSNumber *value in ack[@"bytes"]) { uint8_t byte = value.unsignedCharValue; [ackPacket appendBytes:&byte length:1]; }
                }
                NSMutableDictionary *writeDetails = [details mutableCopy];
                writeDetails[@"attempt"] = @(attempts + 1);
                void (^completion)(NSError *) = ^(NSError *error) {
                    state[@"pending"] = @NO;
                    if (error) writeDetails[@"error"] = error.localizedDescription;
                    self.recordEvent(error ? @"acknowledgement_failed" : @"acknowledgement_written", writeDetails);
                };
                NSDictionary *job = @{@"packet":ackPacket, @"timeout":ack[@"timeoutMs"] ?: @3000, @"details":writeDetails, @"completion":[completion copy]};
                self.recordEvent(@"acknowledgement_queued", writeDetails);
                [self.writeQueue addObject:job];
                [self pumpWrites];
            }
            if (fresh) {
                if (self.configuration[@"reporting"]) {
                    self.recordEvent(@"delivery_started", details);
                    self.deliverIncident(details, ^(NSError *error) {
                        NSMutableDictionary *result = [details mutableCopy];
                        if (error) result[@"error"] = error.localizedDescription;
                        self.recordEvent(error ? @"delivery_failed" : @"delivery_succeeded", result);
                    });
                } else self.recordEvent(@"delivery_skipped", details);
            }
            break;
        }
    }
}
@end
