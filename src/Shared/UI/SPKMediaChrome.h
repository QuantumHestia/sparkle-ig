#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CGFloat const SPKMediaChromeTopBarContentHeight;

void SPKApplyMediaChromeNavigationBar(UINavigationBar *bar);

/// Shared navigation controller for Sparkle's modal stacks (settings, gallery,
/// downloads, etc.). Applies the media-chrome navigation bar styling (custom
/// back chevron everywhere, neutral non-blue tint and, on iOS 18 and lower, a
/// solid background matching the settings/list view background instead of the
/// system's scroll-driven material) and a title-less back button, so every
/// Sparkle top bar is consistent. Liquid Glass is left to the system on iOS 26+.
@interface SPKChromeNavigationController : UINavigationController
@end

UIImage *SPKMediaChromeTopIcon(NSString *resourceName);
UIImage *SPKMediaChromeBottomIcon(NSString *resourceName);
UIImage *SPKMediaChromeTopBarIcon(NSString *resourceName);
UIBarButtonItem *SPKMediaChromeTopBarButtonItem(NSString *resourceName, id target, SEL action);
UIBarButtonItem *SPKMediaChromeTopBarButtonItemWithTint(NSString *resourceName, id target, SEL action,
                                                        UIColor *_Nullable tintColor,
                                                        NSString *_Nullable accessibilityLabel);
/// Same as WithTint, but lets the caller pick the bar-button style. Use
/// `UIBarButtonItemStyleDone` for a prominent/emphasized button (rendered as a
/// prominent glass capsule on iOS 26 and bold on earlier systems); others should
/// stay `UIBarButtonItemStylePlain`.
UIBarButtonItem *SPKMediaChromeTopBarButtonItemWithStyle(NSString *resourceName, id target, SEL action,
                                                         UIBarButtonItemStyle style,
                                                         UIColor *_Nullable tintColor,
                                                         NSString *_Nullable accessibilityLabel);
// Top-bar button styled like the others but backed by a UIButton that opens
// `menu` as its primary action (single tap), matching the gallery chrome.
UIBarButtonItem *SPKMediaChromeTopBarMenuButtonItem(NSString *resourceName, UIMenu *menu, NSString *_Nullable accessibilityLabel);
/// Same as the menu button above, but with a caller-supplied tint (e.g. IG blue
/// for a prominent "Done"-equivalent menu button).
UIBarButtonItem *SPKMediaChromeTopBarMenuButtonItemWithTint(NSString *resourceName, UIMenu *menu, UIColor *_Nullable tintColor, NSString *_Nullable accessibilityLabel);
void SPKMediaChromeSetLeadingTopBarItems(UINavigationItem *navigationItem, NSArray<UIBarButtonItem *> *items);
void SPKMediaChromeSetTrailingTopBarItems(UINavigationItem *navigationItem, NSArray<UIBarButtonItem *> *items);
/// Like the above, but each inner array becomes its own bar-button group. On
/// iOS 26, fixed-space groups are inserted between them so UIKit renders
/// separate Liquid Glass capsules. Groups are given in visual order, leading to
/// trailing: the *last* group sits nearest the trailing edge, so a prominent
/// "Done" belongs at the end. On iOS 15 the groups are flattened into a plain
/// item list, reversed to preserve that same visual order.
void SPKMediaChromeSetTrailingTopBarItemGroups(UINavigationItem *navigationItem, NSArray<NSArray<UIBarButtonItem *> *> *groups);

// Bottom toolbar. These build a native UIToolbar (driven through the hosting
// UINavigationController) instead of a hand-positioned floating view. On iOS 26
// the system renders it as a Liquid Glass pill and positions it correctly on
// every device; on earlier systems it is a standard translucent bottom bar.

/// Normalized, template-rendered icon sized for bottom toolbar buttons.
UIImage *SPKMediaChromeBottomBarIcon(NSString *resourceName);

/// Creates a bar button item for the bottom toolbar. `target`/`action` may be
/// nil when the item is driven purely by a menu assigned later.
UIBarButtonItem *SPKMediaChromeBottomBarButtonItem(NSString *resourceName, NSString *accessibilityLabel, id _Nullable target, SEL _Nullable action);

/// Wraps content items with spacers to satisfy Liquid Glass grouping rules.
/// iOS 26: keeps the items adjacent inside a single centered glass capsule.
/// iOS <= 18: distributes the items evenly across a standard bottom bar.
NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItems(NSArray<UIBarButtonItem *> *contentItems);

/// Like SPKMediaChromeBottomToolbarItems, but breaks `trailingItems` out into a
/// separate glass capsule (iOS 26). Both groups stay centered together with a
/// fixed gap splitting the capsule between them. On iOS <= 18 every item is
/// distributed evenly across the standard bottom bar.
NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItemsWithTrailingGroup(NSArray<UIBarButtonItem *> *primaryItems, NSArray<UIBarButtonItem *> *trailingItems);

/// Like the above for any number of groups, given leading to trailing. Each
/// non-empty group becomes its own glass capsule on iOS 26; on iOS <= 18 every
/// item is distributed evenly across the standard bottom bar.
NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItemsWithGroups(NSArray<NSArray<UIBarButtonItem *> *> *groups);

/// Shows `title` in the navigation bar. While the top scroll edge style is soft
/// on iOS 26+, the text sits in a Liquid Glass capsule so it stays readable
/// over bright media; otherwise it is the plain navigation title. Nil clears it.
void SPKMediaChromeSetGlassTitle(UIViewController *viewController, NSString *_Nullable title);

/// Applies media-chrome styling to a bottom toolbar: neutral tint, and on iOS
/// 18 and lower a solid background matching the settings/list view background
/// (mirroring the navigation bar). No-op background on iOS 26+, where Liquid
/// Glass renders its own capsule.
void SPKMediaChromeConfigureBottomToolbar(UIToolbar *toolbar);

/// Toggles a translucent material backing on the navigation bar and bottom
/// toolbar. Used by the full-screen media preview so its bars stay transparent
/// over letterboxed content and gain a material backing when content scrolls or
/// zooms behind them. This is the deliberate exception to the solid-background
/// chrome used elsewhere. No-op on iOS 26+, where Liquid Glass adapts itself.
void SPKMediaChromeSetBarsMaterialActive(UINavigationController *navigationController, BOOL active);

NS_ASSUME_NONNULL_END
