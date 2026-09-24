#import "SPKStrings.h"
#import "SPKWhatsNewViewController.h"
#import "../Tweak.h"

@implementation SPKWhatsNewViewController

// Release notes are curated from the conventional-commit log for the release range
// (see whats-new.sh). Feature rows carry a per-surface IG catalog glyph; fix rows
// share the `subtract` bullet so they read as one clean list. Icon names are
// SPKAssetUtils override keys — never SF Symbols. Keep in sync with README/FEATURES.
//
// Every content row is replaced wholesale each release. The keys name the change
// rather than its English wording, and the previous release's keys are deleted from
// every catalog, so a stale translation can never be reused for a different row.
- (NSArray<SPKPagedSheetPage *> *)buildPages {
    return @[
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_NEW_FEATURES_TEXT")
                                    body:[NSString stringWithFormat:SPKL(@"SETTINGS_WHATS_NEW_WHAT_S_NEW_VALUE_FORMAT"), SPKVersionString]
                                    rows:@[
                                        @{ @"icon": @"messages_off", @"text": SPKL(@"SETTINGS_WHATS_NEW_HIDE_CHATS_TEXT") },
                                        @{ @"icon": @"map_pin", @"text": SPKL(@"SETTINGS_WHATS_NEW_FRIENDS_MAP_LOCATION_TEXT") },
                                        @{ @"icon": @"instants", @"text": SPKL(@"SETTINGS_WHATS_NEW_INSTANTS_MANUAL_SEEN_TEXT") },
                                        @{ @"icon": @"playback", @"symbol": @"speedometer", @"text": SPKL(@"SETTINGS_WHATS_NEW_PLAYBACK_CONTROLS_TEXT") },
                                        @{ @"icon": @"loop", @"text": SPKL(@"SETTINGS_WHATS_NEW_STOP_LOOPING_REELS_TEXT") },
                                        @{ @"icon": @"compass", @"text": SPKL(@"SETTINGS_WHATS_NEW_OPEN_LINKS_IN_SAFARI_TEXT") },
                                        @{ @"icon": @"link", @"text": SPKL(@"SETTINGS_WHATS_NEW_CAPTION_LINKS_TEXT") },
                                        @{ @"icon": @"download", @"text": SPKL(@"SETTINGS_WHATS_NEW_BACKGROUND_DOWNLOADS_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_MORE_EXPLORE_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"translate", @"text": SPKL(@"SETTINGS_WHATS_NEW_LANGUAGE_DOWNLOADS_TEXT") },
                                        @{ @"icon": @"save", @"text": SPKL(@"SETTINGS_WHATS_NEW_PROFILE_SAVED_TAB_TEXT") },
                                        @{ @"icon": @"eye", @"text": SPKL(@"SETTINGS_WHATS_NEW_STORY_SEEN_TOGGLE_TEXT") },
                                        @{ @"icon": @"volume_none", @"text": SPKL(@"SETTINGS_WHATS_NEW_HIDE_AUDIO_UNAVAILABLE_TEXT") },
                                        @{ @"icon": @"repost", @"text": SPKL(@"SETTINGS_WHATS_NEW_REPOST_DATE_TEXT") },
                                        @{ @"icon": @"pip", @"symbol": @"pip", @"text": SPKL(@"SETTINGS_WHATS_NEW_PICTURE_IN_PICTURE_TEXT") },
                                        @{ @"icon": @"grid_square", @"text": SPKL(@"SETTINGS_WHATS_NEW_SQUARE_GRID_TEXT") },
                                        @{ @"icon": @"sparkle_gallery", @"text": SPKL(@"SETTINGS_WHATS_NEW_GALLERY_DRAG_SELECT_TEXT") },
                                        @{ @"text": SPKL(@"SETTINGS_WHATS_NEW_PLENTY_MORE_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_FIXES_IMPROVEMENTS_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_INSTAGRAM_448_COMPATIBILITY_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_COMMENTS_SWIPE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_DELETED_LOG_CRASH_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_INSTANTS_PERFORMANCE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_SEND_BUTTON_TAPS_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_STORY_PEEK_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_STORY_AUDIO_CHOICE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_REELS_START_MUTED_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_EXPLORE_LINK_PAGE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_DOWNLOAD_HISTORY_EDITS_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_ENCODING_SETTINGS_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_COPIED_LINK_QUALITY_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_OTHER_BUG_FIXES_UI_IMPROVEMENTS_TEXT") },
                                    ]],
    ];
}

- (NSString *)finishButtonTitle {
    return SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT");
}

- (BOOL)allowsInteractiveDismiss {
    return YES;
}

@end
