#import "SPKFakeLocation.h"

#import <os/lock.h>

#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../i18n/SPKStrings.h"

NSNotificationName const SPKFakeLocationDidChangeNotification = @"SPKFakeLocationDidChangeNotification";

NSString *const kSPKFakeLocationEnabledKey = @"msgs_fake_location";
NSString *const kSPKFakeLocationPlaceKey = @"msgs_fake_location_place";
NSString *const kSPKFakeLocationSavedPlacesKey = @"msgs_fake_location_saved_places";
NSString *const kSPKFakeLocationMapButtonKey = @"msgs_fake_location_map_button";

// Instagram waits this long after its first forced upload before the map settles;
// a second pass catches the case where the first one raced its own session setup.
static const NSTimeInterval kSPKFakeLocationSecondPushDelay = 1.0;

#pragma mark - Place

@implementation SPKFakeLocationPlace

+ (instancetype)placeWithName:(NSString *)name address:(NSString *)address coordinate:(CLLocationCoordinate2D)coordinate {
    SPKFakeLocationPlace *place = [SPKFakeLocationPlace new];
    place.identifier = [NSUUID UUID].UUIDString;
    place.name = name ?: @"";
    place.address = address.length ? address : nil;
    place.coordinate = coordinate;
    return place;
}

+ (instancetype)placeFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary *values = dictionary;
    id lat = values[@"lat"];
    id lon = values[@"lon"];
    if (![lat respondsToSelector:@selector(doubleValue)] || ![lon respondsToSelector:@selector(doubleValue)])
        return nil;
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
    if (!CLLocationCoordinate2DIsValid(coordinate))
        return nil;

    SPKFakeLocationPlace *place = [SPKFakeLocationPlace new];
    NSString *identifier = [values[@"id"] isKindOfClass:[NSString class]] ? values[@"id"] : nil;
    place.identifier = identifier.length ? identifier : [NSUUID UUID].UUIDString;
    place.name = [values[@"name"] isKindOfClass:[NSString class]] ? values[@"name"] : @"";
    NSString *address = [values[@"address"] isKindOfClass:[NSString class]] ? values[@"address"] : nil;
    place.address = address.length ? address : nil;
    place.coordinate = coordinate;
    return place;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *values = [@{
        @"id" : self.identifier ?: [NSUUID UUID].UUIDString,
        @"name" : self.name ?: @"",
        @"lat" : @(self.coordinate.latitude),
        @"lon" : @(self.coordinate.longitude),
    } mutableCopy];
    if (self.address.length)
        values[@"address"] = self.address;
    return values;
}

- (NSString *)displaySubtitle {
    if (self.address.length)
        return self.address;
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = [SPKUtils spk_activeFormattingLocale];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimumFractionDigits = 5;
    formatter.maximumFractionDigits = 5;
    NSString *lat = [formatter stringFromNumber:@(self.coordinate.latitude)] ?: @"";
    NSString *lon = [formatter stringFromNumber:@(self.coordinate.longitude)] ?: @"";
    return [NSString stringWithFormat:SPKL(@"MESSAGES_FAKE_LOCATION_COORDINATE_FORMAT"), lat, lon];
}

@end

#pragma mark - Cache

// Written on the main thread, read from IG's location thread.
static os_unfair_lock sSPKFakeLocationLock = OS_UNFAIR_LOCK_INIT;
static BOOL sSPKFakeLocationCachedActive = NO;
static CLLocationCoordinate2D sSPKFakeLocationCachedCoordinate;

@implementation SPKFakeLocation

+ (void)load {
    // Account switches change which per-account place applies. The observer is
    // registered here rather than at hook install so the cache is right even when
    // the settings page is the first thing to touch it.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          [SPKFakeLocation reloadCache];
                                                          [[NSNotificationCenter defaultCenter] postNotificationName:SPKFakeLocationDidChangeNotification object:nil];
                                                      }];
    });
}

+ (BOOL)isEnabled {
    return [SPKUtils getBoolPref:kSPKFakeLocationEnabledKey];
}

+ (SPKFakeLocationPlace *)currentPlace {
    return [SPKFakeLocationPlace placeFromDictionary:SPKPreferenceObjectForKey(kSPKFakeLocationPlaceKey)];
}

+ (BOOL)isActive {
    return [self isEnabled] && [self currentPlace] != nil;
}

+ (void)reloadCache {
    SPKFakeLocationPlace *place = [self currentPlace];
    BOOL active = [self isEnabled] && place != nil;
    os_unfair_lock_lock(&sSPKFakeLocationLock);
    sSPKFakeLocationCachedActive = active;
    if (place)
        sSPKFakeLocationCachedCoordinate = place.coordinate;
    os_unfair_lock_unlock(&sSPKFakeLocationLock);
}

+ (CLLocation *)spoofedLocation {
    os_unfair_lock_lock(&sSPKFakeLocationLock);
    BOOL active = sSPKFakeLocationCachedActive;
    CLLocationCoordinate2D coordinate = sSPKFakeLocationCachedCoordinate;
    os_unfair_lock_unlock(&sSPKFakeLocationLock);
    if (!active)
        return nil;
    // A fresh timestamp on every read: IG discards fixes it considers stale, and a
    // tight accuracy keeps it from waiting on a better one.
    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:0.0
                               horizontalAccuracy:5.0
                                 verticalAccuracy:5.0
                                        timestamp:[NSDate date]];
}

+ (void)spk_commitChangePushing:(BOOL)push {
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reloadCache];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKFakeLocationDidChangeNotification object:nil];
    if (push)
        [self pushToFriendsMap];
}

+ (BOOL)setEnabled:(BOOL)enabled {
    if (enabled && ![self currentPlace])
        return NO;
    if (enabled == [self isEnabled])
        return YES;
    SPKPreferenceSetObject(@(enabled), kSPKFakeLocationEnabledKey);
    // Switching off pushes too, so friends see the real location again right away
    // instead of the fake one lingering until IG's next scheduled upload.
    [self spk_commitChangePushing:YES];
    return YES;
}

+ (void)applyPlace:(SPKFakeLocationPlace *)place enable:(BOOL)enable {
    if (!place)
        return;
    SPKPreferenceSetObject([place dictionaryRepresentation], kSPKFakeLocationPlaceKey);
    if (enable)
        SPKPreferenceSetObject(@YES, kSPKFakeLocationEnabledKey);
    [self spk_commitChangePushing:[self isEnabled]];
}

#pragma mark Saved places

+ (NSArray<SPKFakeLocationPlace *> *)savedPlaces {
    id stored = SPKPreferenceObjectForKey(kSPKFakeLocationSavedPlacesKey);
    if (![stored isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<SPKFakeLocationPlace *> *places = [NSMutableArray array];
    for (id entry in (NSArray *)stored) {
        SPKFakeLocationPlace *place = [SPKFakeLocationPlace placeFromDictionary:entry];
        if (place)
            [places addObject:place];
    }
    return places;
}

+ (void)spk_storeSavedPlaces:(NSArray<SPKFakeLocationPlace *> *)places {
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:places.count];
    for (SPKFakeLocationPlace *place in places)
        [values addObject:[place dictionaryRepresentation]];
    SPKPreferenceSetObject(values, kSPKFakeLocationSavedPlacesKey);
    [self spk_commitChangePushing:NO];
}

+ (void)addSavedPlace:(SPKFakeLocationPlace *)place {
    if (!place)
        return;
    NSMutableArray *places = [[self savedPlaces] mutableCopy];
    [places addObject:place];
    [self spk_storeSavedPlaces:places];
}

+ (void)removeSavedPlaceWithIdentifier:(NSString *)identifier {
    NSMutableArray *places = [[self savedPlaces] mutableCopy];
    NSIndexSet *matches = [places indexesOfObjectsPassingTest:^BOOL(SPKFakeLocationPlace *place, __unused NSUInteger idx, __unused BOOL *stop) {
        return [place.identifier isEqualToString:identifier];
    }];
    if (matches.count == 0)
        return;
    [places removeObjectsAtIndexes:matches];
    [self spk_storeSavedPlaces:places];
}

+ (void)renameSavedPlaceWithIdentifier:(NSString *)identifier toName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return;
    NSArray<SPKFakeLocationPlace *> *places = [self savedPlaces];
    BOOL renamedCurrent = NO;
    for (SPKFakeLocationPlace *place in places) {
        if (![place.identifier isEqualToString:identifier])
            continue;
        renamedCurrent = [self savedPlaceMatchesCurrent:place];
        place.name = trimmed;
    }
    [self spk_storeSavedPlaces:places];
    if (renamedCurrent) {
        SPKFakeLocationPlace *current = [self currentPlace];
        current.name = trimmed;
        SPKPreferenceSetObject([current dictionaryRepresentation], kSPKFakeLocationPlaceKey);
        [self spk_commitChangePushing:NO];
    }
}

+ (BOOL)savedPlaceMatchesCurrent:(SPKFakeLocationPlace *)place {
    SPKFakeLocationPlace *current = [self currentPlace];
    if (!current || !place)
        return NO;
    if ([current.identifier isEqualToString:place.identifier])
        return YES;
    // Coordinates are compared at roughly a metre so a place re-applied from the
    // picker still reads as the saved one it came from.
    return fabs(current.coordinate.latitude - place.coordinate.latitude) < 1e-5 &&
           fabs(current.coordinate.longitude - place.coordinate.longitude) < 1e-5;
}

#pragma mark Friends Map push

static id SPKFakeLocationFriendsMapService(void) {
    id session = [SPKUtils activeUserSession];
    SEL selector = NSSelectorFromString(@"friendsMapService");
    if (!session || ![session respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(session, selector);
}

// The service's completions are Swift closures on some builds; hand it empty
// blocks rather than nil so a callee that invokes them unconditionally is safe.
static void SPKFakeLocationRequestUpload(id service) {
    if (!service)
        return;
    SEL fetchSettings = NSSelectorFromString(@"_fetchSettingsAndUpdateLocationWithSource:completion:");
    if ([service respondsToSelector:fetchSettings]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(service, fetchSettings, @"APP_FOREGROUND", ^{
        });
    }
    SEL updateLocation = NSSelectorFromString(@"updateCurrentLocationWithCompletion:isSubscriptionUpdate:");
    if ([service respondsToSelector:updateLocation]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(service, updateLocation, ^{
        }, NO);
    }
}

static void SPKFakeLocationCollectStackViews(UIView *view, Class stackClass, NSMutableArray<UIView *> *found) {
    if ([view isKindOfClass:stackClass]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews)
        SPKFakeLocationCollectStackViews(subview, stackClass, found);
}

// Recentres an open Friends Map on the (now fake) self location through IG's own
// locate button, so the map shows where friends will see you.
static void SPKFakeLocationRecentreOpenMaps(void) {
    Class stackClass = SPKResolveIGClass(@"IGFriendsMapSecondaryButtonsStackController.IGFriendsMapSecondaryButtonsStackView", nil);
    SEL locate = NSSelectorFromString(@"didTapLocateButton");
    if (!stackClass || ![stackClass instancesRespondToSelector:locate])
        return;
    NSMutableArray<UIView *> *stacks = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden)
                SPKFakeLocationCollectStackViews(window, stackClass, stacks);
        }
    }
    for (UIView *stack in stacks) {
        if (stack.window)
            ((void (*)(id, SEL))objc_msgSend)(stack, locate);
    }
}

+ (void)pushToFriendsMap {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pushToFriendsMap];
        });
        return;
    }
    id service = SPKFakeLocationFriendsMapService();
    if (!service) {
        SPKLog(@"FakeLocation", @"[Sparkle] No Friends Map service on this session; upload waits for Instagram");
        return;
    }
    SPKLog(@"FakeLocation", @"[Sparkle] Requesting Friends Map upload (active=%@)", [self isActive] ? @"YES" : @"NO");
    SPKFakeLocationRequestUpload(service);
    __weak id weakService = service;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKFakeLocationSecondPushDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKFakeLocationRequestUpload(weakService);
        SPKFakeLocationRecentreOpenMaps();
    });
}

@end
