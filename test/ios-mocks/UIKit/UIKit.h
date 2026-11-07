// Minimal test-only UIKit surface; the production handler is also built with the iOS SDK.
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, UIApplicationState) { UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground };
typedef NSUInteger UIBackgroundTaskIdentifier;
#define UIBackgroundTaskInvalid NSUIntegerMax
#define UIApplicationDidEnterBackgroundNotification @"TestApplicationBackground"
#define UIApplicationWillEnterForegroundNotification @"TestApplicationForeground"
#define UISceneDidEnterBackgroundNotification @"TestSceneBackground"
#define UISceneWillEnterForegroundNotification @"TestSceneForeground"
#define UIApplicationLaunchOptionsBluetoothCentralsKey @"TestBluetoothCentrals"
@interface UIApplication : NSObject
@property(nonatomic) UIApplicationState applicationState;
+ (instancetype)sharedApplication;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;
@end
