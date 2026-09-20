#import <UIKit/UIKit.h>

@class SPKMediaItem;

@protocol SPKFullScreenContentDelegate <NSObject>
@optional
- (void)mediaContentDidTap:(UIViewController *)controller;
- (void)mediaContent:(UIViewController *)controller didFailWithError:(NSError *)error;
/// Reports the zoom state of the content so the host can adapt chrome (e.g.
/// show a material backing behind the bars when content fills behind them).
- (void)mediaContent:(UIViewController *)controller didChangeZoomState:(BOOL)isZoomed;
/// Reports Live Text highlighting (the OCR button being switched on). While it is
/// active VisionKit draws its own "Copy All" quick action over the bottom of the
/// image, inside the content hierarchy, so the host has to move its own chrome out
/// of the way rather than raise anything above it.
- (void)mediaContent:(UIViewController *)controller
    didChangeLiveTextHighlight:(BOOL)highlighted;
/// Picture in Picture took the video out of the viewer. The host gets out of the
/// way (the floating window is the point of PiP) while keeping itself and its
/// pages alive, so the window's restore button has something to return to.
- (void)mediaContentWillStartPictureInPicture:(UIViewController *)controller;
/// The restore button was pressed. The host puts itself back on screen and calls
/// `completion` with whether the content is in a window again; AVKit animates the
/// window back into the player only after that.
- (void)mediaContent:(UIViewController *)controller
    restorePictureInPictureWithCompletion:(void (^)(BOOL restored))completion;
/// The session ended. If the host stepped aside and was never restored, this is
/// where it finishes the dismissal it deferred.
- (void)mediaContentDidStopPictureInPicture:(UIViewController *)controller;
@end

NS_ASSUME_NONNULL_BEGIN

/// Non-notched devices (no home indicator) have opaque top/bottom preview bars
/// that overlap edge-to-edge media — e.g. a 16:9 photo or video fills the whole
/// screen and disappears behind (and fights touches with) the chrome. On those
/// devices we inset the media between the bars; notched devices keep the
/// immersive full-bleed layout, since the system safe area already separates
/// content from the chrome and looks right full-screen.
static inline BOOL SPKFullScreenPreviewShouldInsetMediaBetweenBars(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
            if (!window)
                window = candidate;
        }
        if (window.isKeyWindow)
            break;
    }
    // Home indicator => notched/edge-to-edge device: keep full-bleed.
    return window.safeAreaInsets.bottom <= 0.0;
}

/// YES when VisionKit can analyze images on this device: iOS 16+ with an analyzer
/// the hardware supports. The Live Text controls over the photo preview, and the
/// setting that governs them, are both meaningless without it.
FOUNDATION_EXPORT BOOL SPKLiveTextIsSupported(void);

@interface SPKFullScreenImageViewController : UIViewController

@property (nonatomic, strong, readonly) SPKMediaItem *mediaItem;
@property (nonatomic, weak) id<SPKFullScreenContentDelegate> delegate;
@property (nonatomic, readonly) BOOL isZoomed;

- (instancetype)initWithMediaItem:(SPKMediaItem *)item;
- (void)preloadContent;
- (void)cleanup;
- (void)resetZoomIfNeeded;
- (void)applyMediaContentInsets:(UIEdgeInsets)insets;
/// Distance from the bottom of the screen to the top of the host's action toolbar,
/// measured by the host while the chrome is visible. Floating controls anchor to it
/// instead of the safe area, which shrinks and grows as the bars come and go.
- (void)applyChromeBottomLimit:(CGFloat)bottomLimit;

@end

NS_ASSUME_NONNULL_END
