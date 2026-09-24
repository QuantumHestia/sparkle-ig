#import "SPKStoryDynamicRange.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../UI/SPKChrome.h"
#import "../../Utils.h"

static UIView *spkStoryOverlayForButton(UIView *view);

static BOOL spkLayerWantsExtendedDynamicRangeContent(CALayer *layer) {
    if (!layer)
        return NO;

    SEL selector = NSSelectorFromString(@"wantsExtendedDynamicRangeContent");
    if ([layer respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(layer, selector)) {
        return YES;
    }

    selector = NSSelectorFromString(@"preferredDynamicRange");
    if ([layer respondsToSelector:selector]) {
        id range = ((id (*)(id, SEL))objc_msgSend)(layer, selector);
        NSString *description = [[range description] uppercaseString];
        if ([description containsString:@"HIGH"] || [description containsString:@"EDR"]) {
            return YES;
        }
    }

    return NO;
}

static BOOL spkLayerTreeReportsExtendedDynamicRange(CALayer *layer, NSInteger depth) {
    if (!layer || depth > 12)
        return NO;
    if (spkLayerWantsExtendedDynamicRangeContent(layer))
        return YES;

    for (CALayer *sublayer in layer.sublayers) {
        if (spkLayerTreeReportsExtendedDynamicRange(sublayer, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL spkStringDescribesHDR(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID())
        return NO;

    NSString *string = [(__bridge NSString *)value uppercaseString];
    return [string containsString:@"HLG"] ||
           [string containsString:@"2084"] ||
           [string containsString:@"PQ"] ||
           [string containsString:@"2100"];
}

static BOOL spkFormatDescriptionIsHDR(CMFormatDescriptionRef formatDescription) {
    if (!formatDescription)
        return NO;

    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(formatDescription);
    if (!extensions)
        return NO;

    CFTypeRef transfer = CFDictionaryGetValue(extensions, kCMFormatDescriptionExtension_TransferFunction);
    if (spkStringDescribesHDR(transfer))
        return YES;

    transfer = CFDictionaryGetValue(extensions, CFSTR("CVImageBufferTransferFunction"));
    return spkStringDescribesHDR(transfer);
}

static BOOL spkAssetIsHDR(AVAsset *asset) {
    if (!asset)
        return NO;

    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeVideo]) {
        for (id descriptionObject in track.formatDescriptions) {
            CMFormatDescriptionRef description = NULL;
            if ([descriptionObject respondsToSelector:@selector(pointerValue)]) {
                description = (CMFormatDescriptionRef)[descriptionObject pointerValue];
            }
            if (!description && CFGetTypeID((__bridge CFTypeRef)descriptionObject) == CMFormatDescriptionGetTypeID()) {
                description = (__bridge CMFormatDescriptionRef)descriptionObject;
            }
            if (spkFormatDescriptionIsHDR(description))
                return YES;
        }
    }
    return NO;
}

static BOOL spkObjectIsHDRPlayer(id object, NSInteger depth);

static BOOL spkLayerTreeContainsHDRPlayer(CALayer *layer, NSInteger depth) {
    if (!layer || depth > 12)
        return NO;

    SEL playerSelector = NSSelectorFromString(@"player");
    if ([layer respondsToSelector:playerSelector]) {
        id player = ((id (*)(id, SEL))objc_msgSend)(layer, playerSelector);
        if (spkObjectIsHDRPlayer(player, 0))
            return YES;
    }

    for (CALayer *sublayer in layer.sublayers) {
        if (spkLayerTreeContainsHDRPlayer(sublayer, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL spkObjectIsHDRPlayer(id object, NSInteger depth) {
    if (!object || depth > 4)
        return NO;

    AVPlayer *player = nil;
    if ([object isKindOfClass:[AVPlayer class]]) {
        player = (AVPlayer *)object;
    } else if ([object respondsToSelector:@selector(currentItem)]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(object, @selector(currentItem));
        if ([candidate isKindOfClass:[AVPlayerItem class]]) {
            AVAsset *asset = ((AVPlayerItem *)candidate).asset;
            if (spkAssetIsHDR(asset))
                return YES;
        }
    }

    if (player && spkAssetIsHDR(player.currentItem.asset))
        return YES;

    for (NSString *selectorName in @[ @"player", @"avPlayer", @"videoPlayer", @"playbackController", @"playerController" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector])
            continue;
        id nested = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (nested && nested != object && spkObjectIsHDRPlayer(nested, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL spkImageIsExtendedRange(UIImage *image) {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef)
        return NO;

    CGColorSpaceRef colorSpace = CGImageGetColorSpace(imageRef);
    if (!colorSpace)
        return NO;

    NSString *name = (__bridge NSString *)CGColorSpaceGetName(colorSpace);
    if (!name.length)
        return NO;

    NSString *upperName = name.uppercaseString;
    return [upperName containsString:@"EXTENDED"] || [upperName containsString:@"HDR"];
}

static BOOL spkImageTreeIsExtendedRange(UIView *view, NSInteger depth) {
    if (!view || depth > 8)
        return NO;
    if ([view isKindOfClass:[UIImageView class]] && spkImageIsExtendedRange(((UIImageView *)view).image))
        return YES;
    for (UIView *subview in view.subviews) {
        if (spkImageTreeIsExtendedRange(subview, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL spkStoryVideoCandidate(UIView *view) {
    NSString *className = NSStringFromClass(view.class).uppercaseString;
    return [className containsString:@"STORYVIDE"] ||
           [className containsString:@"STORYPHOTO"] ||
           [className containsString:@"STORYPLAYER"] ||
           [className containsString:@"ASSETPLAYER"];
}

static BOOL spkColorIsExtendedRange(UIColor *color) {
    if (!color) return NO;
    CGColorRef cgColor = color.CGColor;
    if (!cgColor) return NO;
    CGColorSpaceRef colorSpace = CGColorGetColorSpace(cgColor);
    if (colorSpace) {
        CFStringRef name = CGColorSpaceGetName(colorSpace);
        if (name) {
            NSString *spaceName = (__bridge NSString *)name;
            if ([spaceName.uppercaseString containsString:@"EXTENDED"] || [spaceName.uppercaseString containsString:@"HDR"]) {
                return YES;
            }
        }
    }
    size_t numComponents = CGColorGetNumberOfComponents(cgColor);
    const CGFloat *components = CGColorGetComponents(cgColor);
    if (components && numComponents >= 3) {
        if (components[0] > 1.001 || components[1] > 1.001 || components[2] > 1.001) {
            return YES;
        }
    }
    return NO;
}

static BOOL spkTapButtonIsEDR(UIView *view) {
    if (!view) return NO;

    if (spkLayerWantsExtendedDynamicRangeContent(view.layer))
        return YES;
    if (spkLayerTreeReportsExtendedDynamicRange(view.layer, 0))
        return YES;

    Class tapBtnClass = NSClassFromString(@"IGTapButton");
    if (!tapBtnClass) tapBtnClass = [view class];

    Ivar iv = class_getInstanceVariable(tapBtnClass, "_edr");
    if (!iv) iv = class_getInstanceVariable(object_getClass(view), "_edr");
    if (iv) {
        ptrdiff_t offset = ivar_getOffset(iv);
        if (offset >= 0) {
            uint8_t *base = (uint8_t *)((__bridge void *)view);
            BOOL edrVal = NO;
            memcpy(&edrVal, base + offset, sizeof(BOOL));
            if (edrVal) return YES;
        }
    }

    for (NSString *selName in @[ @"isEDR", @"edr", @"EDR" ]) {
        SEL sel = NSSelectorFromString(selName);
        if ([view respondsToSelector:sel]) {
            BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel);
            if (val) return YES;
        }
    }

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        UIColor *tint = btn.imageView.tintColor ?: btn.tintColor;
        if (tint && spkColorIsExtendedRange(tint)) {
            return YES;
        }
    }

    return NO;
}

static id spkObjectForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) {
        @try {
            return ((id (*)(id, SEL))objc_msgSend)(target, selector);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static UIButton *spkFindHeaderButtonInView(UIView *view) {
    if (!view) return nil;

    for (NSString *propName in @[ @"dismissButton", @"moreOptionsButton", @"mimicryHamburgerButton", @"titleView" ]) {
        id candidate = spkObjectForSelector(view, propName);
        if (!candidate) candidate = [SPKUtils getIvarForObj:view name:[[NSString stringWithFormat:@"_%@", propName] UTF8String]];
        if ([candidate isKindOfClass:[UIButton class]]) {
            return (UIButton *)candidate;
        }
    }

    Class tapClass = NSClassFromString(@"IGTapButton");
    NSMutableArray *queue = [NSMutableArray arrayWithObject:view];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (tapClass && [v isKindOfClass:tapClass]) {
            return (UIButton *)v;
        }
        if ([NSStringFromClass(v.class) containsString:@"IGTapButton"]) {
            return (UIButton *)v;
        }
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
    return nil;
}

static BOOL spkOverlayTapButtonsReportEDR(UIView *overlay, NSInteger depth) {
    if (!overlay || depth > 8)
        return NO;

    for (UIView *subview in overlay.subviews) {
        if (!subview)
            continue;

        NSString *className = NSStringFromClass(subview.class);
        if ([className containsString:@"Tap"] || [className containsString:@"Header"] ||
            [className containsString:@"Button"]) {
            if (spkTapButtonIsEDR(subview)) {
                return YES;
            }

            if ([subview respondsToSelector:@selector(imageView)]) {
                @try {
                    UIImageView *iv = ((UIImageView *(*)(id, SEL))objc_msgSend)(subview, @selector(imageView));
                    if (iv && iv.image && spkImageIsExtendedRange(iv.image)) {
                        return YES;
                    }
                } @catch (__unused NSException *e) {
                }
            }

            if ([subview isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)subview;
                if (iv.image && spkImageIsExtendedRange(iv.image)) {
                    return YES;
                }
            }
        }

        if (spkOverlayTapButtonsReportEDR(subview, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL spkKeyWindowReportsEDR(NSInteger depth) {
    if (depth > 6)
        return NO;

    UIApplication *app = nil;
    @try {
        app = [UIApplication valueForKey:@"sharedApplication"];
    } @catch (__unused NSException *e) {
        app = nil;
    }

    UIWindow *keyWindow = nil;
    @try {
        keyWindow = [app valueForKey:@"keyWindow"] ?: [[app valueForKey:@"windows"] firstObject];
    } @catch (__unused NSException *e) {
        keyWindow = UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.windows.firstObject;
    }

    if (!keyWindow)
        return NO;

    for (UIView *sub in keyWindow.subviews) {
        if (spkOverlayTapButtonsReportEDR(sub, 0)) {
            return YES;
        }
    }
    return NO;
}

static BOOL spkStoryViewIsHDR(UIView *view, NSInteger depth) {
    if (!view || depth > 12)
        return NO;

    BOOL candidate = spkStoryVideoCandidate(view);
    if (candidate && (spkLayerTreeReportsExtendedDynamicRange(view.layer, 0) ||
                      spkLayerTreeContainsHDRPlayer(view.layer, 0)))
        return YES;

    if (candidate && (spkObjectIsHDRPlayer(view, 0) || spkImageTreeIsExtendedRange(view, 0)))
        return YES;

    UIView *overlay = spkStoryOverlayForButton(view);
    if (overlay && spkOverlayTapButtonsReportEDR(overlay, 0)) {
        return YES;
    }

    if (spkKeyWindowReportsEDR(0)) {
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if (spkStoryViewIsHDR(subview, depth + 1))
            return YES;
    }
    return NO;
}

static UIView *spkStoryOverlayForButton(UIView *view) {
    for (UIView *walker = view; walker; walker = walker.superview) {
        NSString *className = NSStringFromClass(walker.class);
        if ([className containsString:@"IGStoryFullscreenOverlayView"])
            return walker;
    }
    return nil;
}

static UIView *spkStoryChromeAncestorForButton(UIView *view) {
    for (UIView *walker = view; walker; walker = walker.superview) {
        NSString *className = NSStringFromClass(walker.class);
        if (!className)
            continue;
        NSString *upper = className.uppercaseString;
        if ([upper containsString:@"IGSTORYFULLSCREENOVERLAYVIEW"]) {
            return walker;
        }
        if ([upper containsString:@"IGSTORYFULLSCREENHEADER"] || [upper containsString:@"IGSTORYHEADER"] || [upper containsString:@"VIEWERHEADER"] || [upper containsString:@"FULLSCREENHEADER"]) {
            return walker;
        }
        if ([upper containsString:@"STORYVIEWER"] || [upper containsString:@"STORYOVERLAY"]) {
            return walker;
        }
    }
    return nil;
}

static UIColor *spkExtendedWhiteTint(UIView *view) {
    CGFloat headroom = 1.85;
    UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
    SEL selector = NSSelectorFromString(@"potentialEDRHeadroom");
    if ([screen respondsToSelector:selector]) {
        CGFloat available = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, selector);
        if (available > 1.0) {
            headroom = MIN(2.0, MAX(headroom, available * 0.65));
        }
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    if (!colorSpace)
        return nil;

    CGFloat components[] = { headroom, headroom, headroom, 1.0 };
    CGColorRef colorRef = CGColorCreate(colorSpace, components);
    UIColor *color = colorRef ? [UIColor colorWithCGColor:colorRef] : nil;
    if (colorRef)
        CGColorRelease(colorRef);
    CGColorSpaceRelease(colorSpace);
    return color;
}

static void spkApplyEDRTintToImageView(UIImageView *imageView, UIColor *tint) {
    if (!imageView || !tint)
        return;

    imageView.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
    imageView.tintColor = tint;
    imageView.alpha = 1.0;
    imageView.hidden = NO;
    imageView.layer.opacity = 1.0;
    imageView.layer.hidden = NO;

    UIImage *image = imageView.image;
    if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
        imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

void SPKStoryApplyDynamicRangeToButton(UIButton *button) {
    if (!button)
        return;

    UIView *chromeAncestor = spkStoryChromeAncestorForButton(button);
    if (!chromeAncestor) {
        return;
    }

    UIView *overlay = spkStoryOverlayForButton(button) ?: chromeAncestor;
    UIView *headerView = [SPKUtils getIvarForObj:overlay name:"_headerView"];
    if (![headerView isKindOfClass:[UIView class]]) {
        id selectorHeader = spkObjectForSelector(overlay, @"headerView");
        headerView = [selectorHeader isKindOfClass:[UIView class]] ? (UIView *)selectorHeader : nil;
    }
    if (!headerView) {
        for (UIView *w = button; w; w = w.superview) {
            if ([NSStringFromClass(w.class) containsString:@"IGStoryFullscreenHeaderView"]) {
                headerView = w;
                break;
            }
        }
    }

    UIButton *headerButton = spkFindHeaderButtonInView(headerView ?: chromeAncestor);
    BOOL isHDR = NO;
    UIColor *nativeHeaderTint = nil;

    if (headerButton) {
        if (spkTapButtonIsEDR(headerButton)) {
            isHDR = YES;
        }
        nativeHeaderTint = headerButton.imageView.tintColor ?: headerButton.tintColor;
        if (nativeHeaderTint && spkColorIsExtendedRange(nativeHeaderTint)) {
            isHDR = YES;
        }
    }

    if (!isHDR) {
        isHDR = spkStoryViewIsHDR(chromeAncestor, 0);
    }

    if (!isHDR) {
        button.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        button.tintColor = UIColor.whiteColor;
        if ([button isKindOfClass:[SPKChromeButton class]]) {
            SPKChromeButton *chromeButton = (SPKChromeButton *)button;
            chromeButton.iconTint = UIColor.whiteColor;
            chromeButton.iconView.tintColor = UIColor.whiteColor;
        }
        if (button.imageView) {
            button.imageView.tintColor = UIColor.whiteColor;
        }
        return;
    }

    SPKChromeEnableExtendedDynamicRangeContent(button);

    UIColor *tint = nil;
    if (nativeHeaderTint && spkColorIsExtendedRange(nativeHeaderTint)) {
        tint = nativeHeaderTint;
    } else {
        tint = spkExtendedWhiteTint(button);
    }

    if (!tint) tint = UIColor.whiteColor;

    // This runs from layout callbacks, several times per frame per button, so
    // only the transitions are worth logging.
    UIColor *previousTint = button.tintColor;
    BOOL tintChanged = ![previousTint isEqual:tint];

    button.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
    button.adjustsImageWhenHighlighted = NO;
    button.tintColor = tint;

    if ([button isKindOfClass:[SPKChromeButton class]]) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        chromeButton.iconTint = tint;
        spkApplyEDRTintToImageView(chromeButton.iconView, tint);
    }

    UIImageView *imageView = button.imageView;
    spkApplyEDRTintToImageView(imageView, tint);

    if (tintChanged)
        SPKLog(@"Stories", @"[EDR] Applied EDR tint to button (tag=%ld)", (long)button.tag);
}

UIColor *SPKStoryDynamicRangeAccentTint(UIButton *button, UIColor *color) {
    UIColor *reference = [button isKindOfClass:[SPKChromeButton class]] ? ((SPKChromeButton *)button).iconTint : button.tintColor;
    if (!color || !spkColorIsExtendedRange(reference))
        return color;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    if (!colorSpace)
        return color;

    // The EDR white tint is a uniform gain over 1.0; its brightest component is
    // that gain, and scaling the accent by it keeps both buttons equally bright.
    CGFloat headroom = 1.0;
    CGColorRef referenceRef = CGColorCreateCopyByMatchingToColorSpace(colorSpace, kCGRenderingIntentDefault, reference.CGColor, NULL);
    if (referenceRef) {
        const CGFloat *components = CGColorGetComponents(referenceRef);
        if (components && CGColorGetNumberOfComponents(referenceRef) >= 3)
            headroom = MAX(components[0], MAX(components[1], components[2]));
        CGColorRelease(referenceRef);
    }

    UIColor *result = color;
    CGColorRef accentRef = headroom > 1.001 ? CGColorCreateCopyByMatchingToColorSpace(colorSpace, kCGRenderingIntentDefault, color.CGColor, NULL) : NULL;
    if (accentRef) {
        const CGFloat *components = CGColorGetComponents(accentRef);
        if (components && CGColorGetNumberOfComponents(accentRef) >= 4) {
            CGFloat scaled[] = { components[0] * headroom, components[1] * headroom, components[2] * headroom, components[3] };
            CGColorRef scaledRef = CGColorCreate(colorSpace, scaled);
            if (scaledRef) {
                result = [UIColor colorWithCGColor:scaledRef];
                CGColorRelease(scaledRef);
            }
        }
        CGColorRelease(accentRef);
    }
    CGColorSpaceRelease(colorSpace);
    return result;
}
