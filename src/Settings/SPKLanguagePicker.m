#import "SPKStrings.h"
#import "SPKLanguagePicker.h"
#import "SPKLanguagePack.h"
#import "SPKSetting.h"
#import "SPKSettingsViewController.h"
#import "SPKTopicSettingsSupport.h"
#import "../AssetUtils.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Utils.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Names the translation issue form. A bare issues/new carries a title but lands
// on the template chooser, because blank issues are disabled for this repository.
static NSString *const kSPKTranslationIssueURL =
    @"https://github.com/efibalogh/sparkle-ig/issues/new?template=3-translation.yaml";
static NSString *const kSPKTranslationGuideURL = @"https://github.com/efibalogh/sparkle-ig/blob/main/TRANSLATING.md";

/// The issue form's Language field, prefilled with the language being read right
/// now. Left empty for English, where the report is as likely to be about some
/// other language as about the text on screen.
static NSString *SPKTranslationIssueURLString(void) {
    NSString *active = [SPKStrings activeLanguage];
    if (active.length == 0 || [active isEqualToString:@"en"])
        return kSPKTranslationIssueURL;
    NSString *encoded = [active stringByAddingPercentEncodingWithAllowedCharacters:
                                    NSCharacterSet.URLQueryAllowedCharacterSet]
                        ?: active;
    return [NSString stringWithFormat:@"%@&language=%@", kSPKTranslationIssueURL, encoded];
}

// Endonyms (each language's own name) — best UX for a language picker. Covers the
// languages a community catalog exists for; an imported pack naming any other
// language falls back to what the system calls it.
static NSDictionary<NSString *, NSString *> *SPKLangNames(void) {
    static NSDictionary *m = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ m = @{
        @"en":@"English", @"ar":@"العربية", @"de":@"Deutsch", @"el":@"Ελληνικά",
        @"es-ES":@"Español", @"fr":@"Français", @"hi":@"हिन्दी", @"it":@"Italiano",
        @"ja":@"日本語", @"ko":@"한국어", @"lt":@"Lietuvių", @"pt-BR":@"Português (Brasil)", @"ru":@"Русский",
        @"ro":@"Română",
        @"tr":@"Türkçe", @"uk":@"Українська", @"vi":@"Tiếng Việt", @"zh-Hans":@"简体中文" }; });
    return m;
}

NSString *SPKLanguageDisplayName(NSString *code) {
    if (code.length == 0 || [code isEqualToString:@"auto"]) return SPKL(@"LANGUAGE_SYSTEM_DEFAULT");
    NSString *known = SPKLangNames()[code];
    if (known)
        return known;
    // Ask the language to name itself, so an imported pack for a language Sparkle
    // has never shipped still reads naturally to the person who installed it.
    NSString *endonym = [[NSLocale localeWithLocaleIdentifier:code] localizedStringForLocaleIdentifier:code];
    return endonym.length > 0 ? endonym : code;
}

@interface SPKLanguagePickerViewController : SPKSettingsViewController <UIDocumentPickerDelegate>

@property (nonatomic, copy) NSArray<NSString *> *languageCodes;
@property (nonatomic, copy) NSArray<SPKLanguagePack *> *installedPacks;
// Held for the lifetime of the presentation: UIDocumentPickerViewController keeps
// its delegate weakly, so nothing else retains us as the delegate while it is up.
@property (nonatomic, strong, nullable) UIDocumentPickerViewController *activePicker;
/// Archives from one pick, imported after the picker is off screen so anything
/// this reports is presented by a sheet that is actually on screen.
@property (nonatomic, strong, nullable) NSMutableArray<NSURL *> *pendingImportURLs;

@end

@implementation SPKLanguagePickerViewController

- (instancetype)init {
    self = [super initWithTitle:SPKL(@"LANGUAGE_TITLE") sections:@[] reduceMargin:NO];
    if (self) {
        [self reloadLanguages];
    }
    return self;
}

// A safety net, not the main path. The document picker presents as a page sheet,
// which leaves this view in the hierarchy and so fires no appearance callbacks
// when it goes away; the picker's own dismissal completion drives the import.
// Taking the queue is atomic, so being called from both is harmless.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingImportURLs.count > 0)
        [self importPendingArchives];
}

- (void)reloadLanguages {
    self.installedPacks = [SPKLanguagePackManager installedPacks];
    NSArray<NSString *> *languages = [SPKStrings supportedLanguages];
    // Following the system is only a choice when there is something else to
    // follow it to. With English alone installed, the row would be a second name
    // for the only row beneath it.
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    if (languages.count > 1)
        [codes addObject:@"auto"];
    [codes addObjectsFromArray:languages];
    self.languageCodes = [codes copy];
    [self rebuildSections];
}

/// The row to show as chosen. Without an override Sparkle follows the system, but
/// while that row is hidden the language it resolves to is the one to check.
- (NSString *)selectedLanguageCode {
    NSString *override = [SPKStrings languageOverride];
    if (override.length > 0)
        return override;
    return [self.languageCodes containsObject:@"auto"] ? @"auto" : @"en";
}

- (nullable SPKLanguagePack *)packForCode:(NSString *)code {
    for (SPKLanguagePack *pack in self.installedPacks) {
        if ([pack.code isEqualToString:code])
            return pack;
    }
    return nil;
}

- (void)rebuildSections {
    NSString *selected = [self selectedLanguageCode];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<SPKSetting *> *languageRows = [NSMutableArray arrayWithCapacity:self.languageCodes.count];
    for (NSString *code in self.languageCodes) {
        BOOL isSelected = [selected isEqualToString:code];
        SPKLanguagePack *pack = [self packForCode:code];
        NSString *subtitle = pack ? [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_COVERAGE_SUBTITLE_FORMAT"),
                                                               (long)pack.coveragePercent]
                                  : nil;
        SPKSetting *row = [SPKSetting buttonCellWithTitle:SPKLanguageDisplayName(code)
                                                 subtitle:subtitle
                                                     icon:nil
                                                   action:^{
                                                       [weakSelf selectLanguageCode:code];
                                                   }];
        NSMutableDictionary *userInfo = [@{
            @"languageCode" : code,
            @"checkmarked" : @(isSelected),
            @"hidesDisclosure" : @(YES),
        } mutableCopy];
        if (pack)
            userInfo[@"pack"] = pack;
        row.userInfo = userInfo;
        [languageRows addObject:row];
    }

    SPKSetting *importRow = [SPKSetting buttonCellWithTitle:SPKL(@"LANGUAGE_PACK_IMPORT_TITLE")
                                                   subtitle:SPKL(@"LANGUAGE_PACK_IMPORT_SUBTITLE")
                                                       icon:SPKSettingsIcon(@"plus")
                                                     action:^{
                                                         [weakSelf presentImportPicker];
                                                     }];
    SPKSetting *exportRow = [SPKSetting buttonCellWithTitle:SPKL(@"LANGUAGE_PACK_EXPORT_TITLE")
                                                   subtitle:SPKL(@"LANGUAGE_PACK_EXPORT_SUBTITLE")
                                                       icon:SPKSettingsIcon(@"share")
                                                     action:^{
                                                         [weakSelf exportTemplate];
                                                     }];

    // Reporting and contributing are different jobs with different destinations:
    // one fills in a form, the other opens the guide that needs no build.
    SPKSetting *reportRow = [SPKSetting linkCellWithTitle:SPKL(@"LANGUAGE_REPORT_ISSUE_TITLE")
                                                 subtitle:SPKL(@"LANGUAGE_REPORT_ISSUE_SUBTITLE")
                                                     icon:SPKSettingsIcon(@"flag")
                                                      url:SPKTranslationIssueURLString()];
    SPKSetting *contributeRow = [SPKSetting linkCellWithTitle:SPKL(@"LANGUAGE_CONTRIBUTE_TITLE")
                                                     subtitle:SPKL(@"LANGUAGE_CONTRIBUTE_SUBTITLE")
                                                         icon:SPKSettingsIcon(@"translate")
                                                          url:kSPKTranslationGuideURL];
    [self replaceSections:@[
        SPKTopicSection(@"", languageRows, SPKL(@"LANGUAGE_LIST_FOOTER")),
        SPKTopicSection(SPKL(@"LANGUAGE_PACKS_HEADER"), @[ importRow, exportRow ], nil),
        SPKTopicSection(@"", @[ reportRow, contributeRow ], SPKL(@"LANGUAGE_HELP_FOOTER")),
    ]];
}

- (void)selectLanguageCode:(NSString *)code {
    if ([[self selectedLanguageCode] isEqualToString:code]) {
        return;
    }
    [self applyLanguageCode:code];
}

- (void)applyLanguageCode:(NSString *)code {
    [SPKStrings setLanguageOverride:[code isEqualToString:@"auto"] ? nil : code];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self rebuildSections];
    [self dismissViewControllerAnimated:YES completion:^{
        [SPKUtils showRestartConfirmation];
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    if (row.userInfo[@"languageCode"]) {
        if ([row.userInfo[@"checkmarked"] boolValue]) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:@"circle_check_filled"
                                                      pointSize:24.0
                                                  renderingMode:UIImageRenderingModeAlwaysTemplate];
            UIImageView *checkmark = [[UIImageView alloc] initWithImage:image];
            checkmark.tintColor = [SPKUtils SPKColor_InstagramBlue];
            cell.accessoryView = checkmark;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    return cell;
}

#pragma mark - Deleting a pack

- (nullable SPKLanguagePack *)packAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count)
        return nil;
    NSArray<SPKSetting *> *rows = self.sections[indexPath.section][@"rows"];
    if (indexPath.row >= (NSInteger)rows.count)
        return nil;
    id pack = rows[indexPath.row].userInfo[@"pack"];
    return [pack isKindOfClass:[SPKLanguagePack class]] ? pack : nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self packAtIndexPath:indexPath] != nil;
}

// The base returns None for every row, which suppresses swipe-to-delete outright --
// canEditRowAtIndexPath: alone is not enough to bring it back.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self packAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

// The system's own delete button would be a red bar reading "Delete"; every other
// Sparkle list deletes through a trash glyph on Instagram's destructive red.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKLanguagePack *pack = [self packAtIndexPath:indexPath];
    if (!pack)
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:nil
                                              handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
                                                  [weakSelf deletePack:pack];
                                                  completionHandler(YES);
                                              }];
    deleteAction.image = [SPKAssetUtils menuIconNamed:@"trash"];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"LANGUAGE_PACK_DELETE_ACCESSIBILITY_LABEL");
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    [self deletePack:[self packAtIndexPath:indexPath]];
}

- (void)deletePack:(SPKLanguagePack *)pack {
    if (!pack)
        return;

    BOOL wasActive = [[SPKStrings languageOverride] isEqualToString:pack.code];
    NSError *error = nil;
    if (![SPKLanguagePackManager removePack:pack error:&error]) {
        [self presentErrorWithTitle:SPKL(@"LANGUAGE_PACK_DELETE_ERROR_TITLE") message:error.localizedDescription];
        return;
    }

    [self reloadLanguages];
    // The interface is still rendered in the language that just went away.
    if (wasActive) {
        [NSUserDefaults.standardUserDefaults synchronize];
        [SPKUtils showRestartConfirmation];
    }
}

#pragma mark - Import and export

- (void)presentImportPicker {
    // Zip only. A folder cannot be selected in the Files browser once file types
    // are on offer, and a picked catalog file is copied out of its folder before
    // it arrives, losing the .lproj that says what language it is. An archive is
    // the one shape that survives the trip intact.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP ] asCopy:YES];
    picker.delegate = self;
    // Several languages can be installed in one go.
    picker.allowsMultipleSelection = YES;
    // UIKit dims files that do not conform to the requested type rather than
    // hiding them, and offers no way to filter them out, so showing extensions is
    // the only thing that makes the pickable archives obvious at a glance.
    picker.shouldShowFileExtensions = YES;
    self.activePicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.activePicker = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    self.activePicker = nil;
    if (urls.count == 0)
        return;

    SPKLog(@"i18n", @"Picked %lu language pack archive(s)", (unsigned long)urls.count);
    self.pendingImportURLs = [urls mutableCopy];

    // Importing here would work, but reporting a failure or switching language
    // would not: an alert raised now is presented into a picker that is on its
    // way out, and dismissing this sheet would dismiss the picker instead. So
    // dismiss the picker explicitly and act once it has actually gone. Its own
    // automatic dismissal offers no completion to hang this on.
    __weak typeof(self) weakSelf = self;
    UIViewController *presented = self.presentedViewController ?: controller;
    if (presented.presentingViewController) {
        [presented dismissViewControllerAnimated:YES
                                      completion:^{
                                          [weakSelf importPendingArchives];
                                      }];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf importPendingArchives];
    });
}

- (void)importPendingArchives {
    NSArray<NSURL *> *urls = self.pendingImportURLs;
    self.pendingImportURLs = nil;
    if (urls.count == 0)
        return;

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSError *error = nil;
        SPKLanguagePack *pack = [SPKLanguagePackManager importPackAtURL:url error:&error];
        if (!pack) {
            SPKWarnLog(@"i18n", @"Language pack import failed for %@: %@", url.lastPathComponent, error);
            [failures addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent,
                                                           error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_ERROR_GENERIC")]];
        }
    }

    // Installing a pack makes a language available; it does not choose it. The
    // new rows appear in the list above and switching stays an explicit tap,
    // which also keeps importing several at once from meaning anything arbitrary.
    [self reloadLanguages];

    if (failures.count > 0) {
        [self presentErrorWithTitle:SPKL(@"LANGUAGE_PACK_IMPORT_ERROR_TITLE")
                            message:[failures componentsJoinedByString:@"\n"]];
    }
}

- (void)exportTemplate {
    NSError *error = nil;
    NSString *archive = [SPKLanguagePackManager exportArchiveForLanguage:@"en" error:&error];
    if (archive.length == 0) {
        [self presentErrorWithTitle:SPKL(@"LANGUAGE_PACK_EXPORT_ERROR_TITLE") message:error.localizedDescription];
        return;
    }

    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:archive] ]
                                         applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)presentErrorWithTitle:(NSString *)title message:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:title
                                                message:message.length > 0 ? message : SPKL(@"LANGUAGE_PACK_ERROR_GENERIC")
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

@end

void SPKPresentLanguagePicker(UIViewController *presenter) {
    if (!presenter) {
        return;
    }
    SPKLanguagePickerViewController *picker = [SPKLanguagePickerViewController new];
    UINavigationController *navigationController = [[SPKChromeNavigationController alloc] initWithRootViewController:picker];
    navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = navigationController.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    }
    [presenter presentViewController:navigationController animated:YES completion:nil];
}
