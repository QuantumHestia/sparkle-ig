#import "SPKPreferenceMigrations.h"

#import "../Utils.h"

NSString *const SPKPreferenceMigrationsCompletedKey = @"app_preference_migrations";

/// Converts a legacy value for the new key. Returning nil drops the value.
typedef id _Nullable (^SPKPreferenceMigrationTransform)(id legacyValue);

@interface SPKPreferenceMigration : NSObject
/// Stable identifier recorded once the migration has run. Never reuse or rename one.
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *legacyKey;
/// nil removes the legacy key without carrying its value anywhere.
@property (nonatomic, copy, nullable) NSString *replacementKey;
/// nil copies the value unchanged.
@property (nonatomic, copy, nullable) SPKPreferenceMigrationTransform transform;
/// Per-migration completion flag written before the shared ledger existed.
@property (nonatomic, copy, nullable) NSString *legacyCompletionFlag;
@end

@implementation SPKPreferenceMigration
@end

static SPKPreferenceMigration *SPKMigration(NSString *identifier, NSString *legacyKey, NSString *_Nullable replacementKey, SPKPreferenceMigrationTransform _Nullable transform) {
    SPKPreferenceMigration *migration = [SPKPreferenceMigration new];
    migration.identifier = identifier;
    migration.legacyKey = legacyKey;
    migration.replacementKey = replacementKey;
    migration.transform = transform;
    return migration;
}

/// Every preference migration, oldest first. Append new entries at the end; later
/// entries see the results of earlier ones, so chained renames work.
static NSArray<SPKPreferenceMigration *> *SPKPreferenceMigrationList(void) {
    static NSArray<SPKPreferenceMigration *> *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The Instants upload button and the saved-instants button became one
        // button with a menu.
        SPKPreferenceMigration *instantsCameraButton = SPKMigration(@"instants_camera_btn", @"instants_upload_from_gallery", @"instants_camera_btn", nil);
        instantsCameraButton.legacyCompletionFlag = @"instants_camera_btn_migrated";

        // Terminology rename.
        SPKPreferenceMigration *hideRecentSearches = SPKMigration(@"general_hide_recent_searches", @"general_no_recent_searches", @"general_hide_recent_searches", nil);
        hideRecentSearches.legacyCompletionFlag = @"general_hide_recent_searches_migrated";

        // The Progressive Blur toggle became the scroll edge style menu. On forced
        // the soft blur; off installed nothing.
        SPKPreferenceMigration *scrollEdgeStyle = SPKMigration(@"interface_scroll_edge_style", @"interface_progressive_blur", @"interface_scroll_edge_style", ^id(id value) {
            if (![value respondsToSelector:@selector(boolValue)])
                return nil;
            return [value boolValue] ? @"soft" : @"off";
        });

        // The Manually Mark Seen switch for stories became a menu that adds a
        // mode where the eye button toggles seen receipts.
        SPKPreferenceMigration *storyManualSeenMode = SPKMigration(@"stories_manual_seen_mode", @"stories_manual_seen", @"stories_manual_seen_mode", ^id(id value) {
            if (![value respondsToSelector:@selector(boolValue)])
                return nil;
            return [value boolValue] ? @"tap" : @"off";
        });

        list = @[ instantsCameraButton, hideRecentSearches, scrollEdgeStyle, storyManualSeenMode ];
    });
    return list;
}

/// The namespace prefix of a stored copy of `baseKey`: @"" for the global value,
/// @"u_<pk>_" for a per-account one, nil when `key` is not a copy of `baseKey`.
static NSString *SPKPreferenceNamespacePrefix(NSString *key, NSString *baseKey) {
    if ([key isEqualToString:baseKey])
        return @"";
    if (![key hasPrefix:@"u_"] || key.length <= baseKey.length + 3 || ![key hasSuffix:baseKey])
        return nil;
    NSUInteger prefixLength = key.length - baseKey.length;
    if ([key characterAtIndex:prefixLength - 1] != '_')
        return nil;
    NSString *pk = [key substringWithRange:NSMakeRange(2, prefixLength - 3)];
    if (pk.length == 0 || [pk rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
        return nil;
    return [key substringToIndex:prefixLength];
}

/// Applies one migration to `state`, reporting each write through `write` (nil
/// value = remove). A value already stored under the new key always wins.
static void SPKApplyPreferenceMigration(SPKPreferenceMigration *migration, NSMutableDictionary<NSString *, id> *state, void (^_Nullable write)(NSString *key, id _Nullable value)) {
    for (NSString *key in state.allKeys) {
        NSString *prefix = SPKPreferenceNamespacePrefix(key, migration.legacyKey);
        if (!prefix)
            continue;
        id value = state[key];
        if (migration.replacementKey.length > 0) {
            id converted = migration.transform ? migration.transform(value) : value;
            NSString *target = [prefix stringByAppendingString:migration.replacementKey];
            if (converted && !state[target]) {
                state[target] = converted;
                if (write)
                    write(target, converted);
            }
        }
        [state removeObjectForKey:key];
        if (write)
            write(key, nil);
    }
}

void SPKRunPendingPreferenceMigrations(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSArray *stored = [defaults arrayForKey:SPKPreferenceMigrationsCompletedKey];
        NSMutableOrderedSet<NSString *> *completed = [NSMutableOrderedSet orderedSetWithArray:stored ?: @[]];
        NSUInteger completedCount = completed.count;

        NSMutableArray<SPKPreferenceMigration *> *pending = [NSMutableArray array];
        for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
            if ([completed containsObject:migration.identifier])
                continue;
            if (migration.legacyCompletionFlag.length > 0 && [defaults boolForKey:migration.legacyCompletionFlag]) {
                [completed addObject:migration.identifier];
                continue;
            }
            [pending addObject:migration];
        }

        if (pending.count > 0) {
            // Snapshot once; the working copy carries earlier results into later
            // migrations while every change is mirrored to defaults.
            NSMutableDictionary<NSString *, id> *state = [[defaults dictionaryRepresentation] mutableCopy];
            for (SPKPreferenceMigration *migration in pending) {
                SPKApplyPreferenceMigration(migration, state, ^(NSString *key, id value) {
                    if (value)
                        [defaults setObject:value forKey:key];
                    else
                        [defaults removeObjectForKey:key];
                });
                [completed addObject:migration.identifier];
                SPKLog(@"Preferences", @"Ran preference migration %@", migration.identifier);
            }
        }

        for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
            if (migration.legacyCompletionFlag.length > 0)
                [defaults removeObjectForKey:migration.legacyCompletionFlag];
        }
        if (completed.count != completedCount)
            [defaults setObject:completed.array forKey:SPKPreferenceMigrationsCompletedKey];
    });
}

NSDictionary<NSString *, id> *SPKPreferenceMigrationsAppliedToDictionary(NSDictionary<NSString *, id> *preferences) {
    NSMutableDictionary<NSString *, id> *state = [preferences mutableCopy];
    for (SPKPreferenceMigration *migration in SPKPreferenceMigrationList()) {
        SPKApplyPreferenceMigration(migration, state, nil);
    }
    [state removeObjectForKey:SPKPreferenceMigrationsCompletedKey];
    return state;
}
