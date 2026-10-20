#import "BLEBackgroundReporting.h"

@implementation BLEBackgroundReporting
+ (NSMutableURLRequest *)requestForIncident:(NSDictionary *)incident
    reporting:(NSDictionary *)reporting
    sentAt:(NSString *)sentAt
    appState:(NSString *)appState
    error:(NSError **)error {
    NSString *problem = nil;
    if (!reporting) problem = @"Reporting is not configured.";
    else if (reporting[@"body"] && [incident[@"event"] isEqual:@"preflight"]) {
        problem = @"Preflight is unavailable with reporting.body. It could perform the configured action. Skip preflight for this configuration.";
    }
    else if (reporting[@"body"] && ![reporting[@"body"] isKindOfClass:NSDictionary.class]) {
        problem = @"reporting.body must be a JSON object, not a serialized string.";
    }
    if (problem) {
        if (error) *error = [NSError errorWithDomain:@"BluetoothLEBackground.Reporting" code:1 userInfo:@{NSLocalizedDescriptionKey:problem}];
        return nil;
    }

    NSDictionary *body = reporting[@"body"];
    if (!body) {
        // Preserve the original incident envelope when no custom body is supplied.
        NSMutableDictionary *envelope = [incident mutableCopy];
        if (!envelope[@"event"]) envelope[@"event"] = @"notification_received";
        envelope[@"sentAt"] = sentAt;
        envelope[@"sentAppState"] = appState;
        body = envelope;
    }
    if (![NSJSONSerialization isValidJSONObject:body]) {
        if (error) *error = [NSError errorWithDomain:@"BluetoothLEBackground.Reporting" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Reporting body must contain valid JSON values."}];
        return nil;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!json) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:reporting[@"url"]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = [reporting[@"timeoutMs"] ?: @8000 doubleValue] / 1000.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    for (NSString *header in reporting[@"headers"]) [request setValue:reporting[@"headers"][header] forHTTPHeaderField:header];
    request.HTTPBody = json;
    return request;
}
@end
