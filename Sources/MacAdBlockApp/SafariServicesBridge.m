#import "SafariServicesBridge.h"

#import <SafariServices/SafariServices.h>

@implementation MABSafariServicesBridge

+ (void)getContentBlockerState:(NSString *)identifier
                    completion:(void (^)(BOOL enabled))completion {
    [SFContentBlockerManager getStateOfContentBlockerWithIdentifier:identifier
                                                 completionHandler:^(SFContentBlockerState *state, NSError *error) {
        BOOL enabled = error == nil && state.isEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(enabled);
        });
    }];
}

+ (void)getWebExtensionState:(NSString *)identifier
                   completion:(void (^)(BOOL enabled))completion {
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:identifier
                                                     completionHandler:^(SFSafariExtensionState *state, NSError *error) {
        BOOL enabled = error == nil && state.isEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(enabled);
        });
    }];
}

+ (void)showPreferencesForExtension:(NSString *)identifier
                          completion:(void (^)(BOOL succeeded))completion {
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:identifier
                                                 completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil);
        });
    }];
}

+ (void)reloadContentBlocker:(NSString *)identifier
                   completion:(void (^)(NSString *errorDomain, NSString *errorMessage))completion {
    [SFContentBlockerManager reloadContentBlockerWithIdentifier:identifier
                                              completionHandler:^(NSError *error) {
        NSString *domain = error.domain;
        NSString *message = error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(domain, message);
        });
    }];
}

@end
