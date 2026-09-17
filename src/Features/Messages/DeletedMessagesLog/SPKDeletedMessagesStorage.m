#import "SPKDeletedMessagesStorage.h"
#import <UIKit/UIKit.h>
#import "SPKStrings.h"
#import "../../../Shared/Avatars/SPKAvatarCache.h"
#import "../../../Shared/SPKStoragePaths.h"

NSNotificationName const SPKDeletedMessagesDidChangeNotification = @"SPKDeletedMessagesDidChangeNotification";

static NSString *const kSPKDMMediaDir = @"media";
static NSString *const kSPKDMSenderFlagsFile = @"sender_flags.json";
static NSString *const kSPKDMPendingCandidatesDir = @"candidates";
static NSString *const kSPKDMPendingRemovalsDir = @"removals";

@implementation SPKDeletedMessagesStorage

#pragma mark - Plumbing

static dispatch_queue_t spkDMQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.sparkle.deletedmessages.io", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static NSString *spkSafePK(NSString *pk) {
    return pk.length ? pk : @"anon";
}

static NSString *spkStorageDir(void) {
    NSString *dir = [SPKStoragePaths deletedMessagesDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *spkMediaDirForOwner(NSString *pk) {
    NSString *dir = [[spkStorageDir() stringByAppendingPathComponent:kSPKDMMediaDir]
        stringByAppendingPathComponent:spkSafePK(pk)];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *spkPendingStorageDir(void) {
    NSString *dir = [SPKStoragePaths deletedMessagesPendingDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *spkPendingSubdirectory(NSString *name) {
    NSString *dir = [spkPendingStorageDir() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *spkPendingJSONPath(NSString *directory, NSString *pk) {
    return [[spkPendingSubdirectory(directory) stringByAppendingPathComponent:spkSafePK(pk)]
        stringByAppendingPathExtension:@"json"];
}

static NSString *spkStagedMediaDirForOwner(NSString *pk) {
    NSString *dir = [[spkPendingStorageDir() stringByAppendingPathComponent:kSPKDMMediaDir]
        stringByAppendingPathComponent:spkSafePK(pk)];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *spkJSONPathForOwner(NSString *pk) {
    return [spkStorageDir() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", spkSafePK(pk)]];
}

static NSString *spkFlagsPath(void) {
    return [spkStorageDir() stringByAppendingPathComponent:kSPKDMSenderFlagsFile];
}

static NSArray *spkReadArray(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length)
        return @[];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSArray class]] ? obj : @[];
}

static BOOL spkWriteArray(NSString *path, NSArray *arr) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:(arr ?: @[]) options:0 error:&err];
    if (!data)
        return NO;
    return [data writeToFile:path atomically:YES];
}

static NSMutableDictionary *spkReadDictionary(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length)
        return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : [NSMutableDictionary dictionary];
}

static BOOL spkWriteDictionary(NSString *path, NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:(dict ?: @{}) options:0 error:nil];
    return data ? [data writeToFile:path atomically:YES] : NO;
}

#pragma mark - Pending store cache

// The pending stores (candidates, removals) used to be re-read, parsed and
// rewritten in full for every change. Candidates change once per incoming
// message, and Instagram applies a sync backlog message by message on the main
// thread without draining the autorelease pool, so each rewrite's temporaries
// piled up until the app was killed for memory. The stores now live in memory,
// loaded once per file, and are written back off the calling thread.
//
// The on-disk format is unchanged, so files written by older builds load as-is
// and older builds can read what this writes. Everything that touches these
// files goes through the functions below, on spkDMQueue.

static const NSTimeInterval kSPKDMCandidateFlushDelay = 1.5;
static const NSUInteger kSPKDMCandidateLimit = 2500;
static const NSUInteger kSPKDMCandidatePruneSlack = 250;
static const NSTimeInterval kSPKDMCandidateMaxAge = 14 * 24 * 60 * 60;
static NSString *const kSPKDMCandidateCapturedAtKey = @"captured_at";
// A recorded unsend whose content is still unresolved after this long never
// will be: neither Instagram's cache nor a thread fetch has it.
static const NSTimeInterval kSPKDMRemovalMaxAge = 30 * 24 * 60 * 60;

static NSMutableDictionary<NSString *, NSMutableDictionary *> *spkPendingStores;
static NSMutableSet<NSString *> *spkPendingDirtyPaths;
static BOOL spkPendingFlushScheduled;

static NSString *spkStagedMediaDirForOwner(NSString *pk);
static void spkPendingFlushOnQueue(void);

static dispatch_queue_t spkPendingWriterQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.sparkle.deletedmessages.pending-writer", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Flushes everything outstanding and waits for the writes to land. Called when
// the app leaves the foreground, the last point it reliably gets to run.
static void spkPendingFlushAndWait(void) {
    dispatch_sync(spkDMQueue(), ^{
        spkPendingFlushOnQueue();
    });
    dispatch_sync(spkPendingWriterQueue(), ^{
    });
}

static void spkPendingObserveLifecycleOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[ UIApplicationDidEnterBackgroundNotification, UIApplicationWillTerminateNotification ]) {
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(__unused NSNotification *note) {
                                spkPendingFlushAndWait();
                            }];
        }
    });
}

static NSNumber *spkPendingTimestamp(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

// Drops staging candidates nobody is likely to need: older than the age limit,
// then the oldest beyond the count limit. A candidate is only a pre-captured copy
// of a message that still exists in Instagram; the deleted-messages log itself is
// a separate file and is never touched here. Candidates that a recorded unsend is
// still waiting on are always kept. Returns YES if anything changed.
static BOOL spkPruneCandidates(NSMutableDictionary *candidates, NSDictionary *removals, NSString *pk) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL changed = NO;
    NSMutableArray<NSString *> *prunable = [NSMutableArray array];
    NSMutableArray<NSString *> *dropped = [NSMutableArray array];

    for (NSString *messageId in candidates.allKeys) {
        NSMutableDictionary *entry = candidates[messageId];
        if (![entry isKindOfClass:[NSMutableDictionary class]])
            continue;
        // Entries written before this field existed get the current time, so
        // upgrading never ages anything out at once.
        if (!spkPendingTimestamp(entry[kSPKDMCandidateCapturedAtKey])) {
            entry[kSPKDMCandidateCapturedAtKey] = @(now);
            changed = YES;
        }
        if (removals[messageId])
            continue;
        if (now - spkPendingTimestamp(entry[kSPKDMCandidateCapturedAtKey]).doubleValue > kSPKDMCandidateMaxAge)
            [dropped addObject:messageId];
        else
            [prunable addObject:messageId];
    }

    if (prunable.count > kSPKDMCandidateLimit) {
        [prunable sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDictionary *ea = candidates[a], *eb = candidates[b];
            NSComparisonResult r = [spkPendingTimestamp(ea[kSPKDMCandidateCapturedAtKey]) compare:spkPendingTimestamp(eb[kSPKDMCandidateCapturedAtKey])];
            if (r != NSOrderedSame)
                return r;
            return [(spkPendingTimestamp(ea[@"sent_at"]) ?: @0) compare:(spkPendingTimestamp(eb[@"sent_at"]) ?: @0)];
        }];
        [dropped addObjectsFromArray:[prunable subarrayWithRange:NSMakeRange(0, prunable.count - kSPKDMCandidateLimit)]];
    }

    if (!dropped.count)
        return changed;

    // Staged media belongs to its candidate alone; the log keeps its own copy in a
    // different directory once a message is finalized.
    NSString *stagedDir = spkStagedMediaDirForOwner(pk);
    NSMutableArray<NSString *> *stagedFiles = [NSMutableArray array];
    for (NSString *messageId in dropped) {
        NSDictionary *entry = candidates[messageId];
        for (NSString *key in @[ @"staged_media_path", @"staged_thumbnail_path" ]) {
            NSString *rel = [entry[key] isKindOfClass:[NSString class]] ? entry[key] : nil;
            if (rel.length)
                [stagedFiles addObject:[stagedDir stringByAppendingPathComponent:rel.lastPathComponent]];
        }
        [candidates removeObjectForKey:messageId];
    }
    if (stagedFiles.count) {
        dispatch_async(spkPendingWriterQueue(), ^{
            for (NSString *file in stagedFiles)
                [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        });
    }
    return YES;
}

static void spkPendingMarkDirtyOnQueue(NSString *path, BOOL immediate) {
    if (!spkPendingDirtyPaths)
        spkPendingDirtyPaths = [NSMutableSet set];
    [spkPendingDirtyPaths addObject:path];
    if (immediate) {
        spkPendingFlushOnQueue();
        return;
    }
    if (spkPendingFlushScheduled)
        return;
    spkPendingFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKDMCandidateFlushDelay * NSEC_PER_SEC)), spkDMQueue(), ^{
        spkPendingFlushScheduled = NO;
        spkPendingFlushOnQueue();
    });
}

static void spkPendingFlushOnQueue(void) {
    if (!spkPendingDirtyPaths.count)
        return;
    for (NSString *path in spkPendingDirtyPaths) {
        NSDictionary *store = spkPendingStores[path];
        if (!store)
            continue;
        NSData *data = nil;
        @autoreleasepool {
            data = [NSJSONSerialization dataWithJSONObject:store options:0 error:nil];
        }
        if (!data)
            continue;
        dispatch_async(spkPendingWriterQueue(), ^{
            @autoreleasepool {
                [data writeToFile:path atomically:YES];
            }
        });
    }
    [spkPendingDirtyPaths removeAllObjects];
}

// Returns the live, mutable store for one pending file, loading it on first use.
// Must run on spkDMQueue.
static NSMutableDictionary *spkPendingStoreOnQueue(NSString *directory, NSString *pk) {
    NSString *path = spkPendingJSONPath(directory, pk);
    NSMutableDictionary *store = spkPendingStores[path];
    if (store)
        return store;

    spkPendingObserveLifecycleOnce();
    if (!spkPendingStores)
        spkPendingStores = [NSMutableDictionary dictionary];

    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if ([obj isKindOfClass:[NSMutableDictionary class]]) {
                store = obj;
            } else {
                // Keep an unreadable file instead of overwriting it with an empty store.
                NSString *backup = [path stringByAppendingFormat:@".unreadable-%.0f", [NSDate date].timeIntervalSince1970];
                [[NSFileManager defaultManager] moveItemAtPath:path toPath:backup error:nil];
            }
        }
    }
    if (!store)
        store = [NSMutableDictionary dictionary];
    spkPendingStores[path] = store;

    if ([directory isEqualToString:kSPKDMPendingRemovalsDir]) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        BOOL changed = NO;
        for (NSString *messageId in store.allKeys) {
            NSDictionary *entry = [store[messageId] isKindOfClass:[NSDictionary class]] ? store[messageId] : nil;
            NSNumber *createdAt = spkPendingTimestamp(entry[@"created_at"]);
            if (createdAt && now - createdAt.doubleValue > kSPKDMRemovalMaxAge) {
                [store removeObjectForKey:messageId];
                changed = YES;
            }
        }
        if (changed)
            spkPendingMarkDirtyOnQueue(path, NO);
    }

    if ([directory isEqualToString:kSPKDMPendingCandidatesDir]) {
        NSDictionary *removals = spkPendingStoreOnQueue(kSPKDMPendingRemovalsDir, pk);
        if (spkPruneCandidates(store, removals, pk))
            spkPendingMarkDirtyOnQueue(path, NO);
    }
    return store;
}

static unsigned long long spkDirectorySize(NSString *dir) {
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
    unsigned long long total = 0;
    for (NSString *rel in en) {
        NSDictionary *attrs = [en fileAttributes];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) {
            total += [attrs[NSFileSize] unsignedLongLongValue];
        }
        (void)rel;
    }
    return total;
}

// Sender flags are checked for every unsend, often on the main thread, and only
// change when the user pins or blocks someone. The file is read once and kept
// in memory; every write goes through spkWriteFlags, which updates this copy.
// Code that replaces or removes the file by other means calls
// spkInvalidateFlagsCacheOnQueue. Must be used on spkDMQueue.
static NSMutableDictionary *spkFlagsCache;

static void spkInvalidateFlagsCacheOnQueue(void) {
    spkFlagsCache = nil;
}

static NSMutableDictionary *spkReadFlagsFromDisk(void) {
    NSData *data = [NSData dataWithContentsOfFile:spkFlagsPath()];
    if (!data.length)
        return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : [NSMutableDictionary dictionary];
}

static NSMutableDictionary *spkReadFlags(void) {
    if (!spkFlagsCache)
        spkFlagsCache = spkReadFlagsFromDisk();
    return spkFlagsCache;
}

static BOOL spkWriteFlags(NSMutableDictionary *flags) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:(flags ?: @{}) options:0 error:nil];
    BOOL written = data ? [data writeToFile:spkFlagsPath() atomically:YES] : NO;
    // If the write failed, reload from disk next time so memory never claims a
    // change the file doesn't have.
    spkFlagsCache = written ? flags : nil;
    return written;
}

static NSMutableDictionary *spkFlagsForOwner(NSMutableDictionary *flags, NSString *ownerPK, BOOL create) {
    NSString *owner = spkSafePK(ownerPK);
    id existing = flags[owner];
    if ([existing isKindOfClass:[NSMutableDictionary class]])
        return existing;
    if ([existing isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *copy = [existing mutableCopy];
        flags[owner] = copy;
        return copy;
    }
    if (!create)
        return nil;
    NSMutableDictionary *ownerFlags = [NSMutableDictionary dictionary];
    flags[owner] = ownerFlags;
    return ownerFlags;
}

static NSDictionary *spkSenderFlags(NSString *senderPK, NSString *ownerPK) {
    if (!senderPK.length)
        return @{};
    __block NSDictionary *result = nil;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *flags = spkReadFlags();
        NSDictionary *ownerFlags = spkFlagsForOwner(flags, ownerPK, NO);
        id senderFlags = ownerFlags[senderPK];
        result = [senderFlags isKindOfClass:[NSDictionary class]] ? [senderFlags copy] : @{};
    });
    return result ?: @{};
}

static void spkPostChanged(NSString *ownerPK) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKDeletedMessagesDidChangeNotification
                                                            object:nil
                                                          userInfo:ownerPK.length ? @{@"owner_pk" : ownerPK} : @{}];
    });
}

// Newest-first order. capturedAt is required; deletedAt is the truer key when present.
static NSDate *spkSortKey(SPKDeletedMessage *m) {
    return m.deletedAt ?: (m.capturedAt ?: m.sentAt);
}

static NSArray<SPKDeletedMessage *> *spkDecode(NSArray *raw) {
    NSMutableArray<SPKDeletedMessage *> *out = [NSMutableArray arrayWithCapacity:raw.count];
    for (id d in raw) {
        SPKDeletedMessage *m = [SPKDeletedMessage messageFromJSONDict:d];
        if (m)
            [out addObject:m];
    }
    return out;
}

static NSArray<NSDictionary *> *spkEncode(NSArray<SPKDeletedMessage *> *msgs) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:msgs.count];
    for (SPKDeletedMessage *m in msgs)
        [out addObject:[m toJSONDict]];
    return out;
}

#pragma mark - Read

+ (NSArray<SPKDeletedMessage *> *)allMessagesForOwnerPK:(NSString *)ownerPK {
    __block NSArray<SPKDeletedMessage *> *result = nil;
    dispatch_sync(spkDMQueue(), ^{
        result = spkDecode(spkReadArray(spkJSONPathForOwner(ownerPK)));
    });
    return result ?: @[];
}

+ (NSArray<NSString *> *)allOwnerPKs {
    __block NSArray<NSString *> *owners = @[];
    dispatch_sync(spkDMQueue(), ^{
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:spkStorageDir() error:nil] ?: @[];
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (NSString *file in files) {
            if (![file.pathExtension isEqualToString:@"json"])
                continue;
            if ([file isEqualToString:kSPKDMSenderFlagsFile])
                continue;
            NSString *owner = file.stringByDeletingPathExtension;
            if (owner.length)
                [result addObject:owner];
        }
        owners = [result copy];
    });
    return owners;
}

+ (NSArray<SPKDeletedMessage *> *)messagesForSenderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    if (!senderPK.length)
        return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (SPKDeletedMessage *m in [self allMessagesForOwnerPK:ownerPK]) {
        if ([m.senderPk isEqualToString:senderPK])
            [out addObject:m];
    }
    return out;
}

+ (NSArray<SPKDeletedMessage *> *)messagesForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId.length)
        return @[];
    NSMutableArray<SPKDeletedMessage *> *out = [NSMutableArray array];
    for (SPKDeletedMessage *m in [self allMessagesForOwnerPK:ownerPK]) {
        if ([m.threadId isEqualToString:threadId])
            [out addObject:m];
    }
    // Chronological by original send time (fall back to deletion time) so the
    // conversation reads top-to-bottom like a real chat.
    [out sortUsingComparator:^NSComparisonResult(SPKDeletedMessage *a, SPKDeletedMessage *b) {
        NSDate *da = a.sentAt ?: a.deletedAt ?
                             : a.capturedAt  ?
                                             : [NSDate distantPast];
        NSDate *db = b.sentAt ?: b.deletedAt ?
                             : b.capturedAt  ?
                                             : [NSDate distantPast];
        return [da compare:db];
    }];
    return out;
}

// Best display label for a sender, from any captured message by them. Prefer
// the full name (IG titles untitled groups with participant names, not handles).
static NSString *spkSenderLabel(SPKDeletedMessage *m) {
    if (m.senderFullName.length)
        return m.senderFullName;
    if (m.senderUsername.length)
        return [@"@" stringByAppendingString:m.senderUsername];
    return nil;
}

// Generated group title from the distinct non-owner sender labels — used when
// the real thread name wasn't captured (e.g. messages logged before the chat
// was opened with the tweak active).
static NSString *spkGeneratedGroupTitle(NSArray<SPKDeletedMessage *> *msgs, NSString *ownerPK) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (SPKDeletedMessage *m in msgs) {
        if (!m.senderPk.length || [m.senderPk isEqualToString:ownerPK])
            continue;
        if ([seen containsObject:m.senderPk])
            continue;
        [seen addObject:m.senderPk];
        NSString *label = spkSenderLabel(m);
        if (label.length)
            [labels addObject:label];
    }
    if (!labels.count)
        return SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_GROUP_CHAT_TEXT");
    if (labels.count <= 3)
        return [labels componentsJoinedByString:@", "];
    NSArray *head = [labels subarrayWithRange:NSMakeRange(0, 3)];
    return [NSString stringWithFormat:@"%@ +%lu", [head componentsJoinedByString:@", "], (unsigned long)(labels.count - 3)];
}

+ (NSArray<SPKDeletedMessageGroup *> *)groupedForOwnerPK:(NSString *)ownerPK {
    NSArray<SPKDeletedMessage *> *all = [self allMessagesForOwnerPK:ownerPK]; // newest-first

    // First pass: per-thread aggregates that decide group-ness and title.
    NSMutableDictionary<NSString *, NSMutableArray<SPKDeletedMessage *> *> *byThread = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *nonOwnerSenders = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *flaggedGroupThreads = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *titleByThread = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *photoByThread = [NSMutableDictionary dictionary];
    for (SPKDeletedMessage *m in all) {
        NSString *tid = m.threadId;
        if (!tid.length)
            continue;
        NSMutableArray *list = byThread[tid];
        if (!list) {
            list = [NSMutableArray array];
            byThread[tid] = list;
        }
        [list addObject:m];
        if (m.senderPk.length && ![m.senderPk isEqualToString:ownerPK]) {
            NSMutableSet *s = nonOwnerSenders[tid];
            if (!s) {
                s = [NSMutableSet set];
                nonOwnerSenders[tid] = s;
            }
            [s addObject:m.senderPk];
        }
        if (m.isGroup)
            [flaggedGroupThreads addObject:tid];
        if (m.threadTitle.length && !titleByThread[tid])
            titleByThread[tid] = m.threadTitle;
        if (m.threadPhotoURL.length && !photoByThread[tid])
            photoByThread[tid] = m.threadPhotoURL;
    }

    NSMutableSet<NSString *> *groupThreads = [NSMutableSet set];
    for (NSString *tid in byThread) {
        if ([flaggedGroupThreads containsObject:tid] || nonOwnerSenders[tid].count >= 2) {
            [groupThreads addObject:tid];
        }
    }

    NSMutableArray<SPKDeletedMessageGroup *> *groups = [NSMutableArray array];

    // Group-thread entries — one per thread.
    for (NSString *tid in groupThreads) {
        NSArray<SPKDeletedMessage *> *msgs = byThread[tid];
        if (!msgs.count)
            continue;
        SPKDeletedMessageGroup *g = [SPKDeletedMessageGroup new];
        g.isGroup = YES;
        g.threadId = tid;
        g.threadTitle = titleByThread[tid].length ? titleByThread[tid] : spkGeneratedGroupTitle(msgs, ownerPK);
        g.threadPhotoURL = photoByThread[tid];
        g.messages = msgs;
        NSDictionary *flags = spkSenderFlags(g.flagKey, ownerPK);
        g.isPinned = [flags[@"pinned"] boolValue];
        g.isBlocked = [flags[@"blocked"] boolValue];
        [groups addObject:g];
    }

    // 1:1 entries — bucket the rest by sender (legacy behaviour).
    NSMutableDictionary<NSString *, NSMutableArray<SPKDeletedMessage *> *> *byPk = [NSMutableDictionary dictionary];
    for (SPKDeletedMessage *m in all) {
        if (m.threadId.length && [groupThreads containsObject:m.threadId])
            continue;
        if (!m.senderPk.length)
            continue;
        NSMutableArray *list = byPk[m.senderPk];
        if (!list) {
            list = [NSMutableArray array];
            byPk[m.senderPk] = list;
        }
        [list addObject:m];
    }
    for (NSString *pk in byPk) {
        NSArray<SPKDeletedMessage *> *msgs = byPk[pk];
        SPKDeletedMessage *latest = msgs.firstObject;
        SPKDeletedMessageGroup *g = [SPKDeletedMessageGroup new];
        g.senderPk = pk;
        g.senderUsername = latest.senderUsername;
        g.senderFullName = latest.senderFullName;
        g.senderProfilePicURL = latest.senderProfilePicURL;
        NSDictionary *flags = spkSenderFlags(pk, ownerPK);
        g.isPinned = [flags[@"pinned"] boolValue];
        g.isBlocked = [flags[@"blocked"] boolValue];
        g.messages = msgs;
        [groups addObject:g];
    }

    [groups sortUsingComparator:^NSComparisonResult(SPKDeletedMessageGroup *a, SPKDeletedMessageGroup *b) {
        if (a.isPinned != b.isPinned)
            return a.isPinned ? NSOrderedAscending : NSOrderedDescending;
        NSDate *da = a.lastDeletedAt ?: [NSDate distantPast];
        NSDate *db = b.lastDeletedAt ?: [NSDate distantPast];
        return [db compare:da];
    }];
    return groups;
}

+ (SPKDeletedMessageGroup *)groupForSenderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    if (!senderPK.length)
        return nil;
    NSArray<SPKDeletedMessage *> *msgs = [self messagesForSenderPK:senderPK ownerPK:ownerPK];
    if (!msgs.count)
        return nil;
    SPKDeletedMessage *latest = msgs.firstObject; // already newest-first
    SPKDeletedMessageGroup *g = [SPKDeletedMessageGroup new];
    g.senderPk = senderPK;
    g.senderUsername = latest.senderUsername;
    g.senderFullName = latest.senderFullName;
    g.senderProfilePicURL = latest.senderProfilePicURL;
    NSDictionary *flags = spkSenderFlags(senderPK, ownerPK);
    g.isPinned = [flags[@"pinned"] boolValue];
    g.isBlocked = [flags[@"blocked"] boolValue];
    g.messages = msgs;
    return g;
}

+ (SPKDeletedMessageGroup *)groupForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId.length)
        return nil;
    NSArray<SPKDeletedMessage *> *all = [self allMessagesForOwnerPK:ownerPK]; // newest-first
    NSMutableArray<SPKDeletedMessage *> *msgs = [NSMutableArray array];
    NSMutableSet<NSString *> *nonOwner = [NSMutableSet set];
    BOOL flagged = NO;
    NSString *title = nil;
    NSString *photo = nil;
    NSString *fallbackSender = nil;
    for (SPKDeletedMessage *m in all) {
        if (![m.threadId isEqualToString:threadId])
            continue;
        [msgs addObject:m];
        if (m.senderPk.length && ![m.senderPk isEqualToString:ownerPK])
            [nonOwner addObject:m.senderPk];
        if (m.senderPk.length && !fallbackSender)
            fallbackSender = m.senderPk;
        if (m.isGroup)
            flagged = YES;
        if (m.threadTitle.length && !title)
            title = m.threadTitle;
        if (m.threadPhotoURL.length && !photo)
            photo = m.threadPhotoURL;
    }
    if (!msgs.count)
        return nil;

    if (flagged || nonOwner.count >= 2) {
        SPKDeletedMessageGroup *g = [SPKDeletedMessageGroup new];
        g.isGroup = YES;
        g.threadId = threadId;
        g.threadTitle = title.length ? title : spkGeneratedGroupTitle(msgs, ownerPK);
        g.threadPhotoURL = photo;
        g.messages = msgs;
        NSDictionary *flags = spkSenderFlags(g.flagKey, ownerPK);
        g.isPinned = [flags[@"pinned"] boolValue];
        g.isBlocked = [flags[@"blocked"] boolValue];
        return g;
    }

    // 1:1 — prefer the non-owner sender, else whatever sender we have.
    NSString *senderPK = nonOwner.anyObject ?: fallbackSender;
    return senderPK.length ? [self groupForSenderPK:senderPK ownerPK:ownerPK] : nil;
}

#pragma mark - Write

+ (BOOL)saveMessage:(SPKDeletedMessage *)message forOwnerPK:(NSString *)ownerPK {
    if (!message.messageId.length)
        return NO;
    return [self saveMessages:@[ message ] forOwnerPK:ownerPK];
}

+ (BOOL)saveMessages:(NSArray<SPKDeletedMessage *> *)messages forOwnerPK:(NSString *)ownerPK {
    if (!messages.count)
        return NO;
    __block BOOL ok = NO;
    dispatch_sync(spkDMQueue(), ^{
        NSString *path = spkJSONPathForOwner(ownerPK);
        NSMutableArray<SPKDeletedMessage *> *cur = [spkDecode(spkReadArray(path)) mutableCopy];
        NSMutableSet<NSString *> *incomingIds = [NSMutableSet setWithCapacity:messages.count];
        NSMutableDictionary<NSString *, SPKDeletedMessage *> *existingById = [NSMutableDictionary dictionary];
        for (SPKDeletedMessage *m in cur) {
            if (m.messageId.length)
                existingById[m.messageId] = m;
        }
        for (SPKDeletedMessage *m in messages) {
            if (!m.messageId.length)
                continue;
            SPKDeletedMessage *existing = existingById[m.messageId];
            if (!m.mediaPath.length)
                m.mediaPath = existing.mediaPath;
            if (!m.thumbnailPath.length)
                m.thumbnailPath = existing.thumbnailPath;
            if (!m.mediaMimeType.length)
                m.mediaMimeType = existing.mediaMimeType;
            if (!m.stagedMediaPath.length)
                m.stagedMediaPath = existing.stagedMediaPath;
            if (!m.stagedThumbnailPath.length)
                m.stagedThumbnailPath = existing.stagedThumbnailPath;
            [incomingIds addObject:m.messageId];
        }
        // Drop any existing record for the incoming ids (replace semantics).
        NSMutableArray<SPKDeletedMessage *> *kept = [NSMutableArray arrayWithCapacity:cur.count];
        for (SPKDeletedMessage *m in cur) {
            if (![incomingIds containsObject:m.messageId])
                [kept addObject:m];
        }
        [kept addObjectsFromArray:messages];
        [kept sortUsingComparator:^NSComparisonResult(SPKDeletedMessage *a, SPKDeletedMessage *b) {
            NSDate *da = spkSortKey(a) ?: [NSDate distantPast];
            NSDate *db = spkSortKey(b) ?: [NSDate distantPast];
            return [db compare:da];
        }];
        NSUInteger maxCount = 10000;
        if (kept.count > maxCount) {
            [kept removeObjectsInRange:NSMakeRange(maxCount, kept.count - maxCount)];
        }
        ok = spkWriteArray(path, spkEncode(kept));
    });
    if (ok)
        spkPostChanged(ownerPK);
    return ok;
}

+ (BOOL)applySenderInfo:(NSDictionary *)info
            forSenderPK:(NSString *)senderPK
                ownerPK:(NSString *)ownerPK {
    if (!senderPK.length || ![info isKindOfClass:[NSDictionary class]])
        return NO;
    NSString *u = [info[@"username"] isKindOfClass:[NSString class]] ? info[@"username"] : nil;
    NSString *fn = [info[@"full_name"] isKindOfClass:[NSString class]] ? info[@"full_name"] : nil;
    NSString *p = [info[@"profile_pic_url"] isKindOfClass:[NSString class]] ? info[@"profile_pic_url"] : nil;
    if (!u.length && !fn.length && !p.length)
        return NO;

    __block BOOL touched = NO;
    dispatch_sync(spkDMQueue(), ^{
        NSString *path = spkJSONPathForOwner(ownerPK);
        NSMutableArray<SPKDeletedMessage *> *cur = [spkDecode(spkReadArray(path)) mutableCopy];
        for (SPKDeletedMessage *m in cur) {
            if (![m.senderPk isEqualToString:senderPK])
                continue;
            if (u.length && !m.senderUsername.length) {
                m.senderUsername = u;
                touched = YES;
            }
            if (fn.length && !m.senderFullName.length) {
                m.senderFullName = fn;
                touched = YES;
            }
            if (p.length && !m.senderProfilePicURL.length) {
                m.senderProfilePicURL = p;
                touched = YES;
            }
        }
        if (touched)
            spkWriteArray(path, spkEncode(cur));
    });
    if (touched)
        spkPostChanged(ownerPK);
    return touched;
}

+ (BOOL)backfillThreadTitle:(NSString *)title
                    isGroup:(BOOL)isGroup
                   photoURL:(NSString *)photoURL
                forThreadId:(NSString *)threadId
                    ownerPK:(NSString *)ownerPK {
    if (!threadId.length)
        return NO;
    __block BOOL changed = NO;
    dispatch_sync(spkDMQueue(), ^{
        NSString *path = spkJSONPathForOwner(ownerPK);
        NSMutableArray<SPKDeletedMessage *> *cur = [spkDecode(spkReadArray(path)) mutableCopy];
        for (SPKDeletedMessage *m in cur) {
            if (![m.threadId isEqualToString:threadId])
                continue;
            if (isGroup && !m.isGroup) {
                m.isGroup = YES;
                changed = YES;
            }
            if (title.length && ![m.threadTitle isEqualToString:title]) {
                m.threadTitle = title;
                changed = YES;
            }
            if (photoURL.length && ![m.threadPhotoURL isEqualToString:photoURL]) {
                m.threadPhotoURL = photoURL;
                changed = YES;
            }
        }
        if (changed)
            spkWriteArray(path, spkEncode(cur));
    });
    if (changed)
        spkPostChanged(ownerPK);

    // This runs from the thread-metadata resolver with a *fresh* group-photo URL
    // (the live thread object). Group-photo CDN URLs can't be re-resolved by PK
    // like user avatars, so warm the shared cache now while the URL is valid —
    // the downloaded jpg then survives the URL's later expiry.
    if (isGroup && photoURL.length && threadId.length) {
        NSString *key = [@"grp_" stringByAppendingString:threadId];
        [[SPKAvatarCache shared] avatarForPK:key urlString:photoURL forceRefresh:YES completion:nil];
    }
    return changed;
}

+ (BOOL)isSenderPinned:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    return [spkSenderFlags(senderPK, ownerPK)[@"pinned"] boolValue];
}

+ (BOOL)isSenderBlocked:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    return [spkSenderFlags(senderPK, ownerPK)[@"blocked"] boolValue];
}

+ (void)setSenderPinned:(BOOL)pinned senderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    if (!senderPK.length)
        return;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *flags = spkReadFlags();
        NSMutableDictionary *ownerFlags = spkFlagsForOwner(flags, ownerPK, YES);
        NSMutableDictionary *senderFlags = [ownerFlags[senderPK] isKindOfClass:[NSMutableDictionary class]]
                                               ? ownerFlags[senderPK]
                                               : ([ownerFlags[senderPK] isKindOfClass:[NSDictionary class]] ? [ownerFlags[senderPK] mutableCopy] : [NSMutableDictionary dictionary]);
        senderFlags[@"pinned"] = @(pinned);
        ownerFlags[senderPK] = senderFlags;
        spkWriteFlags(flags);
    });
    spkPostChanged(ownerPK);
}

+ (void)setSenderBlocked:(BOOL)blocked senderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    if (!senderPK.length)
        return;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *flags = spkReadFlags();
        NSMutableDictionary *ownerFlags = spkFlagsForOwner(flags, ownerPK, YES);
        NSMutableDictionary *senderFlags = [ownerFlags[senderPK] isKindOfClass:[NSMutableDictionary class]]
                                               ? ownerFlags[senderPK]
                                               : ([ownerFlags[senderPK] isKindOfClass:[NSDictionary class]] ? [ownerFlags[senderPK] mutableCopy] : [NSMutableDictionary dictionary]);
        senderFlags[@"blocked"] = @(blocked);
        ownerFlags[senderPK] = senderFlags;
        spkWriteFlags(flags);
    });
    spkPostChanged(ownerPK);
}

+ (void)deleteMessageId:(NSString *)messageId forOwnerPK:(NSString *)ownerPK {
    if (!messageId.length)
        return;
    dispatch_sync(spkDMQueue(), ^{
        NSString *path = spkJSONPathForOwner(ownerPK);
        NSMutableArray<SPKDeletedMessage *> *cur = [spkDecode(spkReadArray(path)) mutableCopy];
        NSMutableArray<SPKDeletedMessage *> *kept = [NSMutableArray arrayWithCapacity:cur.count];
        for (SPKDeletedMessage *m in cur) {
            if ([m.messageId isEqualToString:messageId]) {
                if (m.mediaPath.length) {
                    [[NSFileManager defaultManager] removeItemAtPath:
                                                        [spkMediaDirForOwner(ownerPK) stringByAppendingPathComponent:m.mediaPath.lastPathComponent]
                                                               error:nil];
                }
                if (m.thumbnailPath.length) {
                    [[NSFileManager defaultManager] removeItemAtPath:
                                                        [spkMediaDirForOwner(ownerPK) stringByAppendingPathComponent:m.thumbnailPath.lastPathComponent]
                                                               error:nil];
                }
                continue;
            }
            [kept addObject:m];
        }
        spkWriteArray(path, spkEncode(kept));
    });
    spkPostChanged(ownerPK);
}

+ (void)deleteMessagesForSenderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK {
    if (!senderPK.length)
        return;
    NSArray *toDrop = [self messagesForSenderPK:senderPK ownerPK:ownerPK];
    for (SPKDeletedMessage *m in toDrop) {
        [self deleteMessageId:m.messageId forOwnerPK:ownerPK];
    }
}

+ (void)deleteMessagesForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId.length)
        return;
    NSArray *toDrop = [self messagesForThreadId:threadId ownerPK:ownerPK];
    for (SPKDeletedMessage *m in toDrop) {
        [self deleteMessageId:m.messageId forOwnerPK:ownerPK];
    }
}

+ (void)resetForOwnerPK:(NSString *)ownerPK {
    dispatch_sync(spkDMQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:spkJSONPathForOwner(ownerPK) error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:spkMediaDirForOwner(ownerPK) error:nil];
        NSMutableDictionary *flags = spkReadFlags();
        [flags removeObjectForKey:spkSafePK(ownerPK)];
        spkWriteFlags(flags);
    });
    spkPostChanged(ownerPK);
}

+ (void)resetAll {
    dispatch_sync(spkDMQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:spkStorageDir() error:nil];
        spkInvalidateFlagsCacheOnQueue();
    });
    spkPostChanged(nil);
}

#pragma mark - Media

+ (NSString *)absolutePathForRelativePath:(NSString *)relativePath ownerPK:(NSString *)ownerPK {
    if (!relativePath.length)
        return nil;
    return [spkMediaDirForOwner(ownerPK) stringByAppendingPathComponent:relativePath.lastPathComponent];
}

+ (NSString *)reserveRelativeMediaPathForMessageId:(NSString *)messageId
                                         extension:(NSString *)ext
                                           ownerPK:(NSString *)ownerPK {
    NSString *safeId = [messageId stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *cleanExt = ext.length ? ([ext hasPrefix:@"."] ? [ext substringFromIndex:1] : ext) : @"bin";
    NSString *fname = [NSString stringWithFormat:@"%@.%@", safeId, cleanExt];
    // Touch the dir so callers can write straight away.
    (void)spkMediaDirForOwner(ownerPK);
    return fname;
}

+ (unsigned long long)mediaSizeBytesForOwnerPK:(NSString *)ownerPK {
    return spkDirectorySize(spkMediaDirForOwner(ownerPK));
}

#pragma mark - Pending reconciliation and media recovery cache

+ (void)flushPendingStores {
    spkPendingFlushAndWait();
}

+ (BOOL)savePendingCandidateSnapshot:(NSDictionary *)snapshot forOwnerPK:(NSString *)ownerPK {
    NSString *messageId = [snapshot[@"message_id"] isKindOfClass:[NSString class]] ? snapshot[@"message_id"] : nil;
    if (!messageId.length)
        return NO;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingCandidatesDir, ownerPK);
        NSMutableDictionary *merged = [all[messageId] isKindOfClass:[NSDictionary class]]
                                          ? [all[messageId] mutableCopy]
                                          : [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:snapshot];
        if (!spkPendingTimestamp(merged[kSPKDMCandidateCapturedAtKey]))
            merged[kSPKDMCandidateCapturedAtKey] = @([NSDate date].timeIntervalSince1970);
        all[messageId] = merged;
        if (all.count > kSPKDMCandidateLimit + kSPKDMCandidatePruneSlack)
            spkPruneCandidates(all, spkPendingStoreOnQueue(kSPKDMPendingRemovalsDir, ownerPK), ownerPK);
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingCandidatesDir, ownerPK), NO);
    });
    return YES;
}

+ (NSDictionary *)pendingCandidateSnapshotForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK {
    if (!messageId.length)
        return nil;
    __block NSDictionary *result = nil;
    dispatch_sync(spkDMQueue(), ^{
        id candidate = spkPendingStoreOnQueue(kSPKDMPendingCandidatesDir, ownerPK)[messageId];
        if ([candidate isKindOfClass:[NSDictionary class]])
            result = [candidate copy];
    });
    return result;
}

+ (BOOL)patchPendingCandidateForMessageId:(NSString *)messageId values:(NSDictionary *)values ownerPK:(NSString *)ownerPK {
    if (!messageId.length || !values.count)
        return NO;
    __block BOOL ok = NO;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingCandidatesDir, ownerPK);
        NSMutableDictionary *candidate = [all[messageId] isKindOfClass:[NSDictionary class]]
                                             ? [all[messageId] mutableCopy]
                                             : nil;
        if (!candidate)
            return;
        BOOL stagesMedia = values[@"staged_media_path"] != nil || values[@"staged_thumbnail_path"] != nil;
        if (stagesMedia && [candidate[@"staging_disabled"] boolValue])
            return;
        [candidate addEntriesFromDictionary:values];
        all[messageId] = candidate;
        // A staged media path is what lets an unsend keep its media, so persist it
        // right away rather than on the batched flush.
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingCandidatesDir, ownerPK), stagesMedia);
        ok = YES;
    });
    return ok;
}

+ (void)removePendingCandidateForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK {
    if (!messageId.length)
        return;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingCandidatesDir, ownerPK);
        if (!all[messageId])
            return;
        [all removeObjectForKey:messageId];
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingCandidatesDir, ownerPK), NO);
    });
}

+ (BOOL)savePendingRemovalForMessageId:(NSString *)messageId
                              threadId:(NSString *)threadId
                            mutationId:(NSString *)mutationId
                               ownerPK:(NSString *)ownerPK {
    if (!messageId.length)
        return NO;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingRemovalsDir, ownerPK);
        NSMutableDictionary *entry = [all[messageId] isKindOfClass:[NSDictionary class]]
                                         ? [all[messageId] mutableCopy]
                                         : [NSMutableDictionary dictionary];
        entry[@"message_id"] = messageId;
        if (threadId.length)
            entry[@"thread_id"] = threadId;
        if (mutationId.length)
            entry[@"mutation_id"] = mutationId;
        if (!entry[@"created_at"])
            entry[@"created_at"] = @([NSDate date].timeIntervalSince1970);
        all[messageId] = entry;
        // A recorded unsend is the only trace of that deletion until it is
        // resolved, so it is written immediately.
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingRemovalsDir, ownerPK), YES);
    });
    return YES;
}

+ (NSArray<NSDictionary *> *)pendingRemovalsForOwnerPK:(NSString *)ownerPK {
    __block NSArray *result = nil;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingRemovalsDir, ownerPK);
        if (!all.count)
            return;
        NSMutableArray *copies = [NSMutableArray arrayWithCapacity:all.count];
        for (id entry in all.allValues)
            [copies addObject:[entry copy]];
        result = copies;
    });
    return result ?: @[];
}

+ (void)removePendingRemovalForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK {
    if (!messageId.length)
        return;
    dispatch_sync(spkDMQueue(), ^{
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingRemovalsDir, ownerPK);
        if (!all[messageId])
            return;
        [all removeObjectForKey:messageId];
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingRemovalsDir, ownerPK), YES);
    });
}

+ (NSString *)reserveRelativeStagedMediaPathForMessageId:(NSString *)messageId
                                               extension:(NSString *)ext
                                                 ownerPK:(NSString *)ownerPK
                                               thumbnail:(BOOL)thumbnail {
    NSString *safeId = [messageId stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *cleanExt = ext.length ? ([ext hasPrefix:@"."] ? [ext substringFromIndex:1] : ext) : @"bin";
    (void)spkStagedMediaDirForOwner(ownerPK);
    return [NSString stringWithFormat:@"%@%@.%@", thumbnail ? @"thumb_" : @"", safeId, cleanExt];
}

+ (NSString *)absoluteStagedPathForRelativePath:(NSString *)relativePath ownerPK:(NSString *)ownerPK {
    if (!relativePath.length)
        return nil;
    return [spkStagedMediaDirForOwner(ownerPK) stringByAppendingPathComponent:relativePath.lastPathComponent];
}

+ (NSString *)promoteStagedRelativePath:(NSString *)relativePath
                              messageId:(NSString *)messageId
                                ownerPK:(NSString *)ownerPK
                              thumbnail:(BOOL)thumbnail {
    if (!relativePath.length || !messageId.length)
        return nil;
    NSString *source = [self absoluteStagedPathForRelativePath:relativePath ownerPK:ownerPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:source])
        return nil;
    NSString *baseId = thumbnail ? [@"thumb_" stringByAppendingString:messageId] : messageId;
    NSString *destinationRel = [self reserveRelativeMediaPathForMessageId:baseId extension:relativePath.pathExtension ownerPK:ownerPK];
    NSString *destination = [self absolutePathForRelativePath:destinationRel ownerPK:ownerPK];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:destination]) {
        if (![fm moveItemAtPath:source toPath:destination error:nil])
            return nil;
    } else {
        [fm removeItemAtPath:source error:nil];
    }
    return destinationRel;
}

+ (unsigned long long)stagedMediaSizeBytesForOwnerPK:(NSString *)ownerPK {
    return spkDirectorySize(spkStagedMediaDirForOwner(ownerPK));
}

+ (void)clearStagedMediaForOwnerPK:(NSString *)ownerPK {
    dispatch_sync(spkDMQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:spkStagedMediaDirForOwner(ownerPK) error:nil];
        NSMutableDictionary *all = spkPendingStoreOnQueue(kSPKDMPendingCandidatesDir, ownerPK);
        for (NSString *key in all.allKeys) {
            NSMutableDictionary *candidate = [all[key] mutableCopy];
            [candidate removeObjectForKey:@"staged_media_path"];
            [candidate removeObjectForKey:@"staged_thumbnail_path"];
            candidate[@"staging_disabled"] = @YES;
            all[key] = candidate;
        }
        spkPendingMarkDirtyOnQueue(spkPendingJSONPath(kSPKDMPendingCandidatesDir, ownerPK), YES);
    });
    spkPostChanged(ownerPK);
}

+ (NSString *)storageRootPath {
    return spkStorageDir();
}

+ (BOOL)replaceStorageWithDirectoryAtPath:(NSString *)sourcePath error:(NSError **)error {
    if (sourcePath.length == 0)
        return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destination = spkStorageDir();
    if ([fm fileExistsAtPath:destination] && ![fm removeItemAtPath:destination error:error]) {
        return NO;
    }
    NSString *parent = [destination stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL copied = [fm copyItemAtPath:sourcePath toPath:destination error:error];
    dispatch_sync(spkDMQueue(), ^{
        spkInvalidateFlagsCacheOnQueue();
    });
    if (copied)
        spkPostChanged(nil);
    return copied;
}

+ (NSInteger)mergeFromStorageDirectory:(NSString *)sourcePath
                         ownerFilterPK:(NSString *)ownerFilterPK
                                 error:(NSError **)error {
    if (sourcePath.length == 0)
        return 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:sourcePath error:error];
    if (!entries)
        return -1;

    NSInteger added = 0;
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"json"])
            continue;
        if ([entry isEqualToString:kSPKDMSenderFlagsFile])
            continue;
        NSString *ownerPK = [entry stringByDeletingPathExtension]; // "<pk>.json"
        if (ownerFilterPK.length > 0 && ![ownerPK isEqualToString:spkSafePK(ownerFilterPK)])
            continue;

        NSArray<SPKDeletedMessage *> *incoming = spkDecode(spkReadArray([sourcePath stringByAppendingPathComponent:entry]));
        if (incoming.count == 0)
            continue;

        // Count genuinely-new messages (saveMessages: replaces by id, so existing ones don't grow the log).
        NSMutableSet<NSString *> *existingIds = [NSMutableSet set];
        for (SPKDeletedMessage *m in [self allMessagesForOwnerPK:ownerPK]) {
            if (m.messageId.length)
                [existingIds addObject:m.messageId];
        }
        for (SPKDeletedMessage *m in incoming) {
            if (m.messageId.length && ![existingIds containsObject:m.messageId])
                added++;
        }

        // Copy this owner's media before saving the records that reference it.
        NSString *srcMediaDir = [[sourcePath stringByAppendingPathComponent:kSPKDMMediaDir] stringByAppendingPathComponent:ownerPK];
        NSString *dstMediaDir = spkMediaDirForOwner(ownerPK);
        for (NSString *file in [fm contentsOfDirectoryAtPath:srcMediaDir error:nil]) {
            NSString *dst = [dstMediaDir stringByAppendingPathComponent:file];
            if (![fm fileExistsAtPath:dst]) {
                [fm copyItemAtPath:[srcMediaDir stringByAppendingPathComponent:file] toPath:dst error:nil];
            }
        }

        [self saveMessages:incoming forOwnerPK:ownerPK]; // merges by messageId
    }

    // Sender flags: fill in entries we don't already have (never overwrite local).
    NSString *srcFlags = [sourcePath stringByAppendingPathComponent:kSPKDMSenderFlagsFile];
    if ([fm fileExistsAtPath:srcFlags]) {
        dispatch_sync(spkDMQueue(), ^{
            NSMutableDictionary *live = spkReadFlags();
            NSDictionary *incoming = spkReadDictionary(srcFlags);
            BOOL changed = NO;
            for (NSString *key in incoming) {
                if (ownerFilterPK.length > 0 && ![key isEqualToString:spkSafePK(ownerFilterPK)])
                    continue;
                if (!live[key]) {
                    live[key] = incoming[key];
                    changed = YES;
                }
            }
            if (changed)
                spkWriteFlags(live);
        });
    }

    spkPostChanged(nil);
    return added;
}

@end
