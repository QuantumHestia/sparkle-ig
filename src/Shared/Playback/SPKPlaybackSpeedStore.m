#import "SPKPlaybackSpeedStore.h"

#import "../../Utils.h"
#import "../i18n/SPKStrings.h"

NSNotificationName const SPKPlaybackSpeedDidChangeNotification = @"SPKPlaybackSpeedDidChangeNotification";

// Instagram's players don't go below half speed (its own speed options stop at 0.5x).
double const SPKPlaybackSpeedMinimum = 0.5;
double const SPKPlaybackSpeedMaximum = 2.0;
double const SPKPlaybackSpeedStep = 0.25;

// In-memory state per surface. Session speed lives until the viewer closes; the
// video speed is bound to one model object and never outlives it.
typedef struct {
    double sessionSpeed;
    double videoSpeed;
} SPKPlaybackSpeedState;

static SPKPlaybackSpeedState sSPKPlaybackSpeedStates[2] = {{1.0, 1.0}, {1.0, 1.0}};
static __weak id sSPKPlaybackStoriesVideoItem = nil;
static __weak id sSPKPlaybackReelsVideoItem = nil;

static NSInteger SPKPlaybackSurfaceIndex(SPKPlaybackSurface surface) {
    return surface == SPKPlaybackSurfaceReels ? 1 : 0;
}

static id SPKPlaybackVideoItem(SPKPlaybackSurface surface) {
    return surface == SPKPlaybackSurfaceReels ? sSPKPlaybackReelsVideoItem : sSPKPlaybackStoriesVideoItem;
}

static void SPKPlaybackSetVideoItem(SPKPlaybackSurface surface, id item) {
    if (surface == SPKPlaybackSurfaceReels)
        sSPKPlaybackReelsVideoItem = item;
    else
        sSPKPlaybackStoriesVideoItem = item;
}

static NSString *SPKPlaybackSurfacePrefix(SPKPlaybackSurface surface) {
    return surface == SPKPlaybackSurfaceReels ? @"reels" : @"stories";
}

static NSString *SPKPlaybackSavedSpeedKey(SPKPlaybackSurface surface) {
    return [SPKPlaybackSurfacePrefix(surface) stringByAppendingString:@"_playback_saved_speed"];
}

static void SPKPlaybackSpeedPostChange(SPKPlaybackSurface surface) {
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKPlaybackSpeedDidChangeNotification object:@(surface)];
    };
    if ([NSThread isMainThread])
        post();
    else
        dispatch_async(dispatch_get_main_queue(), post);
}

BOOL SPKPlaybackControlsEnabled(SPKPlaybackSurface surface) {
    return [SPKUtils getBoolPref:[SPKPlaybackSurfacePrefix(surface) stringByAppendingString:@"_playback_controls"]];
}

NSString *SPKPlaybackSpeedScopePreferenceKey(SPKPlaybackSurface surface) {
    return [SPKPlaybackSurfacePrefix(surface) stringByAppendingString:@"_playback_speed_scope"];
}

NSString *SPKPlaybackSpeedScopeValue(SPKPlaybackSpeedScope scope) {
    switch (scope) {
        case SPKPlaybackSpeedScopeVideo:
            return @"video";
        case SPKPlaybackSpeedScopeAlways:
            return @"always";
        case SPKPlaybackSpeedScopeSession:
        default:
            return @"session";
    }
}

SPKPlaybackSpeedScope SPKPlaybackSpeedCurrentScope(SPKPlaybackSurface surface) {
    NSString *value = [SPKUtils getStringPref:SPKPlaybackSpeedScopePreferenceKey(surface)];
    if ([value isEqualToString:@"video"])
        return SPKPlaybackSpeedScopeVideo;
    if ([value isEqualToString:@"always"])
        return SPKPlaybackSpeedScopeAlways;
    return SPKPlaybackSpeedScopeSession;
}

double SPKPlaybackSpeedClamp(double speed) {
    if (!isfinite(speed) || speed <= 0.0)
        return 1.0;
    double stepped = round(speed / SPKPlaybackSpeedStep) * SPKPlaybackSpeedStep;
    return MIN(SPKPlaybackSpeedMaximum, MAX(SPKPlaybackSpeedMinimum, stepped));
}

BOOL SPKPlaybackSpeedIsNormal(double speed) {
    return fabs(speed - 1.0) < 0.001;
}

static double SPKPlaybackSavedSpeed(SPKPlaybackSurface surface) {
    return SPKPlaybackSpeedClamp([SPKUtils getDoublePref:SPKPlaybackSavedSpeedKey(surface)]);
}

double SPKPlaybackSpeedEffective(SPKPlaybackSurface surface, id item) {
    if (!SPKPlaybackControlsEnabled(surface))
        return 1.0;

    NSInteger index = SPKPlaybackSurfaceIndex(surface);
    switch (SPKPlaybackSpeedCurrentScope(surface)) {
        case SPKPlaybackSpeedScopeAlways:
            return SPKPlaybackSavedSpeed(surface);
        case SPKPlaybackSpeedScopeVideo: {
            id videoItem = SPKPlaybackVideoItem(surface);
            return (item && videoItem == item) ? sSPKPlaybackSpeedStates[index].videoSpeed : 1.0;
        }
        case SPKPlaybackSpeedScopeSession:
        default:
            return sSPKPlaybackSpeedStates[index].sessionSpeed;
    }
}

void SPKPlaybackSpeedSetForItem(SPKPlaybackSurface surface, double speed, id item) {
    speed = SPKPlaybackSpeedClamp(speed);
    NSInteger index = SPKPlaybackSurfaceIndex(surface);
    switch (SPKPlaybackSpeedCurrentScope(surface)) {
        case SPKPlaybackSpeedScopeAlways:
            SPKPreferenceSetObject(@(speed), SPKPlaybackSavedSpeedKey(surface));
            break;
        case SPKPlaybackSpeedScopeVideo:
            SPKPlaybackSetVideoItem(surface, item);
            sSPKPlaybackSpeedStates[index].videoSpeed = speed;
            break;
        case SPKPlaybackSpeedScopeSession:
        default:
            sSPKPlaybackSpeedStates[index].sessionSpeed = speed;
            break;
    }
    SPKPlaybackSpeedPostChange(surface);
}

void SPKPlaybackSpeedSetScope(SPKPlaybackSurface surface, SPKPlaybackSpeedScope scope, id currentItem) {
    // Carry the speed the viewer is hearing right now into the new scope, so
    // switching the picker never changes playback on its own.
    double current = SPKPlaybackSpeedEffective(surface, currentItem);
    NSInteger index = SPKPlaybackSurfaceIndex(surface);

    SPKPreferenceSetObject(SPKPlaybackSpeedScopeValue(scope), SPKPlaybackSpeedScopePreferenceKey(surface));
    if (scope != SPKPlaybackSpeedScopeAlways)
        SPKPreferenceSetObject(@(1.0), SPKPlaybackSavedSpeedKey(surface));
    if (scope != SPKPlaybackSpeedScopeSession)
        sSPKPlaybackSpeedStates[index].sessionSpeed = 1.0;
    if (scope != SPKPlaybackSpeedScopeVideo) {
        SPKPlaybackSetVideoItem(surface, nil);
        sSPKPlaybackSpeedStates[index].videoSpeed = 1.0;
    }

    SPKPlaybackSpeedSetForItem(surface, current, currentItem);
}

void SPKPlaybackSpeedEndSession(SPKPlaybackSurface surface) {
    NSInteger index = SPKPlaybackSurfaceIndex(surface);
    BOOL changed = !SPKPlaybackSpeedIsNormal(sSPKPlaybackSpeedStates[index].sessionSpeed) ||
                   SPKPlaybackVideoItem(surface) != nil;
    sSPKPlaybackSpeedStates[index].sessionSpeed = 1.0;
    sSPKPlaybackSpeedStates[index].videoSpeed = 1.0;
    SPKPlaybackSetVideoItem(surface, nil);
    if (changed)
        SPKPlaybackSpeedPostChange(surface);
}

NSString *SPKPlaybackSpeedLabel(double speed) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        // Decimal separator follows Sparkle's interface language (restart-required,
        // so resolving it once is enough).
        formatter.locale = [SPKUtils spk_activeFormattingLocale];
        formatter.minimumFractionDigits = 0;
        formatter.maximumFractionDigits = 2;
    });
    NSString *number = [formatter stringFromNumber:@(speed)] ?: [NSString stringWithFormat:@"%g", speed];
    return [NSString stringWithFormat:SPKL(@"PLAYBACK_PANEL_SPEED_VALUE_FORMAT"), number];
}

NSArray<NSNumber *> *SPKPlaybackSpeedPresets(void) {
    return @[ @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0 ];
}

NSString *SPKPlaybackSpeedScopeTitle(SPKPlaybackSpeedScope scope) {
    switch (scope) {
        case SPKPlaybackSpeedScopeVideo:
            return SPKL(@"PLAYBACK_PANEL_SCOPE_VIDEO");
        case SPKPlaybackSpeedScopeAlways:
            return SPKL(@"PLAYBACK_PANEL_SCOPE_ALWAYS");
        case SPKPlaybackSpeedScopeSession:
        default:
            return SPKL(@"PLAYBACK_PANEL_SCOPE_SESSION");
    }
}
