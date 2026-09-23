#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MABSafariServicesBridge : NSObject

+ (void)getContentBlockerState:(NSString *)identifier
                    completion:(void (^)(BOOL enabled))completion NS_SWIFT_DISABLE_ASYNC;

+ (void)getWebExtensionState:(NSString *)identifier
                   completion:(void (^)(BOOL enabled))completion NS_SWIFT_DISABLE_ASYNC;

+ (void)showPreferencesForExtension:(NSString *)identifier
                          completion:(void (^)(BOOL succeeded))completion NS_SWIFT_DISABLE_ASYNC;

+ (void)reloadContentBlocker:(NSString *)identifier
                   completion:(void (^)(NSString * _Nullable errorDomain,
                                         NSString * _Nullable errorMessage))completion NS_SWIFT_DISABLE_ASYNC;

@end

NS_ASSUME_NONNULL_END
