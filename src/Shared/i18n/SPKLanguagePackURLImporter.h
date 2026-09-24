//  SPKLanguagePackURLImporter.h
//  Sparkle — downloads a language pack over the network and installs it.
//
//  Installs through the EXISTING SPKLanguagePackManager importPackAtURL: path, so catalog,
//  code and format validation stay in one place. This class adds only the transport: an
//  HTTPS-only download, a size cap, optional sha256 pinning, progress, cancel, and temp-file
//  hygiene.
//
//  Two trust levels, because the two callers are not equally exposed:
//    * No `expectedSHA256` (a URL the user pasted) — nothing vouches for the bytes, so the
//      peer address must be provably public and a system proxy is refused outright.
//    * Pinned `expectedSHA256` (a catalog row, or an auto-update) — the hash decides what may
//      be installed, so a proxied or peer-unverifiable fetch is allowed: it can fail the
//      integrity check, never pass one it should not. Without this the feature would simply
//      not work behind a VPN or corporate proxy.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SPKLanguagePackURLImportErrorDomain;

typedef NS_ENUM(NSInteger, SPKLanguagePackURLImportErrorCode) {
    SPKLanguagePackURLImportErrorInvalidURL = 1,
    SPKLanguagePackURLImportErrorInsecureScheme,
    SPKLanguagePackURLImportErrorDisallowedHost,
    SPKLanguagePackURLImportErrorHTTPStatus,
    SPKLanguagePackURLImportErrorDownloadFailed,
    SPKLanguagePackURLImportErrorTooLarge,
    SPKLanguagePackURLImportErrorChecksumMismatch,
    SPKLanguagePackURLImportErrorCancelled,
};

/// TRUE only if `url` is https, has a host, and that host does NOT resolve to a
/// loopback / link-local / private / reserved address (SSRF hygiene, covering DNS
/// names + alternate numeric encodings). **Performs a DNS lookup — never call on the
/// main thread.** Shared by the catalog fetch.
FOUNDATION_EXPORT BOOL SPKLanguagePackRemoteURLIsSafe(NSURL *_Nullable url);

/// TRUE if `addr` (a numeric IP string, e.g. from NSURLSessionTaskTransactionMetrics.remoteAddress)
/// is a loopback / link-local / private / NAT64-wrapped-private / unparseable address. Used to
/// re-vet the socket's ACTUAL peer after connecting, closing the DNS-rebind gap the pre-flight
/// resolve can't. Empty/unparseable → TRUE (fail closed). Shared by the catalog fetch.
FOUNDATION_EXPORT BOOL SPKLanguagePackRemoteAddrStringIsPrivate(NSString *_Nullable addr);

/// TRUE if the system would route a request to `url` through an HTTP/HTTPS/SOCKS proxy. A proxy
/// resolves and connects on our behalf, so neither the pre-flight resolve nor the peer-address
/// metrics describe the real endpoint. Callers without a pinned hash refuse; callers with one
/// proceed and let the hash decide. Shared by the catalog fetch.
FOUNDATION_EXPORT BOOL SPKLanguagePackURLWouldUseProxy(NSURL *_Nullable url);

@class SPKLanguagePack;

@interface SPKLanguagePackURLImporter : NSObject

/// Downloads the language-pack archive at `url`, verifies it, and installs it via
/// SPKLanguagePackManager. `expectedSHA256` (lowercase hex) is verified when non-nil, and
/// also selects the trust level described at the top of this file. `progress` (0..1) and
/// `completion` are always delivered on the main thread. Returns the live importer so the
/// caller can `-cancel` it; the importer keeps itself alive for the download's duration.
+ (instancetype)importFromURL:(NSURL *)url
               expectedSHA256:(nullable NSString *)expectedSHA256
                     progress:(nullable void (^)(double fraction))progress
                   completion:(void (^)(SPKLanguagePack *_Nullable pack, NSError *_Nullable error))completion;

/// Cancels an in-flight download; `completion` fires once with a Cancelled error.
- (void)cancel;

/// The hard byte ceiling for a downloaded pack (a real pack is ~50–300 KB).
@property (class, nonatomic, readonly) long long maximumPackBytes;

@end

NS_ASSUME_NONNULL_END
