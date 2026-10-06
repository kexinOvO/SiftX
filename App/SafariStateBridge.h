#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Safari SDK 27 annotates its reply UI_ACTOR, but Safari 27 can reply on XPC.
/// Copy only scalar state, then deliver on the main queue before entering Swift.
FOUNDATION_EXPORT void SiftXReadSafariState(NSString *identifier, void (^completion)(BOOL known, BOOL enabled));
FOUNDATION_EXPORT void SiftXOpenSafariPreferences(NSString *identifier, void (^completion)(NSString * _Nullable error));
FOUNDATION_EXPORT void SiftXRefreshSafariToolbar(NSString *identifier, void (^completion)(NSString * _Nullable error));
NS_ASSUME_NONNULL_END
