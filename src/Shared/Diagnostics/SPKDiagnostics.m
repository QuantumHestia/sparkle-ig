#import "SPKDiagnostics.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#import "../../App/SPKCore.h"
#import "../../App/SPKFlexLoader.h"
#import "../../App/SPKStabilityGuard.h"
#import "../../Tweak.h"
#import "../../Utils.h"

NSString *const kSPKPrefToolsDebugButton = @"tools_debug_button";

// MARK: - Helpers

static NSString *SPKDiagnosticsRect(CGRect r) {
    return [NSString stringWithFormat:@"{%.1f,%.1f %.1fx%.1f}", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *SPKDiagnosticsRawText(UIView *view) {
    if ([view isKindOfClass:UILabel.class])
        return ((UILabel *)view).text;
    if ([view isKindOfClass:UITextView.class])
        return ((UITextView *)view).text;
    if ([view isKindOfClass:UITextField.class])
        return ((UITextField *)view).text;
    return nil;
}

static NSString *SPKDiagnosticsViewText(UIView *view, BOOL includeText) {
    NSString *text = SPKDiagnosticsRawText(view);
    if (!text.length)
        return @"";
    if (!includeText)
        return [NSString stringWithFormat:@" text=<%lu chars>", (unsigned long)text.length];
    NSString *flat = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    if (flat.length > 60)
        flat = [[flat substringToIndex:60] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@" text=\"%@\"", flat];
}

static NSString *SPKDiagnosticsAncestors(UIView *view, NSUInteger levels) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIView *v = view.superview;
    while (v && chain.count < levels) {
        [chain addObject:[NSString stringWithFormat:@"%@[%lu/%lu]", NSStringFromClass(v.class),
                                                    (unsigned long)[v.superview.subviews indexOfObjectIdenticalTo:v],
                                                    (unsigned long)v.superview.subviews.count]];
        v = v.superview;
    }
    return [chain componentsJoinedByString:@" < "];
}

static NSString *SPKDiagnosticsLayerFilters(CALayer *layer) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    void (^collect)(CALayer *, NSString *) = ^(CALayer *source, NSString *prefix) {
        for (id filter in source.filters ?: @[]) {
            id type = [filter respondsToSelector:@selector(type)] ? [filter valueForKey:@"type"] : nil;
            [names addObject:[NSString stringWithFormat:@"%@%@", prefix, type ?: NSStringFromClass([filter class])]];
        }
    };
    collect(layer, @"");
    for (CALayer *sub in layer.sublayers)
        collect(sub, [NSString stringWithFormat:@"sub:%@/", NSStringFromClass(sub.class)]);
    return names.count ? [names componentsJoinedByString:@","] : @"-";
}

static NSArray<UIWindow *> *SPKDiagnosticsInspectableWindows(void) {
    Class flexWindowClass = SPKFlexWindowClass();
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || SPKDebugButtonOwnsWindow(window) || (flexWindowClass && [window isKindOfClass:flexWindowClass]))
                continue;
            [windows addObject:window];
        }
    }
    [windows sortWithOptions:NSSortStable
             usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                 if (a.windowLevel == b.windowLevel)
                     return NSOrderedSame;
                 return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
             }];
    return windows;
}

static BOOL SPKDiagnosticsViewIsVisible(UIView *view) {
    return !view.hidden && view.alpha >= 0.01;
}

// Depth-first in subview order, which is the order views are drawn in. Hidden
// subtrees are skipped: nothing in them reaches the screen.
static void SPKDiagnosticsWalk(UIView *root, void (^block)(UIView *view, NSUInteger depth)) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[ root, @0 ]];
    while (stack.count) {
        NSArray *entry = stack.lastObject;
        [stack removeLastObject];
        UIView *view = entry[0];
        if (!SPKDiagnosticsViewIsVisible(view))
            continue;
        NSUInteger depth = [entry[1] unsignedIntegerValue];
        block(view, depth);
        for (UIView *sub in view.subviews.reverseObjectEnumerator)
            [stack addObject:@[ sub, @(depth + 1) ]];
    }
}

static NSArray<UIView *> *SPKDiagnosticsVisibleViewsInPaintOrder(void) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        SPKDiagnosticsWalk(window, ^(UIView *view, __unused NSUInteger depth) {
            [views addObject:view];
        });
    }
    return views;
}

static NSString *SPKDiagnosticsDescribeView(UIView *view, BOOL includeText) {
    CGRect frame = [view convertRect:view.bounds toView:nil];
    NSMutableString *flags = [NSMutableString string];
    if (view.alpha < 1.0)
        [flags appendFormat:@" alpha=%.2f", view.alpha];
    if (!view.userInteractionEnabled)
        [flags appendString:@" noTouch"];
    if (view.clipsToBounds)
        [flags appendString:@" clips"];
    if (view.layer.mask || view.maskView)
        [flags appendString:@" masked"];
    return [NSString stringWithFormat:@"%@ %p %@%@%@", NSStringFromClass(view.class), view, SPKDiagnosticsRect(frame), flags,
                                      SPKDiagnosticsViewText(view, includeText)];
}

static NSString *SPKDiagnosticsInfoString(NSString *key) {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:key];
    return value ? [NSString stringWithFormat:@"%@", value] : @"?";
}

static NSString *SPKDiagnosticsDeviceModel(void) {
    char model[64] = {0};
    size_t size = sizeof(model);
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) != 0)
        return @"?";
    return [NSString stringWithUTF8String:model];
}

static NSString *SPKDiagnosticsTweakPath(void) {
    Dl_info info;
    if (dladdr((const void *)&SPKDiagnosticsTweakPath, &info) && info.dli_fname)
        return [NSString stringWithUTF8String:info.dli_fname];
    return @"?";
}

static NSString *SPKDiagnosticsHeader(NSString *title) {
    return [NSString stringWithFormat:@"# %@\nSparkle %@ | Instagram %@ (%@) | SDK %@ | iOS %@ | %@\n",
                                      title, SPKVersionString, SPKDiagnosticsInfoString(@"CFBundleShortVersionString"),
                                      SPKDiagnosticsInfoString(@"CFBundleVersion"), SPKDiagnosticsInfoString(@"DTSDKName"),
                                      UIDevice.currentDevice.systemVersion, SPKDiagnosticsDeviceModel()];
}

// MARK: - Screen report

static void SPKDiagnosticsAppendControllerTree(NSMutableString *out, UIViewController *controller, NSUInteger depth, NSString *role) {
    if (!controller || depth > 24)
        return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@%@ %p", indent, role.length ? [role stringByAppendingString:@" "] : @"",
                                                              NSStringFromClass(controller.class), controller];
    if (controller.isViewLoaded && controller.view.window)
        [line appendString:@" onscreen"];
    [out appendFormat:@"%@\n", line];

    UIViewController *selected = nil;
    if ([controller isKindOfClass:UITabBarController.class])
        selected = ((UITabBarController *)controller).selectedViewController;
    UIViewController *top = [controller isKindOfClass:UINavigationController.class] ? ((UINavigationController *)controller).topViewController : nil;
    for (UIViewController *child in controller.childViewControllers) {
        NSString *childRole = child == selected ? @"[selected]" : (child == top ? @"[top]" : @"");
        SPKDiagnosticsAppendControllerTree(out, child, depth + 1, childRole);
    }
    // Only the presentation made by this controller, not one it inherits.
    UIViewController *presented = controller.presentedViewController;
    if (presented && presented.presentingViewController == controller)
        SPKDiagnosticsAppendControllerTree(out, presented, depth + 1, @"[presented]");
}

// Only switches, numbers and short option tokens are shown: other values can
// hold usernames, allow-lists or coordinates.
static NSString *SPKDiagnosticsPreferenceValue(NSString *key, id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        NSString *lowerKey = key.lowercaseString;
        for (NSString *fragment in @[ @"lat", @"lon", @"lng", @"coord", @"location" ]) {
            if ([lowerKey containsString:fragment])
                return @"<number>";
        }
        return [value description];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        NSCharacterSet *token = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_-."];
        if (string.length <= 24 && [string rangeOfCharacterFromSet:token.invertedSet].location == NSNotFound)
            return string;
        return [NSString stringWithFormat:@"<%lu chars>", (unsigned long)string.length];
    }
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"<%lu items>", (unsigned long)((NSArray *)value).count];
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"<%lu entries>", (unsigned long)((NSDictionary *)value).count];
    return [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
}

NSString *SPKDiagnosticsScreenReport(__unused BOOL includeText) {
    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"Screen report")];
    UITraitCollection *traits = UIScreen.mainScreen.traitCollection;
    [out appendFormat:@"tweak=%@\nstyle=%@ language=%@ perAccount=%d safeMode=%d disableAll=%d\n", SPKDiagnosticsTweakPath(),
                      traits.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light",
                      NSLocale.preferredLanguages.firstObject ?: @"?", SPKPerAccountModeActive(), SPKStabilityGuardIsSafeStartupMode(),
                      [SPKUtils getBoolPref:@"tools_disable_all"]];

    [out appendString:@"\n## View controllers\n"];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        [out appendFormat:@"window %@ %p level=%.0f key=%d %@\n", NSStringFromClass(window.class), window, window.windowLevel, window.isKeyWindow,
                          SPKDiagnosticsRect(window.frame)];
        SPKDiagnosticsAppendControllerTree(out, window.rootViewController, 1, @"[root]");
    }

    [out appendString:@"\n## Preferences changed from default\n"];
    NSDictionary<NSString *, id> *defaults = SPKCoreRegisteredDefaults();
    for (NSString *key in [defaults.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = SPKPreferenceObjectForKey(key);
        if (!value || [value isEqual:defaults[key]])
            continue;
        [out appendFormat:@"%@ = %@\n", key, SPKDiagnosticsPreferenceValue(key, value)];
    }
    return out;
}

// MARK: - Hierarchy report

NSString *SPKDiagnosticsHierarchyReport(BOOL includeText) {
    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"View hierarchy")];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        [out appendString:@"\n"];
        SPKDiagnosticsWalk(window, ^(UIView *view, NSUInteger depth) {
            NSString *indent = [@"" stringByPaddingToLength:MIN(depth, (NSUInteger)60) withString:@" " startingAtIndex:0];
            [out appendFormat:@"%@%@\n", indent, SPKDiagnosticsDescribeView(view, includeText)];
        });
    }
    return out;
}

// MARK: - Inspect report

// Whether a view puts anything on screen itself. Layout and touch containers
// (UIKit's passthrough, wrapper and transition views, most IG hosting views)
// draw nothing and sit above the content they hold, so picking the topmost
// view at a point would almost always land on one of them.
static BOOL SPKDiagnosticsViewDrawsContent(UIView *view) {
    if (view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.01)
        return YES;
    if ([view isKindOfClass:UILabel.class])
        return ((UILabel *)view).text.length > 0 || ((UILabel *)view).attributedText.length > 0;
    if ([view isKindOfClass:UIImageView.class])
        return ((UIImageView *)view).image != nil;
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class] || [view isKindOfClass:UIVisualEffectView.class])
        return YES;
    NSString *name = NSStringFromClass(view.class);
    for (NSString *fragment in @[ @"Backdrop", @"Blur", @"EdgeEffect", @"Glass", @"Video", @"Player" ]) {
        if ([name containsString:fragment])
            return YES;
    }
    CALayer *layer = view.layer;
    if (layer.contents || layer.filters.count || (layer.borderWidth > 0 && layer.borderColor && CGColorGetAlpha(layer.borderColor) > 0.01))
        return YES;
    // Shape, gradient, text, Metal and player layers draw without contents.
    return layer.class != CALayer.class;
}

// A point outside an ancestor that clips is not visible in the view, even
// though it lies inside the view's own bounds.
static BOOL SPKDiagnosticsViewShowsPoint(UIView *view, CGPoint point, id<UICoordinateSpace> screen) {
    for (UIView *v = view; v; v = v.superview) {
        if (v != view && !v.clipsToBounds)
            continue;
        if (!CGRectContainsPoint(v.bounds, [v convertPoint:point fromCoordinateSpace:screen]))
            return NO;
    }
    return YES;
}

NSString *SPKDiagnosticsInspectReport(CGPoint point, BOOL includeText, UIView **selectedView) {
    NSArray<UIView *> *views = SPKDiagnosticsVisibleViewsInPaintOrder();
    NSMutableArray<UIView *> *underPoint = [NSMutableArray array];
    for (UIView *view in views.reverseObjectEnumerator) {
        id<UICoordinateSpace> screen = view.window.windowScene.coordinateSpace ?: view.window.screen.coordinateSpace;
        if (SPKDiagnosticsViewShowsPoint(view, point, screen))
            [underPoint addObject:view];
    }

    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"Inspect element")];
    [out appendFormat:@"point=%.1f,%.1f\n", point.x, point.y];

    // What a touch at this point is delivered to.
    for (UIWindow *window in SPKDiagnosticsInspectableWindows().reverseObjectEnumerator) {
        CGPoint local = [window convertPoint:point fromCoordinateSpace:window.windowScene.coordinateSpace];
        UIView *hit = [window hitTest:local withEvent:nil];
        if (hit) {
            [out appendFormat:@"touch target=%@\n", SPKDiagnosticsDescribeView(hit, includeText)];
            break;
        }
    }

    // The topmost view that draws something, falling back to the topmost view
    // when everything under the point is a container.
    UIView *selected = underPoint.firstObject;
    for (UIView *view in underPoint) {
        if (SPKDiagnosticsViewDrawsContent(view)) {
            selected = view;
            break;
        }
    }
    if (selectedView)
        *selectedView = selected;
    if (!selected) {
        [out appendString:@"\nNothing visible under this point.\n"];
        return out;
    }

    [out appendFormat:@"\n## Selected\n%@\n", SPKDiagnosticsDescribeView(selected, includeText)];
    UIViewController *owner = [SPKUtils nearestViewControllerForView:selected];
    [out appendFormat:@"controller=%@ %p\nfilters=%@\nbackground=%@\ngestures=", owner ? NSStringFromClass(owner.class) : @"-", owner,
                      SPKDiagnosticsLayerFilters(selected.layer), selected.backgroundColor ?: @"-"];
    NSMutableArray<NSString *> *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *recognizer in selected.gestureRecognizers)
        [gestures addObject:NSStringFromClass(recognizer.class)];
    [out appendFormat:@"%@\nancestors=%@\n", gestures.count ? [gestures componentsJoinedByString:@","] : @"-", SPKDiagnosticsAncestors(selected, 40)];

    [out appendString:@"\n## Under this point, topmost first\n"];
    for (NSUInteger i = 0; i < underPoint.count && i < 40; i++) {
        UIView *view = underPoint[i];
        NSString *tag = view == selected ? @"> " : (SPKDiagnosticsViewDrawsContent(view) ? @"  " : @"  (container) ");
        [out appendFormat:@"%@%@\n", tag, SPKDiagnosticsDescribeView(view, includeText)];
    }

    // Everything drawn over the selected view: overlays, blurs and edge effects.
    [out appendString:@"\n## Drawn above the selected view\n"];
    CGRect selectedFrame = [selected convertRect:selected.bounds toView:nil];
    NSUInteger listed = 0;
    NSUInteger start = [views indexOfObjectIdenticalTo:selected];
    for (NSUInteger i = start == NSNotFound ? views.count : start + 1; i < views.count && listed < 40; i++) {
        UIView *view = views[i];
        if ([view isDescendantOfView:selected])
            continue;
        CGRect frame = [view convertRect:view.bounds toView:nil];
        if (view.window != selected.window || !CGRectIntersectsRect(frame, selectedFrame) || frame.size.width < 1 || frame.size.height < 1)
            continue;
        [out appendFormat:@"%@ filters=%@\n", SPKDiagnosticsDescribeView(view, includeText), SPKDiagnosticsLayerFilters(view.layer)];
        listed++;
    }
    if (listed == 0)
        [out appendString:@"-\n"];
    return out;
}
