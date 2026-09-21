#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

// ---------------------------------------------------------------------------
// Disable feed autoplay — hooks installed at dylib load (%ctor) so they're
// in place before any IGFeedPlaybackStrategy objects are created.
//
// Each init swizzle forces the disable flag on the strategy at creation time.
// The strategy is built once per feed session and never revisits its init, so a
// toggle change only lands after a full app restart — hence the row is (restart).
//
// feed_disable_autoplay is a GLOBAL key (see SPKPrefIsGlobalKey): the strategy
// is created during early launch before the account session resolves
// (currentUserPK == nil then), so a per-account effective key would resolve
// against the wrong/roster PK and miss the value. Reading the plain global key
// has no session dependency, so the early init read is reliable.
// ---------------------------------------------------------------------------

static id (*orig_feedAutoplayInit1)(id, SEL, BOOL);
static id spk_feedAutoplayInit1(id self, SEL _cmd, BOOL shouldDisable) {
    if ([SPKUtils getBoolPref:@"feed_disable_autoplay"])
        shouldDisable = YES;
    return orig_feedAutoplayInit1(self, _cmd, shouldDisable);
}

// When we force autoplay off we also force shouldClearStaleReservation=NO.
// A user tap reserves playback (playbackReservationKey); IG clears that
// reservation on the next resolve tick when this flag is set, which is why a
// manually-started video re-pauses during the tap-to-center snap-scroll. Not
// clearing it keeps the manual play alive across the snap.
static id (*orig_feedAutoplayInit2)(id, SEL, BOOL, BOOL);
static id spk_feedAutoplayInit2(id self, SEL _cmd, BOOL shouldDisable, BOOL shouldClearStale) {
    if ([SPKUtils getBoolPref:@"feed_disable_autoplay"]) {
        shouldDisable = YES;
        shouldClearStale = NO;
    }
    return orig_feedAutoplayInit2(self, _cmd, shouldDisable, shouldClearStale);
}

static id (*orig_feedAutoplayInit3)(id, SEL, BOOL, BOOL, BOOL);
static id spk_feedAutoplayInit3(id self, SEL _cmd, BOOL shouldDisable, BOOL shouldClearStale, BOOL bypassForVoiceover) {
    if ([SPKUtils getBoolPref:@"feed_disable_autoplay"]) {
        shouldDisable = YES;
        shouldClearStale = NO;
    }
    return orig_feedAutoplayInit3(self, _cmd, shouldDisable, shouldClearStale, bypassForVoiceover);
}

static id (*orig_feedAutoplayInit5)(id, SEL, BOOL, BOOL, BOOL, BOOL, id);
static id spk_feedAutoplayInit5(id self, SEL _cmd, BOOL shouldDisable, BOOL shouldClearStale, BOOL bypassForVoiceover, BOOL overrideThresholds, id config) {
    if ([SPKUtils getBoolPref:@"feed_disable_autoplay"]) {
        shouldDisable = YES;
        shouldClearStale = NO;
    }
    return orig_feedAutoplayInit5(self, _cmd, shouldDisable, shouldClearStale, bypassForVoiceover, overrideThresholds, config);
}

// Carousel tap-to-play: the modern feed video cell receives single-taps via
// this delegate callback, but the Swift implementation skips resume when the
// cell sits inside a carousel. Force retryStartPlayback after orig.
static void (*orig_feedVideoCellSingleTap)(id, SEL, id, id);
static void spk_feedVideoCellSingleTap(id self, SEL _cmd, id overlay, id recognizer) {
    if (orig_feedVideoCellSingleTap)
        orig_feedVideoCellSingleTap(self, _cmd, overlay, recognizer);
    if (![SPKUtils getBoolPref:@"feed_disable_autoplay"])
        return;
    UIView *superview = [(UIView *)self superview];
    if (!superview || !strstr(class_getName([superview class]), "Carousel"))
        return;
    SEL retrySelector = NSSelectorFromString(@"retryStartPlayback");
    if ([self respondsToSelector:retrySelector]) {
        ((void (*)(id, SEL))objc_msgSend)(self, retrySelector);
    }
}

static void SPKHookFeedPlaybackStrategy(void) {
    static BOOL hooked = NO;
    if (hooked)
        return;
    // IGFeedPlaybackStrategy is a Swift class; on a heavy startup the
    // %ctor can run before its metadata is registered, so objc_getClass
    // returns nil here. Guard + retry (see runloop + staged-installer calls
    // below) so we don't silently leave autoplay un-hooked.
    Class cls = objc_getClass("IGFeedPlayback.IGFeedPlaybackStrategy");
    if (!cls)
        cls = objc_getClass("_TtC14IGFeedPlayback22IGFeedPlaybackStrategy");
    if (!cls)
        return;
    hooked = YES;

    SEL s1 = @selector(initWithShouldDisableAutoplay:);
    if (class_getInstanceMethod(cls, s1)) {
        MSHookMessageEx(cls, s1, (IMP)spk_feedAutoplayInit1, (IMP *)&orig_feedAutoplayInit1);
    }
    SEL s2 = @selector(initWithShouldDisableAutoplay:shouldClearStaleReservation:);
    if (class_getInstanceMethod(cls, s2)) {
        MSHookMessageEx(cls, s2, (IMP)spk_feedAutoplayInit2, (IMP *)&orig_feedAutoplayInit2);
    }
    SEL s3 = @selector(initWithShouldDisableAutoplay:shouldClearStaleReservation:shouldBypassDisabledAutoplayForVoiceover:);
    if (class_getInstanceMethod(cls, s3)) {
        MSHookMessageEx(cls, s3, (IMP)spk_feedAutoplayInit3, (IMP *)&orig_feedAutoplayInit3);
    }
    // IG 448 renamed the trailing launcherSet: argument to mobileConfig: with the same shape.
    for (NSString *name in @[ @"initWithShouldDisableAutoplay:shouldClearStaleReservation:shouldBypassDisabledAutoplayForVoiceover:shouldOverrideDefaultThresholds:mobileConfig:",
                              @"initWithShouldDisableAutoplay:shouldClearStaleReservation:shouldBypassDisabledAutoplayForVoiceover:shouldOverrideDefaultThresholds:launcherSet:" ]) {
        SEL s5 = NSSelectorFromString(name);
        if (class_getInstanceMethod(cls, s5)) {
            MSHookMessageEx(cls, s5, (IMP)spk_feedAutoplayInit5, (IMP *)&orig_feedAutoplayInit5);
            break;
        }
    }
}

static void SPKHookFeedVideoCell(void) {
    static BOOL hooked = NO;
    if (hooked)
        return;
    Class cls = objc_getClass("IGModernFeedVideoCell.IGModernFeedVideoCell");
    if (!cls)
        cls = objc_getClass("IGModernFeedVideoCell");
    if (!cls)
        return;
    SEL selector = @selector(videoPlayerOverlayControllerDidSingleTap:gestureRecognizer:);
    if (class_getInstanceMethod(cls, selector)) {
        MSHookMessageEx(cls, selector, (IMP)spk_feedVideoCellSingleTap, (IMP *)&orig_feedVideoCellSingleTap);
        hooked = YES;
    }
}

// Install hooks at dylib load time — this is the critical fix. The old
// approach waited for IGTabBarController which was too late; the staged
// hook system (0.35s after didFinishLaunching) was also too late. %ctor
// runs at dylib load, before any IG classes are instantiated.
%ctor {
    SPKHookFeedPlaybackStrategy();
    SPKHookFeedVideoCell();
    // Both are Swift classes that can register after dylib init; retry on the
    // main runloop. Both installers are idempotent (static hooked guard).
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKHookFeedPlaybackStrategy();
        SPKHookFeedVideoCell();
    });
}

// Late fallback from the staged feed-surface registry (0.25s–0.75s after
// launch). By then the Swift classes are certainly registered, so this
// guarantees the strategy/cell hooks land even if %ctor and the immediate
// runloop retry both raced ahead of metadata registration. Idempotent.
void SPKInstallDisableFeedAutoplayHooksIfEnabled(void) {
    SPKHookFeedPlaybackStrategy();
    SPKHookFeedVideoCell();
}
