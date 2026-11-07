#import <Foundation/Foundation.h>
#import "BLEBackgroundStore.h"
static NSUInteger checks;
static void check(BOOL result) { checks++; if (!result) { NSLog(@"Recovery policy check %lu failed", (unsigned long)checks); exit(1); } }
int main(void) {
    @autoreleasepool {
        NSDictionary *scope = @{@"accountId":@"synthetic-account", @"expiresAt":@200};
        NSDictionary *valid = @{@"armed":@YES, @"session":scope, @"configuration":@{@"restoration":scope}};
        check([BLEBackgroundStore canRestore:valid now:100]);
        check(![BLEBackgroundStore canRestore:valid now:200]);
        check(![BLEBackgroundStore canRestore:valid now:300]);
        check(![BLEBackgroundStore canRestore:nil now:100]);
        for (NSDictionary *override in @[@{@"armed":@NO}, @{@"session":@{}}, @{@"configuration":@{}},
            @{@"session":@{@"accountId":@"other-account", @"expiresAt":@200}},
            @{@"session":@{@"accountId":@"synthetic-account", @"expiresAt":@99}},
            @{@"session":@{@"accountId":@"synthetic-account", @"expiresAt":@"invalid"}},
            @{@"configuration":@{@"restoration":@{@"accountId":@"synthetic-account", @"expiresAt":@99}}},
            @{@"configuration":NSNull.null}, @{@"session":NSNull.null}]) {
            NSMutableDictionary *state = valid.mutableCopy; [state addEntriesFromDictionary:override];
            check(![BLEBackgroundStore canRestore:state now:100]);
        }
        printf("Native recovery policy passed (%lu checks). No Keychain, Bluetooth or network used.\n", (unsigned long)checks);
    }
}
