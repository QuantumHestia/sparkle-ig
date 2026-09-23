#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Values stored by the link opening mode preferences.
FOUNDATION_EXPORT NSString *const SPKWebLinkOpenModeInstagram;
FOUNDATION_EXPORT NSString *const SPKWebLinkOpenModeInApp;
FOUNDATION_EXPORT NSString *const SPKWebLinkOpenModeSafari;
FOUNDATION_EXPORT NSString *const SPKWebLinkOpenModeAsk;

/// Raw stored link-opening mode (`default`, `in_app`, `safari`, `ask`).
FOUNDATION_EXPORT NSString *SPKLinkOpeningModeSetting(void);

/// Effective mode for links Instagram would open in its own browser: `default`
/// keeps Instagram's browser (stock behavior).
FOUNDATION_EXPORT NSString *SPKBrowserLinkOpeningMode(void);

/// Effective mode for tappable post-text links: `default` opens an in-app
/// Safari view, since post links have no Instagram browser to keep.
FOUNDATION_EXPORT NSString *SPKTappableLinkOpeningMode(void);

FOUNDATION_EXPORT BOOL SPKWebLinkIsWebURL(NSURL *_Nullable url);

/// Unwraps Instagram and Facebook redirect links to their destination and drops
/// click-tracking query items. Returns `url` unchanged when there is nothing to remove.
FOUNDATION_EXPORT NSURL *SPKWebLinkCleanedURL(NSURL *url);

/// YES for Instagram, Facebook and other Meta hosts, whose pages rely on the
/// signed-in session that only Instagram's own browser carries.
FOUNDATION_EXPORT BOOL SPKWebLinkIsMetaOwnedURL(NSURL *url);

/// Opens a web link according to `mode`. `in_app` presents a Safari view controller
/// from `presenter` (falling back to Safari when there is none), `safari` hands the
/// link to the system, and `ask` offers both. When `instagramHandler` is set, `ask`
/// also offers Instagram's browser and `instagram` runs the handler.
FOUNDATION_EXPORT void SPKOpenWebLink(NSURL *url,
                                      NSString *_Nullable mode,
                                      UIViewController *_Nullable presenter,
                                      dispatch_block_t _Nullable instagramHandler);

NS_ASSUME_NONNULL_END
