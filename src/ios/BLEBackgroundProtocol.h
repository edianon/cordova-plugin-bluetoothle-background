#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Device-independent packet and incident logic, tested without Bluetooth or UIKit.
@interface BLEBackgroundProtocol : NSObject
@property(nonatomic, readonly) NSDictionary *configuration;
@property(nonatomic, copy) void (^recordEvent)(NSString *event, NSDictionary *details);
@property(nonatomic, copy) void (^writePacket)(NSData *packet, NSUInteger timeoutMs, void (^completion)(NSError * _Nullable error));
@property(nonatomic, copy) void (^deliverIncident)(NSDictionary *incident, void (^completion)(NSError * _Nullable error));
/** Saves claims BEFORE ACK/delivery and successful ACK completion afterward. Claim failure suppresses both effects. */
@property(nonatomic, copy) BOOL (^persistIncidents)(NSDictionary *incidents);
- (NSDictionary *)incidentSnapshot;
- (BOOL)restoreIncidents:(NSDictionary *)incidents;
- (BOOL)restoreIncidents:(NSDictionary *)incidents afterRelaunch:(BOOL)afterRelaunch;
- (nullable instancetype)initWithConfiguration:(NSDictionary *)configuration error:(NSError **)error;
- (void)receiveData:(NSData *)data atTime:(NSTimeInterval)time context:(NSDictionary *)context;
- (void)resetStream;
@end

NS_ASSUME_NONNULL_END
