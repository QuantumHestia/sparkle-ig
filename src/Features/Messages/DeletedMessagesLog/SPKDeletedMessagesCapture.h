// Persistent candidate + reconciliation pipeline for the deleted-messages log.
//
// KeepDeletedMessages.x already owns the single chokepoint hook on
// `IGDirectCacheUpdatesApplicator._applyThreadUpdates:completion:userAccess:`
// and is the only place we can guarantee ordering relative to the
// remove-keys neutering. Rather than fight install order, that hook calls
// these two C functions directly:
//
//   • `spkDMCaptureNoteInsert(...)` on every insert/replace, so we persist a
//     normalized snapshot of the body BEFORE any unsend can happen.
//   • `spkDMCaptureNoteRemoveSids(sids, ownerPk, threadId)` on every reason==0
//     remove, so we know which captured snapshots became deleted records.
//
// All persistence + media downloading happens here, gated by
// `msgs_deleted_log` (read fresh — never cached).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Which incoming messages get a saved candidate snapshot.
typedef NS_ENUM(NSInteger, SPKDMCandidateMode) {
    SPKDMCandidateModeNone = 0,
    SPKDMCandidateModeAll,
    // Keep Deleted Messages stops Instagram from removing an unsent message, so
    // its content can still be read from Instagram's cache at unsend time. Only
    // media whose links expire needs to be captured when it arrives.
    SPKDMCandidateModeExpiringMediaOnly,
};

void spkDMCaptureNoteInsert(id _Nullable message,
                            NSString *_Nullable ownerPk,
                            NSString *_Nullable threadId,
                            SPKDMCandidateMode candidateMode);

// `keys` are the IGDirectMessageKey objects from the unsend delta. The
// capture side extracts sids itself, persists pending removals, and falls back
// through candidate snapshots, weak refs, cached thread state, and guarded
// thread fetches. Unresolved removals stay queued for later cache warmup.
void spkDMCaptureNoteRemoveKeys(NSArray *_Nullable keys,
                                id _Nullable applicator,
                                NSString *_Nullable ownerPk,
                                NSString *_Nullable threadId);

void spkDMCaptureRetryPendingRemovals(id _Nullable applicator,
                                      NSString *_Nullable ownerPk);

// Resolve a thread's real group name + group flag from IG's cache (the open
// thread's IGDirectThreadMetadata.groupMetadata.customName), then backfill it
// onto stored messages so the log shows the actual chat title. Deduped per
// thread per session; safe to call on every unsend.
void spkDMCaptureResolveThreadMeta(id _Nullable applicator,
                                   NSString *_Nullable threadId,
                                   NSString *_Nullable ownerPk);

// Resolves toast previews for unsent message keys. Live message references are
// taken on the calling thread, before Instagram applies the removal; building
// the previews happens on the capture queue, ahead of the unsend's own
// finalize, and the results are appended to `collector` there. Read
// `collector` only from a block passed to spkDMCaptureAfterQueuedWork.
void spkDMCaptureQueuePreviewMetadataForKeys(NSArray *_Nullable keys,
                                             id _Nullable applicator,
                                             NSString *_Nullable ownerPk,
                                             NSString *_Nullable threadId,
                                             NSMutableArray<NSDictionary *> *collector);

// Runs `block` on the capture queue once everything queued so far has run.
void spkDMCaptureAfterQueuedWork(dispatch_block_t block);

// Reaction unsend: someone removed a reaction they had placed on a message.
// `reaction` is an IGDirectMessageReaction; `reactorPk` is the user who removed
// it; `targetMessage` (optional) is the message the reaction was on, used to
// build a short preview. Persists a reaction record gated by
// `msgs_deleted_log_reactions`. Returns the saved record's sender display info
// as a dict for the toast (keys: senderPk/senderUsername/senderFullName/emoji),
// or nil when nothing was stored.
NSDictionary *_Nullable spkDMCaptureNoteReactionUnsend(id _Nullable reaction,
                                                       NSString *_Nullable reactorPk,
                                                       id _Nullable targetMessage,
                                                       NSString *_Nullable targetMessageId,
                                                       id _Nullable applicator,
                                                       NSString *_Nullable ownerPk,
                                                       NSString *_Nullable threadId);

// One-line preview of the message a reaction was attached to, resolved by
// server id (live ref cache, then thread client state). Used by the unsent
// reaction toast when log capture is off and so didn't already resolve it.
NSString *_Nullable spkDMCaptureReactionTargetPreview(NSString *_Nullable messageId,
                                                      id _Nullable applicator,
                                                      NSString *_Nullable threadId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
