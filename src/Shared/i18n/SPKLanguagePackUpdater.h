//  SPKLanguagePackUpdater.h
//  Keeps installed language packs in step with the catalog.
//
//  Sparkle ships English and nothing else, so every other language a user reads is a pack that was
//  published alongside some earlier release. A release that adds strings leaves every one of those
//  packs short of the new keys, and the user sees the new screens in English with no way of knowing
//  a translated pack already exists. This closes that: on launch, quietly, Sparkle asks the catalog
//  whether the packs already installed have newer builds, and replaces the ones that do.
//
//  It refreshes ONLY languages already installed. Discovering a new language stays a deliberate trip
//  to the catalog screen, so a background check never turns into downloading a set of languages
//  nobody asked for.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Device-global, matching `interface_language` and the pack directory it governs.
FOUNDATION_EXPORT NSString *const kSPKLanguagePackAutoUpdateKey;

@interface SPKLanguagePackUpdater : NSObject

/// YES when the background check is allowed to run. Defaults to YES.
@property (class, nonatomic, assign) BOOL autoUpdateEnabled;

/// Runs the check if auto-update is on, a pack that tracks a published build is installed, and the
/// throttle has elapsed. Safe to call on every launch; returns immediately when there is nothing to
/// do. Never reports anything on success beyond a single pill naming what it refreshed.
+ (void)checkForUpdatesIfDue;

/// When the last successful check ran, or nil if one never has.
+ (nullable NSDate *)lastCheckDate;

@end

NS_ASSUME_NONNULL_END
