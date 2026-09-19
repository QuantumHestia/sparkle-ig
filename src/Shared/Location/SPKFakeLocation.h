#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread whenever the active fake location, its on/off state,
/// or the saved places change, so live UI (the Friends Map button, the settings
/// page) can refresh without polling defaults.
FOUNDATION_EXPORT NSNotificationName const SPKFakeLocationDidChangeNotification;

FOUNDATION_EXPORT NSString *const kSPKFakeLocationEnabledKey;
FOUNDATION_EXPORT NSString *const kSPKFakeLocationPlaceKey;
FOUNDATION_EXPORT NSString *const kSPKFakeLocationSavedPlacesKey;
FOUNDATION_EXPORT NSString *const kSPKFakeLocationMapButtonKey;

/// A named coordinate. Saved places carry a stable identifier so a rename or a
/// delete finds the right row even when two places share a name.
@interface SPKFakeLocationPlace : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *address;
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;

+ (instancetype)placeWithName:(NSString *)name address:(nullable NSString *)address coordinate:(CLLocationCoordinate2D)coordinate;
+ (nullable instancetype)placeFromDictionary:(nullable id)dictionary;
- (NSDictionary *)dictionaryRepresentation;
/// Address when known, otherwise the coordinate as text.
- (NSString *)displaySubtitle;
@end

@interface SPKFakeLocation : NSObject

/// YES when the account has the fake location switched on AND a place is set.
+ (BOOL)isActive;
+ (BOOL)isEnabled;
+ (nullable SPKFakeLocationPlace *)currentPlace;

/// Switching on without a place set is refused (returns NO), so the caller can
/// send the user to the picker instead of spoofing a meaningless coordinate.
+ (BOOL)setEnabled:(BOOL)enabled;
/// Stores `place` as the active location and, when `enable` is YES, switches the
/// fake location on. Pushes the change to the Friends Map straight away.
+ (void)applyPlace:(SPKFakeLocationPlace *)place enable:(BOOL)enable;

+ (NSArray<SPKFakeLocationPlace *> *)savedPlaces;
+ (void)addSavedPlace:(SPKFakeLocationPlace *)place;
+ (void)removeSavedPlaceWithIdentifier:(NSString *)identifier;
+ (void)renameSavedPlaceWithIdentifier:(NSString *)identifier toName:(NSString *)name;
+ (BOOL)savedPlaceMatchesCurrent:(SPKFakeLocationPlace *)place;

/// The fix Instagram's location stack should see, or nil when the fake location
/// is off. Safe to call from any thread: it reads a cache that the main thread
/// refreshes, so IG's own location thread never touches the account session.
+ (nullable CLLocation *)spoofedLocation;

/// Re-reads the preferences into the cache. Main thread only.
+ (void)reloadCache;

/// Asks Instagram's Friends Map service to upload the current location now (it
/// otherwise waits for its next foreground or timer) and recentres any open map.
+ (void)pushToFriendsMap;

@end

NS_ASSUME_NONNULL_END
