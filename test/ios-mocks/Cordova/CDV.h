#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@interface WKWebView : NSObject @end
typedef NS_ENUM(NSInteger, CDVCommandStatus) { CDVCommandStatus_OK, CDVCommandStatus_ERROR };
@interface CDVPluginResult : NSObject
+ (instancetype)resultWithStatus:(CDVCommandStatus)status messageAsString:(NSString *)message;
+ (instancetype)resultWithStatus:(CDVCommandStatus)status messageAsDictionary:(NSDictionary *)message;
@end
@interface CDVInvokedUrlCommand : NSObject
@property(nonatomic) NSArray *arguments;
@property(nonatomic) NSString *callbackId;
@property(nonatomic) NSString *className;
@property(nonatomic) NSString *methodName;
- (instancetype)initWithArguments:(NSArray *)arguments callbackId:(NSString *)callback className:(NSString *)className methodName:(NSString *)methodName;
- (id)argumentAtIndex:(NSUInteger)index withDefault:(id)value andClass:(Class)type;
@end
@interface CDVPlugin : NSObject
@property(nonatomic) WKWebView *webViewEngine;
@property(nonatomic) WKWebView *webView;
@property(nonatomic) id commandDelegate;
@property(nonatomic) id viewController;
- (instancetype)initWithWebViewEngine:(WKWebView *)webView;
- (void)pluginInitialize;
- (void)onReset;
- (void)dispose;
- (void)sendPluginResult:(CDVPluginResult *)result callbackId:(NSString *)callback;
@end
