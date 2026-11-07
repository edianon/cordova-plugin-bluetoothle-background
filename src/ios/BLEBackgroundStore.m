#import "BLEBackgroundStore.h"
#import <Security/Security.h>
#import <math.h>

static NSString *const installKey = @"BLEBackground.installation";
static NSString *const blockedKey = @"BLEBackground.recoveryBlocked";

@implementation BLEBackgroundStore
- (NSDictionary *)query {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:[NSBundle.mainBundle.bundleIdentifier ?: @"app" stringByAppendingString:@".bluetoothle-background"],
        (__bridge id)kSecAttrAccount:@"restoration-v1"};
}
- (NSString *)installation {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *identifier = [defaults stringForKey:installKey];
    if (!identifier) {
        identifier = NSUUID.UUID.UUIDString;
        [defaults setObject:identifier forKey:installKey];
        [defaults synchronize];
    }
    return identifier;
}
- (BOOL)status:(OSStatus)status error:(NSError **)error {
    if (status == errSecSuccess || status == errSecItemNotFound) return YES;
    if (error) *error = [NSError errorWithDomain:@"BluetoothLEBackground.SecureStore" code:status
        userInfo:@{NSLocalizedDescriptionKey:@"Secure Bluetooth recovery storage is unavailable."}];
    return NO;
}
- (NSDictionary *)load:(NSError **)error {
    if ([NSUserDefaults.standardUserDefaults boolForKey:blockedKey]) return nil;
    NSMutableDictionary *query = [self.query mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (![self status:status error:error] || status == errSecItemNotFound) return nil;
    NSData *data = CFBridgingRelease(result);
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![state isKindOfClass:NSDictionary.class] || ![state[@"schema"] isEqual:@1] || ![state[@"installation"] isEqual:[self installation]]) return nil;
    return state;
}
- (BOOL)save:(NSDictionary *)state error:(NSError **)error {
    NSMutableDictionary *value = [state mutableCopy];
    value[@"schema"] = @1; value[@"installation"] = [self installation];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:error];
    if (!data || data.length > 262144) return NO;
    NSDictionary *attributes = @{(__bridge id)kSecValueData:data,
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)self.query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [self.query mutableCopy]; [insert addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    if (status != errSecSuccess) { [self status:status error:error]; return NO; }
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:blockedKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    return YES;
}
- (BOOL)invalidate:(NSError **)error {
    // A failed Keychain deletion must never resurrect an old enabled account.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:blockedKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    return [self status:SecItemDelete((__bridge CFDictionaryRef)self.query) error:error];
}
+ (BOOL)canRestore:(NSDictionary *)state now:(NSTimeInterval)now {
    if (![state isKindOfClass:NSDictionary.class] || ![state[@"armed"] isEqual:@YES]) return NO;
    NSDictionary *session = state[@"session"], *configuration = state[@"configuration"];
    if (![session isKindOfClass:NSDictionary.class] || ![configuration isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *scope = configuration[@"restoration"];
    if (![scope isKindOfClass:NSDictionary.class] || ![session[@"accountId"] isKindOfClass:NSString.class] || ![session[@"accountId"] length] ||
        ![scope[@"accountId"] isEqual:session[@"accountId"]]) return NO;
    for (id expiry in @[session[@"expiresAt"] ?: NSNull.null, scope[@"expiresAt"] ?: NSNull.null]) {
        if (![expiry isKindOfClass:NSNumber.class] || !isfinite([expiry doubleValue]) || [expiry doubleValue] <= now) return NO;
    }
    return YES;
}
@end
