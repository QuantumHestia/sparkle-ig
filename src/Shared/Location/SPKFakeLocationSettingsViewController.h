#import "../../Settings/SPKSettingsViewController.h"
#import "SPKFakeLocation.h"

NS_ASSUME_NONNULL_BEGIN

/// Fake location page: the on switch, the active place, the Friends Map button,
/// and the saved places (tap to use, swipe to rename or delete).
@interface SPKFakeLocationSettingsViewController : SPKSettingsViewController
@end

/// Sections of the page, for settings search from the Messages topic.
FOUNDATION_EXPORT NSArray *SPKFakeLocationSettingsSections(void);
/// "Off", or the active place's name, for the row that opens the page.
FOUNDATION_EXPORT NSString *SPKFakeLocationSettingsSummary(void);

/// Name prompt shared by the page and the Friends Map menu: asks for a name,
/// prefilled with `place.name`, then adds the place to the saved list.
FOUNDATION_EXPORT void SPKFakeLocationPromptToSavePlace(UIViewController *_Nullable presenter, SPKFakeLocationPlace *place);

NS_ASSUME_NONNULL_END
