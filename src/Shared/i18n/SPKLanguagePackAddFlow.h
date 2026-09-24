//  SPKLanguagePackAddFlow.h
//  The two ways to install a language pack over the network, as presentable flows.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPKLanguagePackAddFlow : NSObject

/// Prompts for an https `.zip` URL, downloads it, and installs it. `onImport` fires on the main
/// thread with the installed language code, so the presenter can refresh its list.
+ (void)presentURLPromptFrom:(UIViewController *)presenter
                    onImport:(nullable void (^)(NSString *installedCode))onImport;

/// Pushes (or presents) the catalog list, where a row installs with one tap.
+ (void)presentCatalogFrom:(UIViewController *)presenter
                  onImport:(nullable void (^)(NSString *installedCode))onImport;

@end

NS_ASSUME_NONNULL_END
