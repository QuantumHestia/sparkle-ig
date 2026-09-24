//  SPKLanguagePackAddFlow.m

#import "SPKLanguagePackAddFlow.h"
#import "SPKLanguagePackURLImporter.h"
#import "SPKLanguageCatalogViewController.h"
#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "../../Settings/SPKLanguagePicker.h"   // SPKLanguageDisplayName

@implementation SPKLanguagePackAddFlow

+ (void)presentURLPromptFrom:(UIViewController *)presenter
                    onImport:(nullable void (^)(NSString *))onImport {
    if (!presenter) return;
    // Instagram's own text-input alert, so the one place Sparkle asks for a URL looks like every
    // other prompt in the app rather than a stock UIAlertController.
    //
    // Deliberately NOT seeding the field from UIPasteboard: reading .string fires the system
    // "<App> pasted from …" banner unprompted, and would let whatever is on the clipboard become the
    // download URL. The user pastes with the normal keyboard affordance instead.
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:presenter
                                                           title:SPKL(@"LANGUAGE_PACK_URL_PROMPT_TITLE")
                                                         message:SPKL(@"LANGUAGE_PACK_URL_PROMPT_MESSAGE")
                                                     placeholder:SPKL(@"LANGUAGE_PACK_URL_PROMPT_PLACEHOLDER")
                                                     initialText:nil
                                                 autocapitalized:NO
                                                    confirmTitle:SPKL(@"ALERT_ACTION_INSTALL")
                                                     cancelTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *url = trimmed.length ? [NSURL URLWithString:trimmed] : nil;
        [self downloadURL:url from:presenter onImport:onImport];
    }
                                                     cancelBlock:nil];
}

+ (void)downloadURL:(NSURL *)url from:(UIViewController *)presenter onImport:(nullable void (^)(NSString *))onImport {
    if (!url) {  // e.g. the pasted text wasn't a URL at all
        [self presentError:SPKL(@"LANGUAGE_PACK_URL_INVALID") from:presenter];
        return;
    }
    __weak UIViewController *weakPresenter = presenter;
    __block SPKLanguagePackURLImporter *importer = nil;
    __block BOOL cancelledByUser = NO;
    // A progress pill rather than a modal alert: downloading a pack is background work, and blocking
    // the screen behind a dialog for it means the user cannot keep reading the settings underneath.
    // The pill also owns its own Cancel, so there is no second dismissal to sequence against.
    SPKNotificationPillView *pill = SPKNotifyProgress(kSPKNotificationLanguagePackUpdate,
                                                      SPKL(@"LANGUAGE_PACK_DOWNLOADING"),
                                                      ^{
        cancelledByUser = YES;
        [importer cancel];
    });
    importer = [SPKLanguagePackURLImporter importFromURL:url
                                          expectedSHA256:nil
                                                progress:^(double fraction) {
        [pill setProgress:(float)fraction animated:YES];
    }
                                              completion:^(SPKLanguagePack *pack, NSError *error) {
        [pill dismiss];
        // Domain-qualified: a code 7 from importPackAtURL:'s own error domain must NOT be mistaken
        // for our Cancelled and silently swallow a real failure.
        BOOL wasCancel = [error.domain isEqualToString:SPKLanguagePackURLImportErrorDomain]
                         && error.code == SPKLanguagePackURLImportErrorCancelled;
        if (pack) {
            SPKNotify(kSPKNotificationLanguagePackUpdate, SPKL(@"LANGUAGE_PACK_INSTALLED_TOAST"),
                      SPKLanguageDisplayName(pack.code), @"translate",
                      SPKNotificationToneForIconResource(@"translate"));
            if (onImport) onImport(pack.code);
            return;
        }
        if (cancelledByUser || wasCancel) return;
        UIViewController *strongPresenter = weakPresenter;
        if (strongPresenter)
            [self presentError:(error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED")) from:strongPresenter];
    }];
}

+ (void)presentCatalogFrom:(UIViewController *)presenter onImport:(nullable void (^)(NSString *))onImport {
    if (!presenter) return;
    SPKLanguageCatalogViewController *catalog = [SPKLanguageCatalogViewController new];
    catalog.onInstall = onImport;
    if (presenter.navigationController) {
        [presenter.navigationController pushViewController:catalog animated:YES];
        return;
    }
    // Standing on its own it is still a Sparkle sheet, so it wears Sparkle's chrome rather than a
    // bare navigation bar. This path only runs if the caller was presented without one.
    SPKChromeNavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:catalog];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    catalog.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:catalog
                                                      action:@selector(dismissCatalog)];
    [presenter presentViewController:nav animated:YES completion:nil];
}

+ (void)presentError:(NSString *)message from:(UIViewController *)presenter {
    [SPKIGAlertPresenter presentAlertFromViewController:presenter
                                                  title:SPKL(@"LANGUAGE_PACK_IMPORT_ERROR_TITLE")
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

@end
