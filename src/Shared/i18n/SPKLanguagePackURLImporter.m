//  SPKLanguagePackURLImporter.m

#import "SPKLanguagePackURLImporter.h"
#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../../Utils.h"

#import <CommonCrypto/CommonDigest.h>
#import <CFNetwork/CFNetwork.h>
#import <netdb.h>
#import <netinet/in.h>
#import <arpa/inet.h>

NSString *const SPKLanguagePackURLImportErrorDomain = @"SPKLanguagePackURLImportErrorDomain";

static const long long kSPKMaxPackBytes = 8LL * 1024 * 1024;  // 8 MB
static const double kSPKMetricsJoinTimeout = 4.0;  // how long finalize waits for the peer-address metrics
static NSMutableSet<SPKLanguagePackURLImporter *> *sSPKActiveImporters;  // keep-alive; guarded by @synchronized([SPKLanguagePackURLImporter class])

#pragma mark - SSRF host safety (resolves DNS + all numeric encodings)

static BOOL SPKAddrIsPrivate(const struct sockaddr *sa) {
    if (!sa) return YES;
    if (sa->sa_family == AF_INET) {
        uint32_t a = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
        uint8_t o1 = (a >> 24) & 0xFF, o2 = (a >> 16) & 0xFF;
        if (o1 == 0) return YES;                             // 0.0.0.0/8 "this network" (whole block)
        if (o1 == 127) return YES;                           // 127.0.0.0/8 loopback
        if (o1 == 10) return YES;                            // 10.0.0.0/8
        if (o1 == 172 && o2 >= 16 && o2 <= 31) return YES;   // 172.16.0.0/12
        if (o1 == 192 && o2 == 168) return YES;              // 192.168.0.0/16
        if (o1 == 169 && o2 == 254) return YES;              // 169.254.0.0/16 link-local (AWS metadata)
        if (o1 == 100 && o2 >= 64 && o2 <= 127) return YES;  // 100.64.0.0/10 CGNAT
        if (o1 == 192 && o2 == 0 && ((a >> 8) & 0xFF) == 0) return YES;  // 192.0.0.0/24 IETF protocol assignments
        if (o1 == 198 && (o2 == 18 || o2 == 19)) return YES;  // 198.18.0.0/15 benchmarking
        if (o1 >= 224) return YES;                           // 224/4 multicast + 240/4 reserved + 255.255.255.255
        return NO;
    }
    if (sa->sa_family == AF_INET6) {
        const struct in6_addr *a6 = &((const struct sockaddr_in6 *)sa)->sin6_addr;
        if (IN6_IS_ADDR_LOOPBACK(a6) || IN6_IS_ADDR_UNSPECIFIED(a6) || IN6_IS_ADDR_LINKLOCAL(a6)) return YES;
        if (IN6_IS_ADDR_MULTICAST(a6)) return YES;
        const uint8_t *b = a6->s6_addr;
        if ((b[0] & 0xFE) == 0xFC) return YES;               // fc00::/7 unique-local
        if (IN6_IS_ADDR_V4MAPPED(a6) || IN6_IS_ADDR_V4COMPAT(a6)) {  // ::ffff:a.b.c.d and deprecated ::a.b.c.d
            struct sockaddr_in v4 = {0};
            v4.sin_family = AF_INET;
            memcpy(&v4.sin_addr.s_addr, b + 12, 4);
            return SPKAddrIsPrivate((const struct sockaddr *)&v4);
        }
        // NAT64/DNS64: on an IPv6-only network getaddrinfo synthesises an AAAA that embeds the real
        // (possibly private) IPv4, so an attacker's A record pointing at 10.x/127.x would otherwise
        // sail through. RFC 6052 splits the address around the reserved u-octet at byte 8, and the
        // split depends on the prefix length — reading the wrong bytes silently lets LAN addresses
        // through, so each known prefix is decoded at exactly its own defined length.
        BOOL wellKnown = (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B);
        if (wellKnown) {
            uint8_t v[4];
            BOOL embedded = NO;
            if (b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] == 0 &&
                b[8] == 0 && b[9] == 0 && b[10] == 0 && b[11] == 0) {
                // 64:ff9b::/96 (RFC 6052 well-known): v4 occupies the last four bytes.
                v[0] = b[12]; v[1] = b[13]; v[2] = b[14]; v[3] = b[15];
                embedded = YES;
            } else if (b[4] == 0x00 && b[5] == 0x01) {
                // 64:ff9b:1::/48 (RFC 8215 local-use): v4 straddles the u-octet — bytes 6,7 then 9,10.
                v[0] = b[6]; v[1] = b[7]; v[2] = b[9]; v[3] = b[10];
                embedded = YES;
            }
            if (embedded) {
                struct sockaddr_in v4 = {0};
                v4.sin_family = AF_INET;
                memcpy(&v4.sin_addr.s_addr, v, 4);
                return SPKAddrIsPrivate((const struct sockaddr *)&v4);
            }
        }
        return NO;
    }
    return YES;  // unknown family → refuse
}

// Vet a numeric address STRING (from NSURLSessionTaskTransactionMetrics.remoteAddress) — the IP the
// socket actually connected to. Used post-connection to catch DNS rebinding between our pre-flight
// getaddrinfo() and NSURLSession's own independent resolve. Unparseable/empty → refuse (fail closed).
BOOL SPKLanguagePackRemoteAddrStringIsPrivate(NSString *addr) {
    if (addr.length == 0) return YES;
    NSString *bare = [[addr componentsSeparatedByString:@"%"] firstObject];  // strip any %zone id
    const char *c = bare.UTF8String;
    struct in_addr v4;
    if (inet_pton(AF_INET, c, &v4) == 1) {
        struct sockaddr_in sa = {0}; sa.sin_family = AF_INET; sa.sin_addr = v4;
        return SPKAddrIsPrivate((const struct sockaddr *)&sa);
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, c, &v6) == 1) {
        struct sockaddr_in6 sa = {0}; sa.sin6_family = AF_INET6; sa.sin6_addr = v6;
        return SPKAddrIsPrivate((const struct sockaddr *)&sa);
    }
    return YES;  // couldn't parse → refuse
}

// TRUE if the system would route a request to `url` through an HTTP/HTTPS/SOCKS proxy. With a proxy in
// play the proxy — not the device — resolves and connects to the target, so neither our pre-flight
// getaddrinfo nor the peer-address metrics reflect the REAL endpoint (metrics report the proxy's IP).
BOOL SPKLanguagePackURLWouldUseProxy(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    CFDictionaryRef sys = CFNetworkCopySystemProxySettings();
    if (!sys) return NO;
    CFArrayRef proxies = CFNetworkCopyProxiesForURL((__bridge CFURLRef)url, sys);
    CFRelease(sys);
    if (!proxies) return NO;
    BOOL applies = NO;
    for (CFIndex i = 0, n = CFArrayGetCount(proxies); i < n; i++) {
        CFDictionaryRef p = (CFDictionaryRef)CFArrayGetValueAtIndex(proxies, i);
        CFStringRef type = (CFStringRef)CFDictionaryGetValue(p, kCFProxyTypeKey);
        if (type && !CFEqual(type, kCFProxyTypeNone)) { applies = YES; break; }  // any non-"none" proxy
    }
    CFRelease(proxies);
    return applies;
}

BOOL SPKLanguagePackRemoteURLIsSafe(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (url.user.length || url.password.length) return NO;   // no userinfo@host
    NSString *host = url.host;
    if (host.length == 0) return NO;
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) return NO;  // unresolvable → refuse
    BOOL safe = YES;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        if (SPKAddrIsPrivate(p->ai_addr)) { safe = NO; break; }
    }
    freeaddrinfo(res);
    return safe;
}

#pragma mark -

@interface SPKLanguagePackURLImporter () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, copy, nullable) NSString *expectedSHA256;
@property (nonatomic, copy, nullable) void (^progressBlock)(double);
@property (nonatomic, copy) void (^completionBlock)(SPKLanguagePack *_Nullable, NSError *_Nullable);
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL finished;
// NO when a sha256 is pinned: the hash then decides what may be installed, so a fetch whose peer we
// cannot vouch for is allowed to proceed and fail the integrity check instead of being refused up
// front. Only an unpinned (user-pasted) URL demands a provably public peer.
@property (nonatomic, assign) BOOL requiresVerifiedPeer;
// Import is deferred out of didFinishDownloadingToURL: into didCompleteWithError: so the socket's
// actual peer address (collected via metrics) can be re-vetted before we trust the payload.
@property (nonatomic, copy, nullable) NSString *pendingZipPath;
@property (nonatomic, copy, nullable) NSString *pendingTempDir;
@property (atomic, assign) BOOL remoteAddrPrivate;   // set from didFinishCollectingMetrics:
// Finalize joins TWO async signals — the task completing successfully AND the peer-address metrics —
// because NSURLSession does NOT guarantee didFinishCollectingMetrics: fires before didCompleteWithError:
// (it can arrive later, or never). All four flags are read/written only under @synchronized(self).
@property (nonatomic, assign) BOOL downloadDone;       // didCompleteWithError: fired with no error
@property (nonatomic, assign) BOOL metricsDone;        // metrics observed OR the join timeout elapsed
@property (nonatomic, assign) BOOL metricsUnverified;  // timeout elapsed before metrics → peer unchecked
@property (nonatomic, assign) BOOL finalizeStarted;    // one-shot guard for -finalizeDownload
@end

@implementation SPKLanguagePackURLImporter

+ (long long)maximumPackBytes { return kSPKMaxPackBytes; }

+ (NSError *)errorWithCode:(SPKLanguagePackURLImportErrorCode)code message:(NSString *)message underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (message.length) info[NSLocalizedDescriptionKey] = message;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:SPKLanguagePackURLImportErrorDomain code:code userInfo:info];
}

+ (instancetype)importFromURL:(NSURL *)url
               expectedSHA256:(nullable NSString *)expectedSHA256
                     progress:(nullable void (^)(double))progress
                   completion:(void (^)(SPKLanguagePack *_Nullable, NSError *_Nullable))completion {
    NSParameterAssert(completion);
    SPKLanguagePackURLImporter *importer = [SPKLanguagePackURLImporter new];
    importer.url = url;
    importer.expectedSHA256 = expectedSHA256.lowercaseString;
    importer.requiresVerifiedPeer = (expectedSHA256.length == 0);
    importer.progressBlock = progress;
    importer.completionBlock = completion;
    @synchronized([SPKLanguagePackURLImporter class]) {  // same lock object as the removal site (this is a class method)
        if (!sSPKActiveImporters) sSPKActiveImporters = [NSMutableSet set];
        [sSPKActiveImporters addObject:importer];
    }
    // Resolve + download off-main (getaddrinfo blocks).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [importer start]; });
    return importer;
}

- (void)start {
    if (self.cancelled) { [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]; return; }
    if (![self.url isKindOfClass:[NSURL class]] || self.url.host.length == 0) {
        [self failWithCode:SPKLanguagePackURLImportErrorInvalidURL message:SPKL(@"LANGUAGE_PACK_URL_INVALID") underlying:nil]; return;
    }
    if (![self.url.scheme.lowercaseString isEqualToString:@"https"]) {
        [self failWithCode:SPKLanguagePackURLImportErrorInsecureScheme message:SPKL(@"LANGUAGE_PACK_URL_INSECURE") underlying:nil]; return;
    }
    if (!SPKLanguagePackRemoteURLIsSafe(self.url)) {
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil]; return;
    }
    if (self.requiresVerifiedPeer && SPKLanguagePackURLWouldUseProxy(self.url)) {
        // Unpinned URL through a proxy: the proxy resolves and connects for us, so nothing can vouch
        // for the real target and nothing vouches for the bytes either. Refuse. A pinned download
        // takes the other branch, because its hash makes a hostile endpoint unable to deliver.
        SPKLog(@"i18n", @"[LangPackURL] refusing: a system proxy applies to %@ and no hash is pinned (fail-closed)", self.url.host);
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil]; return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 120.0;
    cfg.HTTPMaximumConnectionsPerHost = 1;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.url];
    request.HTTPMethod = @"GET";
    [request setValue:@"Sparkle-LanguagePack/1.0" forHTTPHeaderField:@"User-Agent"];
    // Create AND resume the task atomically with -cancel's check: -cancel runs on the caller's
    // (main) thread while this runs on a background queue, both touch self.task. Under one lock,
    // either -cancel wins (sets cancelled, we skip resume → deterministic Cancelled) or we win
    // (task created + resumed, so a later -cancel hits a live, resumed task and its cancel is honoured
    // — cancelling a not-yet-resumed task is the case where didCompleteWithError: may never fire).
    BOOL cancelledFirst = NO;
    @synchronized(self) {
        if (self.cancelled) {
            cancelledFirst = YES;
        } else {
            self.task = [self.session downloadTaskWithRequest:request];
            [self.task resume];
        }
    }
    if (cancelledFirst) { [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]; return; }
    SPKLog(@"i18n", @"[LangPackURL] downloading %@", self.url.absoluteString);
}

- (void)cancel {
    @synchronized(self) {
        self.cancelled = YES;
        [self.task cancel];  // task (if any) was resumed under this same lock → didCompleteWithError(Cancelled) fires
    }
}

#pragma mark - Completion plumbing (one-shot)

- (void)finishWithPack:(nullable SPKLanguagePack *)pack error:(nullable NSError *)error {
    @synchronized(self) {
        if (self.finished) return;
        self.finished = YES;
    }
    NSString *temp = self.pendingTempDir;   // every terminal path funnels here → single cleanup site
    if (temp.length) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        self.pendingTempDir = nil; self.pendingZipPath = nil;
    }
    void (^completion)(SPKLanguagePack *, NSError *) = self.completionBlock;
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(pack, error); });
    [self.session finishTasksAndInvalidate];  // releases the session's retain on us
    @synchronized([SPKLanguagePackURLImporter class]) { [sSPKActiveImporters removeObject:self]; }
}

- (void)failWithCode:(SPKLanguagePackURLImportErrorCode)code message:(NSString *)message underlying:(nullable NSError *)underlying {
    [self.task cancel];
    [self finishWithPack:nil error:[[self class] errorWithCode:code message:message underlying:underlying]];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
              didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (self.finished) return;
    if ((totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > kSPKMaxPackBytes) || totalBytesWritten > kSPKMaxPackBytes) {
        [self failWithCode:SPKLanguagePackURLImportErrorTooLarge message:SPKL(@"LANGUAGE_PACK_TOO_LARGE") underlying:nil];
        return;
    }
    void (^progress)(double) = self.progressBlock;
    if (progress && totalBytesExpectedToWrite > 0) {
        double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
        dispatch_async(dispatch_get_main_queue(), ^{ progress(MIN(1.0, MAX(0.0, fraction))); });
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    if (self.finished) return;
    NSHTTPURLResponse *response = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (response && (response.statusCode < 200 || response.statusCode >= 300)) {
        [self failWithCode:SPKLanguagePackURLImportErrorHTTPStatus message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *sizeValue = nil;
    if ([location getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:NULL] && sizeValue.longLongValue > kSPKMaxPackBytes) {
        [self failWithCode:SPKLanguagePackURLImportErrorTooLarge message:SPKL(@"LANGUAGE_PACK_TOO_LARGE") underlying:nil];
        return;
    }
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SparkleLangURL-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:@"pack.zip"];
    NSError *moveError = nil;
    if (![fm moveItemAtPath:location.path toPath:zipPath error:&moveError]) {
        [fm removeItemAtPath:tempDir error:nil];
        [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:moveError];
        return;
    }
    // Defer checksum + import to -finalizeDownload (driven from didCompleteWithError:) so the socket's
    // real peer address — collected via didFinishCollectingMetrics: — is vetted before we trust the file.
    self.pendingTempDir = tempDir;
    self.pendingZipPath = zipPath;
}

// Runs at most once, only after BOTH the download completed successfully AND the peer-address metrics
// landed (or the join timeout fired). Vets the peer, then checksums + imports.
- (void)finalizeDownload {
    if (self.finished) return;
    if (self.cancelled) {  // -cancel landed during the download/metrics-join window; the terminal task's
        // [task cancel] was a no-op, so honour the cancel here before we install. (Header contract: the
        // completion fires once with a Cancelled error.)
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    NSString *zipPath = self.pendingZipPath;
    if (zipPath.length == 0) {  // task succeeded but produced no file — treat as a failed download
        [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    if (self.remoteAddrPrivate) {  // DNS rebind: socket connected to a private IP despite pre-flight check
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil];
        return;
    }
    if (self.metricsUnverified && self.requiresVerifiedPeer) {
        // Unpinned download whose peer we could not confirm (metrics never arrived, or carried no
        // address). A valid TLS cert proves hostname↔cert binding, never that the connected IP is
        // non-private, so a rebind behind an attacker-owned validly-certed domain would slip through.
        // With no hash to catch it afterwards, refuse. A pinned download continues to the checksum.
        SPKLog(@"i18n", @"[LangPackURL] peer address unverifiable and no hash is pinned — refusing import (fail-closed)");
        [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    if (self.expectedSHA256.length) {
        NSString *actual = [[self class] sha256HexOfFileAtPath:zipPath];
        if (actual == nil) {  // couldn't read the temp file to hash it — that's a local I/O failure,
            // NOT a checksum mismatch; report it as such so the user isn't told the pack was tampered.
            [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
            return;
        }
        if (![actual isEqualToString:self.expectedSHA256]) {
            [self failWithCode:SPKLanguagePackURLImportErrorChecksumMismatch message:SPKL(@"LANGUAGE_PACK_CHECKSUM_MISMATCH") underlying:nil];
            return;
        }
    }
    // Serialize the actual on-disk install across ALL importer instances: SPKLanguagePackManager
    // importPackAtURL: does an unlocked removeItemAtPath:+copyItemAtPath: to <code>.lproj, so two
    // concurrent installs of the same code (e.g. a catalog tap racing a paste-URL import) could interleave
    // filesystem ops on the same directory. One shared serial queue makes the install step atomic.
    static dispatch_queue_t installQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installQ = dispatch_queue_create("com.sparkle.langpack.install", DISPATCH_QUEUE_SERIAL); });
    if (self.cancelled) {  // -cancel may have landed during the checksum hash — honour it before installing
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    __block NSError *importError = nil;
    __block SPKLanguagePack *pack = nil;
    dispatch_sync(installQ, ^{ pack = [SPKLanguagePackManager importPackAtURL:[NSURL fileURLWithPath:zipPath] error:&importError]; });
    if (!pack) {
        [self finishWithPack:nil error:importError ?: [[self class] errorWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]];
        return;
    }
    if (self.cancelled) {  // -cancel landed during/just after the install — roll it back so the header's
        // "completion fires with a Cancelled error" contract holds end-to-end (don't leave a pack the user cancelled).
        [SPKLanguagePackManager removePack:pack error:NULL];
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    // Record where this pack came from so the updater can tell a later release apart from this one.
    SPKLanguagePackRecordProvenance(pack.code, self.url.absoluteString, self.expectedSHA256);
    SPKLog(@"i18n", @"[LangPackURL] installed %@ (%lu strings)", pack.code, (unsigned long)pack.stringCount);
    [self finishWithPack:pack error:nil];  // finishWithPack removes pendingTempDir
}

// Finalize fires only when BOTH the success and the metrics signals are in; guarded to run once.
- (void)joinAndFinalizeIfReady {
    BOOL go = NO;
    @synchronized(self) {
        if (self.downloadDone && self.metricsDone && !self.finalizeStarted) { self.finalizeStarted = YES; go = YES; }
    }
    if (go) [self finalizeDownload];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    if (self.finished) return;
    if (error) {
        BOOL wasCancel = self.cancelled || (error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain]);
        [self finishWithPack:nil error:[[self class] errorWithCode:(wasCancel ? SPKLanguagePackURLImportErrorCancelled : SPKLanguagePackURLImportErrorDownloadFailed)
                                                        message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:error]];
        return;
    }
    // Success: DON'T import yet — wait until the peer-address metrics are also in (NSURLSession may
    // deliver them after this callback, or never). Arm a fail-safe so a missing metrics callback can't
    // hang the import forever; it marks the peer unverified and lets finalize proceed on the primary guards.
    @synchronized(self) { self.downloadDone = YES; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKMetricsJoinTimeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL fire = NO;
        @synchronized(self) { if (!self.metricsDone) { self.metricsDone = YES; self.metricsUnverified = YES; fire = YES; } }
        if (fire) [self joinAndFinalizeIfReady];
    });
    [self joinAndFinalizeIfReady];
}

// The IP the connection actually used. Catches DNS rebinding between our pre-flight getaddrinfo()
// and NSURLSession's own resolve at connect time. Delivery ordering vs didCompleteWithError: is NOT
// contractually guaranteed, so finalize JOINS on this signal instead of assuming it ran first.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    BOOL priv = NO;
    NSArray<NSURLSessionTaskTransactionMetrics *> *tms = metrics.transactionMetrics;
    for (NSURLSessionTaskTransactionMetrics *tm in tms) {  // ANY hop private → block (covers rebind on a redirect)
        NSString *remote = tm.remoteAddress;
        if (remote.length && SPKLanguagePackRemoteAddrStringIsPrivate(remote)) { priv = YES; break; }
    }
    // "Verified" must hinge on the FINAL (payload-delivering) transaction, not any earlier hop: a
    // public address on hop 1 must not mask an empty address on the transaction that actually served us.
    BOOL sawAddr = (tms.lastObject.remoteAddress.length > 0);
    @synchronized(self) {
        if (self.metricsDone) return;
        self.metricsDone = YES;
        if (priv) self.remoteAddrPrivate = YES;
        else if (!sawAddr) self.metricsUnverified = YES;  // final hop gave NO usable peer address → unverified, not "safe"
    }
    if (priv) {
        SPKLog(@"i18n", @"[LangPackURL] blocked: peer resolved private (DNS rebind?)");
        if (!self.finished) { [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil]; return; }
    }
    [self joinAndFinalizeIfReady];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    // Re-apply the pre-flight guards to each redirect hop: a redirect target is a fresh host that the
    // original check never saw. The proxy half only binds an unpinned download, matching -start.
    BOOL safe = SPKLanguagePackRemoteURLIsSafe(request.URL) &&
                !(self.requiresVerifiedPeer && SPKLanguagePackURLWouldUseProxy(request.URL));
    if (safe) {
        completionHandler(request);
    } else {
        completionHandler(nil);
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil];
    }
}

#pragma mark - SHA-256

+ (nullable NSString *)sha256HexOfFileAtPath:(NSString *)path {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return nil;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    [stream open];
    uint8_t buffer[65536];
    NSInteger read;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)read);
    [stream close];
    if (read < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [hex copy];
}

@end
