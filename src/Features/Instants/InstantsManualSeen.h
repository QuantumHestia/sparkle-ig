#import <Foundation/Foundation.h>

/// Manually Mark Seen: keeps viewed Instants locally unseen so they stay in the tray until
/// you choose to release one.
///
/// Instagram derives the available snap list as `timeOrderedQuicksnaps` minus `seenSnapPks`,
/// and hydrates `seenSnapPks` from `kIGQuickSnapSeenStateKey` in the session `IGUserDefaults`.
/// It works in three parts, and all three are load bearing:
///
/// 1. Every media PK the viewer consumes is stripped back out of that stored key, silently,
///    so the persisted seen state never records the view.
/// 2. The seen state is never synced to the server, so the server keeps treating those snaps
///    as unseen.
/// 3. When the viewer closes, the list is refetched. This is the step that actually restores
///    the tray: Instagram purges the consumed media out of `timeOrderedQuicksnaps` when the
///    viewer closes, so reloading the seen state alone has nothing left to un-filter
///    (`availableTimeOrderedSnaps` reads 0 at that point, device-confirmed). The refetch
///    brings them back, and 1 and 2 are what make them come back unseen.
///
/// No address arithmetic and no Swift-internal hooks.

/// YES when the pref is on. Re-read at call time.
FOUNDATION_EXPORT BOOL SPKInstantsManualSeenIsEnabled(void);

/// Records every snap the service announces so the feature knows which PKs to keep unseen.
/// Cheap: PK reads only, no media resolution.
FOUNDATION_EXPORT void SPKInstantsManualSeenNoteServiceMedia(NSArray *mediaList);

/// Strips every protected PK from the persisted seen state. Call this on every service
/// update: Instagram rewrites that key as it consumes snaps, so keeping it clean has to be
/// continuous rather than a single pass at the end.
///
/// While the viewer is open this only rewrites the stored value and does not ask Instagram
/// to reload it. Reloading mid-session pushes the snap back into the live available list
/// under the viewer, which makes a consumed Instant reappear instead of letting the viewer
/// finish and close.
FOUNDATION_EXPORT void SPKInstantsManualSeenHoldUnseen(id service);

/// Tells the feature whether the consumption viewer is on screen, which is what decides between
/// the silent write above and an immediate reload.
FOUNDATION_EXPORT void SPKInstantsManualSeenSetViewerOpen(BOOL open);

/// Closes a viewing session: strips anything left over, reloads the seen state, then forces a
/// refetch so the tray picks the Instants back up. This is the only point at which the feature
/// makes snaps reappear, so the viewer plays through to the end and dismisses normally.
FOUNDATION_EXPORT void SPKInstantsManualSeenEndViewerSession(id service);

/// Installs the seen-sync block, so a tray refetch does not come back with the Instants
/// already marked seen server-side.
FOUNDATION_EXPORT void SPKInstallInstantsManualSeenHooksIfEnabled(void);

/// Releases one snap: stops protecting it and marks it seen for real. This is the manual
/// half of the feature, so a held Instant can be cleared deliberately.
FOUNDATION_EXPORT void SPKInstantsManualSeenMarkMediaPK(NSString *mediaPK);

