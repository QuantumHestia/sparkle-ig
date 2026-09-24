#import "SPKStrings.h"
#import "SPKDownloadBackgroundKeeper.h"

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "SPKDownloadTypes.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

// How often the keeper re-checks its remaining background time.
static NSTimeInterval const kSPKKeeperWatchdogInterval = 5.0;
// Escalate to the audio session with this much of the task window left. The
// expiration handler fires too close to the deadline to start playback there.
static NSTimeInterval const kSPKKeeperEscalationThreshold = 20.0;

static NSString *const kSPKKeeperReasonDrained = @"queue drained";
// Distinguishes our own request inside IG's notification delegate.
NSString *const kSPKDownloadFinishedNotificationMarker = @"spk_downloads_finished";

// Build a one second silent PCM file once per app run. Shipping this as a bundle
// resource would mean the keeper stops working on any layout where the bundle
// fails to resolve, and the file is smaller than its own path.
static NSString *_Nullable SPKSilentAudioFilePath(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"spk-download-silence.wav"];
        uint32_t const sampleRate = 8000;
        uint16_t const channels = 1;
        uint16_t const bitsPerSample = 16;
        uint32_t const blockAlign = channels * (bitsPerSample / 8);
        uint32_t const byteRate = sampleRate * blockAlign;
        uint32_t const dataBytes = byteRate; // one second
        uint32_t const riffSize = 36 + dataBytes;
        uint16_t const pcmFormat = 1;
        uint32_t const fmtChunkSize = 16;

        NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
        [wav appendBytes:"RIFF" length:4];
        [wav appendBytes:&riffSize length:4];
        [wav appendBytes:"WAVEfmt " length:8];
        [wav appendBytes:&fmtChunkSize length:4];
        [wav appendBytes:&pcmFormat length:2];
        [wav appendBytes:&channels length:2];
        [wav appendBytes:&sampleRate length:4];
        [wav appendBytes:&byteRate length:4];
        [wav appendBytes:&blockAlign length:2];
        [wav appendBytes:&bitsPerSample length:2];
        [wav appendBytes:"data" length:4];
        [wav appendBytes:&dataBytes length:4];
        [wav increaseLengthBy:dataBytes];

        if ([wav writeToFile:path atomically:YES])
            cached = path;
        else
            SPKLog(@"Downloads", @"background keeper could not stage its silence file");
    });
    return cached;
}

@interface SPKDownloadBackgroundKeeper ()
@property (nonatomic, assign) BOOL hasActiveWork;
@property (nonatomic, assign) BOOL inBackground;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, strong, nullable) dispatch_source_t watchdog;
@property (nonatomic, strong, nullable) AVAudioPlayer *silencePlayer;
@property (nonatomic, copy, nullable) NSString *restoreCategory;
@property (nonatomic, copy, nullable) NSString *restoreMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions restoreOptions;
@property (nonatomic, assign) NSTimeInterval armedAt;
@property (nonatomic, assign) NSUInteger succeededWhileArmed;
@property (nonatomic, assign) NSUInteger failedWhileArmed;
@property (nonatomic, assign) BOOL destinationIsUniform;
@property (nonatomic, assign) SPKDownloadDestination uniformDestination;
@end

@implementation SPKDownloadBackgroundKeeper

+ (SPKDownloadBackgroundKeeper *)shared {
    static SPKDownloadBackgroundKeeper *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [SPKDownloadBackgroundKeeper new];
    });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _backgroundTask = UIBackgroundTaskInvalid;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillTerminate) name:UIApplicationWillTerminateNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Read at call time: the toggle takes effect on the next download without a
// restart, and a user turning it off mid-download drops the keepalive.
- (BOOL)isEnabled {
    return [SPKUtils getBoolPref:kSPKDownloadBackgroundKey];
}

#pragma mark - State

- (void)setHasActiveWork:(BOOL)hasActiveWork {
    if (NSThread.isMainThread) {
        [self applyActiveWork:hasActiveWork];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf applyActiveWork:hasActiveWork];
    });
}

- (void)applyActiveWork:(BOOL)hasActiveWork {
    if (_hasActiveWork == hasActiveWork)
        return;
    _hasActiveWork = hasActiveWork;
    if (!hasActiveWork) {
        [self stopKeepAliveWithReason:kSPKKeeperReasonDrained];
    } else if (self.inBackground) {
        [self startKeepAlive];
    }
}

- (void)applicationDidEnterBackground {
    self.inBackground = YES;
    if (self.hasActiveWork)
        [self startKeepAlive];
}

- (void)applicationWillEnterForeground {
    self.inBackground = NO;
    [self stopKeepAliveWithReason:@"returned to foreground"];
}

- (void)applicationWillTerminate {
    [self stopKeepAliveWithReason:@"app terminating"];
}

#pragma mark - Keepalive

- (void)startKeepAlive {
    if (![self isEnabled]) {
        SPKLog(@"Downloads", @"background keepalive disabled by preference, downloads will stop when Instagram suspends");
        return;
    }
    if (self.armedAt <= 0) {
        self.armedAt = NSDate.date.timeIntervalSince1970;
        self.succeededWhileArmed = 0;
        self.failedWhileArmed = 0;
        self.destinationIsUniform = YES;
        SPKLog(@"Downloads", @"background keepalive armed with work in flight");
    }
    [self beginBackgroundTaskIfNeeded];
    [self startWatchdog];
}

- (void)stopKeepAliveWithReason:(NSString *)reason {
    BOOL wasArmed = self.armedAt > 0;
    NSTimeInterval held = wasArmed ? NSDate.date.timeIntervalSince1970 - self.armedAt : 0;
    BOOL usedAudio = self.silencePlayer != nil;
    // Only a drain means the work actually finished while the user was away. A
    // foreground return hands them the app itself, where the history is a tap
    // away, so a notification there would be noise.
    if (wasArmed && self.inBackground && [reason isEqualToString:kSPKKeeperReasonDrained])
        [self postFinishedNotification];
    self.armedAt = 0;
    [self stopWatchdog];
    [self stopSilentAudio];
    [self endBackgroundTask];
    if (wasArmed)
        SPKLog(@"Downloads", @"background keepalive released after %.1fs, %@ (silent audio: %@)", held, reason, usedAudio ? @"yes" : @"no");
}

- (void)beginBackgroundTaskIfNeeded {
    if (self.backgroundTask != UIBackgroundTaskInvalid)
        return;
    UIApplication *app = UIApplication.sharedApplication;
    if (!app)
        return;
    __weak typeof(self) weakSelf = self;
    self.backgroundTask = [app beginBackgroundTaskWithName:@"com.sparkle.downloads.keepalive"
                                         expirationHandler:^{
                                             // Only reclaims the assertion. If work is still running the
                                             // watchdog has already started the audio session, which is
                                             // what keeps the process alive past this point.
                                             [weakSelf endBackgroundTask];
                                         }];
}

- (void)endBackgroundTask {
    UIBackgroundTaskIdentifier task = self.backgroundTask;
    if (task == UIBackgroundTaskInvalid)
        return;
    self.backgroundTask = UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:task];
}

- (void)startWatchdog {
    if (self.watchdog)
        return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKKeeperWatchdogInterval * NSEC_PER_SEC)),
                              (uint64_t)(kSPKKeeperWatchdogInterval * NSEC_PER_SEC),
                              (uint64_t)(NSEC_PER_SEC / 2));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf watchdogFired];
    });
    self.watchdog = timer;
    dispatch_resume(timer);
}

- (void)stopWatchdog {
    if (!self.watchdog)
        return;
    dispatch_source_cancel(self.watchdog);
    self.watchdog = nil;
}

- (void)watchdogFired {
    if (!self.hasActiveWork || !self.inBackground || ![self isEnabled]) {
        [self stopKeepAliveWithReason:@"no longer needed"];
        return;
    }
    if (self.silencePlayer.isPlaying)
        return;
    NSTimeInterval remaining = UIApplication.sharedApplication.backgroundTimeRemaining;
    // The system reports an effectively unbounded value when nothing is counting
    // down, which is exactly when there is nothing to escalate for.
    if (!isfinite(remaining) || remaining > 1e6)
        return;
    SPKLog(@"Downloads", @"background keepalive has %.0fs of task time left with work still running", remaining);
    if (remaining <= kSPKKeeperEscalationThreshold)
        [self startSilentAudio];
}

#pragma mark - Finish notification

- (void)noteItemFinishedWithSuccess:(BOOL)success destination:(SPKDownloadDestination)destination {
    if (NSThread.isMainThread) {
        [self applyItemFinishedWithSuccess:success destination:destination];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf applyItemFinishedWithSuccess:success destination:destination];
    });
}

- (void)applyItemFinishedWithSuccess:(BOOL)success destination:(SPKDownloadDestination)destination {
    if (self.armedAt <= 0)
        return;
    if (!success) {
        self.failedWhileArmed++;
        return;
    }
    if (self.succeededWhileArmed == 0)
        self.uniformDestination = destination;
    else if (destination != self.uniformDestination)
        self.destinationIsUniform = NO;
    self.succeededWhileArmed++;
}

- (nullable NSString *)finishedNotificationBody {
    NSUInteger saved = self.succeededWhileArmed;
    NSUInteger failed = self.failedWhileArmed;
    if (saved == 0 && failed == 0)
        return nil;
    if (saved == 0)
        return SPKLP(@"DOWNLOADS_BACKGROUND_NOTIFICATION_FAILED_BODY", (NSInteger)failed);

    // The destination is joined on rather than baked into the plural: a plural
    // string carrying a second placeholder would have to survive two formatting
    // passes, which is a trap for anyone translating it.
    NSString *savedText = SPKLP(@"DOWNLOADS_BACKGROUND_NOTIFICATION_SAVED_BODY", (NSInteger)saved);
    if (self.destinationIsUniform && failed == 0) {
        savedText = [NSString stringWithFormat:SPKL(@"DOWNLOADS_BACKGROUND_NOTIFICATION_SAVED_TO_JOINER"),
                                               savedText,
                                               SPKDownloadDestinationDisplayName(self.uniformDestination)];
    }
    if (failed == 0)
        return savedText;
    return [NSString stringWithFormat:SPKL(@"DOWNLOADS_BACKGROUND_NOTIFICATION_BODY_JOINER"),
                                      savedText,
                                      SPKLP(@"DOWNLOADS_BACKGROUND_NOTIFICATION_FAILED_BODY", (NSInteger)failed)];
}

- (void)postFinishedNotification {
    if (![SPKUtils getBoolPref:kSPKDownloadBackgroundNotificationKey])
        return;
    NSString *body = [self finishedNotificationBody];
    if (!body.length)
        return;

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = SPKL(@"DOWNLOADS_BACKGROUND_NOTIFICATION_TITLE");
    content.body = body;
    content.userInfo = @{kSPKDownloadFinishedNotificationMarker : @YES};
    content.sound = UNNotificationSound.defaultSound;

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString
                                                                         content:content
                                                                         trigger:nil];
    NSUInteger saved = self.succeededWhileArmed;
    NSUInteger failed = self.failedWhileArmed;
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
                                                        withCompletionHandler:^(NSError *error) {
                                                            if (!error) {
                                                                SPKLog(@"Downloads", @"delivered background finish notification (%lu saved, %lu failed)",
                                                                       (unsigned long)saved, (unsigned long)failed);
                                                            } else if (error.domain == UNErrorDomain && error.code == UNErrorCodeNotificationsNotAllowed) {
                                                                SPKLog(@"Downloads", @"background finish notification refused: Instagram is not allowed to send notifications");
                                                            } else {
                                                                SPKLog(@"Downloads", @"background finish notification failed: %@", error.localizedDescription);
                                                            }
                                                        }];
}

+ (void)requestNotificationAuthorization {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        // A previously denied app is never prompted again, so requesting would
        // return a silent no and the user would only find out when a finished
        // download failed to announce itself hours later.
        if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
            [self presentAuthorizationDeniedAlert];
            return;
        }
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                              completionHandler:^(BOOL granted, NSError *error) {
                                  if (granted)
                                      return;
                                  SPKLog(@"Downloads", @"background finish notification authorization denied: %@", error.localizedDescription);
                                  [self presentAuthorizationDeniedAlert];
                              }];
    }];
}

+ (void)presentAuthorizationDeniedAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = topMostController();
        if (!presenter)
            return;
        [SPKIGAlertPresenter
            presentAlertFromViewController:presenter
                                     title:SPKL(@"DOWNLOADS_BACKGROUND_NOTIFICATION_DENIED_TITLE")
                                   message:SPKL(@"DOWNLOADS_BACKGROUND_NOTIFICATION_DENIED_MESSAGE")
                                   actions:@[
                                       [SPKIGAlertAction actionWithTitle:SPKL(@"COMMON_ACTION_OPEN_SETTINGS")
                                                                   style:SPKIGAlertActionStyleDefault
                                                                 handler:^{
                                                                     NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                                                                     if (url)
                                                                         [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                                                                 }],
                                       [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                   style:SPKIGAlertActionStyleCancel
                                                                 handler:nil]
                                   ]];
    });
}

#pragma mark - Silent audio

- (void)startSilentAudio {
    if (self.silencePlayer.isPlaying)
        return;
    NSString *path = SPKSilentAudioFilePath();
    if (!path.length)
        return;

    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (!self.restoreCategory) {
        self.restoreCategory = session.category;
        self.restoreMode = session.mode;
        self.restoreOptions = session.categoryOptions;
    }
    NSError *sessionError = nil;
    // Mixing is what keeps this invisible: Instagram's own playback, and anything
    // else already making sound, carries on untouched.
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionMixWithOthers
                        error:&sessionError]) {
        SPKLog(@"Downloads", @"background keeper could not configure its audio session: %@", sessionError.localizedDescription);
        return;
    }
    if (![session setActive:YES error:&sessionError]) {
        SPKLog(@"Downloads", @"background keeper could not activate its audio session: %@", sessionError.localizedDescription);
        return;
    }

    NSError *playerError = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&playerError];
    if (!player) {
        SPKLog(@"Downloads", @"background keeper could not open its silence file: %@", playerError.localizedDescription);
        [self restoreAudioSession];
        return;
    }
    player.numberOfLoops = -1;
    player.volume = 1.0;
    if (![player play]) {
        SPKLog(@"Downloads", @"background keeper could not start silent playback");
        [self restoreAudioSession];
        return;
    }
    self.silencePlayer = player;
    SPKLog(@"Downloads", @"background keeper escalated to a silent audio session");
}

- (void)stopSilentAudio {
    if (!self.silencePlayer && !self.restoreCategory)
        return;
    [self.silencePlayer stop];
    self.silencePlayer = nil;
    [self restoreAudioSession];
}

- (void)restoreAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (self.restoreCategory.length) {
        [session setCategory:self.restoreCategory mode:self.restoreMode ?: AVAudioSessionModeDefault options:self.restoreOptions error:nil];
    }
    self.restoreCategory = nil;
    self.restoreMode = nil;
    self.restoreOptions = 0;
}

@end
