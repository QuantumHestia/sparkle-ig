#import <UIKit/UIKit.h>

#import "SPKPlaybackSpeedStore.h"

NS_ASSUME_NONNULL_BEGIN

/// The video a playback panel drives. Surfaces fill in the blocks against their
/// own player objects; every block is re-evaluated on each refresh, so a target
/// that resolves "the current item" lazily follows story/reel changes for free.
@interface SPKPlaybackTarget : NSObject
/// NO once the target no longer shows a video (photo item, cell reused, viewer closed).
@property (nonatomic, copy) BOOL (^isAvailable)(void);
@property (nonatomic, copy) double (^currentTime)(void);
@property (nonatomic, copy) double (^duration)(void);
@property (nonatomic, copy) BOOL (^isPlaying)(void);
/// Performs one precise seek and calls `completion` when the player has landed.
/// The panel never overlaps seeks: a player cancelling its previous seek can
/// stay stuck buffering, so requests made meanwhile are coalesced.
@property (nonatomic, copy) void (^seek)(double time, void (^completion)(void));
@property (nonatomic, copy) void (^togglePlayback)(void);
/// Restarts a video that was playing before a seek but stalled after it. Optional.
@property (nonatomic, copy, nullable) void (^resumeAfterSeek)(void);
/// The model object speeds are keyed by for the "This Video" scope.
@property (nonatomic, copy) id _Nullable (^speedItem)(void);
@property (nonatomic, copy) void (^applySpeed)(double speed);
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Shows the floating playback panel next to `anchor`, replacing any panel already on screen.
void SPKPlaybackPanelPresent(UIView *anchor, SPKPlaybackSurface surface, SPKPlaybackTarget *target);
void SPKPlaybackPanelDismiss(BOOL animated);
BOOL SPKPlaybackPanelIsPresentedForAnchor(UIView *_Nullable anchor);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
