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
// interface_scroll_edge_style: off leaves Instagram alone, default keeps the
// edge effects visible with the system style, soft and hard pin that style.

// The forced style, resolved once at install; nil means follow the system.
static id sSPKForcedScrollEdgeStyle;
// An explicitly set hard style stays visible once shown, unlike a hard style
// UIKit resolves on its own, which fades out when the content returns to the
// edge. Hard mode reproduces that by hiding each edge while nothing is under it.
static BOOL sSPKScrollEdgeHidesAtRest;

static id SPKScrollEdgeStyleForPreference(NSString *preference) {
    SEL selector = NULL;
    if ([preference isEqualToString:@"soft"])
        selector = @selector(softStyle);
    else if ([preference isEqualToString:@"hard"])
        selector = @selector(hardStyle);
    Class styleClass = objc_getClass("UIScrollEdgeEffectStyle");
    if (!selector || ![styleClass respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(styleClass, selector);
}

static void SPKApplyForcedScrollEdgeStyle(UIScrollView *scrollView) {
    id forced = sSPKForcedScrollEdgeStyle;
    if (!forced)
        return;
    static SEL selectors[4];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selectors[0] = @selector(topEdgeEffect);
        selectors[1] = @selector(bottomEdgeEffect);
        selectors[2] = @selector(leftEdgeEffect);
        selectors[3] = @selector(rightEdgeEffect);
    });
    for (int i = 0; i < 4; i++) {
        if (![scrollView respondsToSelector:selectors[i]])
            continue;
        id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, selectors[i]);
        if (![effect respondsToSelector:@selector(style)] || ![effect respondsToSelector:@selector(setStyle:)])
            continue;
        if (((id (*)(id, SEL))objc_msgSend)(effect, @selector(style)) != forced)
            ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setStyle:), forced);
    }
}

static void SPKSetScrollEdgeEffectHidden(id effect, BOOL hidden) {
    if (![effect respondsToSelector:@selector(isHidden)] || ![effect respondsToSelector:@selector(setHidden:)])
        return;
    if (((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden)) != hidden)
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setHidden:), hidden);
}

static void SPKUpdateScrollEdgeRestVisibility(UIScrollView *scrollView) {
    if (!sSPKScrollEdgeHidesAtRest || !scrollView.window || ![scrollView respondsToSelector:@selector(topEdgeEffect)])
        return;
    UIEdgeInsets insets = scrollView.adjustedContentInset;
    CGFloat offsetY = scrollView.contentOffset.y;
    // Half a point of slack absorbs fractional insets and rubber-band settling.
    BOOL atTop = offsetY <= -insets.top + 0.5;
    BOOL atBottom = offsetY + CGRectGetHeight(scrollView.bounds) >= scrollView.contentSize.height + insets.bottom - 0.5;
    SPKSetScrollEdgeEffectHidden(((id (*)(id, SEL))objc_msgSend)(scrollView, @selector(topEdgeEffect)), atTop);
    SPKSetScrollEdgeEffectHidden(((id (*)(id, SEL))objc_msgSend)(scrollView, @selector(bottomEdgeEffect)), atBottom);
}

%group SPKScrollEdgeVisibilityHooks
%hook UIScrollEdgeEffect
+ (void)hide {
    // No-op to prevent globally hiding scroll-edge effects
}

- (BOOL)ig_isHidden {
    return NO; // Always show the scroll edge effect
}

- (void)ig_setIsHidden:(BOOL)hidden {
    %orig(NO); // Intercept and prevent individual hiders
}
%end
%end

%group SPKScrollEdgeStyleHooks
%hook UIScrollEdgeEffect
// The automatic style resolves differently per iOS release (soft on iOS 26,
// hard on iOS 27), so pin every explicit style write to the chosen one.
- (void)setStyle:(id)style {
    %orig(sSPKForcedScrollEdgeStyle ?: style);
}
%end

// Edge effects are created lazily with the automatic style and UIKit reads
// the stored value directly, so apply the style once per scroll view as it
// lands in a window. UIScrollView has no public didMoveToWindow of its own, and
// the table and collection view overrides bypass one added here, so hook the
// private window move every scroll view subclass funnels through.
%hook UIScrollView
- (void)_didMoveFromWindow:(UIWindow *)fromWindow toWindow:(UIWindow *)toWindow {
    %orig;
    if (toWindow) {
        SPKApplyForcedScrollEdgeStyle(self);
        SPKUpdateScrollEdgeRestVisibility(self);
    }
}

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    SPKUpdateScrollEdgeRestVisibility(self);
}

- (void)setContentSize:(CGSize)contentSize {
    %orig;
    SPKUpdateScrollEdgeRestVisibility(self);
}

- (void)adjustedContentInsetDidChange {
    %orig;
    SPKUpdateScrollEdgeRestVisibility(self);
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
        if ([preference isEqualToString:@"off"])
            return;
        %init(SPKScrollEdgeVisibilityHooks);
        sSPKForcedScrollEdgeStyle = SPKScrollEdgeStyleForPreference(preference);
        sSPKScrollEdgeHidesAtRest = [preference isEqualToString:@"hard"] && sSPKForcedScrollEdgeStyle;
        if (sSPKForcedScrollEdgeStyle)
            %init(SPKScrollEdgeStyleHooks);
        SPKLog(@"LiquidGlass", @"Scroll edge hooks installed, style=%@", preference);
    });
}

#pragma clang diagnostic pop
