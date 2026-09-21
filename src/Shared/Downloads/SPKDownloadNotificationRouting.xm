#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "SPKDownloadBackgroundKeeper.h"
#import "SPKDownloadService.h"

// Tapping the "Downloads finished" notification has to open Sparkle's download
// history, and the only callback that reports the tap is
// -userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:
// on Instagram's own notification delegate. That delegate is an Instagram class
// whose name changes between versions, so it is reached through the setter that
// installs it rather than by name: whatever object arrives, its class is
// swizzled once, and everything that is not ours is passed straight through.

extern "C" NSString *const kSPKDownloadFinishedNotificationMarker;

static IMP spk_originalDidReceiveResponse = NULL;

static BOOL SPKResponseIsDownloadFinished(UNNotificationResponse *response) {
    if (![response isKindOfClass:UNNotificationResponse.class])
        return NO;
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    if (![userInfo isKindOfClass:NSDictionary.class])
        return NO;
    return [userInfo[kSPKDownloadFinishedNotificationMarker] boolValue];
}

static void SPKOpenDownloadsForNotification(void) {
    // The tap can arrive before Instagram has a window to present from, so this
    // waits for the app to become active instead of presenting into nothing.
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [SPKDownloadService presentDownloadsHistorySheet];
        return;
    }
    __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                          object:nil
                                                                           queue:NSOperationQueue.mainQueue
                                                                      usingBlock:^(NSNotification *note) {
                                                                          (void)note;
                                                                          [NSNotificationCenter.defaultCenter removeObserver:observer];
                                                                          observer = nil;
                                                                          [SPKDownloadService presentDownloadsHistorySheet];
                                                                      }];
}

static void spk_didReceiveNotificationResponse(id self,
                                               SEL _cmd,
                                               UNUserNotificationCenter *center,
                                               UNNotificationResponse *response,
                                               void (^completionHandler)(void)) {
    if (SPKResponseIsDownloadFinished(response)) {
        SPKOpenDownloadsForNotification();
        if (completionHandler)
            completionHandler();
        return;
    }
    if (spk_originalDidReceiveResponse) {
        ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))spk_originalDidReceiveResponse)(self, _cmd, center, response, completionHandler);
        return;
    }
    // Instagram's delegate did not implement the callback, so nothing else is
    // waiting on it; the contract still has to be satisfied.
    if (completionHandler)
        completionHandler();
}

static void SPKInstallResponseHookOnDelegate(id delegate) {
    if (!delegate)
        return;
    static NSHashTable *hookedClasses = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hookedClasses = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
    });
    Class cls = object_getClass(delegate);
    if (!cls)
        return;
    @synchronized(hookedClasses) {
        if ([hookedClasses containsObject:cls])
            return;
        [hookedClasses addObject:cls];
    }

    SEL selector = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
    Method existing = class_getInstanceMethod(cls, selector);
    if (existing) {
        spk_originalDidReceiveResponse = method_setImplementation(existing, (IMP)spk_didReceiveNotificationResponse);
    } else {
        class_addMethod(cls, selector, (IMP)spk_didReceiveNotificationResponse, "v@:@@@?");
    }
    SPKLog(@"Downloads", @"notification response routing installed on %@", NSStringFromClass(cls));
}

%hook UNUserNotificationCenter

- (void)setDelegate:(id<UNUserNotificationCenterDelegate>)delegate {
    %orig;
    SPKInstallResponseHookOnDelegate(delegate);
}

%end

extern "C" void SPKInstallDownloadNotificationRoutingHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init;
        // The delegate is usually installed during launch, before this runs.
        SPKInstallResponseHookOnDelegate(UNUserNotificationCenter.currentNotificationCenter.delegate);
    });
}
