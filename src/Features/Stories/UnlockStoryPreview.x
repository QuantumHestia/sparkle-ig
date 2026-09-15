#import "../../InstagramHeaders.h"
#import "../../Utils.h"

// "Story Preview" (peek a story from the long-press menu without appearing on
// the viewer list) is an Instagram Plus feature. The real story media is already
// prefetched and IG renders it for real — for non-subscribers it just builds the
// peek in "upsell" mode (blur + "Instagram Plus / Upgrade now" overlay, no video
// playback / auto-advance), and the separate "See preview" menu item opens the
// subscribe page (a dead end when sideloaded).
//
// The upsell-vs-real decision is made by IGConsumerSubsStoryPeekEligibility:
// isPeekEligible → real peek mode, isUpsellPeekEligible → upsell. Both the feed
// story-tray and DM-inbox entry points funnel through it (confirmed on-device:
// forcing isPeekEligible to YES makes the coordinator hand the peek its real
// "media" peekMode=0, and video/auto-advance/no-seen all work). The service-level
// isStoryPeeksBenefitEnabled flag is NOT consulted here, so we gate above it.
//
// Behind stories_unlock_preview we force the eligibility gate to real peek, and
// also correct the presenter itself: on 440 and earlier that means redirecting
// the DM manager's presentPeekUpsell… to presentPeek…, and on 441+ (where the
// per-surface plugins were merged into one manager that takes the decision as a
// `peekMode` argument) forcing that mode to real.
//
// These classes are Swift; their runtime names are the mangled _TtC form and do
// not exist on IG 410 (iOS 15) where Instagram Plus is absent, so %hook binds
// nothing there.

static inline BOOL SPKUnlockStoryPreviewEnabled(void) {
    return [SPKUtils getBoolPref:@"stories_unlock_preview"];
}

%group SPKUnlockStoryPreviewHooks

// Demangled: IGConsumerSubsStoryPeekEligibility.IGConsumerSubsStoryPeekEligibility
%hook _TtC34IGConsumerSubsStoryPeekEligibility34IGConsumerSubsStoryPeekEligibility

+ (BOOL)isPeekEligibleForEntryPoint:(long long)point viewModelType:(long long)type consumerSubsService:(id)service launcherSet:(id)set {
    if (SPKUnlockStoryPreviewEnabled()) {
        return YES;
    }
    return %orig;
}

+ (BOOL)isUpsellPeekEligibleForEntryPoint:(long long)point viewModelType:(long long)type consumerSubsService:(id)service launcherSet:(id)set {
    if (SPKUnlockStoryPreviewEnabled()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isAnyPeekEligibleForEntryPoint:(long long)point viewModelType:(long long)type consumerSubsService:(id)service launcherSet:(id)set {
    if (SPKUnlockStoryPreviewEnabled()) {
        return YES;
    }
    return %orig;
}

%end

// Belt-and-suspenders for the DM-inbox entry: if IG ever still routes through
// the upsell presenter, hand it the real one instead.
// Demangled: IGConsumerSubsStoryPeekDirectPlugin.IGConsumerSubsStoryPeekDirectManager
%hook _TtC35IGConsumerSubsStoryPeekDirectPlugin36IGConsumerSubsStoryPeekDirectManager
- (void)presentPeekUpsellWithSourceView:(id)view reelPK:(id)pk presenting:(id)presenting onSubscribeToInstagramPlus:(id)onSubscribe onViewProfile:(id)onViewProfile {
    if (SPKUnlockStoryPreviewEnabled()) {
        SPKLog(@"Peek", @"[Sparkle] DM peek upsell intercepted, showing real preview");
        [self presentPeekWithSourceView:view reelPK:pk presenting:presenting onTapToOpenStory:nil onViewProfile:onViewProfile];
        return;
    }
    %orig(view, pk, presenting, onSubscribe, onViewProfile);
}
%end

%end

// IG 441 replaced the per-surface Direct/Profile plugins with one manager, and
// dropped the separate upsell presenter: the real-vs-upsell choice now rides in
// `peekMode` on a single entry point (1 = upsell, 0 = real).
//
// This is not belt-and-suspenders on 441 — device logs show both entry points
// arriving with mode 1 even while the eligibility gate above is forced, so this
// is what actually unlocks the peek there. Only installed on 441-446, where the
// mode is still an integer.
%group SPKUnlockStoryPreviewIntegerModeHooks

// Demangled: IGConsumerSubsStoryPeekPlugin.IGConsumerSubsStoryPeekManager
%hook _TtC29IGConsumerSubsStoryPeekPlugin30IGConsumerSubsStoryPeekManager

- (void)presentPeekWithReelPK:(id)pk source:(id)source pogPosition:(long long)position peekMode:(long long)mode context:(id)context actions:(id)actions presenting:(id)presenting {
    if (SPKUnlockStoryPreviewEnabled() && mode != 0) {
        SPKLog(@"Peek", @"[Sparkle] peek mode %lld forced to real (reelPK)", mode);
        mode = 0;
    }
    %orig(pk, source, position, mode, context, actions, presenting);
}

- (void)presentPeekWithViewModel:(id)model source:(id)source pogPosition:(long long)position peekMode:(long long)mode context:(id)context actions:(id)actions presenting:(id)presenting {
    if (SPKUnlockStoryPreviewEnabled() && mode != 0) {
        SPKLog(@"Peek", @"[Sparkle] peek mode %lld forced to real (viewModel)", mode);
        mode = 0;
    }
    %orig(model, source, position, mode, context, actions, presenting);
}

%end

%end

// IG 447 boxed `peekMode` into an IGConsumerSubsStoryPeekModeObjc instance, so the
// integer force above would hand IG a nil mode and crash. Every entry point now
// receives a mode object instead: the feed tray asks the mode resolver, the
// DM/profile paths go through the manager, and all of them end at the
// coordinator. Replace whatever mode arrives with the standard real peek. The
// wrapped Swift enum is not readable from Obj-C, so upsell and first-run
// education are not told apart; both become the real peek.
static Class SPKStoryPeekModeClass(void) {
    return objc_getClass("_TtC31IGConsumerSubsStoryPeekManaging31IGConsumerSubsStoryPeekModeObjc");
}

static id SPKRealStoryPeekMode(id mode, NSString *site) {
    if (!mode || !SPKUnlockStoryPreviewEnabled())
        return mode;
    Class modeClass = SPKStoryPeekModeClass();
    if (!modeClass || ![mode isKindOfClass:modeClass] || ![modeClass respondsToSelector:@selector(peek)])
        return mode;
    id real = [modeClass peek];
    if (!real)
        return mode;
    if (site)
        SPKLog(@"Peek", @"[Sparkle] peek mode %@ forced to real (%@)", mode, site);
    return real;
}

%group SPKUnlockStoryPreviewObjectModeHooks

// Demangled: IGConsumerSubsStoryPeekPlugin.IGConsumerSubsStoryPeekManager
%hook _TtC29IGConsumerSubsStoryPeekPlugin30IGConsumerSubsStoryPeekManager

- (void)presentPeekWithReelPK:(id)pk source:(id)source pogPosition:(long long)position peekMode:(id)mode context:(id)context actions:(id)actions presenting:(id)presenting {
    %orig(pk, source, position, SPKRealStoryPeekMode(mode, @"reelPK"), context, actions, presenting);
}

- (void)presentPeekWithViewModel:(id)model source:(id)source pogPosition:(long long)position peekMode:(id)mode context:(id)context actions:(id)actions presenting:(id)presenting {
    %orig(model, source, position, SPKRealStoryPeekMode(mode, @"viewModel"), context, actions, presenting);
}

%end

// Demangled: IGConsumerSubsStoryPeek.IGConsumerSubsStoryPeekModeResolver
// Feed story tray. A nil result means IG will not peek at all for this gesture,
// so only an existing mode is upgraded; a tap is never turned into a peek.
%hook _TtC23IGConsumerSubsStoryPeek35IGConsumerSubsStoryPeekModeResolver

+ (id)longPressModeForEntryPoint:(long long)point viewModel:(id)model userSession:(id)session {
    return SPKRealStoryPeekMode(%orig, @"resolver long press");
}

+ (id)tapModeForEntryPoint:(long long)point viewModel:(id)model userSession:(id)session {
    return SPKRealStoryPeekMode(%orig, @"resolver tap");
}

%end

// Demangled: IGConsumerSubsStoryPeek.IGConsumerSubsStoryPeekCoordinator
// Catch-all for entry points not hooked above. Every known path has already been
// forced by the time it gets here, so this site does not log.
%hook _TtC23IGConsumerSubsStoryPeek34IGConsumerSubsStoryPeekCoordinator

- (void)launchPeekViewControllerBelow:(id)below viewModel:(id)model story:(id)story peekMode:(id)mode pogPosition:(long long)position from:(id)from gesture:(long long)gesture abortedPeekHandler:(id)handler {
    %orig(below, model, story, SPKRealStoryPeekMode(mode, nil), position, from, gesture, handler);
}

%end

%end

void SPKInstallUnlockStoryPreviewHooksIfEnabled(void) {
    if (!SPKUnlockStoryPreviewEnabled())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKUnlockStoryPreviewHooks);
        // The mode wrapper class only exists once `peekMode` became an object.
        if (SPKStoryPeekModeClass()) {
            %init(SPKUnlockStoryPreviewObjectModeHooks);
        } else {
            %init(SPKUnlockStoryPreviewIntegerModeHooks);
        }
    });
}
