#import "SPKDeletedMessagesModels.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const SPKDeletedMessagesDidChangeNotification;

// Per-account on-disk store for deleted-message records and their captured media.
//
// Layout under Documents/Sparkle/DeletedMessages/:
//   <ownerPk>.json      — array of message dicts (newest-first)
//   media/<ownerPk>/    — captured media blobs, named "<message_id>.<ext>"
@interface SPKDeletedMessagesStorage : NSObject

#pragma mark - Read

+ (NSArray<SPKDeletedMessage *> *)allMessagesForOwnerPK:(NSString *)ownerPK;
+ (NSArray<NSString *> *)allOwnerPKs;

// Thread-aware grouping for the top list: group threads collapse into one entry
// (keyed by threadId, isGroup == YES), while 1:1 chats stay keyed by sender. A
// thread is treated as a group when any captured message carries the group flag
// or when it has two or more distinct non-owner senders.
+ (NSArray<SPKDeletedMessageGroup *> *)groupedForOwnerPK:(NSString *)ownerPK;
+ (NSArray<SPKDeletedMessage *> *)messagesForSenderPK:(NSString *)senderPK
                                              ownerPK:(NSString *)ownerPK;

// All captured messages in a thread (every sender, including the owner's own
// unsends), oldest-first by sent time — used to render a chat-style view.
+ (NSArray<SPKDeletedMessage *> *)messagesForThreadId:(NSString *)threadId
                                              ownerPK:(NSString *)ownerPK;

// Single-sender group built from stored records, or nil when that sender has
// no captured messages for this account. Used to deep-link from a chat.
+ (nullable SPKDeletedMessageGroup *)groupForSenderPK:(NSString *)senderPK
                                              ownerPK:(NSString *)ownerPK;

// Group for the non-owner sender in a given thread, or nil when the thread has
// no captured messages. Used to deep-link from an open chat where only the
// threadId is reliably known.
+ (nullable SPKDeletedMessageGroup *)groupForThreadId:(NSString *)threadId
                                              ownerPK:(NSString *)ownerPK;

#pragma mark - Write

// Insert / replace by message_id. Newest-first ordering preserved on disk.
+ (BOOL)saveMessage:(SPKDeletedMessage *)message forOwnerPK:(NSString *)ownerPK;

// Atomic-ish bulk save when capture lands several at once.
+ (BOOL)saveMessages:(NSArray<SPKDeletedMessage *> *)messages forOwnerPK:(NSString *)ownerPK;

// Drop a single record (and its media blobs).
+ (void)deleteMessageId:(NSString *)messageId forOwnerPK:(NSString *)ownerPK;

// Patch every record from `senderPK` with whatever non-empty values are in
// `info` (keys: `username`, `full_name`, `profile_pic_url`). Used by the UI's
// missing-pfp backfill — capture only knows what the resolver has cached.
+ (BOOL)applySenderInfo:(NSDictionary *)info
            forSenderPK:(NSString *)senderPK
                ownerPK:(NSString *)ownerPK;

// Stamp the resolved group name + group flag onto every stored message in a
// thread. Used by capture once it reads the real thread metadata from IG's
// cache. Returns YES when anything changed (and posts a change notification).
+ (BOOL)backfillThreadTitle:(nullable NSString *)title
                    isGroup:(BOOL)isGroup
                   photoURL:(nullable NSString *)photoURL
                forThreadId:(NSString *)threadId
                    ownerPK:(NSString *)ownerPK;

+ (BOOL)isSenderPinned:(NSString *)senderPK ownerPK:(NSString *)ownerPK;
+ (BOOL)isSenderBlocked:(NSString *)senderPK ownerPK:(NSString *)ownerPK;
+ (void)setSenderPinned:(BOOL)pinned senderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK;
+ (void)setSenderBlocked:(BOOL)blocked senderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK;

// Drop every record for one sender.
+ (void)deleteMessagesForSenderPK:(NSString *)senderPK ownerPK:(NSString *)ownerPK;

// Drop every record in one thread (used to delete a whole group log).
+ (void)deleteMessagesForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK;

// Wipe entire log + media for one account.
+ (void)resetForOwnerPK:(NSString *)ownerPK;
+ (void)resetAll;

#pragma mark - Media paths

// Absolute paths derived from relative paths stored on the model.
+ (nullable NSString *)absolutePathForRelativePath:(nullable NSString *)relativePath
                                           ownerPK:(NSString *)ownerPK;

// Reserve a relative path under media/<ownerPK>/ for a new blob. Caller writes the file.
+ (NSString *)reserveRelativeMediaPathForMessageId:(NSString *)messageId
                                         extension:(nullable NSString *)ext
                                           ownerPK:(NSString *)ownerPK;

// Total size (bytes) of stored media for one account — used by Settings.
+ (unsigned long long)mediaSizeBytesForOwnerPK:(NSString *)ownerPK;

#pragma mark - Pending reconciliation and media recovery cache

// Writes any pending-store changes still waiting on the batched flush, and
// waits for them to reach disk.
+ (void)flushPendingStores;
+ (BOOL)savePendingCandidateSnapshot:(NSDictionary *)snapshot forOwnerPK:(NSString *)ownerPK;
+ (nullable NSDictionary *)pendingCandidateSnapshotForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK;
+ (BOOL)patchPendingCandidateForMessageId:(NSString *)messageId values:(NSDictionary *)values ownerPK:(NSString *)ownerPK;
+ (void)removePendingCandidateForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK;
+ (BOOL)savePendingRemovalForMessageId:(NSString *)messageId
                              threadId:(nullable NSString *)threadId
                            mutationId:(nullable NSString *)mutationId
                               ownerPK:(NSString *)ownerPK;
+ (NSArray<NSDictionary *> *)pendingRemovalsForOwnerPK:(NSString *)ownerPK;
+ (void)removePendingRemovalForMessageId:(NSString *)messageId ownerPK:(NSString *)ownerPK;
+ (NSString *)reserveRelativeStagedMediaPathForMessageId:(NSString *)messageId
                                               extension:(nullable NSString *)ext
                                                 ownerPK:(NSString *)ownerPK
                                               thumbnail:(BOOL)thumbnail;
+ (nullable NSString *)absoluteStagedPathForRelativePath:(nullable NSString *)relativePath ownerPK:(NSString *)ownerPK;
+ (nullable NSString *)promoteStagedRelativePath:(nullable NSString *)relativePath
                                       messageId:(NSString *)messageId
                                         ownerPK:(NSString *)ownerPK
                                       thumbnail:(BOOL)thumbnail;
+ (unsigned long long)stagedMediaSizeBytesForOwnerPK:(NSString *)ownerPK;
+ (void)clearStagedMediaForOwnerPK:(NSString *)ownerPK;

+ (NSString *)storageRootPath;
+ (BOOL)replaceStorageWithDirectoryAtPath:(NSString *)sourcePath error:(NSError **)error;

/// Non-destructive import: merges an exported storage directory into the live store —
/// per-owner messages are added (dedup by messageId), their media copied, and sender
/// flags filled in for senders not already known. Existing data is never deleted.
/// When `ownerFilterPK` is non-nil, only that owner's messages are merged (per-account
/// import). Returns the number of messages added, or -1 on a hard failure.
+ (NSInteger)mergeFromStorageDirectory:(NSString *)sourcePath
                         ownerFilterPK:(nullable NSString *)ownerFilterPK
                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
