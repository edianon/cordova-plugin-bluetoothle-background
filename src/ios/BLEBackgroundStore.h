#import <Foundation/Foundation.h>

// One device-only, after-first-unlock item. No credentials in UserDefaults/files/backups.
@interface BLEBackgroundStore : NSObject
- (NSDictionary *)load:(NSError **)error;
- (BOOL)save:(NSDictionary *)state error:(NSError **)error;
- (BOOL)invalidate:(NSError **)error;
+ (BOOL)canRestore:(NSDictionary *)state now:(NSTimeInterval)now;
@end
