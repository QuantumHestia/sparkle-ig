#import <UIKit/UIKit.h>

#import "SPKFakeLocation.h"

NS_ASSUME_NONNULL_BEGIN

/// Map picker for a fake location: pan the map under a fixed pin, or search for a
/// place. Hands the chosen place back and leaves storing it to the caller, so the
/// same screen serves "use this location" and "add a saved place".
@interface SPKFakeLocationPickerViewController : UIViewController

@property (nonatomic, copy, nullable) void (^completion)(SPKFakeLocationPlace *place);

- (instancetype)initWithInitialPlace:(nullable SPKFakeLocationPlace *)place title:(NSString *)title;

/// Wraps a picker in Sparkle's modal chrome and presents it from the frontmost
/// controller above `presenter`.
+ (void)presentFromViewController:(nullable UIViewController *)presenter
                     initialPlace:(nullable SPKFakeLocationPlace *)place
                            title:(NSString *)title
                       completion:(void (^)(SPKFakeLocationPlace *place))completion;

@end

NS_ASSUME_NONNULL_END
