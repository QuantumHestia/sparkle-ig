//  SPKLanguagePackCatalog.h
//  Fetches + models the language-pack catalog: an index JSON listing installable packs, so a
//  language can be installed with one tap instead of a pasted URL, and so an installed pack can
//  notice that a newer build of itself exists.
//
//  Index JSON schema (hosted at SPKLanguageCatalogDefaultURL, overridable via the
//  `langpack_catalog_url` pref):
//    {
//      "version": 1,
//      "packs": [
//        { "code": "lt", "name": "Lithuanian", "endonym": "Lietuvių",
//          "url": "https://github.com/efibalogh/sparkle-ig/releases/download/v1.3.1/Sparkle-lt.zip",
//          "sha256": "…", "bytes": 198686, "coverage": 99 }
//      ]
//    }
//
//  `sha256` doubles as the pack's identity: an installed pack whose recorded hash differs from the
//  catalog's row is out of date, which is how the updater spots a new release without a version field.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SPKLanguageCatalogDefaultURL;
FOUNDATION_EXPORT NSString *const SPKLanguageCatalogErrorDomain;

@interface SPKLanguageCatalogEntry : NSObject
@property (nonatomic, copy) NSString *code;         // BCP-47-ish, validated by SPKLanguageCodeIsWellFormed
@property (nonatomic, copy) NSString *name;         // English name (fallback label)
@property (nonatomic, copy, nullable) NSString *endonym;   // native name for display
@property (nonatomic, strong) NSURL *url;           // https pack .zip
@property (nonatomic, copy, nullable) NSString *sha256;    // lowercase hex, optional
@property (nonatomic, assign) long long bytes;      // reported size (advisory)
@property (nonatomic, assign) NSInteger coverage;   // 0..100
/// Native name if present, else English name, else code.
@property (nonatomic, readonly) NSString *displayName;
@end

@interface SPKLanguagePackCatalog : NSObject

/// The URL the catalog is fetched from (pref override or the compiled default).
+ (NSURL *)catalogURL;

/// Downloads + parses the catalog. Rejects malformed entries individually (a bad row
/// never sinks the whole list). `completion` is delivered on the main thread; on failure
/// `entries` is nil and `error` is set.
+ (void)fetchEntriesWithCompletion:(void (^)(NSArray<SPKLanguageCatalogEntry *> *_Nullable entries,
                                             NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
