#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Builds a request from the validated, in-memory configuration. No network I/O.
@interface BLEBackgroundReporting : NSObject
+ (nullable NSMutableURLRequest *)requestForIncident:(NSDictionary *)incident
    reporting:(nullable NSDictionary *)reporting
    sentAt:(NSString *)sentAt
    appState:(NSString *)appState
    error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
