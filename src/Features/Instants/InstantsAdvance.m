#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "InstantsAdvance.h"
#import "InstantsModeViews.h"

// MARK: - Replayed Press

/// A recognizer that only exists to be handed to the tap controller. It is never added to a
/// view, so UIKit never drives it; the controller just reads the phase and point set here.
@interface SPKInstantsReplayedPress : UILongPressGestureRecognizer
@property (nonatomic, assign) UIGestureRecognizerState spk_state;
@property (nonatomic, weak) UIView *spk_referenceView;
@property (nonatomic, assign) CGPoint spk_point;
@end

@implementation SPKInstantsReplayedPress

- (UIGestureRecognizerState)state {
    return self.spk_state;
}

- (CGPoint)locationInView:(UIView *)view {
    UIView *reference = self.spk_referenceView;
    if (!reference)
        return self.spk_point;
    return [reference convertPoint:self.spk_point toView:view];
}

- (CGPoint)locationOfTouch:(NSUInteger)touchIndex inView:(UIView *)view {
    return [self locationInView:view];
}

- (NSUInteger)numberOfTouches {
    return 1;
}

@end

// MARK: - Lookup

static const char *const kSPKInstantsAnimatingStackClass =
    "_TtC39IGQuickSnapImmersiveViewerSnapStackView48IGQuickSnapImmersiveViewerAnimatingSnapStackView";

static SEL SPKInstantsPressSelector(void) {
    return @selector(didPressWithGestureRecognizer:);
}

static UIView *SPKInstantsFindStackViewIn(UIView *root, Class stackClass) {
    if ([root isKindOfClass:stackClass] && SPKInstantsModeViewIsVisible(root))
        return root;
    for (UIView *sub in root.subviews) {
        UIView *found = SPKInstantsFindStackViewIn(sub, stackClass);
        if (found)
            return found;
    }
    return nil;
}

static UIView *SPKInstantsFindStackView(UIView *hint) {
    Class stackClass = objc_getClass(kSPKInstantsAnimatingStackClass);
    if (!stackClass)
        return nil;
    UIWindow *hintWindow = hint.window;
    if (hintWindow) {
        UIView *found = SPKInstantsFindStackViewIn(hintWindow, stackClass);
        if (found)
            return found;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window == hintWindow)
                continue;
            UIView *found = SPKInstantsFindStackViewIn(window, stackClass);
            if (found)
                return found;
        }
    }
    return nil;
}

/// The target of a recognizer whose action is the press selector. The target/action pairs are
/// not public, so this reads `_targets` (an array of objects with `_target` and `_action`).
/// It only runs when the stored property read below comes back empty.
static id SPKInstantsPressTargetFromRecognizers(UIView *view) {
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        Ivar targetsIvar = class_getInstanceVariable(object_getClass(recognizer), "_targets");
        if (!targetsIvar)
            continue;
        id targets = object_getIvar(recognizer, targetsIvar);
        if (![targets isKindOfClass:NSArray.class])
            continue;
        for (id pair in (NSArray *)targets) {
            Ivar actionIvar = class_getInstanceVariable(object_getClass(pair), "_action");
            Ivar targetIvar = class_getInstanceVariable(object_getClass(pair), "_target");
            if (!actionIvar || !targetIvar)
                continue;
            SEL action = *(SEL *)((uint8_t *)(__bridge void *)pair + ivar_getOffset(actionIvar));
            if (action != SPKInstantsPressSelector())
                continue;
            id target = object_getIvar(pair, targetIvar);
            if ([target respondsToSelector:SPKInstantsPressSelector()])
                return target;
        }
    }
    return nil;
}

static id SPKInstantsTapController(UIView *stackView) {
    id controller = [SPKUtils getIvarForObj:stackView name:"tapController"];
    if ([controller respondsToSelector:SPKInstantsPressSelector()])
        return controller;
    return SPKInstantsPressTargetFromRecognizers(stackView);
}

// MARK: - Advance

static void SPKInstantsSendPress(id controller, SPKInstantsReplayedPress *press, UIGestureRecognizerState state) {
    press.spk_state = state;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, SPKInstantsPressSelector(), press);
    } @catch (__unused NSException *e) {
    }
}

BOOL SPKInstantsAdvanceViewer(UIView *hint) {
    UIView *stackView = SPKInstantsFindStackView(hint);
    if (!stackView) {
        SPKLog(@"Instants", @"advance: no visible snap stack");
        return NO;
    }
    id controller = SPKInstantsTapController(stackView);
    if (!controller) {
        SPKLog(@"Instants", @"advance: tap controller unavailable");
        return NO;
    }

    SPKInstantsReplayedPress *press = [[SPKInstantsReplayedPress alloc] initWithTarget:nil action:NULL];
    press.spk_referenceView = stackView;
    press.spk_point = CGPointMake(CGRectGetMidX(stackView.bounds), CGRectGetMidY(stackView.bounds));

    // The same shape as a real tap: began, changed, ended. The tap completes on ended, so the
    // phases are kept to about two frames; a hand tap's own 50ms or so of contact time would
    // only add lag here. The controller also keeps a long-press timer, which this stays far
    // inside of.
    SPKInstantsSendPress(controller, press, UIGestureRecognizerStateBegan);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKInstantsSendPress(controller, press, UIGestureRecognizerStateChanged);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.032 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKInstantsSendPress(controller, press, UIGestureRecognizerStateEnded);
    });
    return YES;
}
