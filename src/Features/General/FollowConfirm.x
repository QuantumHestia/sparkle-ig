#import "../../InstagramHeaders.h"
#import "SPKStrings.h"
#import "../../Utils.h"

#import <objc/message.h>
#import <objc/runtime.h>

////////////////////////////////////////////////////////

#define CONFIRMFOLLOW(orig)                                                     \
    if ([SPKUtils getBoolPref:@"profile_confirm_follow"]) {                     \
        SPKLog(@"General", @"[Sparkle] Confirm follow triggered");              \
                                                                                \
        [SPKUtils                                                               \
            showConfirmation:^(void) {                                          \
                orig;                                                           \
            }                                                                   \
                       title:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_FOLLOW_TITLE")                                  \
                     message:SPKL(@"GENERAL_FOLLOW_CONFIRM_FOLLOW_ACCOUNT_CONFIRMATION_MESSAGE")]; \
    } else {                                                                    \
        return orig;                                                            \
    }

////////////////////////////////////////////////////////

// IG 442 rebuilt the follow controller in Swift. The class moved to its mangled runtime name, the
// tap handlers lost their underscore prefix, and the `user` property is no longer exposed to the
// Objective-C runtime: only a `_user` ivar survives. KVC against a Swift instance throws, so the
// ivar is read directly. Returns -1 when the layout is unrecognisable, which suppresses both
// prompts rather than wording the wrong one.
static NSInteger SPKFollowControllerStatus(id controller) {
    id user = [SPKUtils getIvarForObj:controller name:"_user"];
    if (![user respondsToSelector:@selector(followStatus)]) {
        SPKLog(@"General", @"[Sparkle] Follow confirm: no readable user on %@<%p>",
               NSStringFromClass([controller class]),
               controller);
        return -1;
    }

    return ((IGUser *)user).followStatus;
}

// A confirmed unfollow can travel through more than one hooked layer before it reaches the network
// call, so the answer is carried down the stack and the prompt stays at one per action. Every hop
// below is synchronous and driven from the main thread, so a plain flag is enough.
static BOOL spk_unfollowConfirmed = NO;

static void SPKConfirmUnfollowElseRestore(void (^perform)(void), void (^restore)(void)) {
    if (spk_unfollowConfirmed || ![SPKUtils getBoolPref:@"profile_confirm_unfollow"]) {
        perform();
        return;
    }

    [SPKUtils
        showConfirmation:^(void) {
            spk_unfollowConfirmed = YES;
            perform();
            spk_unfollowConfirmed = NO;
        }
           cancelHandler:restore
                   title:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_UNFOLLOW_TITLE")
                 message:SPKL(@"GENERAL_FOLLOW_CONFIRM_UNFOLLOW_ACCOUNT_CONFIRMATION_MESSAGE")];
}

static void SPKConfirmUnfollow(void (^perform)(void)) {
    SPKConfirmUnfollowElseRestore(perform, nil);
}

// Follow buttons toggle, so the same tap starts or ends a follow depending on the account's current
// state. The prompt has to be worded from that state rather than from the button that was tapped,
// or ending a follow is announced as starting one.
static void SPKConfirmFollowToggle(BOOL isFollowing, void (^perform)(void)) {
    if (isFollowing) {
        SPKConfirmUnfollow(perform);
        return;
    }

    if (![SPKUtils getBoolPref:@"profile_confirm_follow"]) {
        perform();
        return;
    }

    SPKLog(@"General", @"[Sparkle] Confirm follow triggered");
    [SPKUtils showConfirmation:perform
                         title:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_FOLLOW_TITLE")
                       message:SPKL(@"GENERAL_FOLLOW_CONFIRM_FOLLOW_ACCOUNT_CONFIRMATION_MESSAGE")];
}

// Status 2 is the only state in which a tap begins a follow; anything else undoes one. An account
// that cannot be read keeps the follow wording rather than claiming an unfollow that may not happen.
static BOOL SPKUserIsFollowed(id user) {
    if (![user respondsToSelector:@selector(followStatus)])
        return NO;

    return ((IGUser *)user).followStatus != 2;
}

// Some buttons carry their own state instead of the account, which is cheaper and survives the
// account model being unreachable from the button.
static BOOL SPKButtonReportsFollowing(id button) {
    if (![button respondsToSelector:@selector(isFollowing)])
        return NO;

    return ((BOOL (*)(id, SEL))objc_msgSend)(button, @selector(isFollowing));
}

static id SPKObjectForKnownSelector(id target, SEL selector) {
    if (![target respondsToSelector:selector])
        return nil;

    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

// Suggested account rows keep the account behind a featured user wrapper, on both the row and the
// button inside it.
static id SPKFeaturedUserFromOwner(id owner) {
    return SPKObjectForKnownSelector(SPKObjectForKnownSelector(owner, @selector(userInfo)),
                                     @selector(user));
}

// While following, tapping the button opens the relationship sheet rather than unfollowing on the
// spot, and that sheet carries its own Unfollow row which is confirmed where it is selected. Only
// the surfaces where the tap itself ends the follow are confirmed here. IG 448 dropped the
// Objective-C accessor and kept the flag as a plain Swift stored Bool, so the ivar is read directly
// when the getter is gone; missing it would prompt on the tap and again on the sheet's row.
static BOOL SPKFollowControllerOpensRelationshipSheet(id controller) {
    if ([controller respondsToSelector:@selector(canShowRelationshipSheetWhenFollowing)])
        return ((id<SPKFollowControlling>)controller).canShowRelationshipSheetWhenFollowing;

    Ivar flag = controller ? class_getInstanceVariable(object_getClass(controller), "canShowRelationshipSheetWhenFollowing") : NULL;
    if (!flag)
        return NO;

    return ((const uint8_t *)(__bridge const void *)controller)[ivar_getOffset(flag)] & 1;
}

// A few surfaces, notifications among them, configure the follow control to turn into a Message
// button once the account is already followed. The control keeps its follow identity there, down to
// its accessibility identifier, and only its title changes, so a tap still arrives at the handlers
// below even though it opens a thread instead of ending the follow. Confirming an unfollow there
// asks about something the tap will never do. The title itself is localized and cannot be matched,
// so the surface is read from the flag that put the button in that mode: newer builds expose it on
// the controller, and older ones keep it inside an opaque view configuration, where the direct
// reply presenter stands in for it because it is only wired up on the surfaces that can open a
// thread from this button.
static BOOL SPKFollowControllerTapOpensMessage(id controller) {
    if ([controller respondsToSelector:@selector(showMessageButtonWhenFollowing)])
        return ((id<SPKFollowControlling>)controller).showMessageButtonWhenFollowing;

    return [SPKUtils getIvarForObj:controller name:"_directReplyToAuthorPresenter"] != nil ||
           [SPKUtils getIvarForObj:controller name:"directReplyToAuthorPresenter"] != nil;
}

// The Swift controller reaches performUnfollow through internal Swift dispatch, which never goes
// through objc_msgSend, so a swizzle on it cannot see a tap-driven unfollow. The tap handlers are
// target-action entry points from UIKit and therefore still dispatch normally, so both prompts are
// raised here. Status 2 is the only state in which a tap begins a follow; anything else undoes one.
#define CONFIRMFOLLOWTAP(orig)                                                              \
    {                                                                                       \
        NSInteger status = SPKFollowControllerStatus(self);                                 \
                                                                                            \
        if (status == 2) {                                                                  \
            CONFIRMFOLLOW(orig);                                                            \
        } else if (status >= 0 && !SPKFollowControllerOpensRelationshipSheet(self) &&       \
                   !SPKFollowControllerTapOpensMessage(self)) {                             \
            SPKConfirmUnfollow(^(void) {                                                    \
                orig;                                                                       \
            });                                                                             \
        } else {                                                                            \
            return orig;                                                                    \
        }                                                                                   \
    }

////////////////////////////////////////////////////////

// Follow button on profile page
%group SPKFollowConfirmHooks

%hook IGFollowController
- (void)_didPressFollowButton {
    // Get user follow status (check if already following user)
    NSInteger UserFollowStatus = self.user.followStatus;

    // Only show confirm dialog if user is not following
    if (UserFollowStatus == 2) {
        CONFIRMFOLLOW(%orig);
    } else {
        return %orig;
    }
}

// Unfollow from profile action sheet
- (void)_performUnfollow {
    SPKConfirmUnfollow(^(void) {
        %orig;
    });
}
%end

// Follow button on discover people page
%hook IGDiscoverPeopleButtonGroupView
- (void)_onFollowButtonTapped:(id)arg1 {
    CONFIRMFOLLOW(%orig);
}
// The Following state of the same button, which ends the follow.
- (void)_onFollowingButtonTapped:(id)arg1 {
    SPKConfirmUnfollow(^(void) {
        %orig;
    });
}
%end

// Suggested for you (home feed & profile) follow button
%hook IGHScrollAYMFCell
- (void)_didTapAYMFActionButton {
    SPKConfirmFollowToggle(SPKUserIsFollowed(SPKFeaturedUserFromOwner(self)), ^(void) {
        %orig;
    });
}
%end
%hook IGHScrollAYMFActionButton
- (void)_didTapTextActionButton {
    SPKConfirmFollowToggle(SPKUserIsFollowed(SPKFeaturedUserFromOwner(self)), ^(void) {
        %orig;
    });
}
%end

// Follow button on reels, which follows and unfollows in place without opening a sheet
%hook IGUnifiedVideoFollowButton
- (void)_hackilyHandleOurOwnButtonTaps:(id)arg1 event:(id)arg2 {
    SPKConfirmFollowToggle(SPKButtonReportsFollowing(self), ^(void) {
        %orig;
    });
}
%end

// Follow text on profile (when collapsed into top bar). Tapping it while already following opens
// the relationship sheet, which confirms its own Unfollow row, so only the follow is prompted here.
%hook IGProfileViewController
- (void)navigationItemsControllerDidTapHeaderFollowButton:(id)arg1 {
    if (SPKUserIsFollowed(SPKObjectForKnownSelector(self, @selector(user)))) {
        return %orig;
    }

    CONFIRMFOLLOW(%orig);
}
%end

// Follow button on suggested friends (in story section)
%hook IGStorySectionController
- (void)followButtonTapped:(id)arg1 cell:(id)arg2 {
    CONFIRMFOLLOW(%orig);
}
%end

// Follow all button in group chats (3+ members) people view
static void (*orig_listSectionController)(id, SEL, id, id);

static void hooked_listSectionController(id self, SEL _cmd, id arg1, id arg2) {
    if ([SPKUtils getBoolPref:@"profile_confirm_follow"]) {

        [SPKUtils
            showConfirmation:^{
                orig_listSectionController(self, _cmd, arg1, arg2);
            }
                       title:SPKL(@"GENERAL_FOLLOW_CONFIRM_CONFIRM_FOLLOW_TEXT")
                     message:SPKL(@"GENERAL_FOLLOW_CONFIRM_FOLLOW_EVERYONE_LIST_CONFIRMATION_MESSAGE")];

        return;
    }

    orig_listSectionController(self, _cmd, arg1, arg2);
}

%end

// Same two entry points as the Objective-C follow controller above, on the Swift class that
// replaced it. Demangled: IGFollowing.IGFollowController. Builds that still ship the
// Objective-C class do not define this one, so the group binds nothing there and vice versa.
%group SPKFollowConfirmSwiftHooks

%hook _TtC11IGFollowing18IGFollowController

// Follow button tapped through a gesture recogniser
- (void)didPressFollowButtonWith:(id)arg1 {
    CONFIRMFOLLOWTAP(%orig);
}

// Follow button tapped as a plain control event
- (void)didPressFollowButtonFromControlEvent {
    CONFIRMFOLLOWTAP(%orig);
}

// Kept for the surfaces that still reach this from Objective-C. On builds where the caller is Swift
// too, the selection hook below is what catches the unfollow.
- (void)performUnfollow {
    SPKConfirmUnfollow(^(void) {
        %orig;
    });
}

%end

%end

////////////////////////////////////////////////////////

// Row identifiers used by the relationship sheet, unchanged from IG 410 through 442:
// 0 close friends, 1 mute, 2 unfollow, 3 restrict, 5 favorites.
static const NSInteger kSPKFollowSheetUnfollowRow = 2;

// The sheet keeps the rows it is showing in an array of boxed row identifiers, which is the only
// description of a row that is not a localized title. Newer builds renamed the backing store when
// the class moved to Swift, so both spellings are tried and the result is type checked before use.
static BOOL SPKFollowSheetRowIsUnfollow(id sectionController, NSInteger index) {
    id rows = [SPKUtils getIvarForObj:sectionController name:"rowValues"];
    if (![rows isKindOfClass:[NSArray class]])
        rows = [SPKUtils getIvarForObj:sectionController name:"_rowValues"];

    if (![rows isKindOfClass:[NSArray class]] || index < 0 || (NSUInteger)index >= [rows count]) {
        SPKLog(@"General", @"[Sparkle] Follow confirm: unreadable relationship sheet rows on %@",
               NSStringFromClass([sectionController class]));
        return NO;
    }

    id value = [rows objectAtIndex:(NSUInteger)index];
    return [value respondsToSelector:@selector(integerValue)] &&
           [value integerValue] == kSPKFollowSheetUnfollowRow;
}

// The list adapter owning a section controller hands out selection changes, so the row is cleared
// through the same context Instagram uses rather than by reaching for the collection view.
static void SPKDeselectSectionControllerRow(id sectionController, NSInteger index) {
    id context = SPKObjectForKnownSelector(sectionController, @selector(collectionContext));
    SEL deselect = @selector(deselectItemAtIndex:sectionController:animated:);
    if (![context respondsToSelector:deselect])
        return;

    ((void (*)(id, SEL, NSInteger, id, BOOL))objc_msgSend)(context, deselect, index, sectionController, NO);
}

// The relationship sheet the profile follow button opens while already following. Selecting its
// Unfollow row runs the unfollow through the follow controller's own internals, which are out of
// reach once that class is Swift, so the selection itself is where the action is confirmed. The list
// adapter driving this callback is Objective-C, so it still dispatches normally.
%group SPKFollowConfirmSheetHooks

// Demangled: IGProfileFollowing.IGProfileFollowActionsSectionController
%hook _TtC18IGProfileFollowing39IGProfileFollowActionsSectionController

- (void)didSelectItemAtIndex:(NSInteger)index {
    if (!SPKFollowSheetRowIsUnfollow(self, index)) {
        return %orig;
    }

    SPKConfirmUnfollowElseRestore(
        ^(void) {
            %orig;
        },
        ^(void) {
            // Clearing the selection is part of what Instagram's own handler does, so declining the
            // prompt has to do it instead or the row stays highlighted behind the dismissed alert.
            SPKDeselectSectionControllerRow(self, index);
        });
}

%end

%end

static void SPKInstallFollowAllConfirmHook(void) {
    Class cls = objc_getClass("IGDirectDetailMembersKit.IGDirectThreadDetailsMembersListViewController");
    if (!cls)
        return;

    MSHookMessageEx(
        cls,
        @selector(listSectionController:didTapHeaderButtonWithViewModel:),
        (IMP)hooked_listSectionController,
        (IMP *)&orig_listSectionController);
}

void SPKInstallFollowConfirmHooksIfNeeded(void) {
    if (![SPKUtils getBoolPref:@"profile_confirm_follow"] && ![SPKUtils getBoolPref:@"profile_confirm_unfollow"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKFollowConfirmHooks);
        %init(SPKFollowConfirmSwiftHooks);
        %init(SPKFollowConfirmSheetHooks);
        SPKInstallFollowAllConfirmHook();
    });
}
