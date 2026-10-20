#import <Foundation/Foundation.h>
#import "BLEBackgroundReporting.h"

static NSUInteger checks = 0;
static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSMutableURLRequest *request(NSDictionary *incident, NSDictionary *reporting, NSError **error) {
    return [BLEBackgroundReporting requestForIncident:incident reporting:reporting
        sentAt:@"test-send-time" appState:@"background" error:error];
}

static NSDictionary *decode(NSURLRequest *request) {
    NSError *error;
    id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:&error];
    check(!error && [body isKindOfClass:NSDictionary.class], @"HTTP body is a JSON object, not a quoted JSON string");
    return body;
}

static void testDefaultEnvelope(void) {
    NSDictionary *incident = @{@"incidentId":@"synthetic-incident", @"ruleId":@"example", @"metadata":@{@"source":@"test"}};
    NSError *error = nil;
    NSMutableURLRequest *prepared = request(incident, @{@"url":@"https://example.invalid/events"}, &error);
    check(prepared && !error, @"default request still builds");
    NSMutableDictionary *expected = [incident mutableCopy];
    expected[@"event"] = @"notification_received";
    expected[@"sentAt"] = @"test-send-time";
    expected[@"sentAppState"] = @"background";
    check([decode(prepared) isEqual:expected], @"default incident envelope retains event and send context");
    check([incident count] == 3 && !incident[@"sentAt"], @"request preparation does not change the logged incident");
    check(prepared.timeoutInterval == 8 && [prepared.HTTPMethod isEqual:@"POST"], @"default timeout and POST preserved");
    check([[prepared valueForHTTPHeaderField:@"Content-Type"] isEqual:@"application/json"], @"default JSON content type preserved");

    prepared = request(@{@"event":@"preflight"}, @{@"url":@"https://example.invalid/events"}, &error);
    check([decode(prepared)[@"event"] isEqual:@"preflight"], @"preflight retains its diagnostic event without a custom body");
}

static void testCustomBody(void) {
    NSDictionary *body = @{@"subject":@"Synthetic test", @"description":@"Quotes: \" and unicode: ✓",
        @"enabled":@NO, @"attachment":NSNull.null, @"nested":@{@"items":@[@1, @"two", NSNull.null]}};
    NSDictionary *reporting = @{@"url":@"https://example.invalid/actions", @"body":body, @"timeoutMs":@1234,
        @"headers":@{@"Content-Type":@"application/json", @"x-auth-token":@"synthetic-token", @"CLIENT-ID":@"synthetic-client"}};
    NSDictionary *incident = @{@"incidentId":@"synthetic-id", @"metadata":@{@"source":@"test"}, @"payload":@[@0x42]};
    NSError *error = nil;
    NSMutableURLRequest *prepared = request(incident, reporting, &error);
    check(prepared && !error, @"custom request builds without contacting a server");
    check([decode(prepared) isEqual:body], @"custom body is exact, including nested data, booleans, unicode and null");
    check(!decode(prepared)[@"incidentId"] && !decode(prepared)[@"sentAt"], @"no incident fields or timestamps are injected into a custom body");
    check([prepared.URL.absoluteString isEqual:reporting[@"url"]], @"app-supplied destination retained");
    check([[prepared valueForHTTPHeaderField:@"x-auth-token"] isEqual:@"synthetic-token"], @"plain authentication header retained");
    check([[prepared valueForHTTPHeaderField:@"CLIENT-ID"] isEqual:@"synthetic-client"], @"optional organization header retained");
    check(prepared.timeoutInterval == 1.234, @"configured timeout converted from milliseconds");
    check([prepared.HTTPMethod isEqual:@"POST"], @"custom request uses POST");
    check([incident count] == 3 && !incident[@"body"] && !incident[@"headers"], @"request body and credentials are not added to event details");

    prepared = request(incident, @{@"url":@"https://example.invalid/actions", @"body":@{}}, &error);
    check([decode(prepared) count] == 0, @"empty custom object is honored instead of falling back to the envelope");
}

static void testPreflightAndErrors(void) {
    NSError *error = nil;
    NSDictionary *reporting = @{@"url":@"https://example.invalid/actions", @"body":@{@"action":@"test"}};
    check(!request(@{@"event":@"preflight"}, reporting, &error) && error != nil,
        @"custom-body preflight is rejected before a URL request can be sent");
    check([error.localizedDescription containsString:@"Skip preflight"], @"preflight rejection explains how the app should proceed");
    error = nil;
    check(!request(@{@"event":@"preflight"}, @{@"url":@"https://example.invalid/actions", @"body":@{}}, &error) && error,
        @"even an empty custom body cannot perform preflight");
    error = nil;
    check(!request(@{}, nil, &error) && error, @"missing reporting fails before constructing a request");
    for (id invalidBody in @[@"{\"action\":\"test\"}", @[], NSNull.null, @42]) {
        error = nil;
        check(!request(@{}, @{@"url":@"https://example.invalid/actions", @"body":invalidBody}, &error) && error,
            @"non-object custom bodies are rejected without a request");
    }
    error = nil;
    check(!request(@{}, @{@"url":@"https://example.invalid/actions", @"body":@{@"bad":@(NAN)}}, &error) && error,
        @"JSON serialization errors fail instead of preparing an empty-body request");
}

int main(void) {
    @autoreleasepool {
        testDefaultEnvelope(); testCustomBody(); testPreflightAndErrors();
        printf("Native HTTP request tests passed (%lu checks). No Bluetooth or network used.\n", (unsigned long)checks);
    }
    return 0;
}
