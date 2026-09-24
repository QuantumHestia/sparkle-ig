#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKPlaybackSurface) {
    SPKPlaybackSurfaceStories = 0,
    SPKPlaybackSurfaceReels,
};

/// How long a speed picked in the playback panel stays applied.
typedef NS_ENUM(NSInteger, SPKPlaybackSpeedScope) {
    SPKPlaybackSpeedScopeVideo = 0,
    SPKPlaybackSpeedScopeSession,
    SPKPlaybackSpeedScopeAlways,
};

/// Posted on the main queue whenever a surface's speed or scope changes. The
/// `object` is the surface as an NSNumber.
FOUNDATION_EXPORT NSNotificationName const SPKPlaybackSpeedDidChangeNotification;

FOUNDATION_EXPORT double const SPKPlaybackSpeedMinimum;
FOUNDATION_EXPORT double const SPKPlaybackSpeedMaximum;
FOUNDATION_EXPORT double const SPKPlaybackSpeedStep;

#ifdef __cplusplus
extern "C" {
#endif

/// The feature toggle for `surface` (`stories_playback_controls` / `reels_playback_controls`).
BOOL SPKPlaybackControlsEnabled(SPKPlaybackSurface surface);

NSString *SPKPlaybackSpeedScopePreferenceKey(SPKPlaybackSurface surface);
SPKPlaybackSpeedScope SPKPlaybackSpeedCurrentScope(SPKPlaybackSurface surface);
void SPKPlaybackSpeedSetScope(SPKPlaybackSurface surface, SPKPlaybackSpeedScope scope, id _Nullable currentItem);

/// The speed that should play for `item` (the story item or reel media model).
/// Returns 1.0 whenever the feature is off.
double SPKPlaybackSpeedEffective(SPKPlaybackSurface surface, id _Nullable item);

/// Records a speed picked for `item`, honouring the surface's current scope.
void SPKPlaybackSpeedSetForItem(SPKPlaybackSurface surface, double speed, id _Nullable item);

/// Ends a viewing session: session-scoped and video-scoped speeds fall back to 1x.
void SPKPlaybackSpeedEndSession(SPKPlaybackSurface surface);

double SPKPlaybackSpeedClamp(double speed);
BOOL SPKPlaybackSpeedIsNormal(double speed);

/// Localized "1.5×" style label.
NSString *SPKPlaybackSpeedLabel(double speed);
NSArray<NSNumber *> *SPKPlaybackSpeedPresets(void);
NSString *SPKPlaybackSpeedScopeTitle(SPKPlaybackSpeedScope scope);
/// Stored preference value for `scope` ("video" / "session" / "always").
NSString *SPKPlaybackSpeedScopeValue(SPKPlaybackSpeedScope scope);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
