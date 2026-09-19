#import "SPKStrings.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>

// IGAudioStatusAnnouncer keeps one global sticky sound state: 0 unset, 1 user
// muted, 2 user unmuted. Reels follow it once it is set, but while it is unset
// they pick sound on or off by themselves, inconsistently. Starting muted means
// writing 1 whenever the state is unset; a tap still writes 2 as usual.
static const long long kSPKStickySoundStateUnset = 0;
static const long long kSPKStickySoundStateMuted = 1;
static const long long kSPKStickySoundStateReason = 5; // what IG's own mute toggle passes

// The first activation after launch is where IG restores the previous session's
// state, so that one is overridden even when set; later ones only fill an unset state.
static BOOL sSPKReelsDidOverrideLaunchSoundState = NO;

static long long *SPKReelsStickySoundStateSlot(id announcer) {
    Ivar ivar = announcer ? class_getInstanceVariable([announcer class], "_stickySoundState") : NULL;
    if (!ivar)
        return NULL;
    return (long long *)((uint8_t *)(__bridge void *)announcer + ivar_getOffset(ivar));
}

static void SPKReelsWriteMutedSoundState(id announcer) {
    SEL setter = @selector(setStickySoundState:forReason:);
    if ([announcer respondsToSelector:setter]) {
        ((void (*)(id, SEL, long long, long long))objc_msgSend)(announcer,
                                                                setter,
                                                                kSPKStickySoundStateMuted,
                                                                kSPKStickySoundStateReason);
        return;
    }

    // 410 has no setter: write the state and notify listeners the way the setter does.
    long long *slot = SPKReelsStickySoundStateSlot(announcer);
    if (!slot)
        return;
    *slot = kSPKStickySoundStateMuted;
    Ivar enabledIvar = class_getInstanceVariable([announcer class], "_audioEnabled");
    if (enabledIvar)
        *((BOOL *)((uint8_t *)(__bridge void *)announcer + ivar_getOffset(enabledIvar))) = NO;

    SEL notify = @selector(audioStatusDidChangeIsAudioEnabled:forReason:);
    id listeners = [SPKUtils getIvarForObj:announcer name:"_announcerForDefaultBehaviors"];
    if ([listeners respondsToSelector:notify])
        ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(listeners, notify, NO, kSPKStickySoundStateReason);
}

static void SPKReelsApplyStartMuted(id announcer) {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"])
        return;
    long long *slot = SPKReelsStickySoundStateSlot(announcer);
    if (!slot)
        return;

    BOOL launch = !sSPKReelsDidOverrideLaunchSoundState;
    sSPKReelsDidOverrideLaunchSoundState = YES;
    if (*slot == kSPKStickySoundStateMuted || (!launch && *slot != kSPKStickySoundStateUnset))
        return;
    SPKReelsWriteMutedSoundState(announcer);
}

%group SPKReelsPlaybackHooks

%hook IGSundialPlaybackControlsTestConfiguration
- (id)initWithLauncherSet:(id)set
                     tapToPauseEnabled:(_Bool)tapPauseEnabled
      combineSingleTapPlaybackControls:(_Bool)controls
        isVideoPreviewThumbnailEnabled:(_Bool)previewThumbEnabled
                minScrubberDurationSec:(long long)minSec
         seekResumeScrubberCooldownSec:(double)seekSec
          tapResumeScrubberCooldownSec:(double)tapSec
    persistentScrubberMinVideoDuration:(long long)duration
        isScrubberForShortVideoEnabled:(_Bool)shortScrubberEnabled {
    _Bool userTapPauseEnabled = tapPauseEnabled;
    if ([[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"pause"])
        userTapPauseEnabled = true;
    else if ([[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"mute"])
        userTapPauseEnabled = false;

    return %orig(set, userTapPauseEnabled, controls, previewThumbEnabled, minSec, seekSec, tapSec, duration, shortScrubberEnabled);
}
%end

%hook IGSundialFeedViewController
- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2 {
    if ([SPKUtils getBoolPref:@"reels_prevent_doom_scroll"] && arg2) {
        IGRefreshControl *_refreshControl = MSHookIvar<IGRefreshControl *>(self, "_refreshControl");
        [_refreshControl finishLoading];
        if ([self respondsToSelector:@selector(finishPullToRefreshLoading)]) {
            [self finishPullToRefreshLoading];
        }

        return;
    }

    if ([SPKUtils getBoolPref:@"reels_confirm_refresh"] && arg2) {
        SPKLog(@"General", @"[Sparkle] Reel refresh triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig(arg1, arg2);
            }
            cancelHandler:^(void) {
                IGRefreshControl *_refreshControl = MSHookIvar<IGRefreshControl *>(self, "_refreshControl");
                [_refreshControl finishLoading];
                if ([self respondsToSelector:@selector(finishPullToRefreshLoading)]) {
                    [self finishPullToRefreshLoading];
                }
            }
            title:SPKL(@"REELS_REELS_PLAYBACK_CONFIRM_REELS_REFRESH_TEXT")
            message:SPKL(@"REELS_REELS_PLAYBACK_REFRESH_REELS_FEED_CONFIRMATION_MESSAGE")];
    } else {
        return %orig(arg1, arg2);
    }
}

- (void)triggerRefreshFromTabTap {
    if ([SPKUtils getBoolPref:@"reels_confirm_refresh"]) {
        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
               cancelHandler:nil
                       title:SPKL(@"REELS_REELS_PLAYBACK_CONFIRM_REELS_REFRESH_TEXT")
                     message:SPKL(@"REELS_REELS_PLAYBACK_REFRESH_REELS_FEED_CONFIRMATION_MESSAGE")];
    } else {
        %orig;
    }
}
%end

// * Disable volume/mute button triggering unmutes
%hook IGAudioStatusAnnouncer
- (void)_muteSwitchStateChanged:(id)changed {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"]) {
        %orig(changed);
    }
}
- (void)_didPressVolumeButton:(id)button {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"]) {
        %orig(button);
    }
}
// 410 passes the notification, newer versions take no argument.
- (void)_didUnplugHeadphones:(id)headphones {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"]) {
        %orig(headphones);
    }
}
- (void)_didUnplugHeadphones {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"]) {
        %orig;
    }
}
// IG may restore last session's sound state or reset it to unset here.
- (void)_applicationDidBecomeActive {
    %orig;
    SPKReelsApplyStartMuted(self);
}
- (void)_applicationDidBecomeActive:(id)notification {
    %orig(notification);
    SPKReelsApplyStartMuted(self);
}
%end

%end

extern "C" void SPKInstallReelsPlaybackHooksIfNeeded(void) {
    BOOL shouldInstall = ![[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"default"] ||
                         [SPKUtils getBoolPref:@"reels_prevent_doom_scroll"] ||
                         [SPKUtils getBoolPref:@"reels_confirm_refresh"] ||
                         [SPKUtils getBoolPref:@"reels_disable_auto_unmute"];
    if (!shouldInstall)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKReelsPlaybackHooks);

        // Surface hooks install after launch, usually past the first activation.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
            return;
        Class announcerClass = NSClassFromString(@"IGAudioStatusAnnouncer");
        if ([announcerClass respondsToSelector:@selector(sharedInstance)])
            SPKReelsApplyStartMuted([announcerClass sharedInstance]);
    });
}
