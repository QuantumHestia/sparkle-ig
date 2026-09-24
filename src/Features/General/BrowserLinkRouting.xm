// Opens links that Instagram would load in its own browser in a Safari view
// controller or Safari instead. Neither shares Instagram's web session or its
// injected page scripts, and the l.instagram.com redirect plus click-tracking
// query items are removed before the destination is contacted.
//
// Three layers: IGBrowserController reroutes the tap before Instagram's browser
// is built. The present interception catches a browser container presented by
// any other path before its page loads, and the IGBrowserNavigationController
// fallback covers containers that reach the screen without either.

#import <objc/message.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Shared/Links/SPKWebLinkOpener.h"
#import "../../Utils.h"

static const void *kSPKBrowserSessionRoutedKey = &kSPKBrowserSessionRoutedKey;
static const void *kSPKBrowserNavigationPendingURLKey = &kSPKBrowserNavigationPendingURLKey;
static const void *kSPKBrowserContainerHandledKey = &kSPKBrowserContainerHandledKey;
static const void *kSPKBrowserSessionMarkedURLKey = &kSPKBrowserSessionMarkedURLKey;

// Bound at install time; lets the present interception below recognise the
// browser containers without paying NSClassFromString on every modal in the app.
static Class gSPKBrowserNavigationControllerClass = Nil;
static Class gSPKBrowserViewControllerClass = Nil;

// Bypass for the ask -> Instagram replay on the presentBrowser path: the
// replayed %orig must not sheet again. Set only for the duration of that call.
static IGBrowserSession *gSPKBrowserReplaySession = nil;

// A session mark is a handoff token for ONE approved presentation, not a
// permanent verdict: IG recycles session objects (hot instances, same-link
// retaps), so a sticky mark would silently skip future prompts. Marks are
// cleared when consumed, when their container is dismissed, and when a tap
// entry point sees a stale one. The marked URL tells a continuing restore
// (same URL) apart from a recycled session carrying a new link.
static NSString *SPKBrowserMarkedURL(IGBrowserSession *session) {
    id marked = objc_getAssociatedObject(session, kSPKBrowserSessionMarkedURLKey);
    return [marked isKindOfClass:[NSString class]] ? marked : nil;
}

static void SPKBrowserMarkSession(IGBrowserSession *session, NSString *urlString) {
    if (!session)
        return;
    objc_setAssociatedObject(session, kSPKBrowserSessionRoutedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(session, kSPKBrowserSessionMarkedURLKey, urlString, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void SPKBrowserClearSessionMark(IGBrowserSession *session) {
    if (!session)
        return;
    objc_setAssociatedObject(session, kSPKBrowserSessionRoutedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(session, kSPKBrowserSessionMarkedURLKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void SPKBrowserClearContainerMark(UIViewController *container) {
    if (!container)
        return;
    objc_setAssociatedObject(container, kSPKBrowserContainerHandledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id SPKBrowserSessionObject(id session, SEL getter, const char *ivarName) {
    if ([session respondsToSelector:getter])
        return ((id (*)(id, SEL))objc_msgSend)(session, getter);
    Ivar ivar = class_getInstanceVariable([session class], ivarName);
    return ivar ? object_getIvar(session, ivar) : nil;
}

// Raw http(s) URL carried by the session (request first, destination fallback),
// or nil. Pure extraction, no policy checks: callers compare it (recycling
// detection) or feed it into SPKBrowserSessionReroutableURL for the decision.
static NSURL *SPKBrowserSessionPickedURL(IGBrowserSession *session) {
    if (!session)
        return nil;
    NSURLRequest *request = SPKBrowserSessionObject(session, NSSelectorFromString(@"urlRequest"), "_urlRequest");
    NSURL *rawURL = [request isKindOfClass:[NSURLRequest class]] ? request.URL : nil;
    id destination = SPKBrowserSessionObject(session, NSSelectorFromString(@"destinationURL"), "_destinationURL");
    NSURL *destinationURL = [destination isKindOfClass:[NSURL class]] ? destination : nil;
    return SPKWebLinkIsWebURL(rawURL) ? rawURL : destinationURL;
}

// The cleaned destination to open outside Instagram, or nil when the session has
// to stay in Instagram's browser: sign-in handoffs and lead forms report back to
// the app, Instant Experience pages talk to it through a script bridge, and Meta's
// own pages need the signed-in session.
static NSURL *SPKBrowserSessionReroutableURL(IGBrowserSession *session, NSURL *picked) {
    if (!session)
        return nil;
    id webAuth = SPKBrowserSessionObject(session, @selector(webAuthenticationRequest), "_webAuthenticationRequest");
    id leadForm = SPKBrowserSessionObject(session, @selector(leadGenFormId), "_leadGenFormId");
    id scriptHandler = SPKBrowserSessionObject(session, NSSelectorFromString(@"scriptMessageHandler"), "_scriptMessageHandler");
    if (webAuth || leadForm || scriptHandler) {
        SPKLog(@"Browser", @"Kept in Instagram's browser: %@", webAuth ? @"sign-in" : (leadForm ? @"lead form" : @"script bridge"));
        return nil;
    }

    if (!SPKWebLinkIsWebURL(picked))
        return nil;

    NSURL *cleaned = SPKWebLinkCleanedURL(picked);
    if (!SPKWebLinkIsWebURL(cleaned) || SPKWebLinkIsMetaOwnedURL(cleaned)) {
        SPKLog(@"Browser", @"Kept in Instagram's browser: Meta host=%@", cleaned.host ?: @"(none)");
        return nil;
    }
    return cleaned;
}

static UIViewController *SPKBrowserLinkPresenter(UIViewController *candidate) {
    UIViewController *presenter = candidate.view.window ? candidate : topMostController();
    for (NSUInteger depth = 0; depth < 8; depth++) {
        UIViewController *presented = presenter.presentedViewController;
        if (!presented || presented.isBeingDismissed)
            break;
        presenter = presented;
    }
    return presenter;
}

static BOOL SPKBrowserIsKnownContainer(UIViewController *vc) {
    return (gSPKBrowserNavigationControllerClass && [vc isKindOfClass:gSPKBrowserNavigationControllerClass]) ||
           (gSPKBrowserViewControllerClass && [vc isKindOfClass:gSPKBrowserViewControllerClass]);
}

// Shared present decision. Returns the outside URL when `container` needs a
// new decision with a reroutable session, else nil for pass-through. Nothing
// is approved here; the caller's Instagram handler marks the container. A
// marked session presenting the same URL is the approved restore flow and is
// consumed one-shot; anything else decides fresh.
static NSURL *SPKBrowserRerouteURL(UIViewController *container, NSString *mode, NSString *tag) {
    if (objc_getAssociatedObject(container, kSPKBrowserContainerHandledKey))
        return nil;
    IGBrowserSession *session = nil;
    if ([(id)container respondsToSelector:@selector(browserSession)])
        session = [(id)container browserSession];
    if (!session || [mode isEqualToString:SPKWebLinkOpenModeInstagram])
        return nil;
    NSURL *picked = SPKBrowserSessionPickedURL(session);
    NSString *marked = SPKBrowserMarkedURL(session);
    if (marked.length > 0 && picked && [marked isEqualToString:picked.absoluteString]) {
        SPKBrowserClearSessionMark(session);
        objc_setAssociatedObject(container, kSPKBrowserContainerHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    SPKBrowserClearSessionMark(session);
    NSURL *url = SPKBrowserSessionReroutableURL(session, picked);
    if (url)
        SPKLog(@"Browser", @"%@: rerouting host=%@ mode=%@", tag, url.host ?: @"(none)", mode);
    return url;
}

%group SPKBrowserLinkRoutingHooks

%hook IGBrowserController
- (void)presentBrowserWithBrowserSession:(IGBrowserSession *)session viewController:(UIViewController *)controller presentingPanGesture:(id)gesture forceFreshLoad:(BOOL)forceFreshLoad {
    NSString *mode = SPKBrowserLinkOpeningMode();
    // IGBrowserController looks transient (per-tap): the ask sheet outlives the
    // original call, so the fallback below must keep the controller alive.
    // spkController is referenced inside the block to force a strong capture.
    IGBrowserController *spkController = (IGBrowserController *)self;
    // Approved ask -> Instagram replay: approved synchronously, never sheets again.
    if (session && session == gSPKBrowserReplaySession) {
        gSPKBrowserReplaySession = nil;
        %orig;
        return;
    }
    // A tap is always a new decision: a stale mark means the session object was
    // recycled, and it must never suppress this tap's prompt.
    SPKBrowserClearSessionMark(session);
    if ([mode isEqualToString:SPKWebLinkOpenModeInstagram]) {
        %orig;
        return;
    }
    NSURL *picked = SPKBrowserSessionPickedURL(session);
    NSURL *url = SPKBrowserSessionReroutableURL(session, picked);
    if (!url) {
        %orig;
        return;
    }

    SPKLog(@"Browser", @"presentBrowser: rerouting host=%@ mode=%@", url.host ?: @"(none)", mode);
    SPKOpenWebLink(url, mode, SPKBrowserLinkPresenter(controller), ^{
        (void)spkController;
        // Approve only once the user picked Instagram: the mark lets the
        // container this replay presents pass the present interception.
        SPKBrowserMarkSession(session, picked.absoluteString);
        // %orig calls the original IMP directly and never re-enters this hook,
        // so the bypass only matters if IG re-enters presentBrowser itself.
        gSPKBrowserReplaySession = session;
        %orig(session, controller, gesture, forceFreshLoad);
        gSPKBrowserReplaySession = nil;
    });
}
%end

// Safety net for launch paths that present the browser container without
// going through IGBrowserController: catches it while it is still just a
// presentation request, so the page never loads. Every other modal costs two
// class checks and falls straight through.
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (SPKBrowserIsKnownContainer(viewControllerToPresent)) {
        NSString *mode = SPKBrowserLinkOpeningMode();
        NSURL *url = SPKBrowserRerouteURL(viewControllerToPresent, mode, @"Intercept present");
        if (url) {
            UIViewController *presenter = SPKBrowserLinkPresenter((UIViewController *)self);
            SPKOpenWebLink(url, mode, presenter, ^{
                // Keeps the nav fallback from rerouting the approved container.
                objc_setAssociatedObject(viewControllerToPresent, kSPKBrowserContainerHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                %orig(viewControllerToPresent, animated, completion);
            });
            return;
        }
    }
    %orig;
}
%end

// Note: there is deliberately no push interception. IGBrowserViewController
// declares push unsupported, and device logs on both supported IG versions
// never showed a browser container being pushed. If that ever changes, add a
// UINavigationController push hook mirroring the present one.

// Fallback for launch paths that build the browser without going through
// IGBrowserController. The container is hidden before it shows, then dismissed
// once its presentation settles, since dismissing mid-transition is ignored.
%hook IGBrowserNavigationController
- (void)viewWillAppear:(BOOL)animated {
    IGBrowserNavigationController *browser = (IGBrowserNavigationController *)self;
    IGBrowserSession *session = [browser respondsToSelector:@selector(browserSession)] ? browser.browserSession : nil;
    NSString *mode = SPKBrowserLinkOpeningMode();
    if (objc_getAssociatedObject(self, kSPKBrowserContainerHandledKey) || !browser.isBeingPresented || !session ||
        [mode isEqualToString:SPKWebLinkOpenModeInstagram]) {
        %orig;
        return;
    }
    NSURL *picked = SPKBrowserSessionPickedURL(session);
    NSString *marked = SPKBrowserMarkedURL(session);
    if (marked.length > 0 && picked && [marked isEqualToString:picked.absoluteString]) {
        SPKBrowserClearSessionMark(session);
        objc_setAssociatedObject(self, kSPKBrowserContainerHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig;
        return;
    }
    SPKBrowserClearSessionMark(session);
    NSURL *url = SPKBrowserSessionReroutableURL(session, picked);
    if (url) {
        SPKLog(@"Browser", @"Nav fallback: rerouting host=%@ mode=%@", url.host ?: @"(none)", mode);
        objc_setAssociatedObject(self, kSPKBrowserNavigationPendingURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        browser.view.hidden = YES;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSURL *url = objc_getAssociatedObject(self, kSPKBrowserNavigationPendingURLKey);
    if (!url)
        return;
    objc_setAssociatedObject(self, kSPKBrowserNavigationPendingURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationController *browser = (UINavigationController *)self;
    UIViewController *presenter = browser.presentingViewController;
    NSString *mode = SPKBrowserLinkOpeningMode();
    [browser dismissViewControllerAnimated:NO completion:^{
        browser.view.hidden = NO;
        SPKOpenWebLink(url, mode, SPKBrowserLinkPresenter(presenter), ^{
            // Approve only on this choice, so the restore passes the present
            // interception and this hook. The container mark alone carries it.
            objc_setAssociatedObject(browser, kSPKBrowserContainerHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [SPKBrowserLinkPresenter(presenter) presentViewController:browser animated:YES completion:nil];
        });
    }];
}

// Marks die with the decided presentation: once the user dismisses the
// approved Instagram browser, the session is fresh again and the next tap
// prompts. Covering presentations (share sheets etc.) don't dismiss, so they
// can't clear a live decision early.
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    if (vc.isBeingDismissed || vc.isMovingFromParentViewController) {
        IGBrowserNavigationController *browser = (IGBrowserNavigationController *)self;
        IGBrowserSession *session = [browser respondsToSelector:@selector(browserSession)] ? browser.browserSession : nil;
        SPKBrowserClearSessionMark(session);
        SPKBrowserClearContainerMark(self);
    }
}
%end

%end

// Same lifetime rule for the unwrapped browser view controller, in case a path
// presents it without the navigation wrapper. Separate group so a missing class
// only drops this hook.
%group SPKBrowserViewControllerHooks

%hook IGBrowserViewController
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (((UIViewController *)self).isBeingDismissed || ((UIViewController *)self).isMovingFromParentViewController) {
        IGBrowserSession *session = [(id)self respondsToSelector:@selector(browserSession)] ? [(id)self browserSession] : nil;
        SPKBrowserClearSessionMark(session);
        SPKBrowserClearContainerMark((UIViewController *)self);
    }
}
%end

%end

extern "C" void SPKInstallBrowserLinkRoutingHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controllerClass = NSClassFromString(@"IGBrowserController");
        Class navigationClass = NSClassFromString(@"IGBrowserNavigationController");
        Class browserVCClass = NSClassFromString(@"IGBrowserViewController");
        if (!controllerClass || !navigationClass) {
            SPKLog(@"Browser", @"Browser classes missing controller=%@ navigation=%@", controllerClass ? @"YES" : @"NO", navigationClass ? @"YES" : @"NO");
            return;
        }
        gSPKBrowserNavigationControllerClass = navigationClass;
        gSPKBrowserViewControllerClass = browserVCClass;
        %init(SPKBrowserLinkRoutingHooks,
              IGBrowserController = controllerClass,
              IGBrowserNavigationController = navigationClass);
        if (browserVCClass)
            %init(SPKBrowserViewControllerHooks, IGBrowserViewController = browserVCClass);
        SPKLog(@"Browser", @"Browser link routing hooks installed browserVC=%@", browserVCClass ? @"YES" : @"NO");
    });
}
