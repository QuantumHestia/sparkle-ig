#import "../../InstagramHeaders.h"
#import "../../Shared/Gallery/SPKGalleryFile.h"
#import "../../Shared/Gallery/SPKGalleryOriginController.h"
#import "../../Shared/Gallery/SPKGallerySaveMetadata.h"
#import "../../Shared/MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

@interface IGProfileAvatarView : UIView
@end

@interface IGProfilePhotoView : UIView
@end

static id SPKObjectForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id SPKUserFromViewHierarchy(UIView *view) {
    if (!view)
        return nil;

    id user = SPKObjectForSelector(view, @"user");
    if (user && [user respondsToSelector:@selector(username)])
        return user;

    user = SPKObjectForSelector(view, @"userGQL");
    if (user && [user respondsToSelector:@selector(username)])
        return user;

    id profilePicImageView = SPKObjectForSelector(view, @"profilePicImageView");
    if (!profilePicImageView) {
        profilePicImageView = [SPKUtils getIvarForObj:view name:"_profilePicImageView"];
    }
    user = SPKObjectForSelector(profilePicImageView, @"user");
    if (user && [user respondsToSelector:@selector(username)])
        return user;

    UIViewController *ancestorController = [SPKUtils viewControllerForAncestralView:view];
    user = SPKObjectForSelector(ancestorController, @"user");
    if (user && [user respondsToSelector:@selector(username)])
        return user;

    user = SPKObjectForSelector(ancestorController, @"userGQL");
    if (user && [user respondsToSelector:@selector(username)])
        return user;

    UIResponder *responder = view;
    while ((responder = [responder nextResponder])) {
        user = SPKObjectForSelector(responder, @"user");
        if (user && [user respondsToSelector:@selector(username)])
            return user;

        user = SPKObjectForSelector(responder, @"userGQL");
        if (user && [user respondsToSelector:@selector(username)])
            return user;
    }

    return nil;
}

static NSString *SPKUsernameFromIGUser(id user) {
    if (!user) {
        return nil;
    }
    id name = nil;
    @try {
        name = [user valueForKey:@"username"];
    } @catch (__unused NSException *e) {
    }
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) {
        return (NSString *)name;
    }
    return nil;
}

static NSURL *SPKImageURLFromViewHierarchy(UIView *view) {
    Class igImageViewClass = NSClassFromString(@"IGImageView");
    if (igImageViewClass && [view isKindOfClass:igImageViewClass]) {
        IGImageView *iv = (IGImageView *)view;
        if (iv.imageSpecifier && iv.imageSpecifier.url) {
            return iv.imageSpecifier.url;
        }
    }
    for (UIView *sub in view.subviews) {
        NSURL *url = SPKImageURLFromViewHierarchy(sub);
        if (url)
            return url;
    }
    return nil;
}

// Demangled: IGProfileStoryViewerPresenter.IGProfileStoryPresenter
static Class SPKProfileStoryPresenterClass(void) {
    return objc_getClass("_TtC29IGProfileStoryViewerPresenter23IGProfileStoryPresenter");
}

// Zoom only applies to the profile page header. Avatars elsewhere (explore,
// feed, comments) keep IG's own long press, which is usually the story peek.
static UIViewController *SPKProfileControllerForView(UIView *view) {
    Class profileControllerClass = NSClassFromString(@"IGProfileViewController");
    if (!profileControllerClass || !view)
        return nil;
    for (UIViewController *controller = [SPKUtils viewControllerForAncestralView:view]; controller; controller = controller.parentViewController) {
        if ([controller isKindOfClass:profileControllerClass])
            return controller;
    }
    return nil;
}

// The profile header uses the same long press for story peek and for the photo.
// When story peek is unlocked and the avatar shows a story ring, IG's peek owns
// the gesture, and the photo zoom moves into the peek's "View profile picture"
// row (see the presenter hook below).
static BOOL SPKProfileStoryPeekOwnsLongPress(UIView *view) {
    if (![SPKUtils getBoolPref:@"stories_unlock_preview"] || !SPKProfileStoryPresenterClass())
        return NO;

    UIViewController *controller = SPKProfileControllerForView(view);
    if (!controller)
        return NO;

    UIView *photoView = SPKObjectForSelector(view, @"profilePhotoView") ?: view;
    SEL hasRing = NSSelectorFromString(@"hasAnyStoryRing");
    for (UIView *candidate = photoView; candidate; candidate = candidate.superview) {
        if ([candidate respondsToSelector:hasRing])
            return ((BOOL (*)(id, SEL))objc_msgSend)(candidate, hasRing);
        if (candidate == controller.view)
            break;
    }
    return NO;
}

static BOOL SPKShowProfilePhotoZoomFromView(UIView *view) {
    if (!view) {
        return NO;
    }

    id user = SPKUserFromViewHierarchy(view);
    NSURL *url = [SPKUtils getBestProfilePictureURLForUser:user];
    if (!url) {
        url = SPKImageURLFromViewHierarchy(view);
    }
    if (!url) {
        return NO;
    }

    NSString *username = SPKUsernameFromIGUser(user);
    SPKGallerySaveMetadata *meta = [[SPKGallerySaveMetadata alloc] init];
    meta.source = (int16_t)SPKGallerySourceProfile;
    [SPKGalleryOriginController populateProfileMetadata:meta username:username user:user];

    UIViewController *presentingController = [SPKUtils viewControllerForAncestralView:view];
    [SPKFullScreenMediaPlayer showRemoteImageURL:url
                                        metadata:meta
                                  playbackSource:SPKFullScreenPlaybackSourceProfile
                                      sourceView:view
                                      controller:presentingController
                                   pausePlayback:nil
                                  resumePlayback:nil];
    return YES;
}

static BOOL SPKShouldInterceptProfileLongPress(UILongPressGestureRecognizer *gesture) {
    if (![SPKUtils getBoolPref:@"profile_photo_zoom"]) {
        return NO;
    }

    if (!gesture || gesture.state != UIGestureRecognizerStateBegan || !gesture.view) {
        return NO;
    }

    if (!SPKProfileControllerForView(gesture.view) || SPKProfileStoryPeekOwnsLongPress(gesture.view)) {
        return NO;
    }

    return SPKShowProfilePhotoZoomFromView(gesture.view);
}

static id SPKProfilePhotoZoomBlock(id original, UIView *view) {
    if (!view)
        return original;
    void (^fallback)(void) = original;
    __weak UIView *weakView = view;
    return [^{
        if ([SPKUtils getBoolPref:@"profile_photo_zoom"] && SPKShowProfilePhotoZoomFromView(weakView))
            return;
        if (fallback)
            fallback();
    } copy];
}

static void (*orig_coinFlipLongPress)(id, SEL, UILongPressGestureRecognizer *);
static void SPKHookedCoinFlipLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    if (SPKShouldInterceptProfileLongPress(gesture)) {
        return;
    }

    if (orig_coinFlipLongPress) {
        orig_coinFlipLongPress(self, _cmd, gesture);
    }
}

%group SPKProfilePhotoZoomHooks

%hook IGProfileAvatarView
- (void)_profilePictureLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (SPKShouldInterceptProfileLongPress(gesture)) {
        return;
    }

    %orig;
}
%end

%hook IGProfilePhotoView
- (void)_profilePictureLongPress:(UILongPressGestureRecognizer *)gesture {
    if (SPKShouldInterceptProfileLongPress(gesture)) {
        return;
    }

    %orig;
}
%end

// The profile story peek's "View profile picture" row, and the expanded photo IG
// falls back to when a peek cannot load, both open the zoom instead.
%hook _TtC29IGProfileStoryViewerPresenter23IGProfileStoryPresenter
- (void)showStoryPeekFromView:(UIView *)view storyViewModel:(id)model showExpandedPicFallbackHandler:(id)fallback onFollowUser:(id)onFollow onViewProfilePicture:(id)onViewProfilePicture {
    UIView *sourceView = [view isKindOfClass:[UIView class]] ? view : nil;
    %orig(view, model, SPKProfilePhotoZoomBlock(fallback, sourceView), onFollow, SPKProfilePhotoZoomBlock(onViewProfilePicture, sourceView));
}
%end

%end

void SPKInstallProfilePhotoZoomHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"profile_photo_zoom"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKProfilePhotoZoomHooks);

        Class coinFlipClass = NSClassFromString(@"IGProfilePhotoCoinFlipUI.IGProfilePhotoCoinFlipView");
        SEL selector = NSSelectorFromString(@"viewLongPressedWithGesture:");

        if (coinFlipClass && class_getInstanceMethod(coinFlipClass, selector)) {
            MSHookMessageEx(coinFlipClass,
                            selector,
                            (IMP)SPKHookedCoinFlipLongPress,
                            (IMP *)&orig_coinFlipLongPress);
        }
    });
}
