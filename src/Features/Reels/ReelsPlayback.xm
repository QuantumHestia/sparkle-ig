#import "SPKStrings.h"
#import "../../Utils.h"

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
- (void)_didUnplugHeadphones:(id)headphones {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"]) {
        %orig(headphones);
    }
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
    });
}
