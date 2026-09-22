#import <objc/runtime.h>
#import <substrate.h>

#include "../../../modules/SPKSideloadFix/fishhook/fishhook.h"
#import "../../Settings/SPKPreferences.h"
#import "../../Utils.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

typedef BOOL (*SPK_BOOL_MSG)(id self, SEL _cmd);
typedef void (*SPK_VOID_MSG)(id self, SEL _cmd);
typedef void (*SPK_SET_CGFLOAT_MSG)(id self, SEL _cmd, CGFloat value);

static BOOL SPKIsLiquidGlassEnabled(void) {
    return [SPKUtils spk_isLiquidGlassEffectivelyEnabled];
}

// MARK: - Experiment-helper overrides (IG 433+)
//
// On 433+ the real per-account gate is
// IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper, which
// exposes @objc override setters (overrideIsEnabled: etc.). Driving these is
// IG's own QE-override path and propagates consistently to the nav chrome /
// follow button, unlike swizzling individual getters.

static Class SPKLiquidGlassNavHelperClass(void) {
    Class c = objc_getClass("_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper");
    if (!c)
        c = NSClassFromString(@"IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper");
    return c;
}

static id SPKLiquidGlassSharedSingleton(Class cls) {
    if (cls && [cls respondsToSelector:@selector(shared)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    }
    return nil;
}

// Calls a "-(void)overrideXxx:" setter, adapting to whether the first argument
// is a scalar BOOL or a boxed object (Bool? bridges to NSNumber *).
static void SPKLiquidGlassCallOverrideBool(id target, SEL sel, BOOL value) {
    if (!target || ![target respondsToSelector:sel])
        return;
    Method m = class_getInstanceMethod([target class], sel);
    char argType[16] = {0};
    if (m)
        method_getArgumentType(m, 2, argType, sizeof(argType));
    if (argType[0] == '@') {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, @(value));
    } else {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
    }
}

// Force the navigation Liquid Glass experiment on, matching the gate values
// observed on a server-enabled account (isEnabled=YES, everything else left at
// its natural value).
extern "C" void SPKApplyLiquidGlassExperimentOverridesIfEnabled(void) {
    if (!SPKIsLiquidGlassEnabled())
        return;
    id nav = SPKLiquidGlassSharedSingleton(SPKLiquidGlassNavHelperClass());
    if (!nav) {
        SPKLog(@"LiquidGlass", @"NavExperimentHelper unavailable; override skipped");
        return;
    }
    SPKLiquidGlassCallOverrideBool(nav, @selector(overrideIsEnabled:), YES);
    SPKLog(@"LiquidGlass", @"Applied NavExperimentHelper overrideIsEnabled:YES");
}

// MARK: - UIScrollEdgeEffect declaration
@interface UIScrollEdgeEffect : NSObject
+ (void)hide;
- (BOOL)ig_isHidden;
- (void)ig_setIsHidden:(BOOL)hidden;
@end

// MARK: - Native button experiment

static SPK_BOOL_MSG orig_swizzleToggle_isEnabled;
static BOOL hook_swizzleToggle_isEnabled(id self, SEL _cmd) {
    return SPKIsLiquidGlassEnabled() ? YES : (orig_swizzleToggle_isEnabled ? orig_swizzleToggle_isEnabled(self, _cmd) : NO);
}

static SPK_BOOL_MSG orig_navigationExperiment_isEnabled;
static BOOL hook_navigationExperiment_isEnabled(id self, SEL _cmd) {
    return SPKIsLiquidGlassEnabled() ? YES : (orig_navigationExperiment_isEnabled ? orig_navigationExperiment_isEnabled(self, _cmd) : NO);
}

static SPK_BOOL_MSG orig_navigationExperiment_isHomeFeedHeaderEnabled;
static BOOL hook_navigationExperiment_isHomeFeedHeaderEnabled(id self, SEL _cmd) {
    return SPKIsLiquidGlassEnabled() ? YES : (orig_navigationExperiment_isHomeFeedHeaderEnabled ? orig_navigationExperiment_isHomeFeedHeaderEnabled(self, _cmd) : NO);
}

// MARK: - Native surface feature symbols

static BOOL (*orig_IGFloatingTabBarEnabled)(void);
static BOOL (*orig_IGTabBarDynamicSizingEnabled)(void);
static BOOL (*orig_IGTabBarEnhancedDynamicSizingEnabled)(void);
static BOOL (*orig_IGTabBarHomecomingWithFloatingTabEnabled)(void);
static BOOL (*orig_IGTabBarViewPointFixEnabled)(void);
static NSInteger (*orig_IGTabBarStyleForLauncherSet)(NSInteger launcherSet);

#define SPK_LIQUID_GLASS_BOOL_FISHHOOK(name)                                         \
    static BOOL hook_##name(void) {                                                  \
        return SPKIsLiquidGlassEnabled() ? YES : (orig_##name ? orig_##name() : NO); \
    }

SPK_LIQUID_GLASS_BOOL_FISHHOOK(IGFloatingTabBarEnabled)
SPK_LIQUID_GLASS_BOOL_FISHHOOK(IGTabBarDynamicSizingEnabled)
SPK_LIQUID_GLASS_BOOL_FISHHOOK(IGTabBarEnhancedDynamicSizingEnabled)
SPK_LIQUID_GLASS_BOOL_FISHHOOK(IGTabBarHomecomingWithFloatingTabEnabled)
SPK_LIQUID_GLASS_BOOL_FISHHOOK(IGTabBarViewPointFixEnabled)

static NSInteger hook_IGTabBarStyleForLauncherSet(NSInteger launcherSet) {
    return SPKIsLiquidGlassEnabled() ? 1 : (orig_IGTabBarStyleForLauncherSet ? orig_IGTabBarStyleForLauncherSet(launcherSet) : launcherSet);
}

// MARK: - Tab bar scroll state

typedef NS_ENUM(NSInteger, SPKLiquidGlassTabBarMode) {
    SPKLiquidGlassTabBarModeDefault = 0,
    SPKLiquidGlassTabBarModeFixed,
    SPKLiquidGlassTabBarModeHide,
};

static SPKLiquidGlassTabBarMode SPKCurrentLiquidGlassTabBarMode(void) {
    NSString *mode = [SPKUtils getStringPref:kSPKPrefInterfaceLiquidGlassTabBarMode];
    if ([mode isEqualToString:@"fixed"])
        return SPKLiquidGlassTabBarModeFixed;
    if ([mode isEqualToString:@"hide"])
        return SPKLiquidGlassTabBarModeHide;
    return SPKLiquidGlassTabBarModeDefault;
}

static const void *kSPKLiquidGlassTabBarHiddenKey = &kSPKLiquidGlassTabBarHiddenKey;

static void SPKApplyLiquidGlassTabBarHiddenState(UIView *bar, BOOL hidden) {
    NSNumber *current = objc_getAssociatedObject(bar, kSPKLiquidGlassTabBarHiddenKey);
    if (current && current.boolValue == hidden)
        return;
    objc_setAssociatedObject(bar, kSPKLiquidGlassTabBarHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat dropY = CGRectGetHeight(bar.bounds) + 40.0;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         bar.transform = hidden ? CGAffineTransformMakeTranslation(0.0, dropY) : CGAffineTransformIdentity;
                         bar.alpha = hidden ? 0.0 : 1.0;
                     }
                     completion:nil];
}

static void (*orig_tabBar_setScaleProgress)(id self, SEL _cmd, double progress);
static void hook_tabBar_setScaleProgress(id self, SEL _cmd, double progress) {
    SPKLiquidGlassTabBarMode mode = SPKIsLiquidGlassEnabled() ? SPKCurrentLiquidGlassTabBarMode() : SPKLiquidGlassTabBarModeDefault;
    if (mode == SPKLiquidGlassTabBarModeFixed) {
        SPKApplyLiquidGlassTabBarHiddenState((UIView *)self, NO);
        progress = 0.0;
    } else if (mode == SPKLiquidGlassTabBarModeHide) {
        SPKApplyLiquidGlassTabBarHiddenState((UIView *)self, progress > 0.05);
        progress = 0.0;
    } else {
        SPKApplyLiquidGlassTabBarHiddenState((UIView *)self, NO);
    }
    if (orig_tabBar_setScaleProgress)
        orig_tabBar_setScaleProgress(self, _cmd, progress);
}

static void (*orig_tabBar_scaleDownWithInteraction)(id self, SEL _cmd, id interaction);
static void hook_tabBar_scaleDownWithInteraction(id self, SEL _cmd, id interaction) {
    SPKLiquidGlassTabBarMode mode = SPKIsLiquidGlassEnabled() ? SPKCurrentLiquidGlassTabBarMode() : SPKLiquidGlassTabBarModeDefault;
    if (mode != SPKLiquidGlassTabBarModeDefault)
        return;
    if (orig_tabBar_scaleDownWithInteraction)
        orig_tabBar_scaleDownWithInteraction(self, _cmd, interaction);
}

// MARK: - Direct inbox separator workaround

static Class SPKDirectInboxNavigationHeaderViewClass(void) {
    Class cls = objc_getClass("IGDirectInboxNavigationHeaderView");
    if (!cls) {
        cls = objc_getClass("IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView");
    }
    return cls;
}

static UIView *SPKDirectInboxHeaderSeparatorView(id headerView) {
    if (![headerView isKindOfClass:UIView.class])
        return nil;

    NSArray<UIView *> *subviews = [(UIView *)headerView subviews];
    if (subviews.count <= 1)
        return nil;

    UIView *candidate = subviews[1];
    if (![candidate isKindOfClass:UIView.class])
        return nil;

    CGFloat height = MAX(candidate.bounds.size.height, candidate.frame.size.height);
    return (subviews.count == 2 || height <= 3.0) ? candidate : nil;
}

static void SPKRemoveDirectInboxHeaderSeparator(id headerView) {
    if (!SPKIsLiquidGlassEnabled())
        return;
    UIView *separator = SPKDirectInboxHeaderSeparatorView(headerView);
    separator.alpha = 0.0;
    separator.hidden = YES;
    [separator removeFromSuperview];
}

static SPK_VOID_MSG orig_directInboxHeader_layoutSubviews;
static void hook_directInboxHeader_layoutSubviews(id self, SEL _cmd) {
    if (orig_directInboxHeader_layoutSubviews)
        orig_directInboxHeader_layoutSubviews(self, _cmd);
    SPKRemoveDirectInboxHeaderSeparator(self);
}

static SPK_VOID_MSG orig_directInboxHeader_didMoveToWindow;
static void hook_directInboxHeader_didMoveToWindow(id self, SEL _cmd) {
    if (orig_directInboxHeader_didMoveToWindow)
        orig_directInboxHeader_didMoveToWindow(self, _cmd);
    SPKRemoveDirectInboxHeaderSeparator(self);
}

static SPK_SET_CGFLOAT_MSG orig_directInboxHeader_setSeparatorAlpha;
static void hook_directInboxHeader_setSeparatorAlpha(id self, SEL _cmd, CGFloat alpha) {
    if (orig_directInboxHeader_setSeparatorAlpha) {
        orig_directInboxHeader_setSeparatorAlpha(self, _cmd, SPKIsLiquidGlassEnabled() ? 0.0 : alpha);
    }
    SPKRemoveDirectInboxHeaderSeparator(self);
}

static void SPKHookInstanceMethodIfPresent(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls && class_getInstanceMethod(cls, selector)) {
        MSHookMessageEx(cls, selector, replacement, original);
    }
}

extern "C" void SPKInstallLiquidGlassHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The tab bar reshape (floating pill) is shape-only and works on any
        // iOS — the tab bar experiment gates just change the bar's layout, not
        // its material. These always install when the pref is on.
        int result = rebind_symbols((struct rebinding[]){
                                        {"IGFloatingTabBarEnabled", (void *)hook_IGFloatingTabBarEnabled, (void **)&orig_IGFloatingTabBarEnabled},
                                        {"IGTabBarDynamicSizingEnabled", (void *)hook_IGTabBarDynamicSizingEnabled, (void **)&orig_IGTabBarDynamicSizingEnabled},
                                        {"IGTabBarEnhancedDynamicSizingEnabled", (void *)hook_IGTabBarEnhancedDynamicSizingEnabled, (void **)&orig_IGTabBarEnhancedDynamicSizingEnabled},
                                        {"IGTabBarHomecomingWithFloatingTabEnabled", (void *)hook_IGTabBarHomecomingWithFloatingTabEnabled, (void **)&orig_IGTabBarHomecomingWithFloatingTabEnabled},
                                        {"IGTabBarViewPointFixEnabled", (void *)hook_IGTabBarViewPointFixEnabled, (void **)&orig_IGTabBarViewPointFixEnabled},
                                        {"IGTabBarStyleForLauncherSet", (void *)hook_IGTabBarStyleForLauncherSet, (void **)&orig_IGTabBarStyleForLauncherSet},
                                    },
                                    6);
        SPKLog(@"LiquidGlass", @"Surface fishhook result=%d", result);

        Class cls = objc_getClass("IGLiquidGlassInteractiveTabBar");
        SPKHookInstanceMethodIfPresent(cls, @selector(setScaleProgress:), (IMP)hook_tabBar_setScaleProgress, (IMP *)&orig_tabBar_setScaleProgress);
        SPKHookInstanceMethodIfPresent(cls, @selector(scaleDownWithInteraction:), (IMP)hook_tabBar_scaleDownWithInteraction, (IMP *)&orig_tabBar_scaleDownWithInteraction);

        // The remaining hooks force IG's Liquid Glass *material* onto the nav
        // chrome — back / Follow buttons, profile tab chips, feed header, DM
        // inbox header. iOS 18 and lower can't render that material, so these
        // would leave those controls as barely-visible translucent blobs. Only
        // install them where the glass material actually exists (iOS 26+); on
        // older systems the pref means "Pill-Shaped Tab Bar", nothing more.
        if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0")) {
            SPKLog(@"LiquidGlass", @"Pre-iOS 26: tab bar pill only, skipping chrome glass hooks");
            return;
        }

        cls = objc_getClass("IGLiquidGlassSwizzle.IGLiquidGlassSwizzleToggle");
        SPKHookInstanceMethodIfPresent(cls, @selector(isEnabled), (IMP)hook_swizzleToggle_isEnabled, (IMP *)&orig_swizzleToggle_isEnabled);

        cls = objc_getClass("IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper");
        SPKHookInstanceMethodIfPresent(cls, @selector(isEnabled), (IMP)hook_navigationExperiment_isEnabled, (IMP *)&orig_navigationExperiment_isEnabled);
        SPKHookInstanceMethodIfPresent(cls, @selector(isHomeFeedHeaderEnabled), (IMP)hook_navigationExperiment_isHomeFeedHeaderEnabled, (IMP *)&orig_navigationExperiment_isHomeFeedHeaderEnabled);

        cls = SPKDirectInboxNavigationHeaderViewClass();
        SPKHookInstanceMethodIfPresent(cls, @selector(layoutSubviews), (IMP)hook_directInboxHeader_layoutSubviews, (IMP *)&orig_directInboxHeader_layoutSubviews);
        SPKHookInstanceMethodIfPresent(cls, @selector(didMoveToWindow), (IMP)hook_directInboxHeader_didMoveToWindow, (IMP *)&orig_directInboxHeader_didMoveToWindow);
        SPKHookInstanceMethodIfPresent(cls, @selector(setSeparatorAlpha:), (IMP)hook_directInboxHeader_setSeparatorAlpha, (IMP *)&orig_directInboxHeader_setSeparatorAlpha);

        SPKApplyLiquidGlassExperimentOverridesIfEnabled();
    });
}

// MARK: - Scroll edge style hooks
//
// interface_scroll_edge_style drives the top edge effect of every scroll view:
// off lets Instagram disable it as usual, default keeps it visible with the system style,
// and soft and hard pin that style. Bottom and side edges always keep the
// system treatment: a style forced onto the edge behind a
// toolbar or tab bar renders a flat band on iOS 27 instead of the blur.
//
// Only scroll views whose content runs under a top bar get the effect. Every
// other scroll view keeps its top edge hidden: full-screen containers, story
// viewers, carousels and small inner lists have nothing to separate from, and
// on the iOS 27 SDK such a container draws its edge over all of its content,
// which blurs the navigation chrome and story header inside it.
//
// The hooks stay installed on iOS 26+ and read the mode at call time, so every
// mode except Off applies live. Instagram hides edge effects once while it sets
// screens up, so returning to Off needs a restart to bring those hides back.

typedef NS_ENUM(NSInteger, SPKScrollEdgeMode) {
    SPKScrollEdgeModeOff = 0,
    SPKScrollEdgeModeDefault,
    SPKScrollEdgeModeSoft,
    SPKScrollEdgeModeHard,
};

static SPKScrollEdgeMode sSPKScrollEdgeMode = SPKScrollEdgeModeOff;
// Set while a live sweep runs; collects every scroll view whose edge effect
// changed.
static NSHashTable<UIScrollView *> *sSPKScrollEdgeChangedScrollViews;

// Stamped on the effect fetched through -topEdgeEffect. The effect object has
// no public edge identity, and the setter hooks must leave other edges alone.
// Holds whether the owning scroll view is eligible for a forced style.
static char kSPKScrollEdgeTopKey;
// Stamped when Sparkle hid the effect, so only those hides are ever undone.
static char kSPKScrollEdgeSparkleHiddenKey;
// Stamped when Sparkle replaced the style, so default can restore automatic.
static char kSPKScrollEdgeForcedStyleKey;

static SPKScrollEdgeMode SPKScrollEdgeModeForPreference(NSString *preference) {
    if ([preference isEqualToString:@"off"])
        return SPKScrollEdgeModeOff;
    if ([preference isEqualToString:@"soft"])
        return SPKScrollEdgeModeSoft;
    if ([preference isEqualToString:@"hard"])
        return SPKScrollEdgeModeHard;
    return SPKScrollEdgeModeDefault;
}

static id SPKScrollEdgeStyleObject(SEL selector) {
    Class styleClass = objc_getClass("UIScrollEdgeEffectStyle");
    if (![styleClass respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(styleClass, selector);
}

// The style Sparkle pins on top edges, or nil to follow the system.
static id SPKScrollEdgeForcedStyle(void) {
    switch (sSPKScrollEdgeMode) {
    case SPKScrollEdgeModeSoft:
        return SPKScrollEdgeStyleObject(@selector(softStyle));
    case SPKScrollEdgeModeHard:
        return SPKScrollEdgeStyleObject(@selector(hardStyle));
    default:
        return nil;
    }
}

// A top bar or header shows up as a real top inset. Containers report none,
// and inner lists only a few points of padding.
static BOOL SPKScrollEdgeIsEligible(UIScrollView *scrollView) {
    return scrollView.adjustedContentInset.top >= 20.0;
}

static id SPKTopEdgeEffect(UIScrollView *scrollView) {
    if (![scrollView respondsToSelector:@selector(topEdgeEffect)])
        return nil;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, @selector(topEdgeEffect));
    if (effect) {
        NSNumber *eligible = @(SPKScrollEdgeIsEligible(scrollView));
        if (![objc_getAssociatedObject(effect, &kSPKScrollEdgeTopKey) isEqual:eligible])
            objc_setAssociatedObject(effect, &kSPKScrollEdgeTopKey, eligible, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return effect;
}

static BOOL SPKTopEdgeEffectIsEligible(id effect) {
    return [objc_getAssociatedObject(effect, &kSPKScrollEdgeTopKey) boolValue];
}

// Hides the top edge of ineligible scroll views, and in Hard mode while the
// content rests at the top: an explicitly set hard style stays visible once
// shown, unlike the system-resolved one, which fades out at rest.
static BOOL SPKUpdateTopEdgeVisibility(UIScrollView *scrollView, id effect) {
    if (!effect || ![effect respondsToSelector:@selector(setHidden:)] || ![effect respondsToSelector:@selector(isHidden)])
        return NO;
    BOOL wantsHidden = NO;
    if (sSPKScrollEdgeMode != SPKScrollEdgeModeOff && !SPKTopEdgeEffectIsEligible(effect)) {
        wantsHidden = YES;
    } else if (sSPKScrollEdgeMode == SPKScrollEdgeModeHard && scrollView.window) {
        // Half a point of slack absorbs fractional insets and rubber-band settling.
        wantsHidden = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5;
    }
    BOOL isHidden = ((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden));
    if (wantsHidden) {
        if (!isHidden) {
            objc_setAssociatedObject(effect, &kSPKScrollEdgeSparkleHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setHidden:), YES);
            return YES;
        }
    } else if (objc_getAssociatedObject(effect, &kSPKScrollEdgeSparkleHiddenKey)) {
        objc_setAssociatedObject(effect, &kSPKScrollEdgeSparkleHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isHidden) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setHidden:), NO);
            return YES;
        }
    }
    return NO;
}

// Returns whether the edge effect's style or visibility actually changed, so
// live sweeps can leave untouched scroll views alone.
static BOOL SPKApplyScrollEdgeMode(UIScrollView *scrollView) {
    id effect = SPKTopEdgeEffect(scrollView);
    if (!effect || ![effect respondsToSelector:@selector(setStyle:)] || ![effect respondsToSelector:@selector(style)])
        return NO;

    BOOL changed = NO;
    id forced = SPKTopEdgeEffectIsEligible(effect) ? SPKScrollEdgeForcedStyle() : nil;
    id current = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(style));
    if (forced) {
        objc_setAssociatedObject(effect, &kSPKScrollEdgeForcedStyleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (current != forced) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setStyle:), forced);
            changed = YES;
        }
    } else if (objc_getAssociatedObject(effect, &kSPKScrollEdgeForcedStyleKey)) {
        objc_setAssociatedObject(effect, &kSPKScrollEdgeForcedStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id automatic = SPKScrollEdgeStyleObject(@selector(automaticStyle));
        if (automatic && current != automatic) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setStyle:), automatic);
            changed = YES;
        }
    }

    if (SPKUpdateTopEdgeVisibility(scrollView, effect))
        changed = YES;
    if (changed)
        [sSPKScrollEdgeChangedScrollViews addObject:scrollView];
    return changed;
}

static void SPKForEachScrollView(UIView *root, void (^block)(UIScrollView *scrollView)) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:UIScrollView.class])
            block((UIScrollView *)view);
        [stack addObjectsFromArray:view.subviews];
    }
}

// UIKit does not rebuild an edge effect's layers after a live style or
// visibility change until the scroll view and the effect view lay out again.
static void SPKNudgeScrollEdgeLayout(UIScrollView *scrollView) {
    [scrollView setNeedsLayout];
    for (UIView *container in scrollView.subviews) {
        for (UIView *subview in container.subviews) {
            if ([NSStringFromClass(subview.class) containsString:@"ScrollEdgeEffect"]) {
                [container setNeedsLayout];
                [subview setNeedsLayout];
            }
        }
    }
}

// Rebuilding an edge effect can change a scroll view's top inset, which moves
// an open list. Keep each list's distance from its top edge rather than its raw
// offset: the raw offset fights UIKit whenever the inset really changed.
static void SPKKeepScrollDistances(NSMapTable<UIScrollView *, NSNumber *> *distances) {
    for (UIScrollView *scrollView in distances) {
        if (scrollView.isTracking || scrollView.isDecelerating)
            continue;
        CGFloat distance = [[distances objectForKey:scrollView] doubleValue];
        CGPoint offset = scrollView.contentOffset;
        offset.y = distance - scrollView.adjustedContentInset.top;
        if (fabs(offset.y - scrollView.contentOffset.y) > 0.5)
            [scrollView setContentOffset:offset animated:NO];
    }
}

static void SPKReapplyScrollEdgeModeEverywhere(void) {
    NSString *preference = [SPKUtils getStringPref:kSPKPrefInterfaceScrollEdgeStyle];
    sSPKScrollEdgeMode = SPKScrollEdgeModeForPreference(preference);
    sSPKScrollEdgeChangedScrollViews = [NSHashTable weakObjectsHashTable];
    NSMapTable<UIScrollView *, NSNumber *> *distances = [NSMapTable weakToStrongObjectsMapTable];

    // Everything, including the layout that rebuilds the effects and the
    // offset correction, commits in one transaction, so no frame ever shows
    // the list moved.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            SPKForEachScrollView(window, ^(UIScrollView *scrollView) {
                [distances setObject:@(scrollView.contentOffset.y + scrollView.adjustedContentInset.top) forKey:scrollView];
            });
        }
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            SPKForEachScrollView(window, ^(UIScrollView *scrollView) {
                SPKApplyScrollEdgeMode(scrollView);
            });
        }
        NSHashTable<UIScrollView *> *changed = sSPKScrollEdgeChangedScrollViews;
        sSPKScrollEdgeChangedScrollViews = nil;
        for (UIScrollView *scrollView in changed) {
            SPKNudgeScrollEdgeLayout(scrollView);
            [scrollView layoutIfNeeded];
        }
        // Only the lists that were touched get corrected.
        for (UIScrollView *scrollView in distances.keyEnumerator.allObjects) {
            if (![changed containsObject:scrollView])
                [distances removeObjectForKey:scrollView];
        }
        SPKKeepScrollDistances(distances);
    }];
    [CATransaction commit];

    // Insets that settle on the following pass get the same correction.
    if (distances.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                SPKKeepScrollDistances(distances);
            }];
        });
    }
    SPKLog(@"LiquidGlass", @"Scroll edge style applied live, style=%@, rebuilt=%lu", preference, (unsigned long)distances.count);
}

%group SPKScrollEdgeHooks
%hook UIScrollEdgeEffect
+ (void)hide {
    // Instagram hides edge effects globally; every mode but Off keeps them.
    if (sSPKScrollEdgeMode == SPKScrollEdgeModeOff)
        %orig;
}

- (BOOL)ig_isHidden {
    return sSPKScrollEdgeMode == SPKScrollEdgeModeOff ? %orig : NO;
}

- (void)ig_setIsHidden:(BOOL)hidden {
    %orig(sSPKScrollEdgeMode == SPKScrollEdgeModeOff ? hidden : NO);
}

// UIKit writes the automatic style again while navigation chrome changes, and
// it resolves to hard on iOS 27, so pin top edges on every write.
- (void)setStyle:(id)style {
    id forced = SPKTopEdgeEffectIsEligible(self) ? SPKScrollEdgeForcedStyle() : nil;
    %orig(forced ?: style);
}
%end

// Edge effects are created lazily with the automatic style, so apply the mode
// as each scroll view lands in a window. UIScrollView has no public
// didMoveToWindow of its own, and the table and collection view overrides
// bypass one added here, so hook the private window move every subclass uses.
%hook UIScrollView
- (void)_didMoveFromWindow:(UIWindow *)fromWindow toWindow:(UIWindow *)toWindow {
    %orig;
    if (toWindow && sSPKScrollEdgeMode != SPKScrollEdgeModeOff)
        SPKApplyScrollEdgeMode(self);
}

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    if (sSPKScrollEdgeMode == SPKScrollEdgeModeHard)
        SPKUpdateTopEdgeVisibility(self, SPKTopEdgeEffect(self));
}

- (void)setContentSize:(CGSize)contentSize {
    %orig;
    if (sSPKScrollEdgeMode == SPKScrollEdgeModeHard)
        SPKUpdateTopEdgeVisibility(self, SPKTopEdgeEffect(self));
}

- (void)adjustedContentInsetDidChange {
    %orig;
    // Eligibility follows the top inset, which settles after the first layout.
    if (sSPKScrollEdgeMode != SPKScrollEdgeModeOff && self.window)
        SPKApplyScrollEdgeMode(self);
}
%end

%end

extern "C" void SPKInstallProgressiveBlurHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!objc_getClass("UIScrollEdgeEffect")) {
            SPKLog(@"LiquidGlass", @"UIScrollEdgeEffect class not found at runtime, skipping hooks.");
            return;
        }
        NSString *preference = [SPKUtils getStringPref:kSPKPrefInterfaceScrollEdgeStyle];
        sSPKScrollEdgeMode = SPKScrollEdgeModeForPreference(preference);
        %init(SPKScrollEdgeHooks);
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKScrollEdgeStyleDidChangeNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *notification) {
                                                          SPKReapplyScrollEdgeModeEverywhere();
                                                      }];
        SPKLog(@"LiquidGlass", @"Scroll edge hooks installed, style=%@", preference);
    });
}

#pragma clang diagnostic pop
