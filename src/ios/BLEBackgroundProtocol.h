#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Device-independent packet and incident logic, tested without Bluetooth or UIKit.
@interface BLEBackgroundProtocol : NSObject
@property(nonatomic, readonly) NSDictionary *configuration;
@property(nonatomic, copy) void (^recordEvent)(NSString *event, NSDictionary *details);
@property(nonatomic, copy) void (^writePacket)(NSData *packet, NSUInteger timeoutMs, void (^completion)(NSError * _Nullable error));
@property(nonatomic, copy) void (^deliverIncident)(NSDictionary *incident, void (^completion)(NSError * _Nullable error));
- (nullable instancetype)initWithConfiguration:(NSDictionary *)configuration error:(NSError **)error;
- (void)receiveData:(NSData *)data atTime:(NSTimeInterval)time context:(NSDictionary *)context;
- (void)resetStream;
@end

NS_ASSUME_NONNULL_END
