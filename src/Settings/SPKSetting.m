#import "SPKSetting.h"
#include <Foundation/Foundation.h>
#import "../Utils.h"

@interface SPKSetting ()

@property (nonatomic, readwrite) SPKTableCell type;

- (instancetype)initWithType:(SPKTableCell)type NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

///

NSNotificationName const SPKSettingAccessoryTextDidChangeNotification = @"SPKSettingAccessoryTextDidChangeNotification";

@implementation SPKSetting

// MARK: - - initWithType

- (instancetype)initWithType:(SPKTableCell)type {
    self = [super init];

    if (self) {
        self.type = type;
    }

    return self;
}

// MARK: - + staticCellWithTitle

+ (instancetype)staticCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                               icon:(nullable UIImage *)icon {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellStatic];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.icon = icon;

    return setting;
}

+ (instancetype)staticCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                           imageUrl:(NSString *)imageUrl {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellStatic];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.imageUrl = [NSURL URLWithString:imageUrl];

    return setting;
}

// MARK: - + linkCellWithTitle

+ (instancetype)linkCellWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                             icon:(nullable UIImage *)icon
                              url:(NSString *)url {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellLink];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.icon = icon;
    setting.url = [NSURL URLWithString:url];

    return setting;
}

+ (instancetype)linkCellWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                         imageUrl:(NSString *)imageUrl
                              url:(NSString *)url {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellLink];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.imageUrl = [NSURL URLWithString:imageUrl];
    setting.url = [NSURL URLWithString:url];

    return setting;
}

// MARK: - + switchCellWithTitle

+ (instancetype)switchCellWithTitle:(NSString *)title
                        defaultsKey:(NSString *)defaultsKey {
    return [self switchCellWithTitle:title subtitle:@"" icon:nil defaultsKey:defaultsKey];
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                        defaultsKey:(NSString *)defaultsKey
                    requiresRestart:(BOOL)requiresRestart {
    return [self switchCellWithTitle:title subtitle:@"" defaultsKey:defaultsKey requiresRestart:requiresRestart];
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                               icon:(nullable UIImage *)icon
                        defaultsKey:(NSString *)defaultsKey {
    return [self switchCellWithTitle:title subtitle:@"" icon:icon defaultsKey:defaultsKey];
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                               icon:(nullable UIImage *)icon
                        defaultsKey:(NSString *)defaultsKey
                    requiresRestart:(BOOL)requiresRestart {
    SPKSetting *setting = [self switchCellWithTitle:title subtitle:@"" icon:icon defaultsKey:defaultsKey];
    setting.requiresRestart = requiresRestart;
    return setting;
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                        defaultsKey:(NSString *)defaultsKey {
    return [self switchCellWithTitle:title subtitle:subtitle icon:nil defaultsKey:defaultsKey];
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                               icon:(UIImage *)icon
                        defaultsKey:(NSString *)defaultsKey {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellSwitch];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.icon = icon;
    setting.defaultsKey = defaultsKey;

    return setting;
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                        defaultsKey:(NSString *)defaultsKey
                    requiresRestart:(BOOL)requiresRestart {
    return [self switchCellWithTitle:title
                            subtitle:subtitle
                         defaultsKey:defaultsKey
                     requiresRestart:requiresRestart
        mutuallyExclusiveDefaultsKey:nil];
}

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                        defaultsKey:(NSString *)defaultsKey
                    requiresRestart:(BOOL)requiresRestart
       mutuallyExclusiveDefaultsKey:(NSString *)exclusiveDefaultsKey {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellSwitch];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.defaultsKey = defaultsKey;
    setting.requiresRestart = requiresRestart;
    setting.mutuallyExclusiveDefaultsKey = [exclusiveDefaultsKey copy];

    return setting;
}

// MARK: - + stepperCellWithTitle

+ (instancetype)stepperCellWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                         defaultsKey:(NSString *)defaultsKey
                                 min:(double)min
                                 max:(double)max
                                step:(double)step
                               label:(NSString *)label
                       singularLabel:(NSString *)singularLabel {
    return [self stepperCellWithTitle:title
                             subtitle:subtitle
                                 icon:nil
                          defaultsKey:defaultsKey
                                  min:min
                                  max:max
                                 step:step
                                label:label
                        singularLabel:singularLabel];
}

+ (instancetype)stepperCellWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                                icon:(UIImage *)icon
                         defaultsKey:(NSString *)defaultsKey
                                 min:(double)min
                                 max:(double)max
                                step:(double)step
                               label:(NSString *)label
                       singularLabel:(NSString *)singularLabel {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellStepper];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.icon = icon;
    setting.defaultsKey = defaultsKey;

    setting.min = min;
    setting.max = max;
    setting.step = step;
    setting.label = label;
    setting.singularLabel = singularLabel;

    return setting;
}

// MARK: - + buttonCellWithTitle

+ (instancetype)buttonCellWithTitle:(NSString *)title
                           subtitle:(nullable NSString *)subtitle
                               icon:(nullable UIImage *)icon
                             action:(void (^)(void))action {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellButton];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.icon = icon;
    setting.action = action;

    return setting;
}

#pragma mark + menuCellWithTitle

+ (instancetype)menuCellWithTitle:(NSString *)title
                         subtitle:(nullable NSString *)subtitle
                             menu:(UIMenu *)menu {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellMenu];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.baseMenu = menu;

    return setting;
}

+ (instancetype)menuCellWithTitle:(NSString *)title
                             icon:(nullable UIImage *)icon
                             menu:(UIMenu *)menu {
    return [self menuCellWithTitle:title subtitle:@"" icon:icon menu:menu];
}

+ (instancetype)menuCellWithTitle:(NSString *)title
                         subtitle:(nullable NSString *)subtitle
                             icon:(nullable UIImage *)icon
                             menu:(UIMenu *)menu {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellMenu];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.icon = icon;
    setting.baseMenu = menu;

    return setting;
}

// MARK: - + navigationCellWithTitle

+ (instancetype)navigationCellWithTitle:(NSString *)title
                               subtitle:(nullable NSString *)subtitle
                                   icon:(nullable UIImage *)icon
                            navSections:(NSArray *)navSections {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellNavigation];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.icon = icon;
    setting.navSections = navSections;

    return setting;
}

+ (instancetype)navigationCellWithTitle:(NSString *)title
                               subtitle:(nullable NSString *)subtitle
                                   icon:(nullable UIImage *)icon
                         viewController:(UIViewController *)viewController {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellNavigation];

    setting.title = title;
    setting.subtitle = subtitle;

    setting.icon = icon;
    setting.navViewController = viewController;

    return setting;
}

+ (instancetype)textFieldCellWithTitle:(NSString *)title
                           placeholder:(nullable NSString *)placeholder
                          keyboardType:(UIKeyboardType)keyboardType
                           defaultsKey:(NSString *)defaultsKey {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellTextField];

    setting.title = title;
    setting.placeholder = placeholder;
    setting.keyboardType = keyboardType;
    setting.defaultsKey = defaultsKey;

    return setting;
}

+ (instancetype)valueCellWithTitle:(NSString *)title
                          subtitle:(nullable NSString *)subtitle
                              icon:(nullable UIImage *)icon {
    SPKSetting *setting = [[self alloc] initWithType:SPKTableCellValue];

    setting.title = title;
    setting.subtitle = subtitle;
    setting.icon = icon;

    return setting;
}

// MARK: -  Instance methods

- (UIMenu *)menuForButton:(UIButton *)button {
    return [self submenuForButton:button submenu:self.baseMenu];
}

- (UIMenu *)submenuForButton:(UIButton *)button submenu:(UIMenu *)submenu {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

    for (id obj in submenu.children) {
        // Handle recursive submenus
        if ([obj isKindOfClass:[UIMenu class]]) {
            [children addObject:[self submenuForButton:button submenu:(UIMenu *)obj]];
            continue;
        } else if (![obj isKindOfClass:[UICommand class]]) {
            continue;
        }

        UICommand *child = obj;

        NSString *defaultsKey = child.propertyList[@"defaultsKey"];
        NSString *effectiveKey = SPKEffectivePreferenceKey(defaultsKey);
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:effectiveKey];
        if (saved == nil && ![effectiveKey isEqualToString:defaultsKey]) {
            saved = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey]; // inherit global
        }

        UICommand *command = [UICommand commandWithTitle:child.title
                                                   image:child.image
                                                  action:child.action
                                            propertyList:child.propertyList];

        if ([child.propertyList[@"value"] isEqualToString:@"max"] && ![SPKUtils getBoolPref:@"downloads_fetch_4k_images"]) {
            command.attributes = UIMenuElementAttributesDisabled;
        }

        if ([child.propertyList[@"value"] isEqualToString:saved]) {
            command.state = YES;

            [button setTitle:command.title forState:UIControlStateNormal];
        } else {
            command.state = NO;
        }

        [children addObject:command];
    }

    return [UIMenu menuWithTitle:submenu.title image:nil identifier:nil options:submenu.options children:children];
}

@end
