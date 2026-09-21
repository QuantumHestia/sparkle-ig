// Hide story midcards — the interstitial "Recommended for you" / suggested-user
// (SU) and "Add Yours" (AY) promo cards Instagram injects into the stories tray.
//
// IGStoriesMidcardsController fetches these units. We short-circuit the fetch and
// the two eligibility checks so no midcard is ever produced. Hooks are installed
// at dylib load (%ctor) — the first fetch can fire very early with the feed, so a
// staged surface installer risks being too late. Each method re-checks the pref
// at call time, so the toggle takes effect without a restart.
//
// The controller class only exists on modern IG (435+/436+); on 410 the stories
// midcard architecture is different, so the class guard makes this a clean no-op.

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

%group SPKHideStoryMidcardsHooks

%hook IGStoriesMidcardsController

- (void)fetchMidcards {
    if ([SPKUtils getBoolPref:@"stories_hide_join_trending"])
        return;
    %orig;
}

// IG 448 passes a score into the fetch and SU eligibility paths. The bare
// variants above and below still cover older builds.
- (void)fetchMidcardsWithLness28Score:(id)score {
    if ([SPKUtils getBoolPref:@"stories_hide_join_trending"])
        return;
    %orig;
}

- (BOOL)_isEligibleForAYPromo {
    if ([SPKUtils getBoolPref:@"stories_hide_join_trending"])
        return NO;
    return %orig;
}

- (BOOL)_isEligibleForSUMidcard {
    if ([SPKUtils getBoolPref:@"stories_hide_join_trending"])
        return NO;
    return %orig;
}

- (BOOL)_isEligibleForSUMidcardWithLness28Score:(id)score {
    if ([SPKUtils getBoolPref:@"stories_hide_join_trending"])
        return NO;
    return %orig;
}

%end

%end // group SPKHideStoryMidcardsHooks

%ctor {
    if (NSClassFromString(@"IGStoriesMidcardsController")) {
        %init(SPKHideStoryMidcardsHooks);
    }
}
