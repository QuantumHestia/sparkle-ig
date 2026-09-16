//  SPKLanguagePackUpdater.m

#import "SPKLanguagePackUpdater.h"
#import "SPKLanguagePack.h"
#import "SPKLanguagePackCatalog.h"
#import "SPKLanguagePackURLImporter.h"
#import "SPKStrings.h"
#import "../UI/SPKNotificationCenter.h"
#import "../../Utils.h"

NSString *const kSPKLanguagePackAutoUpdateKey = @"language_pack_auto_update";
static NSString *const kSPKLastUpdateCheckKey = @"language_pack_last_update_check";
// Separate from the last SUCCESSFUL check: without it, a device that simply has no network would
// re-attempt the whole fetch on every single launch, because nothing would ever have been recorded.
static NSString *const kSPKLastUpdateAttemptKey = @"language_pack_last_update_attempt";

// Long enough that launching repeatedly costs nothing, short enough that a release published while
// the app sits open still lands the next morning.
static const NSTimeInterval kSPKUpdateCheckInterval = 24 * 60 * 60;
// Held off the very first moments of launch: the check is background work competing with the feed,
// and nothing about it is urgent.
static const NSTimeInterval kSPKUpdateCheckLaunchDelay = 12.0;
// How long a failed attempt is left alone. Long enough that being offline costs one attempt an hour
// rather than one per launch, short enough that connectivity coming back is noticed the same day.
static const NSTimeInterval kSPKUpdateRetryInterval = 60 * 60;

@implementation SPKLanguagePackUpdater

+ (BOOL)autoUpdateEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Registered as a bootstrap default, but a pack can be installed before that runs on a first
    // launch, so an absent value means on rather than off.
    id value = [defaults objectForKey:kSPKLanguagePackAutoUpdateKey];
    return value == nil ? YES : [defaults boolForKey:kSPKLanguagePackAutoUpdateKey];
}

+ (void)setAutoUpdateEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSPKLanguagePackAutoUpdateKey];
}

+ (nullable NSDate *)lastCheckDate {
    NSTimeInterval stamp = [NSUserDefaults.standardUserDefaults doubleForKey:kSPKLastUpdateCheckKey];
    return stamp > 0 ? [NSDate dateWithTimeIntervalSince1970:stamp] : nil;
}

/// Installed packs that name a published build, as code → recorded sha256. A pack imported from a
/// file has no recorded hash and is deliberately left alone: the user put it there by hand, possibly
/// as a translation they are working on, and replacing it from a release would throw that away.
+ (NSDictionary<NSString *, NSString *> *)trackedPacks {
    NSMutableDictionary<NSString *, NSString *> *tracked = [NSMutableDictionary dictionary];
    for (NSString *code in SPKInstalledLanguagePackCodes()) {
        NSString *sha = SPKLanguagePackRecordedSHA256(code);
        if (sha.length)
            tracked[code] = sha;
    }
    return tracked;
}

+ (void)checkForUpdatesIfDue {
    if (![self autoUpdateEnabled])
        return;
    if ([self trackedPacks].count == 0)
        return;  // nothing installed that tracks a release — no reason to touch the network
    NSDate *last = [self lastCheckDate];
    NSDate *now = [NSDate date];
    if (last && [now timeIntervalSinceDate:last] < kSPKUpdateCheckInterval)
        return;
    // Back off after a failure instead of retrying on every launch.
    NSTimeInterval lastAttempt = [NSUserDefaults.standardUserDefaults doubleForKey:kSPKLastUpdateAttemptKey];
    if (lastAttempt > 0 && now.timeIntervalSince1970 - lastAttempt < kSPKUpdateRetryInterval)
        return;
    [NSUserDefaults.standardUserDefaults setDouble:now.timeIntervalSince1970 forKey:kSPKLastUpdateAttemptKey];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKUpdateCheckLaunchDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self performCheck];
    });
}

+ (void)performCheck {
    NSDictionary<NSString *, NSString *> *tracked = [self trackedPacks];
    if (tracked.count == 0)
        return;

    [SPKLanguagePackCatalog fetchEntriesWithCompletion:^(NSArray<SPKLanguageCatalogEntry *> *entries, NSError *error) {
        if (!entries) {
            SPKLog(@"i18n", @"[LangPackUpdate] catalog unavailable, leaving packs as they are");
            return;
        }
        // Only rows naming a language already installed, and only where the published hash differs
        // from the one on disk. A row without a hash cannot be compared, so it is left alone rather
        // than re-downloaded on every check.
        NSMutableArray<SPKLanguageCatalogEntry *> *stale = [NSMutableArray array];
        for (SPKLanguageCatalogEntry *entry in entries) {
            NSString *installedSHA = tracked[entry.code];
            if (!installedSHA) {
                for (NSString *code in tracked) {  // catalog casing need not match the folder's
                    if ([code caseInsensitiveCompare:entry.code] == NSOrderedSame) {
                        installedSHA = tracked[code];
                        break;
                    }
                }
            }
            if (installedSHA.length && entry.sha256.length && ![entry.sha256 isEqualToString:installedSHA])
                [stale addObject:entry];
        }
        [NSUserDefaults.standardUserDefaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kSPKLastUpdateCheckKey];
        if (stale.count == 0) {
            SPKLog(@"i18n", @"[LangPackUpdate] %lu tracked pack(s), all current", (unsigned long)tracked.count);
            return;
        }
        SPKLog(@"i18n", @"[LangPackUpdate] %lu pack(s) out of date", (unsigned long)stale.count);
        [self installSequentially:stale index:0 updated:[NSMutableArray array]];
    }];
}

/// One at a time: each install rewrites a directory the string layer reads, and the whole point is
/// that this is invisible, so there is nothing to gain from racing several downloads at launch.
+ (void)installSequentially:(NSArray<SPKLanguageCatalogEntry *> *)entries
                      index:(NSUInteger)index
                    updated:(NSMutableArray<NSString *> *)updated {
    if (index >= entries.count) {
        if (updated.count > 0) {
            [SPKStrings languagePacksDidChange];
            [self announceUpdated:updated];
        }
        return;
    }
    SPKLanguageCatalogEntry *entry = entries[index];
    [SPKLanguagePackURLImporter importFromURL:entry.url
                               expectedSHA256:entry.sha256
                                     progress:nil
                                   completion:^(SPKLanguagePack *pack, NSError *error) {
        if (pack) {
            SPKLog(@"i18n", @"[LangPackUpdate] refreshed %@ (%lu strings)", pack.code, (unsigned long)pack.stringCount);
            [updated addObject:entry.displayName];
        } else {
            // A failed refresh leaves the older pack in place, which still renders the app. Retrying
            // now would only spend the user's data on the same failure, so the next check gets it.
            SPKWarnLog(@"i18n", @"[LangPackUpdate] could not refresh %@: %@", entry.code, error.localizedDescription);
        }
        [self installSequentially:entries index:index + 1 updated:updated];
    }];
}

+ (void)announceUpdated:(NSArray<NSString *> *)names {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The languages are named in the subtitle, so the title carries no count and needs no plural.
        NSString *subtitle = [names componentsJoinedByString:SPKL(@"COMMON_LIST_SEPARATOR")];
        SPKNotify(kSPKNotificationLanguagePackUpdate,
                  SPKL(@"LANGUAGE_PACK_UPDATED_TOAST"),
                  subtitle,
                  @"translate",
                  SPKNotificationToneForIconResource(@"translate"));
    });
}

@end
