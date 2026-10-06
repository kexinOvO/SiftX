#import "SafariStateBridge.h"
#import <SafariServices/SafariServices.h>

void SiftXReadSafariState(NSString *identifier, void (^completion)(BOOL, BOOL)) {
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:identifier completionHandler:^(SFSafariExtensionState *state, NSError *error) {
        BOOL known = state != nil;
        BOOL enabled = state.isEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(known, enabled); });
    }];
}

void SiftXOpenSafariPreferences(NSString *identifier, void (^completion)(NSString *)) {
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:identifier completionHandler:^(NSError *error) {
        NSString *message = error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(message); });
    }];
}

void SiftXRefreshSafariToolbar(NSString *identifier, void (^completion)(NSString *)) {
    [SFSafariApplication dispatchMessageWithName:@"siftx.toolbarIconChanged" toExtensionWithIdentifier:identifier userInfo:nil completionHandler:^(NSError *error) {
        NSString *message = error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(message); });
    }];
}
