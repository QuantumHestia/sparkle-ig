#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Runs every preference rename or removal that has not run on this install yet,
/// across the global value and every per-account copy (`u_<pk>_<key>`).
///
/// Must run before Sparkle registers its defaults: `objectForKey:` would otherwise
/// report a registered default for the new key, and the user's legacy value would
/// never be carried over. Completed migrations are recorded, so steady-state cost
/// is one defaults read.
FOUNDATION_EXPORT void SPKRunPendingPreferenceMigrations(void);

/// Applies every migration to an imported preferences dictionary, regardless of
/// what already ran on this install, so a backup made before a rename restores
/// its values under the current keys.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SPKPreferenceMigrationsAppliedToDictionary(NSDictionary<NSString *, id> *preferences);

/// Defaults key holding the identifiers of completed migrations. Install state,
/// never part of a settings export.
FOUNDATION_EXPORT NSString *const SPKPreferenceMigrationsCompletedKey;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
