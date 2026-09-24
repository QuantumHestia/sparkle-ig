#import "SPKStrings.h"
#import <UIKit/UIKit.h>

#import "../../Utils.h"
#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"

static NSString *const kSPKInstantsConfirmReactionPref = @"instants_confirm_reaction";

static BOOL SPKInstantsConfirmReactionEnabled(void) {
    return [SPKUtils getBoolPref:kSPKInstantsConfirmReactionPref];
}

static BOOL SPKInstantsResponderChainContainsQuickSnap(UIResponder *responder) {
    UIResponder *current = responder;
    while (current) {
        if ([NSStringFromClass(current.class) containsString:@"QuickSnap"])
            return YES;
        current = current.nextResponder;
    }
    return NO;
}

static NSString *SPKInstantsControlText(UIControl *control) {
    if (!control)
        return nil;
    id text = nil;
    @try {
        text = SPKKVCObject(control, @"text");
    } @catch (__unused NSException *exception) {
    }
    if ([text isKindOfClass:NSString.class])
        return text;
    return control.accessibilityLabel;
}

static BOOL SPKInstantsLooksLikeEmojiText(NSString *text) {
    if (text.length == 0 || text.length > 16)
        return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9')) {
            return NO;
        }
    }
    return YES;
}

%group SPKInstantsReactionConfirmHooks

%hook IGBouncyTextButton
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (!sel_isEqual(action, @selector(didTapToReact:)) ||
        !SPKInstantsConfirmReactionEnabled() ||
        !SPKInstantsResponderChainContainsQuickSnap((UIResponder *)self) ||
        !SPKInstantsLooksLikeEmojiText(SPKInstantsControlText((UIControl *)self))) {
        %orig;
        return;
    }

    [SPKUtils
        showConfirmation:^{
            %orig;
        }
                   title:SPKL(@"INSTANTS_CONFIRMATION_CONFIRM_INSTANT_REACTION_TITLE")
                 message:SPKL(@"INSTANTS_INSTANTS_REACTION_CONFIRM_REACT_INSTANT_CONFIRMATION_MESSAGE")];
}
%end

%end

extern "C" void SPKInstallInstantsReactionConfirmHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKInstantsReactionConfirmHooks);
        SPKLog(@"Instants", @"[Sparkle] Instants reaction confirm hooks installed");
    });
}
