#import "SPKWebLinkOpener.h"

#import <SafariServices/SafariServices.h>

#import "../../Utils.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../i18n/SPKStrings.h"

NSString *const SPKWebLinkOpenModeInstagram = @"instagram";
NSString *const SPKWebLinkOpenModeInApp = @"in_app";
NSString *const SPKWebLinkOpenModeSafari = @"safari";
NSString *const SPKWebLinkOpenModeAsk = @"ask";

NSString *SPKLinkOpeningModeSetting(void) {
    NSString *mode = [SPKUtils getStringPref:@"general_link_opening_mode"];
    return mode.length > 0 ? mode : @"default";
}

NSString *SPKBrowserLinkOpeningMode(void) {
    NSString *mode = SPKLinkOpeningModeSetting();
    return [mode isEqualToString:@"default"] ? SPKWebLinkOpenModeInstagram : mode;
}

NSString *SPKTappableLinkOpeningMode(void) {
    NSString *mode = SPKLinkOpeningModeSetting();
    return [mode isEqualToString:@"default"] ? SPKWebLinkOpenModeInApp : mode;
}

BOOL SPKWebLinkIsWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return url.host.length > 0 && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
}

static BOOL SPKWebLinkHostMatches(NSString *host, NSArray<NSString *> *domains) {
    NSString *lowered = host.lowercaseString;
    for (NSString *domain in domains) {
        if ([lowered isEqualToString:domain] || [lowered hasSuffix:[@"." stringByAppendingString:domain]])
            return YES;
    }
    return NO;
}

BOOL SPKWebLinkIsMetaOwnedURL(NSURL *url) {
    static NSArray<NSString *> *domains;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[ @"instagram.com", @"facebook.com", @"fb.com", @"fb.me", @"meta.com", @"messenger.com", @"threads.net", @"threads.com", @"whatsapp.com" ];
    });
    return url.host.length > 0 && SPKWebLinkHostMatches(url.host, domains);
}

// l.instagram.com/?u=<destination>&e=<click token>, and Facebook's equivalents.
static NSURL *SPKWebLinkUnwrappedRedirect(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"l.instagram.com"] && ![host isEqualToString:@"l.facebook.com"] && ![host isEqualToString:@"lm.facebook.com"])
        return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"u"] || item.value.length == 0)
            continue;
        NSURL *destination = [NSURL URLWithString:item.value];
        return SPKWebLinkIsWebURL(destination) ? destination : url;
    }
    return url;
}

static BOOL SPKWebLinkIsTrackingQueryItem(NSString *name) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[ @"fbclid", @"igsh", @"igshid", @"ig_rid", @"ig_mid", @"mibextid", @"gclid", @"aem" ]];
    });
    NSString *lowered = name.lowercaseString;
    return [names containsObject:lowered] || [lowered hasPrefix:@"utm_"];
}

NSURL *SPKWebLinkCleanedURL(NSURL *url) {
    if (!SPKWebLinkIsWebURL(url))
        return url;
    NSURL *destination = SPKWebLinkUnwrappedRedirect(url);
    NSURLComponents *components = [NSURLComponents componentsWithURL:destination resolvingAgainstBaseURL:NO];
    // Percent-encoded items keep the original encoding, so a literal %2B is not
    // rewritten to a bare + that the site would read as a space.
    NSArray<NSURLQueryItem *> *items = components.percentEncodedQueryItems;
    if (items.count == 0)
        return destination;

    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (NSURLQueryItem *item in items) {
        if (!SPKWebLinkIsTrackingQueryItem(item.name.stringByRemovingPercentEncoding ?: item.name))
            [kept addObject:item];
    }
    if (kept.count == items.count)
        return destination;
    components.percentEncodedQueryItems = kept.count > 0 ? kept : nil;
    return components.URL ?: destination;
}

static void SPKPresentSafariViewController(NSURL *url, UIViewController *presenter) {
    if (!presenter || !presenter.view.window) {
        SPKLog(@"Links", @"No presenter for in-app browser, handing off to Safari host=%@", url.host ?: @"(none)");
        [SPKUtils openURL:url];
        return;
    }
    SFSafariViewControllerConfiguration *configuration = [SFSafariViewControllerConfiguration new];
    configuration.entersReaderIfAvailable = NO;
    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url configuration:configuration];
    browser.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    [presenter presentViewController:browser animated:YES completion:nil];
}

void SPKOpenWebLink(NSURL *url, NSString *mode, UIViewController *presenter, dispatch_block_t instagramHandler) {
    if (!SPKWebLinkIsWebURL(url)) {
        SPKLog(@"Links", @"Refusing to open non-web URL scheme=%@", url.scheme ?: @"(none)");
        return;
    }

    if ([mode isEqualToString:SPKWebLinkOpenModeInstagram] && instagramHandler) {
        instagramHandler();
        return;
    }
    if ([mode isEqualToString:SPKWebLinkOpenModeSafari]) {
        if (![SPKUtils openURL:url])
            SPKLog(@"Links", @"Safari handoff rejected host=%@", url.host ?: @"(none)");
        return;
    }
    if (![mode isEqualToString:SPKWebLinkOpenModeAsk] || !presenter) {
        SPKPresentSafariViewController(url, presenter);
        return;
    }

    NSMutableArray<SPKIGAlertAction *> *actions = [NSMutableArray array];
    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"COMMON_LINK_OPEN_IN_APP_BROWSER_TEXT")
                                                   style:SPKIGAlertActionStyleDefault
                                                 handler:^{
                                                     SPKPresentSafariViewController(url, presenter);
                                                 }]];
    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"COMMON_LINK_OPEN_SAFARI_TEXT")
                                                   style:SPKIGAlertActionStyleDefault
                                                 handler:^{
                                                     if (![SPKUtils openURL:url])
                                                         SPKLog(@"Links", @"Safari handoff rejected host=%@", url.host ?: @"(none)");
                                                 }]];
    if (instagramHandler) {
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"COMMON_LINK_OPEN_INSTAGRAM_BROWSER_TEXT")
                                                       style:SPKIGAlertActionStyleDefault
                                                     handler:instagramHandler]];
    }
    [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                   style:SPKIGAlertActionStyleCancel
                                                 handler:nil]];
    [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                        title:SPKL(@"COMMON_LINK_OPEN_SHEET_TITLE")
                                                      message:url.host
                                                      actions:actions];
}
