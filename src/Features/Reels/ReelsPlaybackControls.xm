#import <objc/message.h>
#import <objc/runtime.h>

#import "../../App/SPKPerfMeter.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Playback/SPKPlaybackPanel.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

static NSString *const kSPKReelsMoreButtonIdentifier = @"more-options-button";
static NSInteger const kSPKReelsSpeedBadgeTag = 926012;
// Sparkle's Reels action button; the speed text sits above it when present.
static NSInteger const kSPKReelsActionButtonTag = 921342;
static const void *kSPKReelsMoreLongPressAssocKey = &kSPKReelsMoreLongPressAssocKey;

// Set while Sparkle drives the cell, so the hooks below can tell its own calls
// from Instagram's.
static BOOL sSPKReelsPlaybackApplyingSpeed = NO;
static BOOL sSPKReelsPlaybackTogglingPlayback = NO;

// Instagram's playback reason codes are an unexported enum that differs between
// versions. Reusing the codes Instagram itself last passed to the cell keeps a
// Sparkle pause/play indistinguishable from the app's own.
static long long sSPKReelsLastPauseReason = 0;
static long long sSPKReelsLastPlayReason = 0;
static const void *kSPKReelsPausedByPanelAssocKey = &kSPKReelsPausedByPanelAssocKey;

static BOOL SPKReelsPlaybackEnabled(void) {
    return SPKPlaybackControlsEnabled(SPKPlaybackSurfaceReels);
}

static id SPKReelsPlaybackSend(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static double SPKReelsPlaybackReadDouble(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return 0.0;
    @try {
        return ((double (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

static NSHashTable<UIView *> *SPKReelsPlaybackLiveUFIs(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// MARK: - Cell access

/// The reel cell that contains `view`, resolved by walking up from the UFI rather
/// than picking the centered cell, which drifts while the feed scrolls.
static UICollectionViewCell *SPKReelsPlaybackVideoCellForView(UIView *view) {
    Class videoCellClass = NSClassFromString(@"IGSundialViewerVideoCell");
    if (!videoCellClass)
        return nil;
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 25; depth++) {
        if ([current isKindOfClass:videoCellClass])
            return (UICollectionViewCell *)current;
        current = current.superview;
    }
    return nil;
}

static id SPKReelsPlaybackVideoView(UICollectionViewCell *cell) {
    id videoView = SPKReelsPlaybackSend(cell, @"videoView");
    return [videoView respondsToSelector:NSSelectorFromString(@"totalPlaybackTime")] ? videoView : nil;
}

static id SPKReelsPlaybackItem(UICollectionViewCell *cell) {
    if (!cell)
        return nil;
    Ivar ivar = class_getInstanceVariable([cell class], "_mediaPassthrough");
    if (ivar) {
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') {
            id media = object_getIvar(cell, ivar);
            if (media)
                return media;
        }
    }
    return SPKReelsPlaybackSend(cell, @"video");
}

static BOOL SPKReelsPlaybackCellIsOnScreen(UICollectionViewCell *cell) {
    UIWindow *window = cell.window;
    if (!window || cell.hidden)
        return NO;
    CGRect frame = [cell convertRect:cell.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(frame);
    CGFloat midX = CGRectGetMidX(frame);
    return CGRectContainsPoint(window.bounds, CGPointMake(midX, midY));
}

static void SPKReelsPlaybackApplySpeed(UICollectionViewCell *cell, double speed) {
    SEL selector = NSSelectorFromString(@"setPlaybackSpeed:");
    if (![cell respondsToSelector:selector])
        return;
    sSPKReelsPlaybackApplyingSpeed = YES;
    @try {
        ((void (*)(id, SEL, float))objc_msgSend)(cell, selector, (float)speed);
    } @catch (__unused NSException *exception) {
    }
    sSPKReelsPlaybackApplyingSpeed = NO;
}

static BOOL SPKReelsPlaybackIsPlaying(UICollectionViewCell *cell) {
    SEL selector = @selector(isPlaying);
    if (![cell respondsToSelector:selector])
        return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(cell, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void SPKReelsPlaybackSendReason(UICollectionViewCell *cell, NSString *selectorName, long long reason) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![cell respondsToSelector:selector])
        return;
    sSPKReelsPlaybackTogglingPlayback = YES;
    @try {
        ((void (*)(id, SEL, long long))objc_msgSend)(cell, selector, reason);
    } @catch (__unused NSException *exception) {
    }
    sSPKReelsPlaybackTogglingPlayback = NO;
}

static SPKPlaybackTarget *SPKReelsPlaybackTargetForCell(UICollectionViewCell *cell) {
    __weak UICollectionViewCell *weakCell = cell;
    SPKPlaybackTarget *target = [SPKPlaybackTarget new];
    target.isAvailable = ^BOOL {
        UICollectionViewCell *strongCell = weakCell;
        return SPKReelsPlaybackEnabled() && SPKReelsPlaybackCellIsOnScreen(strongCell) && SPKReelsPlaybackVideoView(strongCell) != nil;
    };
    target.currentTime = ^double {
        return SPKReelsPlaybackReadDouble(SPKReelsPlaybackVideoView(weakCell), @"currentPlaybackTime");
    };
    target.duration = ^double {
        return SPKReelsPlaybackReadDouble(SPKReelsPlaybackVideoView(weakCell), @"totalPlaybackTime");
    };
    target.isPlaying = ^BOOL {
        return SPKReelsPlaybackIsPlaying(weakCell);
    };
    target.seek = ^(double time, void (^completion)(void)) {
        UICollectionViewCell *strongCell = weakCell;
        SEL cellSeek = NSSelectorFromString(@"seekToTime:preciseTime:trigger:isSeekingOnTap:completionHandler:");
        SEL viewSeek = NSSelectorFromString(@"seekToTime:preciseTime:trigger:completionHandler:");
        // The handler's arguments differ between versions and are not needed.
        id handler = ^{
            completion();
        };
        @try {
            if ([strongCell respondsToSelector:cellSeek]) {
                ((void (*)(id, SEL, double, BOOL, long long, BOOL, id))objc_msgSend)(strongCell, cellSeek, time, YES, 0, NO, handler);
                return;
            }
            id videoView = SPKReelsPlaybackVideoView(strongCell);
            if ([videoView respondsToSelector:viewSeek]) {
                ((void (*)(id, SEL, double, BOOL, long long, id))objc_msgSend)(videoView, viewSeek, time, YES, 0, handler);
                return;
            }
        } @catch (__unused NSException *exception) {
        }
        completion();
    };
    target.togglePlayback = ^{
        UICollectionViewCell *strongCell = weakCell;
        BOOL pausing = SPKReelsPlaybackIsPlaying(strongCell);
        if (pausing)
            SPKReelsPlaybackSendReason(strongCell, @"pauseWithReason:", sSPKReelsLastPauseReason);
        else
            SPKReelsPlaybackSendReason(strongCell, @"playWithReason:", sSPKReelsLastPlayReason);
        // Instagram's own tap handler doesn't recognise a pause it didn't start,
        // so remember it and let the next tap on the reel resume.
        objc_setAssociatedObject(strongCell, kSPKReelsPausedByPanelAssocKey, pausing ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    target.resumeAfterSeek = ^{
        UICollectionViewCell *strongCell = weakCell;
        // A pause the panel holds is intentional; only a stalled player is restarted.
        if (objc_getAssociatedObject(strongCell, kSPKReelsPausedByPanelAssocKey))
            return;
        SPKLog(@"ReelsPlayback", @"Restarting playback stalled after seek");
        SPKReelsPlaybackSendReason(strongCell, @"playWithReason:", sSPKReelsLastPlayReason);
    };
    target.speedItem = ^id {
        return SPKReelsPlaybackItem(weakCell);
    };
    target.applySpeed = ^(double speed) {
        SPKReelsPlaybackApplySpeed(weakCell, speed);
    };
    return target;
}

static void SPKReelsPlaybackSyncSpeed(UICollectionViewCell *cell) {
    if (!SPKReelsPlaybackEnabled() || !cell)
        return;
    double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem(cell));
    // The cell reports its speed as a boxed number that can be nil before playback.
    id reported = SPKReelsPlaybackSend(cell, @"playbackSpeed");
    double current = [reported respondsToSelector:@selector(doubleValue)] ? [reported doubleValue] : 1.0;
    if (fabs(current - wanted) > 0.001)
        SPKReelsPlaybackApplySpeed(cell, wanted);
}

// MARK: - More button + badge

static UIView *SPKReelsSearchMoreButton(UIView *root, NSUInteger depth) {
    if (!root)
        return nil;
    if ([root.accessibilityIdentifier hasSuffix:kSPKReelsMoreButtonIdentifier])
        return root;
    if (depth >= 5)
        return nil;
    for (UIView *subview in root.subviews) {
        UIView *found = SPKReelsSearchMoreButton(subview, depth + 1);
        if (found)
            return found;
    }
    return nil;
}

/// The reel's more button. It is a UIControl (not a UIButton) exposed by the
/// vertical UFI on every supported version; the identifier search is a fallback.
static UIView *SPKReelsFindMoreButton(UIView *verticalUFI) {
    id button = SPKReelsPlaybackSend(verticalUFI, @"moreOptionsButton");
    if ([button isKindOfClass:[UIView class]])
        return (UIView *)button;
    return SPKReelsSearchMoreButton(verticalUFI, 0);
}

@interface SPKReelsPlaybackGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
- (void)handleBadgeTap:(UIButton *)badge;
@end

static void SPKReelsPresentPanel(UIView *anchor) {
    UICollectionViewCell *cell = SPKReelsPlaybackVideoCellForView(anchor);
    if (!SPKReelsPlaybackEnabled() || !SPKReelsPlaybackVideoView(cell)) {
        SPKLog(@"ReelsPlayback", @"Panel unavailable: enabled=%d cell=%@ videoView=%@",
               SPKReelsPlaybackEnabled(), NSStringFromClass(cell.class),
               NSStringFromClass([SPKReelsPlaybackSend(cell, @"videoView") class]));
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeWarning];
        return;
    }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    SPKPlaybackPanelPresent(anchor, SPKPlaybackSurfaceReels, SPKReelsPlaybackTargetForCell(cell));
}

@implementation SPKReelsPlaybackGestureHandler

+ (instancetype)shared {
    static SPKReelsPlaybackGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [SPKReelsPlaybackGestureHandler new];
    });
    return handler;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    SPKReelsPresentPanel(recognizer.view);
}

- (void)handleBadgeTap:(UIButton *)badge {
    // Anchor to the more button: the speed text disappears as soon as the speed
    // returns to 1x, which would take the panel down with it.
    UIView *moreButton = SPKReelsFindMoreButton(badge.superview);
    SPKReelsPresentPanel(moreButton.window ? moreButton : badge);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return SPKReelsPlaybackEnabled();
}

// Win against Instagram's own recognizers on the button and the UFI column (such
// as its hold-for-2x gesture), so a long press opens the panel and nothing else.
// The feed's scroll pan is left alone so a swipe starting on the button still
// scrolls immediately.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return ![otherGestureRecognizer.view isKindOfClass:[UIScrollView class]];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}
@end

static UIButton *SPKReelsSpeedIndicator(UIView *verticalUFI) {
    UIView *existing = [verticalUFI viewWithTag:kSPKReelsSpeedBadgeTag];
    if ([existing isKindOfClass:[UIButton class]])
        return (UIButton *)existing;

    UIButton *indicator = [UIButton buttonWithType:UIButtonTypeCustom];
    indicator.tag = kSPKReelsSpeedBadgeTag;
    indicator.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:16.0 weight:UIFontWeightBold];
    indicator.adjustsImageWhenHighlighted = NO;
    // Matches the shadow Instagram puts under the UFI glyphs over bright video.
    indicator.titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    indicator.titleLabel.layer.shadowOpacity = 0.24;
    indicator.titleLabel.layer.shadowRadius = 1.8;
    indicator.titleLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    indicator.accessibilityLabel = SPKL(@"PLAYBACK_PANEL_OPEN_ACCESSIBILITY_LABEL");
    [indicator addTarget:[SPKReelsPlaybackGestureHandler shared]
                  action:@selector(handleBadgeTap:)
        forControlEvents:UIControlEventTouchUpInside];
    [verticalUFI addSubview:indicator];
    return indicator;
}

/// The Reels UFI glyph tint, which Instagram lifts into extended range on HDR reels.
static UIColor *SPKReelsNativeUFITint(UIView *verticalUFI) {
    id likeButton = SPKReelsPlaybackSend(verticalUFI, @"ufiLikeButton");
    if (![likeButton isKindOfClass:[UIButton class]])
        return UIColor.whiteColor;
    UIButton *like = (UIButton *)likeButton;
    return like.imageView.tintColor ?: like.tintColor ?: UIColor.whiteColor;
}

/// The topmost element of the action column the indicator sits above: Sparkle's
/// action button when it is shown, otherwise Instagram's like button.
static UIView *SPKReelsIndicatorAnchor(UIView *verticalUFI) {
    UIView *actionButton = [verticalUFI viewWithTag:kSPKReelsActionButtonTag];
    if (actionButton && !actionButton.hidden && actionButton.alpha > 0.01)
        return actionButton;
    id likeButton = SPKReelsPlaybackSend(verticalUFI, @"ufiLikeButton");
    return [likeButton isKindOfClass:[UIView class]] ? (UIView *)likeButton : nil;
}

/// Plain speed text over the action column, tinted and EDR-composited like the
/// column's glyphs.
static void SPKReelsUpdateSpeedBadge(UIView *verticalUFI, UIView *moreButton) {
    UICollectionViewCell *cell = SPKReelsPlaybackVideoCellForView(verticalUFI);
    double speed = cell ? SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem(cell)) : 1.0;
    UIView *existing = [verticalUFI viewWithTag:kSPKReelsSpeedBadgeTag];
    UIView *anchor = SPKReelsIndicatorAnchor(verticalUFI);
    if (!SPKReelsPlaybackEnabled() || !cell || !anchor || SPKPlaybackSpeedIsNormal(speed)) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *indicator = SPKReelsSpeedIndicator(verticalUFI);
    NSString *label = SPKPlaybackSpeedLabel(speed);
    if (![[indicator titleForState:UIControlStateNormal] isEqualToString:label]) {
        [UIView performWithoutAnimation:^{
            [indicator setTitle:label forState:UIControlStateNormal];
            [indicator layoutIfNeeded];
        }];
    }
    indicator.accessibilityValue = label;

    UIColor *tint = SPKReelsNativeUFITint(verticalUFI);
    [indicator setTitleColor:tint forState:UIControlStateNormal];
    SPKChromeEnableExtendedDynamicRangeContent(indicator);
    SPKChromeEnableExtendedDynamicRangeContent(indicator.titleLabel);

    CGSize size = [indicator sizeThatFits:CGSizeMake(CGFLOAT_MAX, 28.0)];
    size.width = MAX(size.width, 44.0);
    size.height = 28.0;
    CGRect anchorFrame = [anchor convertRect:anchor.bounds toView:verticalUFI];
    CGRect frame = CGRectMake(round(CGRectGetMidX(anchorFrame) - size.width / 2.0),
                              CGRectGetMinY(anchorFrame) - size.height - 2.0,
                              size.width,
                              size.height);
    if (!CGRectEqualToRect(indicator.frame, frame))
        indicator.frame = frame;
    indicator.alpha = moreButton ? moreButton.alpha : 1.0;
    [verticalUFI bringSubviewToFront:indicator];
}

static void SPKReelsInstallPlaybackControls(UIView *verticalUFI) {
    if (!verticalUFI)
        return;

    [SPKReelsPlaybackLiveUFIs() addObject:verticalUFI];
    UIView *moreButton = SPKReelsFindMoreButton(verticalUFI);
    if (!moreButton && SPKReelsPlaybackEnabled())
        SPKLog(@"ReelsPlayback", @"No more button in %@", NSStringFromClass(verticalUFI.class));
    if (moreButton && !objc_getAssociatedObject(moreButton, kSPKReelsMoreLongPressAssocKey)) {
        SPKReelsPlaybackGestureHandler *handler = [SPKReelsPlaybackGestureHandler shared];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                                 action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.4;
        longPress.delegate = handler;
        [moreButton addGestureRecognizer:longPress];
        objc_setAssociatedObject(moreButton, kSPKReelsMoreLongPressAssocKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    verticalUFI.clipsToBounds = NO;
    SPKReelsUpdateSpeedBadge(verticalUFI, moreButton);
}

static void SPKReelsRefreshAllPlaybackControls(void) {
    for (UIView *verticalUFI in SPKReelsPlaybackLiveUFIs().allObjects) {
        SPKReelsInstallPlaybackControls(verticalUFI);
        SPKReelsPlaybackSyncSpeed(SPKReelsPlaybackVideoCellForView(verticalUFI));
    }
}

// MARK: - Hooks

%group SPKReelsPlaybackControlsUFIHooks

%hook IGSundialViewerVerticalUFI
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ReelsPlaybackControls.layoutSubviews");
    SPKReelsInstallPlaybackControls((UIView *)self);
}
%end

%end

%group SPKReelsPlaybackControlsHooks

%hook IGSundialViewerVideoCell
- (void)setPlaybackSpeed:(float)speed {
    // Instagram resets reels to 1x after its hold-for-2x gesture and when a cell
    // is reused. Keep the chosen speed; its own 2x passes through untouched.
    if (!sSPKReelsPlaybackApplyingSpeed && SPKPlaybackSpeedIsNormal(speed) && SPKReelsPlaybackEnabled()) {
        double wanted = SPKPlaybackSpeedEffective(SPKPlaybackSurfaceReels, SPKReelsPlaybackItem((UICollectionViewCell *)self));
        if (!SPKPlaybackSpeedIsNormal(wanted))
            speed = (float)wanted;
    }
    %orig(speed);
}

- (void)gestureController:(id)controller didObserveSingleTap:(id)tap {
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    if ([objc_getAssociatedObject(cell, kSPKReelsPausedByPanelAssocKey) boolValue]) {
        objc_setAssociatedObject(cell, kSPKReelsPausedByPanelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!SPKReelsPlaybackIsPlaying(cell)) {
            SPKReelsPlaybackSendReason(cell, @"playWithReason:", sSPKReelsLastPlayReason);
            return;
        }
    }
    %orig(controller, tap);
}

- (void)playWithReason:(long long)reason {
    if (!sSPKReelsPlaybackTogglingPlayback) {
        sSPKReelsLastPlayReason = reason;
        objc_setAssociatedObject(self, kSPKReelsPausedByPanelAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(reason);
    SPKReelsPlaybackSyncSpeed((UICollectionViewCell *)self);
}

- (void)pauseWithReason:(long long)reason {
    if (!sSPKReelsPlaybackTogglingPlayback)
        sSPKReelsLastPauseReason = reason;
    %orig(reason);
}
%end

%hook IGSundialFeedViewController
- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    SPKPlaybackPanelDismiss(NO);
    if (SPKPlaybackSpeedCurrentScope(SPKPlaybackSurfaceReels) != SPKPlaybackSpeedScopeAlways)
        SPKPlaybackSpeedEndSession(SPKPlaybackSurfaceReels);
}
%end

%end

extern "C" void SPKInstallReelsPlaybackControlsHooksIfEnabled(void) {
    // IG 436+ registers the Reels UFI under a Swift-mangled name; bail without
    // burning the once token so a later surface pass can retry.
    Class ufiClass = SPKReelsVerticalUFIClass();
    if (!ufiClass)
        return;

    // Installed regardless of the preference so it can be toggled while Reels is
    // open; every hook re-checks the preference at call time.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKPlaybackSpeedDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
                                                          if ([notification.object integerValue] == SPKPlaybackSurfaceReels)
                                                              SPKReelsRefreshAllPlaybackControls();
                                                      }];
        %init(SPKReelsPlaybackControlsUFIHooks, IGSundialViewerVerticalUFI = ufiClass);
        if (NSClassFromString(@"IGSundialViewerVideoCell")) {
            %init(SPKReelsPlaybackControlsHooks);
        }
    });
}
