#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#import "../../Utils.h"

// Sideloaded Instagram delivers some notifications twice: the system shows the
// APNs push (through the bundled InstagramNotificationExtension), and IG's own
// code re-adds that same push as a *local* notification via
// -[UNUserNotificationCenter addNotificationRequest:withCompletionHandler:] --
// two banners for one event.
//
// Instagram does try to handle this itself, and iOS defeats it. Its extension
// recognises the duplicate and returns non-alerting content, but a service
// extension is not allowed to silence a push that way:
//
//     Mutated notification request will not visibly alert the user,
//     will deliver original content; runtime: 0.367519
//
// iOS discards the mutation and delivers the original, which alerts. So the
// local copy has to be dropped on this side instead.
//
// Push-derived adds are identifiable from their content.userInfo: they carry
// IG's server-generated push id ("gid"), which IG's genuinely local
// notifications do not.
//
// Sparkle's own requests (the presence mirror and the background-download finish
// notification; SPKNotify draws an in-app view instead) carry no "gid", so none
// of them can be caught by this.

static BOOL SPKNotificationRequestIsPushDerived(UNNotificationRequest *request) {
    NSDictionary *userInfo = request.content.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    // "gid" alone. Requiring "ig" AND "gid" missed most duplicates: which keys
    // survive into the local copy varies with the notification type (DM vs like
    // vs follow) and with the IG version. Deliberately NOT also matching "aps",
    // even though that looks like the obvious push marker: the local re-add
    // carries no "aps" key at all, so an "aps" arm can only ever match
    // notifications this hook is not meant to touch.
    //
    // "gid" identifies the message, not the recipient. The recipient account is
    // a separate key ("u"), so two accounts signed in to the same group chat
    // legitimately receive the same "gid" twice. That is why this only ever runs
    // against addNotificationRequest:, which the push path never calls -- every
    // request reaching here is already a local re-add.
    return userInfo[@"gid"] != nil;
}

%group SPKFixDuplicateNotificationsHooks

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // Installed from %ctor, which runs ahead of the surface registry that
    // normally enforces the master kill switch, so honour it here.
    if ([SPKUtils getBoolPref:@"tools_disable_all"]) {
        %orig;
        return;
    }

    if (![SPKUtils getBoolPref:@"tools_fix_duplicate_notifications"]) {
        %orig;
        return;
    }

    // Deliberately not gated on applicationState. The previous version only
    // suppressed while the app was foreground-active, which is the rarer case:
    // most duplicates arrive with the app backgrounded, where IG is woken by the
    // push and re-adds it just the same -- the foreground gate is what let them
    // through. There is also no safe way to read applicationState here, since
    // this is called off the main thread.
    if (SPKNotificationRequestIsPushDerived(request)) {
        // Drop it, but still satisfy the API contract by completing without error.
        if (completionHandler)
            completionHandler(nil);
        return;
    }

    %orig;
}

%end

%end

static void SPKInstallFixDuplicateNotificationsHooksNow(void) {
    // Install unconditionally and gate on the pref inside the hook so the toggle
    // takes effect live, without a restart.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKFixDuplicateNotificationsHooks);
    });
}

// At dylib load, not on the staged surface timer. Duplicates overwhelmingly
// arrive while Instagram is backgrounded or not running: the push wakes the
// process, and IG re-adds the notification during launch. The GeneralUI phase
// installs 0.25s after didFinishLaunching, which is comfortably after that
// re-add has already happened -- so on the runs that matter the hook was not yet
// in place. Hooking one system class is cheap enough to do here, and the pref
// is still read per call, so this costs nothing when the feature is off.
%ctor {
    SPKInstallFixDuplicateNotificationsHooksNow();
}

void SPKInstallFixDuplicateNotificationsHooksIfNeeded(void) {
    // Kept for the surface registry; the %ctor above has already run.
    SPKInstallFixDuplicateNotificationsHooksNow();
}
