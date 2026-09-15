#import <objc/message.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static NSInteger const kSPKReelsActionButtonTag = 921342;
static const void *kSPKReelsActionBottomConstraintAssocKey = &kSPKReelsActionBottomConstraintAssocKey;
static const void *kSPKReelsActionCenterXConstraintAssocKey = &kSPKReelsActionCenterXConstraintAssocKey;
static const void *kSPKReelsActionWidthConstraintAssocKey = &kSPKReelsActionWidthConstraintAssocKey;
static const void *kSPKReelsActionHeightConstraintAssocKey = &kSPKReelsActionHeightConstraintAssocKey;
static const void *kSPKReelsActionButtonMediaKey = &kSPKReelsActionButtonMediaKey;
static const void *kSPKReelsActionButtonCarouselIndexKey = &kSPKReelsActionButtonCarouselIndexKey;
static CGFloat const kSPKReelsActionButtonSize = 44.0;
static CGFloat const kSPKReelsActionButtonBottomOffset = -5.0;

// Instagram changes the native reel-UFI tint when the current media enters or
// leaves HDR/EDR. Reuse that tint instead of pinning Sparkle's icon to white.
static UIColor *SPKReelsNativeUFIColor(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return UIColor.whiteColor;

    id likeButton = nil;
    SEL selector = @selector(ufiLikeButton);
    if ([verticalUFIView respondsToSelector:selector]) {
        likeButton = ((id (*)(id, SEL))objc_msgSend)(verticalUFIView, selector);
    }

    if (![likeButton isKindOfClass:[UIButton class]])
        return UIColor.whiteColor;

    UIButton *like = (UIButton *)likeButton;
    UIColor *tint = like.imageView.tintColor ?: like.tintColor;
    return tint ?: UIColor.whiteColor;
}

static void SPKApplyReelsNativeUFIColor(UIButton *button, UIColor *color) {
    if (![button isKindOfClass:[UIButton class]])
        return;

    color = color ?: UIColor.whiteColor;
    // Instagram's UFI icon is EDR-capable. Sparkle's icon is nested inside
    // SPKChromeCanvas, so opt the custom layers into the same compositing path.
    SPKChromeEnableExtendedDynamicRangeContent(button);
    button.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
    button.tintColor = color;

    UIImageView *buttonImageView = button.imageView;
    if (buttonImageView) {

        buttonImageView.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        buttonImageView.tintColor = color;
        UIImage *image = buttonImageView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
            buttonImageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    // Sparkle action buttons use a private icon view so bundled Instagram icons
    // and SF Symbols share the same chrome. Keep that path in sync as well.
    if ([button isKindOfClass:[SPKChromeButton class]]) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        chromeButton.iconTint = color;

        chromeButton.iconView.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        chromeButton.iconView.tintColor = color;
        UIImage *image = chromeButton.iconView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
            chromeButton.iconView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

// MARK: - View hierarchy helpers

// MARK: - Deterministic resolution from IGUnifiedVideoCollectionView (Layer 2)

/// Walk up from `view` to find the paging collection view that holds all reel cells.
static UICollectionView *SPKReelsFindPagingCollectionView(UIView *view) {
    Class pagingClass = NSClassFromString(@"IGUnifiedVideoCollectionView");
    if (!pagingClass)
        return nil;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 30; depth++) {
        if ([current isKindOfClass:pagingClass])
            return (UICollectionView *)current;
        current = current.superview;
    }
    return nil;
}

/// Given the paging collection view, find the currently visible reel cell
/// using contentOffset + cell height. Returns a UICollectionViewCell that is
/// an IGSundialViewerVideoCell, CarouselCell, or PhotoCell.
static UICollectionViewCell *SPKReelsCurrentCellFromPagingView(UICollectionView *pagingView) {
    if (!pagingView)
        return nil;

    CGFloat pageHeight = pagingView.bounds.size.height;
    if (pageHeight <= 0)
        return nil;

    // Center-point heuristic: find the cell whose center is closest to the
    // collection view's visible center.
    CGFloat centerY = pagingView.contentOffset.y + pageHeight / 2.0;

    NSArray<UICollectionViewCell *> *visibleCells = pagingView.visibleCells;
    UICollectionViewCell *bestCell = nil;
    CGFloat bestDistance = CGFLOAT_MAX;

    for (UICollectionViewCell *cell in visibleCells) {
        CGFloat cellCenterY = CGRectGetMidY(cell.frame);
        CGFloat distance = ABS(cellCenterY - centerY);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestCell = cell;
        }
    }

    return bestCell;
}

/// Read the media ivar (_mediaPassthrough) from a known cell type.
/// Falls back to scanning all object-typed ivars for IGMedia.
static id SPKReelsMediaFromCell(UICollectionViewCell *cell) {
    if (!cell)
        return nil;

    // Fast path: read _mediaPassthrough directly (present on both VideoCell and CarouselCell)
    Ivar mediaPTIvar = class_getInstanceVariable([cell class], "_mediaPassthrough");
    if (mediaPTIvar) {
        const char *type = ivar_getTypeEncoding(mediaPTIvar);
        if (type && type[0] == '@') {
            @try {
                id media = object_getIvar(cell, mediaPTIvar);
                if (media) {
                    return media;
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }

    // Fallback: scan ivars for IGMedia
    Class mediaClass = NSClassFromString(@"IGMedia");
    if (!mediaClass)
        return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([cell class], &count);
    id found = nil;
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@')
            continue;
        @try {
            id value = object_getIvar(cell, ivars[i]);
            if (value && [value isKindOfClass:mediaClass]) {
                found = value;
                break;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (ivars)
        free(ivars);
    return found;
}

// MARK: - Carousel helpers

static NSArray *SPKReelsCarouselChildren(id parentMedia) {
    return SPKActionButtonCarouselChildren(parentMedia);
}

/// Read the carousel's current page index from a **specific** carousel cell.
/// Only reads ivars from the cell we deterministically found — never from a BFS result.
static NSInteger SPKReelsCarouselCurrentIndex(UICollectionViewCell *carouselCell, id parentMedia) {
    if (!carouselCell || !parentMedia)
        return -1;

    NSArray *children = SPKReelsCarouselChildren(parentMedia);
    if (children.count == 0)
        return -1;
    if (children.count == 1)
        return 0;

    NSInteger currentIdx = 0;
    Ivar idxIvar = class_getInstanceVariable([carouselCell class], "_currentIndex");
    if (idxIvar) {
        ptrdiff_t offset = ivar_getOffset(idxIvar);
        currentIdx = *(NSInteger *)((char *)(__bridge void *)carouselCell + offset);
    }

    if (!idxIvar || currentIdx == 0) {
        Ivar fracIvar = class_getInstanceVariable([carouselCell class], "_currentFractionalIndex");
        if (fracIvar) {
            ptrdiff_t offset = ivar_getOffset(fracIvar);
            double fractionalIndex = *(double *)((char *)(__bridge void *)carouselCell + offset);
            NSInteger roundedIdx = (NSInteger)round(fractionalIndex);
            if (roundedIdx > 0)
                currentIdx = roundedIdx;
        }
    }

    Ivar collectionViewIvar = class_getInstanceVariable([carouselCell class], "_collectionView");
    if (collectionViewIvar) {
        UICollectionView *cv = object_getIvar(carouselCell, collectionViewIvar);
        if (cv) {
            CGFloat pageWidth = cv.bounds.size.width;
            if (pageWidth > 0) {
                NSInteger cvIdx = (NSInteger)round(cv.contentOffset.x / pageWidth);
                if (cvIdx > currentIdx)
                    currentIdx = cvIdx;
            }
        }
    }

    if (currentIdx < 0)
        return 0;
    if ((NSUInteger)currentIdx >= children.count)
        return (NSInteger)children.count - 1;

    return currentIdx;
}

// MARK: - Media resolution (deterministic, with BFS fallback)

/// Walk UP the superview chain to find the cell that actually CONTAINS this UFI/button.
/// This is the cell the button belongs to — independent of which cell is currently
/// centered, so it doesn't drift with scroll timing.
static UICollectionViewCell *SPKReelsOwnEnclosingCell(UIView *view) {
    Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
    Class videoCellClass = NSClassFromString(@"IGSundialViewerVideoCell");
    Class photoCellClass = NSClassFromString(@"IGSundialViewerPhotoCell");
    UIView *current = view;
    for (NSInteger depth = 0; current && depth < 25; depth++) {
        if ((carouselClass && [current isKindOfClass:carouselClass]) ||
            (videoCellClass && [current isKindOfClass:videoCellClass]) ||
            (photoCellClass && [current isKindOfClass:photoCellClass])) {
            return (UICollectionViewCell *)current;
        }
        current = current.superview;
    }
    return nil;
}

/// Primary resolution: the UFI's OWN enclosing cell (per-button correct, timing-independent).
/// Fallback: globally-centered cell via the paging collection view, then the delegate chain.
static id SPKReelsMediaProvider(UIView *sourceView) {
    // --- PRIMARY: resolve THIS UFI's own enclosing cell ---
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id media = SPKReelsMediaFromCell(ownCell);
        if (media) {
            return media; // carousel parent returned as-is; currentIndexResolver picks the child
        }
    }

    // --- FALLBACK: globally-centered cell via IGUnifiedVideoCollectionView ---
    UICollectionView *pagingView = SPKReelsFindPagingCollectionView(sourceView);
    if (pagingView) {
        UICollectionViewCell *currentCell = SPKReelsCurrentCellFromPagingView(pagingView);
        if (currentCell) {
            id media = SPKReelsMediaFromCell(currentCell);
            if (media) {
                return media;
            }
        }
    }

    // Last resort: delegate chain
    id delegate = SPKObjectForSelector(sourceView, @"delegate");
    id media = SPKObjectForSelector(delegate, @"media");
    if (!media)
        media = SPKKVCObject(delegate, @"media");
    return media;
}

static id SPKReelsBulkMediaProvider(UIView *sourceView) {
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id media = SPKReelsMediaFromCell(ownCell);
        Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
        if (media && carouselClass && [ownCell isKindOfClass:carouselClass]) {
            NSArray *children = SPKReelsCarouselChildren(media);
            if (children.count > 1)
                return media;
        }
    }
    return SPKReelsMediaProvider(sourceView);
}

// MARK: - Current index resolution

static NSInteger SPKReelsCurrentIndexFromVerticalUFI(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return -1;

    for (NSString *selectorName in @[ @"pageIndicator", @"pagingControl" ]) {
        id indicator = SPKObjectForSelector(verticalUFIView, selectorName);
        if ([indicator isKindOfClass:[UIPageControl class]])
            return (NSInteger)((UIPageControl *)indicator).currentPage;
        NSNumber *currentPageNumber = [SPKUtils numericValueForObj:indicator selectorName:@"currentPage"];
        if (currentPageNumber)
            return currentPageNumber.integerValue;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:verticalUFIView];
    while (queue.count > 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([candidate isKindOfClass:[UIPageControl class]])
            return (NSInteger)((UIPageControl *)candidate).currentPage;
        for (UIView *subview in candidate.subviews)
            [queue addObject:subview];
    }

    return -1;
}

static NSInteger SPKReelsCurrentIndexForContext(UIView *sourceView) {
    // PRIMARY: this UFI's own enclosing carousel cell.
    UICollectionViewCell *ownCell = SPKReelsOwnEnclosingCell(sourceView);
    if (ownCell) {
        id parentMedia = SPKReelsMediaFromCell(ownCell);
        Class carouselClass = NSClassFromString(@"IGSundialViewerCarouselCell");
        if (carouselClass && [ownCell isKindOfClass:carouselClass] && parentMedia) {
            NSInteger carouselIndex = SPKReelsCarouselCurrentIndex(ownCell, parentMedia);
            if (carouselIndex >= 0)
                return carouselIndex;
        }
    }

    // Fallback: UFI page indicator
    NSInteger ufiIndex = SPKReelsCurrentIndexFromVerticalUFI(sourceView);
    return ufiIndex >= 0 ? ufiIndex : 0;
}

// MARK: - Caption & repost

static NSString *SPKReelsCaptionForContext(SPKActionButtonContext *context, id media, NSArray *entries, NSInteger currentIndex) {
    NSString *caption = SPKCaptionFromMediaObject(media);
    if (caption.length > 0)
        return caption;
    NSInteger idx = MAX(0, MIN((NSInteger)entries.count - 1, currentIndex));
    if (entries.count > 0) {
        id entryMedia = [entries[idx] valueForKey:@"mediaObject"];
        caption = SPKCaptionFromMediaObject(entryMedia);
    }
    return caption;
}

static BOOL SPKReelsTriggerRepost(SPKActionButtonContext *context) {
    if (!context.view)
        return NO;

    // IG 436+ renamed these to drop the leading underscore (`didTapRepostButton`);
    // older versions used `_didTapRepostButton` / `_didTapRepostButton:`. Try every
    // known variant so the action button's repost works across versions.
    NSArray<NSString *> *noArgSelectors = @[ @"didTapRepostButton", @"_didTapRepostButton" ];
    for (NSString *selectorName in noArgSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([context.view respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(context.view, selector);
            return YES;
        }
    }

    NSArray<NSString *> *oneArgSelectors = @[ @"didTapRepostButton:", @"_didTapRepostButton:" ];
    for (NSString *selectorName in oneArgSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([context.view respondsToSelector:selector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(context.view, selector, nil);
            return YES;
        }
    }

    return NO;
}

// MARK: - Action context

static SPKActionButtonContext *SPKReelsActionContext(UIView *verticalUFIView) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    context.source = SPKActionButtonSourceReels;
    context.view = verticalUFIView;
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceReels);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceReels);
    context.mediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKReelsMediaProvider(resolvedContext.view);
    };
    context.bulkMediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKReelsBulkMediaProvider(resolvedContext.view);
    };
    context.currentIndexResolver = ^NSInteger(SPKActionButtonContext *resolvedContext) {
        return SPKReelsCurrentIndexForContext(resolvedContext.view);
    };
    context.captionResolver = ^NSString *(SPKActionButtonContext *resolvedContext, id media, NSArray *entries, NSInteger currentIndex) {
        return SPKReelsCaptionForContext(resolvedContext, media, entries, currentIndex);
    };
    context.repostHandler = ^BOOL(SPKActionButtonContext *resolvedContext) {
        return SPKReelsTriggerRepost(resolvedContext);
    };
    return context;
}

// MARK: - Layout check

static BOOL SPKReelsConstraintMatches(NSLayoutConstraint *constraint, CGFloat constant) {
    return constraint && constraint.active && ABS(constraint.constant - constant) < 0.5;
}

static BOOL SPKReelsActionButtonLayoutIsCurrent(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]] || button.hidden || !button.superview)
        return NO;

    NSLayoutConstraint *bottomConstraint = objc_getAssociatedObject(button, kSPKReelsActionBottomConstraintAssocKey);
    NSLayoutConstraint *centerXConstraint = objc_getAssociatedObject(button, kSPKReelsActionCenterXConstraintAssocKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kSPKReelsActionWidthConstraintAssocKey);
    NSLayoutConstraint *heightConstraint = objc_getAssociatedObject(button, kSPKReelsActionHeightConstraintAssocKey);

    return SPKReelsConstraintMatches(bottomConstraint, kSPKReelsActionButtonBottomOffset) &&
           centerXConstraint && centerXConstraint.active &&
           SPKReelsConstraintMatches(widthConstraint, kSPKReelsActionButtonSize) &&
           SPKReelsConstraintMatches(heightConstraint, kSPKReelsActionButtonSize);
}

// MARK: - Visibility

static UIButton *SPKReelsHostedActionButton(UIView *verticalUFIView) {
    for (UIView *subview in verticalUFIView.superview.subviews) {
        if (subview.tag == kSPKReelsActionButtonTag && [subview isKindOfClass:[UIButton class]])
            return (UIButton *)subview;
    }
    return nil;
}

// The button is a sibling of the UFI, so it must follow the UFI's fades itself.
// Called from the UFI's alpha/hidden setters so the change lands in the same
// call and inside the same animation block, never a stale mid-fade value.
static void SPKReelsSyncActionButtonVisibility(UIView *verticalUFIView) {
    UIButton *button = SPKReelsHostedActionButton(verticalUFIView);
    if (!button)
        return;
    CGFloat alpha = verticalUFIView.hidden ? 0.0 : verticalUFIView.alpha;
    if (ABS(button.alpha - alpha) > 0.001)
        button.alpha = alpha;
}

// MARK: - UFI EDR anchor

// Outside the [921341, 926003] capture-hiding tag range: the anchor draws nothing.
static NSInteger const kSPKReelsUFIEDRAnchorTag = 927101;

// The UFI layer rasterizes, and its cache only keeps extended range when a
// sublayer asks for EDR. Instagram's own glyphs do not, so without an EDR
// sublayer their HDR tint clamps to SDR. The action button used to supply that
// sublayer by living inside the UFI; now that it lives beside it, this empty
// view keeps the rasterized UFI in extended range.
static void SPKEnsureReelsUFIEDRAnchor(UIView *verticalUFIView) {
    UIView *anchor = [verticalUFIView viewWithTag:kSPKReelsUFIEDRAnchorTag];
    if (anchor.superview == verticalUFIView)
        return;

    anchor = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1.0, 1.0)];
    anchor.tag = kSPKReelsUFIEDRAnchorTag;
    anchor.userInteractionEnabled = NO;
    anchor.backgroundColor = UIColor.clearColor;
    anchor.isAccessibilityElement = NO;
    SEL selector = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    if ([anchor.layer respondsToSelector:selector])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(anchor.layer, selector, YES);
    [verticalUFIView insertSubview:anchor atIndex:0];
}

// MARK: - Installer (with media-change gate — Layer 1)

void SPKInstallReelsActionButton(UIView *verticalUFIView) {
    if (!verticalUFIView)
        return;

    // Host the button beside the UFI, not inside it. The UFI layer rasterizes and
    // casts a shadow from its whole subtree, so as a sublayer the button's
    // silhouette became an opaque black shape whenever UIKit re-rendered it for
    // the touch highlight and the context-menu morph. The UFI's bounds also do
    // not contain the button, which sits above its top edge.
    UIView *host = verticalUFIView.superview ?: verticalUFIView;
    UIButton *legacyButton = (UIButton *)[verticalUFIView viewWithTag:kSPKReelsActionButtonTag];
    if (legacyButton && host != verticalUFIView)
        [legacyButton removeFromSuperview];

    UIButton *button = SPKReelsHostedActionButton(verticalUFIView);
    if (![SPKUtils getBoolPref:@"reels_action_btn"]) {
        [button removeFromSuperview];
        [[verticalUFIView viewWithTag:kSPKReelsUFIEDRAnchorTag] removeFromSuperview];
        return;
    }

    SPKEnsureReelsUFIEDRAnchor(verticalUFIView);
    SPKReelsSyncActionButtonVisibility(verticalUFIView);
    // Siblings are added and reordered on cell reuse; keep the button on top.
    if (button && host.subviews.lastObject != button)
        [host bringSubviewToFront:button];

    // This must run before the layout/media early return: HDR/EDR changes can
    // update Instagram's like tint without changing the reel or our constraints.
    if (button)
        SPKApplyReelsNativeUFIColor(button, SPKReelsNativeUFIColor(verticalUFIView));

    // Resolve current media to detect whether we need to reconfigure
    id currentMedia = SPKReelsMediaProvider(verticalUFIView);
    NSInteger currentCarouselIdx = SPKReelsCurrentIndexForContext(verticalUFIView);
    id lastMedia = button ? objc_getAssociatedObject(button, kSPKReelsActionButtonMediaKey) : nil;
    NSNumber *lastCarouselIdx = button ? objc_getAssociatedObject(button, kSPKReelsActionButtonCarouselIndexKey) : nil;

    BOOL mediaChanged = (lastMedia != currentMedia) ||
                        (lastCarouselIdx && lastCarouselIdx.integerValue != currentCarouselIdx);

    if (SPKReelsActionButtonLayoutIsCurrent(button) && !mediaChanged) {
        return;
    }

    button = button ?: SPKActionButtonWithTag(host, kSPKReelsActionButtonTag);
    SPKReelsSyncActionButtonVisibility(verticalUFIView);
    SPKConfigureActionButton(button, SPKReelsActionContext(verticalUFIView));

    // Store the resolved media + carousel index for change detection on next call
    objc_setAssociatedObject(button, kSPKReelsActionButtonMediaKey, currentMedia, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKReelsActionButtonCarouselIndexKey, @(currentCarouselIdx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (button.hidden)
        return;

    button.translatesAutoresizingMaskIntoConstraints = NO;

    NSLayoutConstraint *bottomConstraint = objc_getAssociatedObject(button, kSPKReelsActionBottomConstraintAssocKey);
    NSLayoutConstraint *centerXConstraint = objc_getAssociatedObject(button, kSPKReelsActionCenterXConstraintAssocKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kSPKReelsActionWidthConstraintAssocKey);
    NSLayoutConstraint *heightConstraint = objc_getAssociatedObject(button, kSPKReelsActionHeightConstraintAssocKey);

    if (!bottomConstraint || !centerXConstraint || !widthConstraint || !heightConstraint) {
        bottomConstraint = [button.bottomAnchor constraintEqualToAnchor:verticalUFIView.topAnchor constant:kSPKReelsActionButtonBottomOffset];
        centerXConstraint = [button.centerXAnchor constraintEqualToAnchor:verticalUFIView.centerXAnchor];
        widthConstraint = [button.widthAnchor constraintEqualToConstant:kSPKReelsActionButtonSize];
        heightConstraint = [button.heightAnchor constraintEqualToConstant:kSPKReelsActionButtonSize];
        [NSLayoutConstraint activateConstraints:@[ bottomConstraint, centerXConstraint, widthConstraint, heightConstraint ]];

        objc_setAssociatedObject(button, kSPKReelsActionBottomConstraintAssocKey, bottomConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kSPKReelsActionCenterXConstraintAssocKey, centerXConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kSPKReelsActionWidthConstraintAssocKey, widthConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kSPKReelsActionHeightConstraintAssocKey, heightConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    bottomConstraint.constant = kSPKReelsActionButtonBottomOffset;
    widthConstraint.constant = kSPKReelsActionButtonSize;
    heightConstraint.constant = kSPKReelsActionButtonSize;

    [host bringSubviewToFront:button];
    SPKApplyButtonStyle(button, SPKActionButtonSourceReels);
    SPKApplyReelsNativeUFIColor(button, SPKReelsNativeUFIColor(verticalUFIView));
}

%group SPKReelsActionButtonHooks

%hook IGSundialViewerVerticalUFI
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ReelsActionButton.layoutSubviews");
    SPKInstallReelsActionButton((UIView *)self);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}

- (void)didMoveToSuperview {
    %orig;
    SPKReelsSyncActionButtonVisibility((UIView *)self);
}
%end

%end

extern "C" void SPKInstallReelsActionButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"reels_action_btn"])
        return;

    // IG 436+ renamed the Reels UFI class to a Swift-mangled symbol; resolve it at
    // runtime and bind the hook group to it. Bail (without burning the once token)
    // if the class isn't registered yet so a later pass can retry.
    Class ufiClass = SPKReelsVerticalUFIClass();
    if (!ufiClass)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKReelsActionButtonHooks, IGSundialViewerVerticalUFI = ufiClass);
    });
}
