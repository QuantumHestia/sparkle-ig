//  SPKLanguageCatalogViewController.h
//  Adding a language: the published packs as a list, one tap each to install or refresh, with the
//  ways of getting a pack from somewhere other than the list behind the screen's own more menu.
//
//  All four routes live here rather than as four rows in the settings page above, because only one
//  of them is the answer nearly every time. A list of published languages is what someone wants;
//  a file, a link, or the English template are for the person building a translation, and they read
//  as clutter to everyone else.

#import <UIKit/UIKit.h>

#import "../../Settings/SPKSettingsViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPKLanguageCatalogViewController : SPKSettingsViewController

/// Called on the main thread after a pack is successfully installed, so the presenter
/// can re-read the installed list.
@property (nonatomic, copy, nullable) void (^onInstall)(NSString *installedCode);

@end

NS_ASSUME_NONNULL_END
