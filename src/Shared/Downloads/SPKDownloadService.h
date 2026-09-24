#import <Foundation/Foundation.h>

#import "SPKDownloadJob.h"
#import "SPKDownloadRequest.h"
#import "SPKDownloadTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPKDownloadSubmissionCompletion)(NSString *_Nullable jobID, NSError *_Nullable error);

@interface SPKDownloadService : NSObject

+ (instancetype)shared;

/// Same sheet UI used by queue pill "Tap to open Downloads" and in-app entry points.
+ (void)presentDownloadsHistorySheet;
+ (void)confirmCancelAllActive;

- (void)submitRequest:(SPKDownloadRequest *)request
           completion:(nullable SPKDownloadSubmissionCompletion)completion;

/// Post-hoc history entry for an already-saved local file (trim / crop /
/// photo edit). Quiet: no pill, no transfer, no duplicate preflight.
/// See SPKDownloadScheduler for semantics.
- (nullable NSString *)recordCompletedFileAtURL:(nullable NSURL *)fileURL
                                      mediaKind:(SPKDownloadMediaKind)kind
                                    destination:(SPKDownloadDestination)destination
                                       metadata:(nullable SPKGallerySaveMetadata *)metadata
                                  sourceSurface:(SPKDownloadSourceSurface)surface
                                      finalPath:(nullable NSString *)finalPath;

- (BOOL)hasActiveJobWithHiddenPill;
- (void)reshowProgressPill;
- (void)confirmCancelForJobID:(NSString *)jobID;

- (NSArray<SPKDownloadJob *> *)jobsMatchingFilter:(SPKDownloadHistoryFilter)filter;
- (nullable SPKDownloadJob *)jobWithID:(NSString *)jobID;

- (void)cancelJobID:(NSString *)jobID;
- (void)cancelAllActive;
- (void)cancelItemID:(NSString *)itemID inJobID:(NSString *)jobID;
- (void)retryJobID:(NSString *)jobID;
- (void)retryItemID:(NSString *)itemID inJobID:(NSString *)jobID;
- (void)clearFinishedHistory;
- (void)removeJobID:(NSString *)jobID;

@end

NS_ASSUME_NONNULL_END
