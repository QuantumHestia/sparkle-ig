#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Applies the same EDR receiving-layer path used by the Reels UFI to a custom
/// Story button. The tint is promoted only when the active Story renderer or
/// video format reports HDR/EDR; SDR Stories retain their normal tint.
FOUNDATION_EXPORT void SPKStoryApplyDynamicRangeToButton(UIButton *button);

/// Returns `color` lifted to the same EDR headroom as the button's current
/// tint, so an accent tint matches neighbouring EDR buttons. Returns `color`
/// unchanged when the button is SDR.
FOUNDATION_EXPORT UIColor *SPKStoryDynamicRangeAccentTint(UIButton *button, UIColor *color);

NS_ASSUME_NONNULL_END
