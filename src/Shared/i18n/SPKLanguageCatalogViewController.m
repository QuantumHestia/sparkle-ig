//  SPKLanguageCatalogViewController.m

#import "SPKLanguageCatalogViewController.h"
#import "SPKLanguagePackCatalog.h"
#import "SPKLanguagePackURLImporter.h"
#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../../Utils.h"
#import "../../AssetUtils.h"   // SPKAssetUtils (menuIconNamed:) — separate from Utils.h
#import "../../Settings/SPKSetting.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "SPKLanguagePackAddFlow.h"
#import "../../Settings/SPKLanguagePicker.h"   // SPKLanguageDisplayName
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, SPKCatalogState) { SPKCatalogLoading, SPKCatalogLoaded, SPKCatalogFailed };

// What tapping a row would do. Installed-and-current rows stay listed rather than being filtered
// out: a catalog that silently omitted them would read as "your language isn't published", and the
// coverage figure next to an installed language is the answer to "is it worth switching to yet".
typedef NS_ENUM(NSInteger, SPKCatalogRowAction) { SPKCatalogRowInstall, SPKCatalogRowUpdate, SPKCatalogRowCurrent };

@interface SPKLanguageCatalogViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<SPKLanguageCatalogEntry *> *entries;
@property (nonatomic, strong) NSMutableSet<NSString *> *installingCodes;  // one tap at a time per row
@property (nonatomic, strong, nullable) SPKLanguagePackURLImporter *activeImporter;  // re-tap busy row to cancel
@property (nonatomic, assign) SPKCatalogState state;
@property (nonatomic, copy, nullable) NSString *failureMessage;
// Held for the lifetime of the presentation: UIDocumentPickerViewController keeps its delegate
// weakly, so nothing else retains us as the delegate while it is up.
@property (nonatomic, strong, nullable) UIDocumentPickerViewController *activePicker;
/// Archives from one pick, imported after the picker is off screen so anything this reports is
/// presented by a screen that is actually on screen.
@property (nonatomic, strong, nullable) NSMutableArray<NSURL *> *pendingImportURLs;
@end

@implementation SPKLanguageCatalogViewController

- (instancetype)init {
    // Built on Sparkle's own settings controller rather than a bare table: the row metrics, grouped
    // background, separators and cell styling then come from the same place as every other Sparkle
    // screen, instead of being re-specified here and drifting from them.
    self = [super initWithTitle:SPKL(@"LANGUAGE_PACK_ADD_TITLE") sections:@[] reduceMargin:NO];
    if (self) {
        _installingCodes = [NSMutableSet set];
        _state = SPKCatalogLoading;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self rebuildSections];
    [self reload];
}

// The base class rebuilds the whole trailing group in viewWillAppear:, so anything set once in
// viewDidLoad is wiped before the screen is ever shown. This is the override point it exposes for
// exactly that: let it place its own items, then add ours after them.
- (void)setupNavigationItems {
    [super setupNavigationItems];
    // Read back whatever the base class just placed. It stores the group under trailingItemGroups on
    // iOS 16+ and clears rightBarButtonItems while doing so, so both have to be consulted or ours
    // would replace its items instead of following them.
    NSMutableArray<UIBarButtonItem *> *trailing = [NSMutableArray array];
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in self.navigationItem.trailingItemGroups)
            [trailing addObjectsFromArray:group.barButtonItems ?: @[]];
    }
    if (trailing.count == 0)
        [trailing addObjectsFromArray:self.navigationItem.rightBarButtonItems ?: @[]];
    // More is always rightmost, matching the deleted-messages and downloads screens.
    [trailing addObject:SPKMediaChromeTopBarMenuButtonItem(@"more", [self moreMenu],
                                                            SPKL(@"LANGUAGE_PACK_MORE_ACCESSIBILITY_LABEL"))];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, trailing);
}

// A page sheet leaves this view in the hierarchy, so it fires no appearance callbacks when the
// document picker goes away; the picker's own dismissal completion drives the import. Taking the
// queue is atomic, so being called from both is harmless.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingImportURLs.count > 0)
        [self importPendingArchives];
}

#pragma mark - More menu

- (UIMenu *)moreMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *filesAction = [UIAction actionWithTitle:SPKL(@"LANGUAGE_PACK_IMPORT_TITLE")
                                                image:[SPKAssetUtils menuIconNamed:@"folder"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) { [weakSelf presentImportPicker]; }];
    UIAction *linkAction = [UIAction actionWithTitle:SPKL(@"LANGUAGE_PACK_IMPORT_URL_TITLE")
                                               image:[SPKAssetUtils menuIconNamed:@"link"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) { [weakSelf presentURLImport]; }];
    UIAction *exportAction = [UIAction actionWithTitle:SPKL(@"LANGUAGE_PACK_EXPORT_TITLE")
                                                 image:[SPKAssetUtils menuIconNamed:@"share"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) { [weakSelf exportTemplate]; }];
    // Exporting starts a translation rather than installing one, so it sits in its own group.
    UIMenu *exportSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                          options:UIMenuOptionsDisplayInline children:@[ exportAction ]];
    return [UIMenu menuWithTitle:@"" children:@[ filesAction, linkAction, exportSection ]];
}

- (void)presentURLImport {
    __weak typeof(self) weakSelf = self;
    [SPKLanguagePackAddFlow presentURLPromptFrom:self
                                        onImport:^(NSString *code) { [weakSelf didInstallCode:code]; }];
}

#pragma mark - Importing from Files

- (void)presentImportPicker {
    // Zip only. A folder cannot be selected in the Files browser once file types are on offer, and a
    // picked catalog file is copied out of its folder before it arrives, losing the .lproj that says
    // what language it is. An archive is the one shape that survives the trip intact.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP ] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;   // several languages in one go
    // UIKit dims files that do not conform to the requested type rather than hiding them, so showing
    // extensions is the only thing that makes the pickable archives obvious at a glance.
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

    // Importing here would work, but reporting a failure would not: an alert raised now is presented
    // into a picker on its way out. Dismiss it explicitly and act once it has actually gone; its own
    // automatic dismissal offers no completion to hang this on.
    __weak typeof(self) weakSelf = self;
    UIViewController *presented = self.presentedViewController ?: controller;
    if (presented.presentingViewController) {
        [presented dismissViewControllerAnimated:YES completion:^{ [weakSelf importPendingArchives]; }];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf importPendingArchives]; });
}

- (void)importPendingArchives {
    NSArray<NSURL *> *urls = self.pendingImportURLs;
    self.pendingImportURLs = nil;
    if (urls.count == 0)
        return;

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSError *error = nil;
        SPKLanguagePack *pack = [SPKLanguagePackManager importPackAtURL:url error:&error];
        if (pack) {
            [installed addObject:SPKLanguageDisplayName(pack.code)];
            if (self.onInstall) self.onInstall(pack.code);
        } else {
            SPKWarnLog(@"i18n", @"Language pack import failed for %@: %@", url.lastPathComponent, error);
            [failures addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent,
                                                            error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_ERROR_GENERIC")]];
        }
    }
    if (installed.count > 0) {
        SPKNotify(kSPKNotificationLanguagePackUpdate, SPKL(@"LANGUAGE_PACK_INSTALLED_TOAST"),
                  [installed componentsJoinedByString:SPKL(@"COMMON_LIST_SEPARATOR")], @"translate",
                  SPKNotificationToneForIconResource(@"translate"));
    }
    [self rebuildSections];  // an imported language may now be listed as installed
    if (failures.count > 0)
        [self presentError:[failures componentsJoinedByString:@"\n"]];
}

- (void)exportTemplate {
    NSError *error = nil;
    NSString *archive = [SPKLanguagePackManager exportArchiveForLanguage:@"en" error:&error];
    if (archive.length == 0) {
        // Exporting failed, so the alert must not claim an import did.
        [self presentError:error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_ERROR_GENERIC")
                     title:SPKL(@"LANGUAGE_PACK_EXPORT_ERROR_TITLE")];
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

/// Shared by every route that ends with a pack on disk.
- (void)didInstallCode:(NSString *)code {
    if (self.onInstall) self.onInstall(code);
    [self rebuildSections];
}

- (void)reload {
    self.state = SPKCatalogLoading;
    [self rebuildSections];
    __weak typeof(self) weakSelf = self;
    [SPKLanguagePackCatalog fetchEntriesWithCompletion:^(NSArray<SPKLanguageCatalogEntry *> *entries, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!entries) {
            self.state = SPKCatalogFailed;
            self.failureMessage = error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_CATALOG_ERROR");
        } else {
            self.entries = [self sortedForDisplay:entries];
            self.state = SPKCatalogLoaded;
        }
        [self rebuildSections];
    }];
}

#pragma mark - Row state

/// The installed pack for `code`, matched case-insensitively because a catalog's spelling of a code
/// need not match the folder name the archive happened to carry.
- (nullable NSString *)installedCodeMatching:(NSString *)code {
    for (NSString *installed in SPKInstalledLanguagePackCodes()) {
        if ([installed caseInsensitiveCompare:code] == NSOrderedSame)
            return installed;
    }
    return nil;
}

- (SPKCatalogRowAction)actionForEntry:(SPKLanguageCatalogEntry *)entry {
    NSString *installed = [self installedCodeMatching:entry.code];
    if (!installed)
        return SPKCatalogRowInstall;
    NSString *recorded = SPKLanguagePackRecordedSHA256(installed);
    // No recorded hash means the pack came from a file the user chose. Offering to replace it with a
    // published build would quietly discard a translation in progress, so it reads as current.
    if (recorded.length && entry.sha256.length && ![recorded isEqualToString:entry.sha256])
        return SPKCatalogRowUpdate;
    return SPKCatalogRowCurrent;
}

/// Anything actionable first, so the reason to have opened this screen is at the top.
- (NSArray<SPKLanguageCatalogEntry *> *)sortedForDisplay:(NSArray<SPKLanguageCatalogEntry *> *)entries {
    __weak typeof(self) weakSelf = self;
    return [entries sortedArrayUsingComparator:^NSComparisonResult(SPKLanguageCatalogEntry *a, SPKLanguageCatalogEntry *b) {
        NSInteger rankA = [weakSelf rankForEntry:a], rankB = [weakSelf rankForEntry:b];
        if (rankA != rankB)
            return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
}

- (NSInteger)rankForEntry:(SPKLanguageCatalogEntry *)entry {
    switch ([self actionForEntry:entry]) {
        case SPKCatalogRowUpdate:  return 0;
        case SPKCatalogRowInstall: return 1;
        case SPKCatalogRowCurrent: return 2;
    }
}

#pragma mark - Sections

- (void)rebuildSections {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];

    if (self.state == SPKCatalogLoading) {
        SPKSetting *row = [SPKSetting staticCellWithTitle:SPKL(@"LANGUAGE_PACK_CATALOG_LOADING") subtitle:@"" icon:nil];
        row.userInfo = @{ @"spinner" : @(YES), @"hidesDisclosure" : @(YES) };
        [rows addObject:row];
    } else if (self.state == SPKCatalogFailed) {
        SPKSetting *row = [SPKSetting buttonCellWithTitle:self.failureMessage
                                                 subtitle:SPKL(@"LANGUAGE_PACK_CATALOG_RETRY_SUBTITLE")
                                                     icon:nil
                                                   action:^{ [weakSelf reload]; }];
        row.userInfo = @{ @"hidesDisclosure" : @(YES) };
        [rows addObject:row];
    } else if (self.entries.count == 0) {
        SPKSetting *row = [SPKSetting staticCellWithTitle:SPKL(@"LANGUAGE_PACK_CATALOG_EMPTY") subtitle:@"" icon:nil];
        row.userInfo = @{ @"hidesDisclosure" : @(YES) };
        [rows addObject:row];
    } else {
        // Installed languages sit in their own section so the list below stays a list of what the
        // user can still add. They keep their rank order within it, which puts anything with an
        // update waiting above the ones that are already current.
        NSMutableArray<SPKSetting *> *installedRows = [NSMutableArray array];
        for (SPKLanguageCatalogEntry *entry in self.entries) {
            SPKSetting *row = [self rowForEntry:entry];
            [([self actionForEntry:entry] == SPKCatalogRowInstall ? rows : installedRows) addObject:row];
        }
        if (installedRows.count > 0) {
            NSArray<NSDictionary *> *sections = @[
                SPKTopicSection(SPKL(@"LANGUAGE_PACK_CATALOG_INSTALLED_HEADER"), installedRows, nil),
                // The footer explains what installing does, so it belongs to the section that still
                // offers it. With everything installed there is no such section, and it would be
                // describing an action the screen no longer presents.
                SPKTopicSection(SPKL(@"LANGUAGE_PACK_CATALOG_AVAILABLE_HEADER"), rows, SPKL(@"LANGUAGE_PACK_CATALOG_FOOTER")),
            ];
            [self replaceSections:rows.count > 0 ? sections : @[ sections.firstObject ]];
            return;
        }
    }

    [self replaceSections:@[ SPKTopicSection(@"", rows, SPKL(@"LANGUAGE_PACK_CATALOG_FOOTER")) ]];
}

- (SPKSetting *)rowForEntry:(SPKLanguageCatalogEntry *)entry {
    SPKCatalogRowAction action = [self actionForEntry:entry];
    BOOL installing = [self.installingCodes containsObject:entry.code];
    NSString *subtitle;
    switch (action) {
        case SPKCatalogRowUpdate:  subtitle = SPKL(@"LANGUAGE_PACK_UPDATE_AVAILABLE_SUBTITLE"); break;
        case SPKCatalogRowCurrent: subtitle = SPKL(@"LANGUAGE_PACK_INSTALLED_SUBTITLE"); break;
        case SPKCatalogRowInstall:
            subtitle = [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_COVERAGE_SUBTITLE_FORMAT"), (long)entry.coverage];
            break;
    }

    __weak typeof(self) weakSelf = self;
    SPKSetting *row;
    if (action == SPKCatalogRowCurrent) {
        // Nothing to do, so it is not a button. The check mark carries the state; no leading glyph,
        // matching the language list this screen installs into.
        row = [SPKSetting staticCellWithTitle:entry.displayName subtitle:subtitle icon:nil];
    } else {
        row = [SPKSetting buttonCellWithTitle:entry.displayName
                                     subtitle:subtitle
                                         icon:nil
                                       action:^{ [weakSelf tapEntry:entry]; }];
    }
    row.userInfo = @{
        @"catalogCode" : entry.code,
        @"checkmarked" : @(action == SPKCatalogRowCurrent && !installing),
        @"spinner" : @(installing),
        @"dimmed" : @(self.installingCodes.count > 0 && !installing),
        @"hidesDisclosure" : @(YES),
    };
    return row;
}

// The check mark and the in-flight spinner are the only things the shared cell cannot express, so
// they are the only things overridden here. Every other attribute stays with the base class.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    NSArray<SPKSetting *> *rows = self.sections[indexPath.section][@"rows"];
    if (indexPath.row >= (NSInteger)rows.count)
        return cell;
    NSDictionary *info = rows[indexPath.row].userInfo;

    if ([info[@"spinner"] boolValue]) {
        UIActivityIndicatorView *spinner =
            [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else if ([info[@"checkmarked"] boolValue]) {
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

    // One install at a time, so the rows that would no-op read as unavailable rather than broken.
    CGFloat alpha = [info[@"dimmed"] boolValue] ? 0.5 : 1.0;
    cell.textLabel.alpha = alpha;
    cell.detailTextLabel.alpha = alpha;
    return cell;
}

#pragma mark - Installing

- (void)tapEntry:(SPKLanguageCatalogEntry *)entry {
    if ([self.installingCodes containsObject:entry.code]) {  // re-tap the busy row → abort that install
        [self.activeImporter cancel];
        return;
    }
    if (self.installingCodes.count > 0)
        return;  // a different install is running — one at a time

    [self.installingCodes addObject:entry.code];
    [self rebuildSections];  // rebuild ALL rows so the others pick up the busy state

    __weak typeof(self) weakSelf = self;
    void (^onInstall)(NSString *) = self.onInstall;  // captured strongly: still fires if the VC is dismissed mid-install
    BOOL wasUpdate = ([self actionForEntry:entry] == SPKCatalogRowUpdate);
    self.activeImporter = [SPKLanguagePackURLImporter importFromURL:entry.url
                              expectedSHA256:entry.sha256
                                    progress:nil
                                  completion:^(SPKLanguagePack *pack, NSError *error) {
        if (pack && onInstall) onInstall(pack.code);
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;  // VC gone — the picker was still refreshed via onInstall above
        self.activeImporter = nil;
        [self.installingCodes removeObject:entry.code];
        if (pack) {
            // The installed code comes from the zip's actual .lproj folder name; a well-formed catalog
            // pins it via sha256, but log if it disagrees with what the row advertised (catalog integrity).
            if (entry.code.length && ![pack.code.lowercaseString isEqualToString:entry.code.lowercaseString]) {
                SPKLog(@"i18n", @"[LangPackCatalog] installed code %@ != catalog entry %@", pack.code, entry.code);
            }
            SPKNotify(kSPKNotificationLanguagePackUpdate,
                      wasUpdate ? SPKL(@"LANGUAGE_PACK_UPDATED_TOAST") : SPKL(@"LANGUAGE_PACK_INSTALLED_TOAST"),
                      entry.displayName, @"translate", SPKNotificationToneForIconResource(@"translate"));
            // Re-sort rather than remove: the row stays, now reading as installed and sinking below
            // whatever is still actionable.
            self.entries = [self sortedForDisplay:self.entries];
            [self rebuildSections];
        } else {
            [self rebuildSections];
            // Domain-qualified: `error` may be an importPackAtURL: error from a different domain, whose
            // code 7 must not be mistaken for our Cancelled and silently swallow a real failure.
            BOOL wasCancel = [error.domain isEqualToString:SPKLanguagePackURLImportErrorDomain]
                             && error.code == SPKLanguagePackURLImportErrorCancelled;
            if (!wasCancel) {
                [self presentError:error.localizedDescription ?: SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED")];
            }
        }
    }];
}

- (void)dismissCatalog {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)presentError:(NSString *)message {
    [self presentError:message title:SPKL(@"LANGUAGE_PACK_IMPORT_ERROR_TITLE")];
}

- (void)presentError:(NSString *)message title:(NSString *)title {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:title
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

@end
