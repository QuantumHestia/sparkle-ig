#import <objc/runtime.h>
#import <limits.h>

#import "../../InstagramHeaders.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"

extern "C" void SPKBeginSavedTabRoutingBypass(void);
extern "C" void SPKEndSavedTabRoutingBypass(void);
FOUNDATION_EXPORT BOOL SPKOpenPostPushMediaURL(NSURL *url,
                                               UIViewController *presentingVC,
                                               void (^fallback)(void),
                                               void (^onDismiss)(void));

static NSString *SPKStringFromClipboardMediaValue(id value) {
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value isKindOfClass:[NSNumber class]])
        return [(NSNumber *)value stringValue];
    return nil;
}

static NSString *SPKClipboardMediaShortcode(NSURL *url) {
    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"])
        return nil;

    NSArray<NSString *> *components = url.pathComponents;
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        NSString *component = components[index].lowercaseString;
        if ([component isEqualToString:@"p"] ||
            [component isEqualToString:@"reel"] ||
            [component isEqualToString:@"reels"] ||
            [component isEqualToString:@"tv"]) {
            NSString *shortcode = components[index + 1];
            return shortcode.length > 0 ? shortcode : nil;
        }
    }
    return nil;
}

static NSString *SPKClipboardMediaPKFromShortcode(NSString *shortcode) {
    if (shortcode.length == 0)
        return nil;

    static NSString *alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    unsigned long long value = 0;
    for (NSUInteger index = 0; index < shortcode.length; index++) {
        NSRange digitRange = [alphabet rangeOfString:[shortcode substringWithRange:NSMakeRange(index, 1)]];
        if (digitRange.location == NSNotFound || value > (ULLONG_MAX - digitRange.location) / 64)
            return nil;
        value = value * 64 + digitRange.location;
    }
    return value > 0 ? [NSString stringWithFormat:@"%llu", value] : nil;
}

static NSURL *SPKClipboardAuthenticatedMediaURL(NSString *fullMediaID) {
    if (fullMediaID.length == 0 || ![fullMediaID containsString:@"_"])
        return nil;
    NSString *encodedID = [fullMediaID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    return encodedID.length > 0
               ? [NSURL URLWithString:[NSString stringWithFormat:@"instagram://media?id=%@", encodedID]]
               : nil;
}

static NSString *SPKClipboardFullMediaIDFromResponse(NSDictionary *response, NSString *mediaPK) {
    NSDictionary *item = nil;
    id items = response[@"items"];
    if ([items isKindOfClass:[NSArray class]] && [items count] > 0 && [items[0] isKindOfClass:[NSDictionary class]])
        item = items[0];
    if (!item && [response[@"item"] isKindOfClass:[NSDictionary class]])
        item = response[@"item"];
    if (!item && [response[@"media"] isKindOfClass:[NSDictionary class]])
        item = response[@"media"];

    NSString *itemID = SPKStringFromClipboardMediaValue(item[@"id"]);
    if ([itemID containsString:@"_"])
        return itemID;

    NSDictionary *user = [item[@"user"] isKindOfClass:[NSDictionary class]] ? item[@"user"] : nil;
    NSString *ownerPK = SPKStringFromClipboardMediaValue(user[@"pk"] ?: user[@"id"]);
    NSString *resolvedMediaPK = SPKStringFromClipboardMediaValue(item[@"pk"]) ?: mediaPK;
    return resolvedMediaPK.length > 0 && ownerPK.length > 0
               ? [NSString stringWithFormat:@"%@_%@", resolvedMediaPK, ownerPK]
               : nil;
}

static BOOL SPKOpenClipboardURLWithSavedRoutingBypass(NSURL *url) {
    SPKBeginSavedTabRoutingBypass();
    if ([SPKUtils openInstagramMediaURL:url])
        return YES;
    SPKEndSavedTabRoutingBypass();
    return NO;
}

// Every post link takes this route, not only when Saved borrows a tab slot: the
// web permalink resolves through continueUserActivity:, which newer Instagram
// builds land in the main feed instead of the post's own page.
static BOOL SPKOpenClipboardMediaLikeGallery(NSURL *webURL) {
    NSString *shortcode = SPKClipboardMediaShortcode(webURL);
    NSString *mediaPK = SPKClipboardMediaPKFromShortcode(shortcode);
    if (mediaPK.length == 0)
        return NO;

    __weak UIViewController *presenter = topMostController();
    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"media/%@/info/", mediaPK]
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
        NSString *fullMediaID = SPKClipboardFullMediaIDFromResponse(response, mediaPK);
        NSURL *mediaURL = SPKClipboardAuthenticatedMediaURL(fullMediaID);
        UIViewController *livePresenter = presenter;
        if (!mediaURL || !livePresenter || !livePresenter.view.window) {
            SPKWarnLog(@"Interface", @"[Sparkle] Explore long-press: native media resolution failed for %@ (%@), using permalink", shortcode, error);
            SPKOpenClipboardURLWithSavedRoutingBypass(webURL);
            return;
        }

        void (^legacyFallback)(void) = ^{
            SPKOpenClipboardURLWithSavedRoutingBypass(webURL);
        };
        SPKBeginSavedTabRoutingBypass();
        if (!SPKOpenPostPushMediaURL(mediaURL, livePresenter, legacyFallback, nil)) {
            SPKEndSavedTabRoutingBypass();
            legacyFallback();
        }
    }];
    return YES;
}

static NSURL *SPKNormalizedInstagramClipboardURL(NSString *raw) {
    if (raw.length == 0)
        return nil;

    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return nil;
    if (![trimmed containsString:@"://"]) {
        trimmed = [@"https://" stringByAppendingString:trimmed];
    }

    NSURL *url = [NSURL URLWithString:trimmed];
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"instagram"]) {
        return url;
    }
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }

    NSString *host = url.host.lowercaseString ?: @"";
    if (host.length == 0)
        return nil;

    if ([host isEqualToString:@"instagram.com"] ||
        [host hasSuffix:@".instagram.com"] ||
        [host isEqualToString:@"instagr.am"] ||
        [host isEqualToString:@"ig.me"]) {
        return url;
    }

    if ([host containsString:@"instagram"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        components.scheme = @"https";
        components.host = @"www.instagram.com";
        return components.URL;
    }

    return nil;
}

static BOOL SPKCanAttemptOpenInstagramClipboardURL(NSURL *url) {
    if (!url)
        return NO;

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        return url.host.length > 0;
    }

    if ([scheme isEqualToString:@"instagram"]) {
        UIApplication *application = [UIApplication sharedApplication];
        id<UIApplicationDelegate> delegate = application.delegate;
        return [application canOpenURL:url] || [delegate respondsToSelector:@selector(application:openURL:options:)];
    }

    return NO;
}

// Intercept the clipboard link at the moment IG's own long-press handler fires.
// Returns YES if we consumed the gesture (opened a link), NO to let IG open search.
static BOOL SPKHandleExploreLongPressClipboard(void) {
    if (![SPKUtils getBoolPref:@"interface_open_clipboard_link"]) {
        SPKLog(@"Interface", @"[Sparkle] Explore long-press: clipboard-link feature disabled, falling through to search");
        return NO;
    }

    NSString *clipboard = UIPasteboard.generalPasteboard.string;
    NSURL *url = SPKNormalizedInstagramClipboardURL(clipboard);
    if (!SPKCanAttemptOpenInstagramClipboardURL(url)) {
        SPKLog(@"Interface", @"[Sparkle] Explore long-press: clipboard (%@) is not an openable Instagram link, falling through to search", clipboard.length ? clipboard : @"<empty>");
        return NO;
    }

    if (SPKOpenClipboardMediaLikeGallery(url)) {
        SPKLog(@"Interface", @"[Sparkle] Explore long-press: resolving clipboard media for native push %@", url);
    } else if (!SPKOpenClipboardURLWithSavedRoutingBypass(url)) {
        SPKWarnLog(@"Interface", @"[Sparkle] Explore long-press: failed to open %@, falling through to search", url);
        return NO;
    }

    SPKLog(@"Interface", @"[Sparkle] Explore long-press: opened clipboard link %@", url);
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    return YES;
}

%group SPKOpenLinkFromClipboardHooks

%hook IGTabBarController

- (void)_exploreButtonLongPressed:(id)gesture {
    // IG's own long-press recognizer fires here (opening search). Only act on the
    // gesture's initial recognition so we don't re-open on every update callback.
    BOOL began = YES;
    if ([gesture isKindOfClass:[UIGestureRecognizer class]]) {
        began = ([(UIGestureRecognizer *)gesture state] == UIGestureRecognizerStateBegan);
    }

    if (began && SPKHandleExploreLongPressClipboard()) {
        return; // consumed: skip IG's search behavior
    }

    %orig;
}

%end

%end

extern "C" void SPKInstallOpenLinkFromClipboardHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"interface_open_clipboard_link"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKOpenLinkFromClipboardHooks);
    });
}
