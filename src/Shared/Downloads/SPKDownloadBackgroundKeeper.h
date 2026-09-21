#import <Foundation/Foundation.h>

#import "SPKDownloadTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Keeps Instagram alive while Sparkle downloads are still running after the
/// user leaves the app.
///
/// Two stages. Backgrounding with work in flight takes a UIBackgroundTask, which
/// buys roughly thirty seconds and covers the whole pipeline: the transfer, any
/// FFmpeg merge or conversion, and the Photos/Gallery write. When work outlives
/// that window the keeper escalates to a silent looping audio session, which the
/// system honours indefinitely. The audio session mixes with others, carries no
/// Now Playing entry and is torn down the moment the queue drains or the app
/// returns to the foreground, so it never takes over the user's music.
@interface SPKDownloadBackgroundKeeper : NSObject

@property (class, nonatomic, readonly) SPKDownloadBackgroundKeeper *shared;

/// Called by the scheduler whenever the set of in-flight items changes.
- (void)setHasActiveWork:(BOOL)hasActiveWork;

/// Called by the scheduler as each item reaches a terminal state. Only tallied
/// while the keepalive is armed, so the finish notification reports the work the
/// user was away for and nothing else.
- (void)noteItemFinishedWithSuccess:(BOOL)success destination:(SPKDownloadDestination)destination;

/// Requested from the settings toggle, never implicitly: posting silently skips
/// itself when Instagram has no notification authorization.
+ (void)requestNotificationAuthorization;

@end

NS_ASSUME_NONNULL_END
