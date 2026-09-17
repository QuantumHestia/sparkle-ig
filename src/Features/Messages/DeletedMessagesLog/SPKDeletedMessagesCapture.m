#import "SPKStrings.h"
#import "SPKDeletedMessagesCapture.h"
#import "../../../Shared/MediaDownload/SPKDashParser.h"
#import "../../../Shared/MediaDownload/SPKMediaFFmpeg.h"
#import "../../../Shared/MediaPreview/SPKImageFormat.h"
#import "../../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../../Shared/Messages/SPKDirectUserResolver.h"
#import "../../../Utils.h"
#import "SPKDeletedMessagesModels.h"
#import "SPKDeletedMessagesStorage.h"
#import <objc/runtime.h>

#pragma mark - Lazy weak-ref cache

// Stash a weak ref at insert; on unsend, promote to strong and snapshot.
// Aged-out messages fall back to a `_messagesByServerId` read.

static NSMapTable *spkMessageRefs(void) {
    static NSMapTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPersonality
                                  valueOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality];
    });
    return t;
}

static NSObject *spkMessageRefsLock(void) {
    static NSObject *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        o = [NSObject new];
    });
    return o;
}

static dispatch_queue_t spkCaptureQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.sparkle.deletedmessages.capture", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static dispatch_queue_t spkDownloadQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.sparkle.deletedmessages.download", DISPATCH_QUEUE_CONCURRENT);
    });
    return q;
}

static NSURLSession *spkSharedSession(void) {
    static NSURLSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 120;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

static BOOL spkCaptureEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_deleted_log"];
}

static SPKDashRepresentation *spkBestDashRepresentation(NSArray<SPKDashRepresentation *> *reps, BOOL video) {
    SPKDashRepresentation *best = nil;
    for (SPKDashRepresentation *rep in reps) {
        NSString *type = rep.contentType.lowercaseString ?: @"";
        BOOL isVideo = [type containsString:@"video"] || rep.width > 0 || rep.height > 0;
        BOOL isAudio = [type containsString:@"audio"] || (!isVideo && rep.url != nil);
        if (video ? !isVideo : !isAudio)
            continue;
        if (!best) {
            best = rep;
            continue;
        }
        NSInteger area = rep.width * rep.height;
        NSInteger bestArea = best.width * best.height;
        if (video) {
            if (area > bestArea || (area == bestArea && rep.bandwidth > best.bandwidth))
                best = rep;
        } else if (rep.bandwidth > best.bandwidth) {
            best = rep;
        }
    }
    return best;
}

#pragma mark - Ivar / selector helpers

static NSString *spkStrIvar(id obj, const char *name) {
    if (!obj || !name)
        return nil;
    Ivar iv = NULL;
    for (Class c = [obj class]; c && !iv; c = class_getSuperclass(c))
        iv = class_getInstanceVariable(c, name);
    if (!iv)
        return nil;
    @try {
        id v = object_getIvar(obj, iv);
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (__unused id e) {
        return nil;
    }
}

static id spkAnyIvar(id obj, const char *name) {
    if (!obj || !name)
        return nil;
    Ivar iv = NULL;
    for (Class c = [obj class]; c && !iv; c = class_getSuperclass(c))
        iv = class_getInstanceVariable(c, name);
    if (!iv)
        return nil;
    @try {
        return object_getIvar(obj, iv);
    } @catch (__unused id e) {
        return nil;
    }
}

static double spkDoubleSelector(id obj, NSString *selName) {
    if (!obj)
        return 0;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel])
        return 0;
    @try {
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        const char *rt = sig.methodReturnType;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = obj;
        inv.selector = sel;
        [inv invoke];
        if (strcmp(rt, "d") == 0) {
            double r;
            [inv getReturnValue:&r];
            return r;
        }
        if (strcmp(rt, "f") == 0) {
            float r;
            [inv getReturnValue:&r];
            return (double)r;
        }
        if (strcmp(rt, "q") == 0) {
            long long r;
            [inv getReturnValue:&r];
            return (double)r;
        }
        if (strcmp(rt, "i") == 0) {
            int r;
            [inv getReturnValue:&r];
            return (double)r;
        }
    } @catch (__unused id e) {
    }
    return 0;
}

// Filter out NSObject's `<ClassName: 0xaddr>` description fallback.
static BOOL spkIsDescriptionFallback(NSString *s) {
    if (!s.length)
        return NO;
    return [s hasPrefix:@"<"] && [s containsString:@": 0x"] && [s hasSuffix:@">"];
}

static NSString *spkTryStringSelectors(id obj, NSArray<NSString *> *names) {
    if (!obj)
        return nil;
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        if (![obj respondsToSelector:s])
            continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(obj, s);
            NSString *str = nil;
            if ([v isKindOfClass:[NSString class]])
                str = v;
            else if ([v isKindOfClass:[NSAttributedString class]])
                str = [(NSAttributedString *)v string];
            if (!str.length || spkIsDescriptionFallback(str))
                continue;
            return str;
        } @catch (__unused id e) {
        }
    }
    return nil;
}

static NSString *spkTryURLSelectors(id obj, NSArray<NSString *> *names) {
    if (!obj)
        return nil;
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        if (![obj respondsToSelector:s])
            continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(obj, s);
            if ([v isKindOfClass:[NSURL class]]) {
                NSString *str = [(NSURL *)v absoluteString];
                if (str.length)
                    return str;
            }
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                return v;
        } @catch (__unused id e) {
        }
    }
    return nil;
}

static id spkTryObjectSelector(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    }
    @catch (__unused id e) {
        return nil;
    }
}

static BOOL spkBoolSelector(id obj, NSString *name, BOOL *found) {
    if (found)
        *found = NO;
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel])
        return NO;
    @try {
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (!sig)
            return NO;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = obj;
        inv.selector = sel;
        [inv invoke];
        BOOL value = NO;
        [inv getReturnValue:&value];
        if (found)
            *found = YES;
        return value;
    } @catch (__unused id e) {
        return NO;
    }
}

static BOOL spkBoolIvar(id obj, const char *name, BOOL *found) {
    if (found)
        *found = NO;
    if (!obj || !name)
        return NO;
    Ivar iv = NULL;
    for (Class c = [obj class]; c && !iv; c = class_getSuperclass(c))
        iv = class_getInstanceVariable(c, name);
    if (!iv)
        return NO;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || (type[0] != 'B' && type[0] != 'c'))
        return NO;
    @try {
        BOOL value = *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
        if (found)
            *found = YES;
        return value;
    } @catch (__unused id e) {
        return NO;
    }
}

static BOOL spkSemanticIsSticker(id obj, BOOL *found) {
    BOOL value = spkBoolSelector(obj, @"isSticker", found);
    if (found && *found)
        return value;
    return spkBoolIvar(obj, "_isSticker", found);
}

static NSString *spkURLStringValue(id value) {
    if ([value isKindOfClass:[NSURL class]])
        return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] ? value : nil;
    return nil;
}

static id spkFindObjectWithClassNamesRecursive(id obj, NSSet<NSString *> *classNames, int depth,
                                               NSMutableSet<NSValue *> *visited) {
    if (!obj || depth < 0)
        return nil;
    if ([classNames containsObject:NSStringFromClass([obj class])])
        return obj;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSURL class]])
        return nil;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)obj) {
            id found = spkFindObjectWithClassNamesRecursive(value, classNames, depth - 1, visited);
            if (found)
                return found;
        }
        return nil;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)obj allValues]) {
            id found = spkFindObjectWithClassNamesRecursive(value, classNames, depth - 1, visited);
            if (found)
                return found;
        }
        return nil;
    }
    NSValue *box = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:box])
        return nil;
    [visited addObject:box];
    for (Class c = [obj class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@')
                continue;
            id value = nil;
            @try {
                value = object_getIvar(obj, ivars[i]);
            } @catch (__unused id e) {
            }
            id found = spkFindObjectWithClassNamesRecursive(value, classNames, depth - 1, visited);
            if (found) {
                free(ivars);
                return found;
            }
        }
        if (ivars)
            free(ivars);
    }
    return nil;
}

static id spkFindObjectWithClassNames(id obj, NSArray<NSString *> *classNames, int depth) {
    return spkFindObjectWithClassNamesRecursive(obj, [NSSet setWithArray:classNames], depth, [NSMutableSet set]);
}

static NSString *spkGiphyMediaURL(id giphy) {
    id imageModels = spkTryObjectSelector(giphy, @"imageModels");
    if (![imageModels isKindOfClass:[NSDictionary class]])
        return nil;
    for (NSString *configName in @[ @"webpConfig", @"gifConfig", @"mp4Config" ]) {
        for (id imageModel in [(NSDictionary *)imageModels allValues]) {
            id config = spkTryObjectSelector(imageModel, configName);
            NSString *url = spkURLStringValue(spkTryObjectSelector(config, @"url"));
            if (url.length)
                return url;
        }
    }
    return nil;
}

static NSString *spkStickerMediaURL(id sticker) {
    id store = spkAnyIvar(sticker, "_storeSticker");
    id facebook = spkAnyIvar(sticker, "_fbSticker");
    for (NSString *selector in @[ @"animatedPreviewImageURL", @"imageURL", @"fallbackImageURL",
                                  @"staticPreviewImageURL", @"url" ]) {
        NSString *url = spkURLStringValue(spkTryObjectSelector(store ?: facebook, selector));
        if (url.length)
            return url;
    }
    return nil;
}

static NSDate *spkDateFromSnapshotValue(id value) {
    if ([value isKindOfClass:[NSDate class]])
        return value;
    if ([value isKindOfClass:[NSNumber class]])
        return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    return nil;
}

static NSDictionary *spkJSONSafeSnapshot(NSDictionary *snapshot) {
    NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithCapacity:snapshot.count];
    for (NSString *key in snapshot) {
        id value = snapshot[key];
        if ([value isKindOfClass:[NSDate class]])
            value = @([(NSDate *)value timeIntervalSince1970]);
        if (value)
            safe[key] = value;
    }
    NSString *sid = safe[@"sid"];
    if (sid.length)
        safe[@"message_id"] = sid;
    return safe;
}

#pragma mark - URL scanner (recursive, scored)

static void spkScanForURLsRecursive(id obj, int depth,
                                    NSString **outMedia, int *mediaScore,
                                    NSString **outThumb, int *thumbScore,
                                    NSString *parentName) {
    if (!obj || depth < 0)
        return;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        BOOL urlShaped = NO;
        for (NSString *p in @[ @"http://", @"https://", @"instagram://",
                               @"fb://", @"fbthreads://", @"intent://" ]) {
            if ([s hasPrefix:p]) {
                urlShaped = YES;
                break;
            }
        }
        if (!urlShaped)
            return;

        NSString *n = parentName ?: @"";
        BOOL thumbHint = [n containsString:@"thumb"] || [n containsString:@"preview"] || [n containsString:@"poster"] || [n containsString:@"cover"];
        BOOL mediaHint = [n containsString:@"playable"] || [n containsString:@"video"] || [n containsString:@"audio"] || [n containsString:@"voice"] || [n containsString:@"asset"] || [n containsString:@"download"] || [n containsString:@"src"] || [n containsString:@"url"];
        BOOL imageHint = [n containsString:@"image"] || [n containsString:@"photo"];

        int score = 1;
        if (mediaHint)
            score = 4;
        if (imageHint)
            score = thumbHint ? 2 : 3;
        if (thumbHint) {
            if (score > *thumbScore) {
                *thumbScore = score;
                *outThumb = s;
            }
        } else {
            if (score > *mediaScore) {
                *mediaScore = score;
                *outMedia = s;
            }
        }
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *s = [(NSURL *)obj absoluteString];
        if (s.length)
            spkScanForURLsRecursive(s, depth, outMedia, mediaScore, outThumb, thumbScore, parentName);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)obj)
            spkScanForURLsRecursive(e, depth - 1, outMedia, mediaScore, outThumb, thumbScore, parentName);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj;
        for (id k in d) {
            id v = d[k];
            NSString *kn = [k isKindOfClass:[NSString class]] ? (NSString *)k : parentName;
            spkScanForURLsRecursive(v, depth - 1, outMedia, mediaScore, outThumb, thumbScore, kn);
        }
        return;
    }
    Class cls = [obj class];
    NSString *cn = NSStringFromClass(cls);
    if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"OS"] || [cn hasPrefix:@"__"])
        return;
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *list = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *type = ivar_getTypeEncoding(list[i]);
            if (!type || type[0] != '@')
                continue;
            const char *name = ivar_getName(list[i]);
            id v = nil;
            @try {
                v = object_getIvar(obj, list[i]);
            } @catch (__unused id e) {
            }
            if (!v)
                continue;
            NSString *nameStr = name ? @(name) : parentName;
            spkScanForURLsRecursive(v, depth - 1, outMedia, mediaScore, outThumb, thumbScore, nameStr);
        }
        if (list)
            free(list);
    }
}

#pragma mark - Token-based kind classifier

static void spkCollectIvarNames(id obj, int depth, NSMutableSet *visited, NSMutableSet<NSString *> *out) {
    if (!obj || depth < 0)
        return;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)obj)
            spkCollectIvarNames(e, depth - 1, visited, out);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj;
        for (id k in d) {
            if ([k isKindOfClass:[NSString class]])
                [out addObject:[(NSString *)k lowercaseString]];
            spkCollectIvarNames(d[k], depth - 1, visited, out);
        }
        return;
    }
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSURL class]])
        return;
    NSValue *box = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:box])
        return;
    [visited addObject:box];
    Class cls = [obj class];
    NSString *cn = NSStringFromClass(cls);
    if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"OS"] || [cn hasPrefix:@"__"])
        return;
    [out addObject:cn.lowercaseString];
    // Only object-typed ivars holding values — IG declares every variant slot up-front, most nil.
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *list = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *name = ivar_getName(list[i]);
            const char *type = ivar_getTypeEncoding(list[i]);
            if (!type || type[0] != '@')
                continue;
            id v = nil;
            @try {
                v = object_getIvar(obj, list[i]);
            } @catch (__unused id e) {
            }
            if (!v)
                continue;
            if (name)
                [out addObject:[@(name) lowercaseString]];
            spkCollectIvarNames(v, depth - 1, visited, out);
        }
        if (list)
            free(list);
    }
}

static BOOL spkSetContainsAny(NSSet<NSString *> *set, NSArray<NSString *> *needles) {
    for (NSString *n in needles) {
        for (NSString *tok in set)
            if ([tok containsString:n])
                return YES;
    }
    return NO;
}

#pragma mark - Sender / metadata extraction

static NSString *spkSidFromMessage(id m) {
    id meta = spkAnyIvar(m, "_metadata");
    if (!meta)
        return nil;
    NSString *sid = spkStrIvar(meta, "_serverId") ?: spkStrIvar(meta, "_messageServerId");
    if (!sid.length) {
        id key = spkAnyIvar(meta, "_key");
        if (key)
            sid = spkStrIvar(key, "_serverId") ?: spkStrIvar(key, "_messageServerId");
    }
    return sid;
}

static NSString *spkSenderPkFromMessage(id m) {
    id meta = spkAnyIvar(m, "_metadata");
    return spkStrIvar(meta, "_senderPk");
}

static NSDate *spkSentAtFromMessage(id m) {
    id meta = spkAnyIvar(m, "_metadata");
    if (!meta)
        return nil;
    static const char *names[] = {"_serverTimestamp", "_clientTimestamp", "_timestamp"};
    for (int i = 0; i < 3; i++) {
        id v = spkAnyIvar(meta, names[i]);
        if ([v isKindOfClass:[NSDate class]])
            return v;
        if ([v isKindOfClass:[NSNumber class]]) {
            double d = [(NSNumber *)v doubleValue];
            if (d > 1.0e12)
                d /= 1.0e9;
            else if (d > 1.0e10)
                d /= 1.0e3;
            if (d > 0)
                return [NSDate dateWithTimeIntervalSince1970:d];
        }
    }
    return nil;
}

// fieldCache (snake_case Pando dict) — KVC returns NSNull for many IGUser fields.
static void spkResolveSenderInfo(NSString *pk, NSString **outUser, NSString **outName, NSString **outPic) {
    if (!pk.length)
        return;
    NSString *u = spkDirectUserResolverUsernameForPK(pk);
    NSString *p = spkDirectUserResolverProfilePicURLStringForPK(pk);
    NSString *fn = nil;
    id user = spkDirectUserResolverUserForPK(pk);
    if (user) {
        Ivar fcIv = NULL;
        for (Class c = [user class]; c && !fcIv; c = class_getSuperclass(c))
            fcIv = class_getInstanceVariable(c, "_fieldCache");
        NSDictionary *fc = nil;
        if (fcIv) {
            id raw = object_getIvar(user, fcIv);
            if ([raw isKindOfClass:[NSDictionary class]])
                fc = raw;
        }
        id (^fcStr)(NSString *) = ^id(NSString *k) {
            id v = fc[k];
            return [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 ? v : nil;
        };
        if (!u.length)
            u = fcStr(@"username");
        if (!p.length)
            p = fcStr(@"profile_pic_url");
        fn = fcStr(@"full_name");
        if (!fn.length) {
            @try {
                id kvc = [user valueForKey:@"fullName"];
                if ([kvc isKindOfClass:[NSString class]])
                    fn = kvc;
            } @catch (__unused id e) {
            }
        }
    }
    if (outUser)
        *outUser = u;
    if (outName)
        *outName = fn;
    if (outPic)
        *outPic = p;
}

#pragma mark - Share/link title fallback

// Walks string ivars by name (title/caption/headline/...). First non-empty wins; longer wins ties.
static NSString *spkExtractShareTitle(id obj) {
    if (!obj)
        return nil;
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:obj];
    NSString *best = nil;
    NSArray<NSString *> *keys = @[ @"title", @"caption", @"text", @"name",
                                   @"description", @"summary", @"label",
                                   @"username", @"headline" ];
    int hops = 0;
    while (stack.count && hops++ < 64) {
        id cur = stack.lastObject;
        [stack removeLastObject];
        if (!cur)
            continue;
        if ([cur isKindOfClass:[NSArray class]]) {
            for (id e in (NSArray *)cur)
                [stack addObject:e];
            continue;
        }
        if ([cur isKindOfClass:[NSString class]] || [cur isKindOfClass:[NSNumber class]] || [cur isKindOfClass:[NSDate class]] || [cur isKindOfClass:[NSURL class]])
            continue;
        NSValue *box = [NSValue valueWithNonretainedObject:cur];
        if ([visited containsObject:box])
            continue;
        [visited addObject:box];
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"OS"] || [cn hasPrefix:@"__"])
            continue;
        for (Class c = [cur class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Ivar *list = class_copyIvarList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *type = ivar_getTypeEncoding(list[i]);
                if (!type || type[0] != '@')
                    continue;
                const char *name = ivar_getName(list[i]);
                id v = nil;
                @try {
                    v = object_getIvar(cur, list[i]);
                } @catch (__unused id e) {
                }
                if (!v)
                    continue;
                NSString *nameStr = name ? [@(name) lowercaseString] : @"";
                if ([v isKindOfClass:[NSString class]]) {
                    for (NSString *needle in keys) {
                        if (![nameStr containsString:needle])
                            continue;
                        NSString *s = v;
                        if (s.length && (!best || s.length > best.length))
                            best = s;
                    }
                } else {
                    [stack addObject:v];
                }
            }
            if (list)
                free(list);
        }
    }
    return best;
}

#pragma mark - Voice metadata sniffer

static void spkScanVoiceMetadata(id media, double *outDuration, NSArray **outWaveform) {
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:media];
    while (stack.count) {
        id cur = stack.lastObject;
        [stack removeLastObject];
        if (!cur)
            continue;
        if ([cur isKindOfClass:[NSArray class]]) {
            for (id e in cur)
                [stack addObject:e];
            continue;
        }
        if ([cur isKindOfClass:[NSString class]] || [cur isKindOfClass:[NSNumber class]] || [cur isKindOfClass:[NSDate class]] || [cur isKindOfClass:[NSURL class]])
            continue;
        NSValue *box = [NSValue valueWithNonretainedObject:cur];
        if ([visited containsObject:box])
            continue;
        [visited addObject:box];
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"OS"] || [cn hasPrefix:@"__"])
            continue;

        if (!*outDuration) {
            double cand = spkDoubleSelector(cur, @"durationInSeconds");
            if (cand <= 0)
                cand = spkDoubleSelector(cur, @"duration");
            if (cand <= 0) {
                for (Class c = [cur class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
                    Ivar iv = class_getInstanceVariable(c, "_durationMs");
                    if (!iv)
                        iv = class_getInstanceVariable(c, "_instamadillo_durationMs");
                    if (!iv)
                        continue;
                    const char *t = ivar_getTypeEncoding(iv);
                    ptrdiff_t off = ivar_getOffset(iv);
                    if (t[0] == 'Q' || t[0] == 'q') {
                        long long ms = *(long long *)((char *)(__bridge void *)cur + off);
                        if (ms > 0)
                            cand = (double)ms / 1000.0;
                    }
                    break;
                }
            }
            if (cand > 0)
                *outDuration = cand;
        }
        if (!*outWaveform) {
            id cand = spkAnyIvar(cur, "_averageVolume")
                          ?: spkAnyIvar(cur, "_waveformData")
                             ?
                         : spkAnyIvar(cur, "_waveform")
                             ?
                             : spkAnyIvar(cur, "_amplitudes");
            if ([cand isKindOfClass:[NSArray class]])
                *outWaveform = cand;
        }
        for (Class c = [cur class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Ivar *list = class_copyIvarList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *type = ivar_getTypeEncoding(list[i]);
                if (!type || type[0] != '@')
                    continue;
                id v = nil;
                @try {
                    v = object_getIvar(cur, list[i]);
                } @catch (__unused id e) {
                }
                if (v)
                    [stack addObject:v];
            }
            if (list)
                free(list);
        }
    }
}

#pragma mark - Share subtype / preview helpers

// Classify what a shared post actually is from its deep-link / target URL and
// (as a hint) the XMA content type. Returns "reel"/"post"/"story"/"profile"/
// "note"/"location"/"audio", or nil when it's an ordinary link or unknowable.
static NSString *spkShareSubtypeFromTarget(NSString *urlStr, NSString *contentType) {
    NSString *ct = [contentType isKindOfClass:[NSString class]] ? contentType.lowercaseString : @"";
    NSURL *u = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
    NSString *path = (u.path.length ? u.path : urlStr).lowercaseString;
    NSString *host = u.host.lowercaseString ?: @"";

    // Path is the most reliable signal for IG permalinks / deep links.
    if ([path containsString:@"/reel/"] || [path containsString:@"/reels/"] || [path containsString:@"clips_viewer"])
        return @"reel";
    if ([path containsString:@"/stories/"] || [path containsString:@"story_viewer"])
        return @"story";
    if ([path containsString:@"/p/"] || [path containsString:@"/tv/"] || [path containsString:@"media?id"])
        return @"post";
    if ([path containsString:@"audio_page"])
        return @"audio";

    // Content-type hints when the URL is opaque.
    if ([ct containsString:@"clip"] || [ct containsString:@"reel"])
        return @"reel";
    if ([ct containsString:@"story"])
        return @"story";
    if ([ct containsString:@"profile"] || [ct containsString:@"user"])
        return @"profile";
    if ([ct containsString:@"location"])
        return @"location";
    if ([ct containsString:@"note"])
        return @"note";
    if ([ct containsString:@"media_share"] || [ct containsString:@"felix"] || [ct containsString:@"clips"])
        return @"post";

    // A bare instagram.com/<handle> path (single component) is a profile share.
    if ([host containsString:@"instagram.com"]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *p in [path componentsSeparatedByString:@"/"])
            if (p.length)
                [parts addObject:p];
        if (parts.count == 1 && ![parts.firstObject containsString:@"."])
            return @"profile";
    }
    return nil;
}

// Whether a URL string looks like a fetchable preview image (CDN image host or
// image extension). Lets us recover a post cover even when the preview sits
// under an unhinted key the scorer wouldn't classify as a thumbnail.
static BOOL spkURLLooksLikeImage(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length)
        return NO;
    NSString *lower = s.lowercaseString;
    if (![lower hasPrefix:@"http"])
        return NO;
    NSString *pathPart = lower;
    NSRange q = [pathPart rangeOfString:@"?"];
    if (q.location != NSNotFound)
        pathPart = [pathPart substringToIndex:q.location];
    for (NSString *ext in @[ @".jpg", @".jpeg", @".png", @".webp", @".heic" ]) {
        if ([pathPart hasSuffix:ext])
            return YES;
    }
    // IG/FB image CDN hosts serve images even without an extension in the path.
    if (([lower containsString:@"cdninstagram.com"] || [lower containsString:@"fbcdn.net"]) && ([lower containsString:@".jpg"] || [lower containsString:@".webp"] || [lower containsString:@".heic"] || [lower containsString:@"=jpg"] || [lower containsString:@"stp="]))
        return YES;
    return NO;
}

// Depth-first hunt for the first image-looking URL anywhere under `obj` (strings,
// URLs, collections, and object ivars). Cycle-guarded; stops at the first hit.
static void spkCollectImageURL(id obj, int depth, NSMutableSet *visited, NSString **out) {
    if (*out || !obj || depth < 0)
        return;
    if ([obj isKindOfClass:[NSString class]]) {
        if (spkURLLooksLikeImage(obj))
            *out = obj;
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        spkCollectImageURL([(NSURL *)obj absoluteString], depth, visited, out);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]] || [obj isKindOfClass:[NSOrderedSet class]]) {
        for (id e in obj) {
            spkCollectImageURL(e, depth - 1, visited, out);
            if (*out)
                return;
        }
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id k in (NSDictionary *)obj) {
            spkCollectImageURL(((NSDictionary *)obj)[k], depth - 1, visited, out);
            if (*out)
                return;
        }
        return;
    }
    Class cls = [obj class];
    NSString *cn = NSStringFromClass(cls);
    if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"OS"] || [cn hasPrefix:@"__"])
        return;
    NSValue *box = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:box])
        return;
    [visited addObject:box];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *list = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(list[i]);
            if (!t || t[0] != '@')
                continue;
            id v = object_getIvar(obj, list[i]);
            spkCollectImageURL(v, depth - 1, visited, out);
            if (*out) {
                free(list);
                return;
            }
        }
        if (list)
            free(list);
    }
}

#pragma mark - Snapshot builder

// Returns nil for system / placeholder / non-user rows.
// `threadContext` is the open chat when the message was seen. The caller reads
// it on the main thread, because the builder can run on a background queue and
// the active context is only updated on the main thread.
static NSDictionary *spkBuildSnapshotWithContext(id message, NSString *ownerHint, SPKDirectThreadContext *threadContext) {
    NSString *sid = spkSidFromMessage(message);
    if (!sid.length)
        return nil;

    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    snap[@"sid"] = sid;
    if (ownerHint.length)
        snap[@"owner_pk"] = ownerHint;

    NSString *threadId = nil;
    @try {
        threadId = [message valueForKey:@"threadId"];
    } @catch (__unused id e) {
    }
    if (![threadId isKindOfClass:[NSString class]] || !threadId.length) {
        id meta = spkAnyIvar(message, "_metadata");
        threadId = spkStrIvar(meta, "_threadId") ?: spkStrIvar(meta, "_threadID");
    }
    if (threadId.length)
        snap[@"thread_id"] = threadId;

    // Stamp group-ness + title from the open thread's metadata when this capture
    // happens while the chat is foregrounded (the common case). Read-time
    // grouping falls back to a multi-sender heuristic when this isn't available.
    if (threadId.length) {
        SPKDirectThreadContext *ctx = threadContext;
        if (ctx && [ctx.threadId isEqualToString:threadId]) {
            if (ctx.isGroup)
                snap[@"is_group"] = @YES;
            if (ctx.threadName.length)
                snap[@"thread_title"] = ctx.threadName;
        }
    }

    NSString *senderPk = spkSenderPkFromMessage(message);
    if (senderPk.length) {
        snap[@"sender_pk"] = senderPk;
        NSString *u = nil, *fn = nil, *pic = nil;
        spkResolveSenderInfo(senderPk, &u, &fn, &pic);
        if (u.length)
            snap[@"sender_username"] = u;
        if (fn.length)
            snap[@"sender_full_name"] = fn;
        if (pic.length)
            snap[@"sender_profile_pic_url"] = pic;
    }
    NSDate *sentAt = spkSentAtFromMessage(message);
    if (sentAt)
        snap[@"sent_at"] = sentAt;

    // Reply id can sit on metadata, on the message, or as a Pando-resolved value-key.
    @try {
        id meta = spkAnyIvar(message, "_metadata");
        NSString *replyId = nil;
        for (NSString *k in @[ @"_replyToMessageId", @"_replyMessageId",
                               @"_quotedMessageId", @"_repliedToMessageId",
                               @"_parentMessageId" ]) {
            NSString *v = spkStrIvar(meta, k.UTF8String) ?: spkStrIvar(message, k.UTF8String);
            if (v.length) {
                replyId = v;
                break;
            }
        }
        if (!replyId.length) {
            for (NSString *k in @[ @"replyToMessageId", @"replyMessageId",
                                   @"quotedMessageId", @"repliedToMessageId",
                                   @"reply_message_id" ]) {
                @try {
                    id v = [message valueForKey:k];
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                        replyId = v;
                        break;
                    }
                } @catch (__unused id e) {
                }
            }
        }
        if (replyId.length)
            snap[@"reply_to_id"] = replyId;
    } @catch (__unused id e) {
    }

    id content = spkAnyIvar(message, "_content")
                     ?: spkAnyIvar(message, "_messageContent")
                        ?
                        : spkAnyIvar(message, "_payload");
    if (!content) {
        @try {
            content = [message valueForKey:@"content"];
        } @catch (__unused id e) {
        }
    }
    if (!content) {
        snap[@"kind"] = @(SPKDeletedMessageKindUnknown);
        return snap;
    }

    if (spkAnyIvar(content, "_threadActivity") || spkAnyIvar(content, "_messageTypeNotLocallyAvailable_placeholderTitle") || spkAnyIvar(content, "_messageTypeNotLocallyAvailable_placeholderMessage") || spkAnyIvar(content, "_expiredPlaceholder_messageContent")) {
        return nil;
    }

    SPKDeletedMessageKind kind = SPKDeletedMessageKindUnknown;
    NSString *text = nil, *mediaURL = nil, *thumbURL = nil;
    NSString *shareSubtype = nil, *shareAuthor = nil;
    int mediaScore = 0, thumbScore = 0;

    NSString *txt = spkStrIvar(content, "_text_string");
    if (txt.length) {
        kind = SPKDeletedMessageKindText;
        text = txt;
    }

    // Media branch — photo / video / voice / gif / sticker.
    id media = spkAnyIvar(content, "_media");
    if (media) {
        id stickerPayload = spkAnyIvar(media, "_sticker") ?: spkTryObjectSelector(media, @"sticker");
        id instamadilloGif = spkTryObjectSelector(media, @"gif")
                                 ?: spkFindObjectWithClassNames(media, @[ @"IGDirectInstamadilloGif" ], 5);
        id giphy = spkAnyIvar(media, "_thirdPartyAnimatedMedia_gif")
                       ?: spkFindObjectWithClassNames(media, @[ @"IGGiphyGIFModel" ], 5);
        BOOL hasSemanticSticker = NO;
        BOOL semanticSticker = spkSemanticIsSticker(instamadilloGif ?: giphy, &hasSemanticSticker);
        if (!hasSemanticSticker)
            semanticSticker = spkBoolIvar(media, "_animatedMedia_isSticker", &hasSemanticSticker);

        NSMutableSet *vis = [NSMutableSet set];
        NSMutableSet<NSString *> *tokens = [NSMutableSet set];
        spkCollectIvarNames(media, 5, vis, tokens);

        if (stickerPayload || (hasSemanticSticker && semanticSticker))
            kind = SPKDeletedMessageKindSticker;
        else if (instamadilloGif || giphy)
            kind = SPKDeletedMessageKindGif;
        else if (spkSetContainsAny(tokens, @[ @"voice", @"audio" ]))
            kind = SPKDeletedMessageKindVoice;
        else if (spkSetContainsAny(tokens, @[ @"sticker" ]))
            kind = SPKDeletedMessageKindSticker;
        else if (spkSetContainsAny(tokens, @[ @"giphy", @"gif", @"animated" ]))
            kind = SPKDeletedMessageKindGif;
        else if (spkSetContainsAny(tokens, @[ @"video", @"dashmanifest", @"playableurl" ]))
            kind = SPKDeletedMessageKindVideo;
        else
            kind = SPKDeletedMessageKindPhoto;

        if (kind == SPKDeletedMessageKindGif || kind == SPKDeletedMessageKindSticker) {
            NSString *explicitURL = spkURLStringValue(spkTryObjectSelector(instamadilloGif, @"gifURL"));
            if (!explicitURL.length)
                explicitURL = spkGiphyMediaURL(giphy);
            if (!explicitURL.length && stickerPayload)
                explicitURL = spkStickerMediaURL(stickerPayload);
            if (explicitURL.length) {
                mediaURL = explicitURL;
                mediaScore = 100;
            }
        }

        if (kind == SPKDeletedMessageKindVoice) {
            double dur = 0;
            NSArray *wf = nil;
            spkScanVoiceMetadata(media, &dur, &wf);
            if (dur > 0)
                snap[@"duration"] = @(dur);
            if (wf.count)
                snap[@"waveform"] = wf;
        }

        // Visual media is an info wrapper. Its payload mirrors permanent media.
        id visualInfo = spkAnyIvar(media, "_visualMedia");
        id visualPayload = spkAnyIvar(visualInfo, "_media") ?: spkTryObjectSelector(visualInfo, @"media");
        if (visualInfo) {
            double viewMode = spkDoubleSelector(visualInfo, @"viewMode");
            snap[@"view_mode"] = @((NSInteger)viewMode);
            id stale = spkAnyIvar(visualInfo, "_mediaUrlGoesStaleDate") ?: spkTryObjectSelector(visualInfo, @"mediaUrlGoesStaleDate");
            if ([stale isKindOfClass:[NSDate class]])
                snap[@"media_url_stale_at"] = stale;
        }

        if (kind == SPKDeletedMessageKindPhoto) {
            id permanent = spkAnyIvar(media, "_permanentMedia_permanentMedia");
            id photo = spkAnyIvar(permanent, "_photo_photo")
                           ?: spkAnyIvar(visualPayload, "_photo_photo");
            NSURL *photoURL = photo ? [SPKUtils getPhotoUrl:photo] : nil;
            if (photoURL.absoluteString.length) {
                mediaURL = photoURL.absoluteString;
                mediaScore = 100;
            }
        }

        // IGVideo sits under _permanentMedia_permanentMedia, not on media.
        if (kind == SPKDeletedMessageKindVideo) {
            id permanent = spkAnyIvar(media, "_permanentMedia_permanentMedia");
            id video = nil;
            id overlayPhoto = nil;
            if (permanent) {
                video = spkAnyIvar(permanent, "_video_video")
                            ?: spkAnyIvar(permanent, "_videoMemo_memoVideo");
                overlayPhoto = spkAnyIvar(permanent, "_video_overlayPhoto")
                                   ?: spkAnyIvar(permanent, "_videoMemo_videoMemoPhoto");
            }
            // visualMedia fallback — view-once flows.
            if (!video) {
                if (visualPayload) {
                    video = spkAnyIvar(visualPayload, "_video_video")
                                ?: spkAnyIvar(visualPayload, "_video");
                    if (!overlayPhoto)
                        overlayPhoto = spkAnyIvar(visualPayload, "_video_overlayPhoto")
                                           ?: spkAnyIvar(visualPayload, "_overlayPhoto");
                }
            }

            if (video) {
                NSData *manifestData = spkAnyIvar(video, "_dashManifestData");
                if ([manifestData isKindOfClass:[NSData class]] && manifestData.length) {
                    NSString *xml = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
                    NSArray<SPKDashRepresentation *> *reps = [SPKDashParser parseManifest:xml];
                    SPKDashRepresentation *bestV = spkBestDashRepresentation(reps, YES);
                    SPKDashRepresentation *bestA = spkBestDashRepresentation(reps, NO);
                    if (bestV.url.absoluteString.length) {
                        mediaURL = bestV.url.absoluteString;
                        mediaScore = 100;
                    }
                    // DASH video + audio are separate reps; muxed via SPKMediaFFmpeg later.
                    if (bestA.url.absoluteString.length)
                        snap[@"audio_url"] = bestA.url.absoluteString;
                }
                if (!mediaURL.length) {
                    for (NSString *ivName in @[ @"_broadcastURL", @"_subtitleURL" ]) {
                        id v = spkAnyIvar(video, ivName.UTF8String);
                        if ([v isKindOfClass:[NSURL class]]) {
                            mediaURL = [(NSURL *)v absoluteString];
                            mediaScore = 90;
                            break;
                        }
                    }
                }
            }
            if (overlayPhoto) {
                NSString *t = nil;
                int ts = 0;
                NSString *m = nil;
                int ms = 0;
                spkScanForURLsRecursive(overlayPhoto, 4, &m, &ms, &t, &ts, @"thumbnail");
                NSString *picked = t.length ? t : m;
                if (picked.length) {
                    thumbURL = picked;
                    thumbScore = MAX(ts, ms);
                }
            }
        }

        spkScanForURLsRecursive(media, 5, &mediaURL, &mediaScore, &thumbURL, &thumbScore, @"media");
    }

    // Some XMA and outgoing layouts keep animated media outside `_media`.
    if (kind == SPKDeletedMessageKindUnknown) {
        id animated = spkFindObjectWithClassNames(content, @[ @"IGDirectInstamadilloGif", @"IGGiphyGIFModel" ], 5);
        if (animated) {
            BOOL foundSticker = NO;
            kind = spkSemanticIsSticker(animated, &foundSticker) && foundSticker
                       ? SPKDeletedMessageKindSticker
                       : SPKDeletedMessageKindGif;
            mediaURL = spkURLStringValue(spkTryObjectSelector(animated, @"gifURL"));
            if (!mediaURL.length)
                mediaURL = spkGiphyMediaURL(animated);
            if (mediaURL.length)
                mediaScore = 100;
            spkScanForURLsRecursive(animated, 4, &mediaURL, &mediaScore, &thumbURL, &thumbScore, @"animatedMedia");
        }
    }

    // Reshare branch.
    id reshare = spkAnyIvar(content, "_reshare_attachment");
    if (reshare && kind == SPKDeletedMessageKindUnknown) {
        kind = SPKDeletedMessageKindShare;
        spkScanForURLsRecursive(reshare, 5, &mediaURL, &mediaScore, &thumbURL, &thumbScore, @"reshare");
        text = spkStrIvar(content, "_reshare_comment");
        if (!text.length)
            text = spkExtractShareTitle(reshare);
        if (!text.length)
            text = spkTryStringSelectors(reshare,
                                         @[ @"caption", @"captionText", @"title", @"headline", @"summary",
                                            @"name", @"username", @"text" ]);
        if (!mediaURL.length) {
            NSString *u = spkTryURLSelectors(reshare,
                                             @[ @"webURL", @"shareURL", @"deepLink", @"url", @"mediaURL", @"playableURL" ]);
            if (u.length)
                mediaURL = u;
        }
        shareAuthor = spkTryStringSelectors(reshare, @[ @"username", @"ownerUsername", @"name" ]);
    }

    // Link branch — IGDirectLinkContext has direct ivars.
    id link = spkAnyIvar(content, "_link_linkContext");
    if (link && kind == SPKDeletedMessageKindUnknown) {
        kind = SPKDeletedMessageKindLink;
        id u = spkAnyIvar(link, "_url");
        id imgU = spkAnyIvar(link, "_imageURL");
        if ([u isKindOfClass:[NSURL class]])
            mediaURL = [(NSURL *)u absoluteString];
        if ([imgU isKindOfClass:[NSURL class]])
            thumbURL = [(NSURL *)imgU absoluteString];
        NSString *title = spkStrIvar(link, "_title");
        NSString *summary = spkStrIvar(link, "_summary");
        NSString *comment = spkStrIvar(content, "_link_commentText");
        NSMutableArray *parts = [NSMutableArray array];
        if (comment.length)
            [parts addObject:comment];
        if (title.length)
            [parts addObject:title];
        if (summary.length)
            [parts addObject:summary];
        if (!parts.count && mediaURL.length)
            [parts addObject:mediaURL];
        if (parts.count)
            text = [parts componentsJoinedByString:@"\n"];
    }

    // XMA — Pando-backed wrapper. IGDirectXMA has zero ivars; data comes
    // via valueForKey on names mirroring IGDirectXMABuilder / IGDirectXMAShareBuilder.
    if (kind == SPKDeletedMessageKindUnknown) {
        id xmaLike = spkAnyIvar(content, "_xma")
                         ?: spkAnyIvar(content, "_bloksXMA")
                            ?
                        : spkAnyIvar(content, "_pollMessage")
                            ?
                            : spkAnyIvar(content, "_progressiveImage");
        if (xmaLike) {
            NSString *xmaContentType = nil;
            @try {
                id v = [xmaLike valueForKey:@"contentType"];
                if ([v isKindOfClass:[NSString class]])
                    xmaContentType = [(NSString *)v lowercaseString];
            } @catch (__unused id e) {
            }

            // Audio share heuristic — generic_xma with playableAudioURL or /reels_audio_page targetURL.
            BOOL isAudio = NO;
            @try {
                id items = [xmaLike valueForKey:@"xmaItems"];
                id first = ([items isKindOfClass:[NSArray class]] && [items count] > 0) ? [items firstObject] : nil;
                if (first) {
                    id pa = [first valueForKey:@"playableAudioURL"];
                    if ([pa isKindOfClass:[NSURL class]] && [(NSURL *)pa absoluteString].length)
                        isAudio = YES;
                    if (!isAudio) {
                        id tgt = [first valueForKey:@"targetURL"];
                        NSString *tgtStr = [tgt isKindOfClass:[NSURL class]] ? [(NSURL *)tgt absoluteString]
                                                                             : ([tgt isKindOfClass:[NSString class]] ? tgt : nil);
                        if ([tgtStr.lowercaseString containsString:@"reels_audio_page"] || [tgtStr.lowercaseString containsString:@"audio_page"])
                            isAudio = YES;
                    }
                }
            } @catch (__unused id e) {
            }

            if (isAudio)
                kind = SPKDeletedMessageKindAudioShare;
            else if ([xmaContentType isEqualToString:@"xma_link"])
                kind = SPKDeletedMessageKindLink;
            else
                kind = SPKDeletedMessageKindShare;

            // Real share payload sits on xmaItems[0] (IGDirectXMAShare).
            NSMutableArray *probeTargets = [NSMutableArray arrayWithObject:xmaLike];
            @try {
                id items = [xmaLike valueForKey:@"xmaItems"];
                if ([items isKindOfClass:[NSArray class]]) {
                    for (id it in (NSArray *)items)
                        if (it)
                            [probeTargets addObject:it];
                }
            } @catch (__unused id e) {
            }
            @
            try {
                id meta = [xmaLike valueForKey:@"metadata"];
                if (meta && meta != [NSNull null])
                    [probeTargets addObject:meta];
            } @catch (__unused id e) {
            }

            NSString * (^pickStr)(id, NSArray<NSString *> *) = ^NSString *(id obj, NSArray<NSString *> *keys) {
                for (NSString *k in keys) {
                    @try {
                        id v = [obj valueForKey:k];
                        if (!v || v == [NSNull null])
                            continue;
                        if ([v isKindOfClass:[NSAttributedString class]])
                            v = [(NSAttributedString *)v string];
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && !spkIsDescriptionFallback(v))
                            return v;
                    } @catch (__unused id e) {
                    }
                }
                return nil;
            };
            NSString * (^pickURL)(id, NSArray<NSString *> *) = ^NSString *(id obj, NSArray<NSString *> *keys) {
                for (NSString *k in keys) {
                    @try {
                        id v = [obj valueForKey:k];
                        if (!v || v == [NSNull null])
                            continue;
                        if ([v isKindOfClass:[NSURL class]]) {
                            NSString *s = [(NSURL *)v absoluteString];
                            if (s.length)
                                return s;
                        }
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                            return v;
                    } @catch (__unused id e) {
                    }
                }
                return nil;
            };

            // IGDirectXMAShareBuilder mirror keys. Author (the shared content's
            // owner) and caption are pulled separately so the card can show
            // "@author" as the title and the caption underneath.
            NSArray<NSString *> *authorKeys = @[
                @"headerTitleText", @"quotedAttributionText", @"groupName",
                @"overlayTitle", @"titleText"
            ];
            NSArray<NSString *> *captionKeys = @[
                @"captionBodyText", @"subtitleText", @"headerSubtitleText",
                @"footerBodyText", @"overlayDescription", @"overlayText",
                @"quotedCaptionBodyText", @"quotedTitleText", @"targetURLTitle",
                @"caption", @"text", @"summary", @"description", @"title"
            ];
            // Audio: prefer .mp4 (download/play); others: targetURL (in-app open).
            NSArray<NSString *> *mediaKeys = (kind == SPKDeletedMessageKindAudioShare)
                                                 ? @[ @"playableAudioURL", @"playableURL", @"accessoryPlayableURL",
                                                      @"fullSizeURL", @"targetURL",
                                                      @"webURL", @"shareURL", @"deepLink", @"url", @"mediaURL" ]
                                                 : @[ @"targetURL",
                                                      @"playableURL", @"playableAudioURL",
                                                      @"accessoryPlayableURL", @"fullSizeURL",
                                                      @"webURL", @"shareURL", @"deepLink", @"url", @"mediaURL" ];
            NSArray<NSString *> *thumbKeys = @[
                @"previewURL", @"accessoryPreviewURL", @"previewMaskURL",
                @"previewIgImageURL",
                @"thumbnailURL", @"posterURL", @"imageURL"
            ];

            for (id obj in probeTargets) {
                NSString *a = pickStr(obj, authorKeys);
                if (a.length) {
                    shareAuthor = a;
                    break;
                }
            }
            NSMutableArray *captionParts = [NSMutableArray array];
            for (id obj in probeTargets) {
                NSString *t = pickStr(obj, captionKeys);
                if (t.length && ![t isEqualToString:shareAuthor] && ![captionParts containsObject:t]) {
                    [captionParts addObject:t];
                }
                if (captionParts.count >= 2)
                    break;
            }
            if (!text.length && captionParts.count)
                text = [captionParts componentsJoinedByString:@"\n"];
            // No caption found — fall back to the author so the row isn't blank
            // and stays searchable.
            if (!text.length && shareAuthor.length)
                text = shareAuthor;

            for (id obj in probeTargets) {
                if (!mediaURL.length) {
                    NSString *u = pickURL(obj, mediaKeys);
                    if (u.length) {
                        mediaURL = u;
                        mediaScore = 70;
                    }
                }
                if (!thumbURL.length) {
                    NSString *u = pickURL(obj, thumbKeys);
                    if (u.length) {
                        thumbURL = u;
                        thumbScore = 70;
                    }
                }
                if (mediaURL.length && thumbURL.length)
                    break;
            }

            spkScanForURLsRecursive(xmaLike, 5, &mediaURL, &mediaScore, &thumbURL, &thumbScore, @"xma");

            // Recover a post cover the scorer may have missed: if we still have no
            // thumbnail, hunt for the first image-looking URL anywhere in the XMA.
            if (!thumbURL.length) {
                NSMutableSet *seen = [NSMutableSet set];
                NSString *img = nil;
                spkCollectImageURL(xmaLike, 5, seen, &img);
                if (img.length) {
                    thumbURL = img;
                    thumbScore = 50;
                }
            }

            // Unwrap IG/FB outbound redirector — `l.instagram.com/?u=<real>`.
            if (kind == SPKDeletedMessageKindLink && mediaURL.length) {
                NSURL *u = [NSURL URLWithString:mediaURL];
                NSString *host = u.host.lowercaseString;
                if ([host isEqualToString:@"l.instagram.com"] || [host isEqualToString:@"l.facebook.com"] || [host isEqualToString:@"lm.facebook.com"]) {
                    NSURLComponents *comps = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
                    for (NSURLQueryItem *q in comps.queryItems) {
                        if ([q.name isEqualToString:@"u"] && q.value.length) {
                            mediaURL = q.value;
                            break;
                        }
                    }
                }
            }

            if (kind == SPKDeletedMessageKindShare) {
                shareSubtype = spkShareSubtypeFromTarget(mediaURL, xmaContentType);
            }
        }
    }

    if (kind == SPKDeletedMessageKindUnknown && text.length)
        kind = SPKDeletedMessageKindText;

    // Reshare and other non-XMA share paths don't carry a content type, but the
    // target URL alone is usually enough to classify the subtype.
    if (kind == SPKDeletedMessageKindShare && !shareSubtype.length) {
        shareSubtype = spkShareSubtypeFromTarget(mediaURL, nil);
    }

    snap[@"kind"] = @(kind);
    if (text.length)
        snap[@"text"] = text;
    if (mediaURL.length)
        snap[@"media_url"] = mediaURL;
    if (thumbURL.length)
        snap[@"thumb_url"] = thumbURL;
    if (shareSubtype.length)
        snap[@"share_subtype"] = shareSubtype;
    if (shareAuthor.length)
        snap[@"share_author"] = shareAuthor;
    return snap;
}

// Off the main thread there is no safe way to read the open chat, so the
// snapshot is built without it.
static NSDictionary *spkBuildSnapshot(id message, NSString *ownerHint) {
    SPKDirectThreadContext *threadContext = NSThread.isMainThread ? SPKDirectActiveThreadContext() : nil;
    return spkBuildSnapshotWithContext(message, ownerHint, threadContext);
}

#pragma mark - Media download

// Pre-downloads for messages that haven't been unsent yet. A backlog can
// deliver many of them at once, so only a few run at a time and the rest wait
// their turn. Downloads for a real unsend don't go through this.
static const long kSPKStagedDownloadSlots = 2;
static const NSTimeInterval kSPKStagedDownloadSlotTimeout = 180;

static void spkRunStagedDownload(void (^start)(dispatch_block_t done)) {
    static dispatch_queue_t gate;
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gate = dispatch_queue_create("com.sparkle.deletedmessages.staged-gate",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        slots = dispatch_semaphore_create(kSPKStagedDownloadSlots);
    });
    dispatch_async(gate, ^{
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        NSObject *lock = [NSObject new];
        __block BOOL released = NO;
        dispatch_block_t done = ^{
            @synchronized(lock) {
                if (released)
                    return;
                released = YES;
            }
            dispatch_semaphore_signal(slots);
        };
        // A download that never reports back must not hold its slot forever.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKStagedDownloadSlotTimeout * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), done);
        dispatch_async(spkDownloadQueue(), ^{
            start(done);
        });
    });
}

// Tiny helper: download a URL into a temp file synchronously on the
// download queue. Used during video+audio mux. Completion is dispatched on
// the same queue that called us so we can chain steps.
static void spkDownloadToTempFile(NSURL *url, void (^done)(NSURL *file, NSError *err)) {
    if (!url) {
        done(nil, [NSError errorWithDomain:@"SPKDM" code:0 userInfo:nil]);
        return;
    }
    [[spkSharedSession() dataTaskWithURL:url
                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                           if (err || !data.length) {
                               done(nil, err);
                               return;
                           }
                           NSString *ext = url.pathExtension.length ? url.pathExtension : @"bin";
                           NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                                       [NSString stringWithFormat:@"spk_dm_%@.%@", [NSUUID UUID].UUIDString, ext]];
                           if (![data writeToFile:tmp atomically:YES]) {
                               done(nil, [NSError errorWithDomain:@"SPKDM" code:1 userInfo:nil]);
                               return;
                           }
                           done([NSURL fileURLWithPath:tmp], nil);
                       }] resume];
}

static BOOL spkAttachStagedPathToFinalizedMessage(NSString *relativePath,
                                                  NSString *messageId,
                                                  NSString *ownerPk,
                                                  BOOL isThumbnail,
                                                  NSString *mimeType) {
    if (!relativePath.length || !messageId.length || !ownerPk.length)
        return NO;
    for (SPKDeletedMessage *m in [SPKDeletedMessagesStorage allMessagesForOwnerPK:ownerPk]) {
        if (![m.messageId isEqualToString:messageId])
            continue;
        NSString *promoted = [SPKDeletedMessagesStorage promoteStagedRelativePath:relativePath
                                                                        messageId:messageId
                                                                          ownerPK:ownerPk
                                                                        thumbnail:isThumbnail];
        if (!promoted.length)
            return NO;
        if (isThumbnail)
            m.thumbnailPath = promoted;
        else {
            m.mediaPath = promoted;
            if (mimeType.length)
                m.mediaMimeType = mimeType;
        }
        return [SPKDeletedMessagesStorage saveMessage:m forOwnerPK:ownerPk];
    }
    return NO;
}

static BOOL spkPersistStagedPath(NSString *relativePath,
                                 NSString *messageId,
                                 NSString *ownerPk,
                                 BOOL isThumbnail,
                                 NSString *mimeType) {
    NSString *key = isThumbnail ? @"staged_thumbnail_path" : @"staged_media_path";
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObject:relativePath forKey:key];
    if (!isThumbnail && mimeType.length)
        values[@"media_mime"] = mimeType;
    BOOL patched = [SPKDeletedMessagesStorage patchPendingCandidateForMessageId:messageId
                                                                         values:values
                                                                        ownerPK:ownerPk];
    BOOL attached = spkAttachStagedPathToFinalizedMessage(relativePath, messageId, ownerPk, isThumbnail, mimeType);
    return patched || attached;
}

// DASH video reps are silent — download video + audio reps and mux to mp4.
static void spkDownloadAndMuxVideo(NSString *videoURL, NSString *audioURL,
                                   NSString *messageId, NSString *ownerPk,
                                   BOOL staged) {
    if (!videoURL.length || !messageId.length)
        return;
    if (!audioURL.length || ![SPKMediaFFmpeg isAvailable])
        return;
    NSURL *vURL = [NSURL URLWithString:videoURL];
    NSURL *aURL = [NSURL URLWithString:audioURL];
    if (!vURL || !aURL)
        return;
    NSString *fname = staged
                          ? [SPKDeletedMessagesStorage reserveRelativeStagedMediaPathForMessageId:messageId extension:@"mp4" ownerPK:ownerPk thumbnail:NO]
                          : [SPKDeletedMessagesStorage reserveRelativeMediaPathForMessageId:messageId extension:@"mp4" ownerPK:ownerPk];
    NSString *abs = staged
                        ? [SPKDeletedMessagesStorage absoluteStagedPathForRelativePath:fname ownerPK:ownerPk]
                        : [SPKDeletedMessagesStorage absolutePathForRelativePath:fname ownerPK:ownerPk];
    if (!abs.length)
        return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:abs]) {
        if (!staged || spkPersistStagedPath(fname, messageId, ownerPk, NO, @"video/mp4"))
            return;
        [[NSFileManager defaultManager] removeItemAtPath:abs error:nil];
    }

    void (^start)(dispatch_block_t) = ^(dispatch_block_t done) {
        __block NSURL *vFile = nil, *aFile = nil;
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        spkDownloadToTempFile(vURL, ^(NSURL *f, NSError *e) {
            if (!e)
                vFile = f;
            dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        spkDownloadToTempFile(aURL, ^(NSURL *f, NSError *e) {
            if (!e)
                aFile = f;
            dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        if (!vFile || !aFile) {
            if (vFile)
                [[NSFileManager defaultManager] removeItemAtURL:vFile error:nil];
            if (aFile)
                [[NSFileManager defaultManager] removeItemAtURL:aFile error:nil];
            if (done)
                done();
            return;
        }
        [SPKMediaFFmpeg mergeVideoFileURL:vFile
                             audioFileURL:aFile
                        preferredBasename:messageId
                        estimatedDuration:0
                                    width:0
                                   height:0
                            sourceBitrate:0
                                 progress:nil
                               completion:^(NSURL *outURL, NSError *err) {
                                   if (done)
                                       done();
                                   [[NSFileManager defaultManager] removeItemAtURL:vFile error:nil];
                                   [[NSFileManager defaultManager] removeItemAtURL:aFile error:nil];
                                   if (err || !outURL)
                                       return;
                                   NSFileManager *fm = [NSFileManager defaultManager];
                                   if ([fm fileExistsAtPath:abs]) {
                                       [fm removeItemAtURL:outURL error:nil];
                                   } else if (![fm moveItemAtURL:outURL toURL:[NSURL fileURLWithPath:abs] error:nil]) {
                                       return;
                                   }
                                   if (staged) {
                                       if (!spkPersistStagedPath(fname, messageId, ownerPk, NO, @"video/mp4")) {
                                           [fm removeItemAtPath:abs error:nil];
                                       }
                                       return;
                                   }
                                   for (SPKDeletedMessage *m in [SPKDeletedMessagesStorage allMessagesForOwnerPK:ownerPk]) {
                                       if (![m.messageId isEqualToString:messageId])
                                           continue;
                                       m.mediaPath = fname;
                                       [SPKDeletedMessagesStorage saveMessage:m forOwnerPK:ownerPk];
                                       break;
                                   }
                               }
                                cancelOut:nil];
    };
    if (staged) {
        spkRunStagedDownload(start);
    } else {
        dispatch_async(spkDownloadQueue(), ^{
            start(nil);
        });
    }
}

static void spkDownloadMedia(NSString *urlString, NSString *messageId,
                             NSString *ownerPk, BOOL isThumbnail,
                             SPKDeletedMessageKind kind, BOOL staged) {
    if (!urlString.length || !messageId.length)
        return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return;

    NSString *ext = url.pathExtension.length
                        ? url.pathExtension
                        : ((isThumbnail || kind == SPKDeletedMessageKindPhoto) ? @"jpg" : @"bin");
    // Voice notes are served with a video container extension (.mp4) even though
    // they are audio-only. Force an audio extension so the file is typed as audio
    // everywhere downstream (preview player, share, save).
    if (!isThumbnail && kind == SPKDeletedMessageKindVoice) {
        ext = @"m4a";
    }
    NSString *fname = staged
                          ? [SPKDeletedMessagesStorage reserveRelativeStagedMediaPathForMessageId:messageId extension:ext ownerPK:ownerPk thumbnail:isThumbnail]
                          : (isThumbnail
                                 ? [NSString stringWithFormat:@"thumb_%@.%@", messageId, ext]
                                 : [SPKDeletedMessagesStorage reserveRelativeMediaPathForMessageId:messageId extension:ext ownerPK:ownerPk]);
    NSString *abs = staged
                        ? [SPKDeletedMessagesStorage absoluteStagedPathForRelativePath:fname ownerPK:ownerPk]
                        : [SPKDeletedMessagesStorage absolutePathForRelativePath:fname ownerPK:ownerPk];
    if (!abs.length)
        return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:abs]) {
        if (!staged || spkPersistStagedPath(fname, messageId, ownerPk, isThumbnail, nil))
            return;
        [[NSFileManager defaultManager] removeItemAtPath:abs error:nil];
    }

    void (^handle)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length)
            return;
        NSString *detectedExt = SPKFileExtensionForMediaResponse(data, resp, url);
        if (!detectedExt.length)
            detectedExt = ext;
        if (!isThumbnail && kind == SPKDeletedMessageKindVoice)
            detectedExt = @"m4a";
        NSString *writeName = fname;
        NSString *writePath = abs;
        if (![detectedExt.lowercaseString isEqualToString:ext.lowercaseString]) {
            writeName = staged
                            ? [SPKDeletedMessagesStorage reserveRelativeStagedMediaPathForMessageId:messageId extension:detectedExt ownerPK:ownerPk thumbnail:isThumbnail]
                            : (isThumbnail
                                   ? [NSString stringWithFormat:@"thumb_%@.%@", messageId, detectedExt]
                                   : [SPKDeletedMessagesStorage reserveRelativeMediaPathForMessageId:messageId extension:detectedExt ownerPK:ownerPk]);
            writePath = staged
                            ? [SPKDeletedMessagesStorage absoluteStagedPathForRelativePath:writeName ownerPK:ownerPk]
                            : [SPKDeletedMessagesStorage absolutePathForRelativePath:writeName ownerPK:ownerPk];
        }
        if (![data writeToFile:writePath atomically:YES])
            return;
        NSString *mimeType = SPKMIMETypeForImageFormat(SPKImageFormatForData(data)) ?: resp.MIMEType;
        if (staged) {
            if (!spkPersistStagedPath(writeName, messageId, ownerPk, isThumbnail, mimeType)) {
                [[NSFileManager defaultManager] removeItemAtPath:writePath error:nil];
            }
            return;
        }
        for (SPKDeletedMessage *m in [SPKDeletedMessagesStorage allMessagesForOwnerPK:ownerPk]) {
            if (![m.messageId isEqualToString:messageId])
                continue;
            if (isThumbnail)
                m.thumbnailPath = writeName;
            else {
                m.mediaPath = writeName;
                m.mediaMimeType = mimeType;
            }
            [SPKDeletedMessagesStorage saveMessage:m forOwnerPK:ownerPk];
            break;
        }
    };
    void (^start)(dispatch_block_t) = ^(dispatch_block_t done) {
        NSURLSessionDataTask *task = [spkSharedSession() dataTaskWithURL:url
                                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                                                           handle(data, resp, err);
                                                           if (done)
                                                               done();
                                                       }];
        [task resume];
    };
    if (staged) {
        spkRunStagedDownload(start);
    } else {
        dispatch_async(spkDownloadQueue(), ^{
            start(nil);
        });
    }
}

static BOOL spkURLIsGiphy(NSString *urlString) {
    NSString *host = urlString.length ? [NSURL URLWithString:urlString].host.lowercaseString : nil;
    return [host isEqualToString:@"giphy.com"] || [host hasSuffix:@".giphy.com"];
}

static void spkStageRecoverySnapshot(NSDictionary *snapshot, NSString *ownerPk) {
    NSString *messageId = snapshot[@"sid"];
    if (!messageId.length || !ownerPk.length)
        return;
    SPKDeletedMessageKind kind = (SPKDeletedMessageKind)[snapshot[@"kind"] integerValue];
    BOOL disappearing = [snapshot[@"view_mode"] isKindOfClass:[NSNumber class]];
    if (!disappearing && kind != SPKDeletedMessageKindGif && kind != SPKDeletedMessageKindSticker)
        return;
    NSString *mediaURL = snapshot[@"media_url"];
    NSString *audioURL = snapshot[@"audio_url"];
    // Giphy links are permanent, so a GIF or sticker served from Giphy can be
    // downloaded when it is actually unsent.
    if (!disappearing && spkURLIsGiphy(mediaURL))
        return;
    if (kind == SPKDeletedMessageKindVideo && mediaURL.length && audioURL.length) {
        spkDownloadAndMuxVideo(mediaURL, audioURL, messageId, ownerPk, YES);
    } else if (mediaURL.length) {
        spkDownloadMedia(mediaURL, messageId, ownerPk, NO, kind, YES);
    }
    NSString *thumbnailURL = snapshot[@"thumb_url"];
    if (thumbnailURL.length)
        spkDownloadMedia(thumbnailURL, messageId, ownerPk, YES, kind, YES);
}

#pragma mark - Per-thread fallback (covers foreground threads in IG's _cache)

static id spkDirectCacheFromApplicator(id applicator) {
    if (!applicator)
        return nil;
    @try {
        Ivar iv = class_getInstanceVariable([applicator class], "_cache");
        return iv ? object_getIvar(applicator, iv) : nil;
    } @catch (__unused id e) {
        return nil;
    }
}

// `applicator._cache.threadClientStateForThreadId:tid` returns an
// IGDirectThreadClientState whose `_messagesByServerId` ivar is a dict
// keyed by sid → IGDirectMessage. Direct ivar read skips method dispatch.
static id spkFallbackLookupMessage(id applicator, NSString *sid, NSString *threadId) {
    if (!applicator || !sid.length || !threadId.length)
        return nil;
    @try {
        id cache = spkDirectCacheFromApplicator(applicator);
        if (!cache)
            return nil;
        id state = nil;
        SEL sel = NSSelectorFromString(@"threadClientStateForThreadId:");
        if ([cache respondsToSelector:sel]) {
            state = ((id (*)(id, SEL, id))objc_msgSend)(cache, sel, threadId);
        } else {
            id states = spkAnyIvar(cache, "_threadClientStateByThreadIds");
            if ([states isKindOfClass:[NSDictionary class]])
                state = states[threadId];
        }
        if (!state)
            return nil;
        for (Class c = [state class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            Ivar di = class_getInstanceVariable(c, "_messagesByServerId");
            if (!di)
                continue;
            id dict = object_getIvar(state, di);
            if ([dict isKindOfClass:[NSDictionary class]])
                return ((NSDictionary *)dict)[sid];
            break;
        }
    } @catch (__unused id e) {
    }
    return nil;
}

static id spkFindMessageInFetchedThread(id value, NSString *sid, NSInteger depth, NSMutableSet *visited) {
    if (!value || !sid.length || depth < 0)
        return nil;
    NSValue *identity = [NSValue valueWithNonretainedObject:value];
    if ([visited containsObject:identity])
        return nil;
    [visited addObject:identity];
    if ([spkSidFromMessage(value) isEqualToString:sid])
        return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        id direct = value[sid];
        if (direct)
            return direct;
        for (id child in [value allValues]) {
            id found = spkFindMessageInFetchedThread(child, sid, depth - 1, visited);
            if (found)
                return found;
        }
        return nil;
    }
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) {
        for (id child in value) {
            id found = spkFindMessageInFetchedThread(child, sid, depth - 1, visited);
            if (found)
                return found;
        }
        return nil;
    }
    for (NSString *name in @[ @"_messagesByServerId", @"_messages", @"_publishedMessages", @"_messageList" ]) {
        id child = spkAnyIvar(value, name.UTF8String);
        id found = spkFindMessageInFetchedThread(child, sid, depth - 1, visited);
        if (found)
            return found;
    }
    return nil;
}

#pragma mark - Public hooks

// Pre-capturing a message means building a snapshot (deep ivar and URL walks)
// and staging media. Instagram applies a sync backlog message by message on the
// main thread, so that work is queued here and done on spkCaptureQueue instead.
// Unsends are finalized on the same serial queue, and a message's insert is
// always queued before its unsend, so the candidate is saved before the unsend
// looks for it. Until then the weak ref below still resolves the live message.

static NSMutableArray<NSArray *> *spkInsertJobs;
static BOOL spkInsertDrainScheduled;

static NSObject *spkInsertJobsLock(void) {
    static NSObject *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        o = [NSObject new];
    });
    return o;
}

static void spkSaveCandidateForMessage(id message, NSString *ownerPk, NSString *threadId, SPKDirectThreadContext *threadContext) {
    @try {
        NSMutableDictionary *snapshot = [spkBuildSnapshotWithContext(message, ownerPk, threadContext) mutableCopy];
        if (!snapshot[@"thread_id"] && threadId.length)
            snapshot[@"thread_id"] = threadId;
        if (snapshot.count) {
            [SPKDeletedMessagesStorage savePendingCandidateSnapshot:spkJSONSafeSnapshot(snapshot) forOwnerPK:ownerPk];
            spkStageRecoverySnapshot(snapshot, ownerPk);
        }
    } @catch (__unused id e) {
    }
}

static void spkDrainInsertJobs(void) {
    for (;;) {
        NSArray<NSArray *> *batch = nil;
        @synchronized(spkInsertJobsLock()) {
            if (!spkInsertJobs.count) {
                spkInsertDrainScheduled = NO;
                return;
            }
            batch = spkInsertJobs;
            spkInsertJobs = [NSMutableArray array];
        }
        for (NSArray *job in batch) {
            @autoreleasepool {
                id threadId = job[2], context = job[3];
                spkSaveCandidateForMessage(job[0], job[1], threadId == NSNull.null ? nil : threadId,
                                           context == NSNull.null ? nil : context);
            }
        }
    }
}

// Leaving the foreground is the last point the app reliably runs. Queued
// captures are finished and written out under a background task, so messages
// that arrived just before the app was closed keep their candidates.
static void spkObserveBackgroundForInsertJobsOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
                                                        UIApplication *app = UIApplication.sharedApplication;
                                                        __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
                                                        void (^finish)(void) = ^{
                                                            if (task == UIBackgroundTaskInvalid)
                                                                return;
                                                            [app endBackgroundTask:task];
                                                            task = UIBackgroundTaskInvalid;
                                                        };
                                                        task = [app beginBackgroundTaskWithName:@"com.sparkle.deletedmessages.capture"
                                                                              expirationHandler:finish];
                                                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                                            dispatch_sync(spkCaptureQueue(), ^{
                                                                spkDrainInsertJobs();
                                                            });
                                                            [SPKDeletedMessagesStorage flushPendingStores];
                                                            dispatch_async(dispatch_get_main_queue(), finish);
                                                        });
                                                    }];
    });
}

static void spkEnqueueCandidateCapture(id message, NSString *ownerPk, NSString *threadId) {
    spkObserveBackgroundForInsertJobsOnce();
    NSArray *job = @[ message, [ownerPk copy], threadId.length ? [threadId copy] : NSNull.null,
                      SPKDirectActiveThreadContext() ?: NSNull.null ];
    BOOL schedule = NO;
    @synchronized(spkInsertJobsLock()) {
        if (!spkInsertJobs)
            spkInsertJobs = [NSMutableArray array];
        [spkInsertJobs addObject:job];
        if (!spkInsertDrainScheduled) {
            spkInsertDrainScheduled = YES;
            schedule = YES;
        }
    }
    if (!schedule)
        return;
    // Utility QoS keeps a backlog from competing with Instagram's UI for CPU.
    // An unsend queued behind it raises the queue's priority while it waits.
    dispatch_block_t drain = dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_UTILITY, 0, ^{
        spkDrainInsertJobs();
    });
    dispatch_async(spkCaptureQueue(), drain);
}

// Disappearing and view-once media, and stickers, whose links can expire before
// an unsend. Mirrors what spkStageRecoverySnapshot stages, using only direct
// ivar reads so it stays cheap on the main thread.
static BOOL spkMessageHasExpiringMedia(id message) {
    @try {
        id content = spkAnyIvar(message, "_content") ?: spkAnyIvar(message, "_messageContent") ?: spkAnyIvar(message, "_payload");
        if (!content) {
            @try {
                content = [message valueForKey:@"content"];
            } @catch (__unused id e) {
            }
        }
        id media = spkAnyIvar(content, "_media");
        if (!media)
            return NO;
        return spkAnyIvar(media, "_visualMedia") || spkAnyIvar(media, "_sticker") || spkTryObjectSelector(media, @"sticker");
    } @catch (__unused id e) {
        // Unknown shape: capture it rather than risk losing it.
        return YES;
    }
}

void spkDMCaptureNoteInsert(id message, NSString *ownerPk, NSString *threadId, SPKDMCandidateMode candidateMode) {
    if (!message)
        return;
    @autoreleasepool {
        @try {
            NSString *sid = spkSidFromMessage(message);
            if (!sid.length)
                return;
            @synchronized(spkMessageRefsLock()) {
                [spkMessageRefs() setObject:message forKey:sid];
            }
            BOOL capture = candidateMode == SPKDMCandidateModeAll
                           || (candidateMode == SPKDMCandidateModeExpiringMediaOnly && spkMessageHasExpiringMedia(message));
            if (capture && ownerPk.length)
                spkEnqueueCandidateCapture(message, ownerPk, threadId);
        } @catch (__unused id e) {
        }
    }
}

static NSString *spkExtractKeySid(id key) {
    if (!key)
        return nil;
    @try {
        for (Class c = [key class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            Ivar iv = class_getInstanceVariable(c, "_serverId");
            if (!iv)
                iv = class_getInstanceVariable(c, "_messageServerId");
            if (!iv)
                continue;
            id v = object_getIvar(key, iv);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                return v;
            break;
        }
    } @catch (__unused id e) {
    }
    return nil;
}

static NSString *spkExtractKeyMutationId(id key) {
    if (!key)
        return nil;
    for (NSString *name in @[ @"_mutationId", @"_mutationID", @"_clientMutationId" ]) {
        NSString *value = spkStrIvar(key, name.UTF8String);
        if (value.length)
            return value;
    }
    return nil;
}

static NSArray<NSDictionary *> *spkPreviewMetadataForKeys(NSArray *keys,
                                                          NSDictionary<NSString *, id> *strongRefs,
                                                          NSString *owner,
                                                          NSString *thread,
                                                          SPKDirectThreadContext *threadContext);

static NSMutableDictionary<NSString *, id> *spkStrongRefsForKeys(NSArray *keys, id applicator, NSString *thread) {
    NSMutableDictionary<NSString *, id> *strongRefs = [NSMutableDictionary dictionary];

    @synchronized(spkMessageRefsLock()) {
        NSMapTable *t = spkMessageRefs();
        for (id key in keys) {
            NSString *sid = spkExtractKeySid(key);
            if (!sid.length)
                continue;
            id m = [t objectForKey:sid];
            if (m)
                strongRefs[sid] = m;
        }
    }

    for (id key in keys) {
        NSString *sid = spkExtractKeySid(key);
        if (!sid.length || strongRefs[sid])
            continue;
        id m = spkFallbackLookupMessage(applicator, sid, thread);
        if (m)
            strongRefs[sid] = m;
    }

    return strongRefs;
}

// Building a preview can mean a full snapshot (deep ivar and URL walks), which
// cost several milliseconds per unsend on the main thread.
void spkDMCaptureQueuePreviewMetadataForKeys(NSArray *keys,
                                             id applicator,
                                             NSString *ownerPk,
                                             NSString *threadId,
                                             NSMutableArray<NSDictionary *> *collector) {
    if (!keys.count || !collector)
        return;
    NSArray *keysCopy = [keys copy];
    NSString *owner = ownerPk.length ? [ownerPk copy] : @"";
    NSString *thread = threadId.length ? [threadId copy] : nil;
    NSDictionary<NSString *, id> *strongRefs = spkStrongRefsForKeys(keysCopy, applicator, thread);
    SPKDirectThreadContext *threadContext = SPKDirectActiveThreadContext();
    dispatch_async(spkCaptureQueue(), ^{
        @autoreleasepool {
            [collector addObjectsFromArray:spkPreviewMetadataForKeys(keysCopy, strongRefs, owner, thread, threadContext)];
        }
    });
}

void spkDMCaptureAfterQueuedWork(dispatch_block_t block) {
    if (block)
        dispatch_async(spkCaptureQueue(), block);
}

static NSArray<NSDictionary *> *spkPreviewMetadataForKeys(NSArray *keys,
                                                          NSDictionary<NSString *, id> *strongRefs,
                                                          NSString *owner,
                                                          NSString *thread,
                                                          SPKDirectThreadContext *threadContext) {
    NSMutableArray<NSDictionary *> *previews = [NSMutableArray arrayWithCapacity:keys.count];
    for (id key in keys) {
        NSString *sid = spkExtractKeySid(key);
        NSDictionary *snap = [SPKDeletedMessagesStorage pendingCandidateSnapshotForMessageId:sid ownerPK:owner]
                                 ?: spkBuildSnapshotWithContext(strongRefs[sid], owner, threadContext);
        if (!snap)
            continue;
        NSString *senderPk = snap[@"sender_pk"];
        if (senderPk.length && [SPKDeletedMessagesStorage isSenderBlocked:senderPk ownerPK:owner])
            continue;

        NSMutableDictionary *preview = [NSMutableDictionary dictionary];
        preview[@"messageId"] = sid;
        preview[@"threadId"] = snap[@"thread_id"] ?: thread ?
                                                            : @"";
        if (senderPk.length)
            preview[@"senderPk"] = senderPk;
        if ([snap[@"sender_username"] isKindOfClass:[NSString class]])
            preview[@"senderUsername"] = snap[@"sender_username"];
        if ([snap[@"sender_full_name"] isKindOfClass:[NSString class]])
            preview[@"senderFullName"] = snap[@"sender_full_name"];
        if ([snap[@"kind"] isKindOfClass:[NSNumber class]])
            preview[@"kind"] = snap[@"kind"];
        if ([snap[@"share_subtype"] isKindOfClass:[NSString class]])
            preview[@"shareSubtype"] = snap[@"share_subtype"];
        if ([snap[@"text"] isKindOfClass:[NSString class]]) {
            preview[@"text"] = snap[@"text"];
            preview[@"previewText"] = snap[@"text"];
        }
        [previews addObject:preview];
    }
    return previews;
}

static BOOL spkFinalizeSnapshot(NSDictionary *snap, NSString *sid, NSString *thread, NSString *owner) {
    if (!snap || !sid.length)
        return NO;
    NSString *senderPk = snap[@"sender_pk"];
    if (!senderPk.length)
        return NO;
    if (senderPk.length && [SPKDeletedMessagesStorage isSenderBlocked:senderPk ownerPK:owner]) {
        [SPKDeletedMessagesStorage removePendingCandidateForMessageId:sid ownerPK:owner];
        [SPKDeletedMessagesStorage removePendingRemovalForMessageId:sid ownerPK:owner];
        return YES;
    }

    SPKDeletedMessageKind kind = (SPKDeletedMessageKind)[snap[@"kind"] integerValue];
    NSString *txt = snap[@"text"];
    NSString *mu = snap[@"media_url"];
    NSString *tu = snap[@"thumb_url"];
    if ((kind == SPKDeletedMessageKindUnknown || kind == SPKDeletedMessageKindOther) && !txt.length && !mu.length && !tu.length)
        return NO;

    NSDate *now = [NSDate date];
    SPKDeletedMessage *m = [SPKDeletedMessage new];
    m.messageId = sid;
    m.threadId = snap[@"thread_id"] ?: thread ?
                                              : @"";
    m.threadTitle = snap[@"thread_title"];
    m.isGroup = [snap[@"is_group"] boolValue];
    m.senderPk = senderPk ?: @"";
    m.senderUsername = snap[@"sender_username"];
    m.senderFullName = snap[@"sender_full_name"];
    m.senderProfilePicURL = snap[@"sender_profile_pic_url"];
    m.sentAt = spkDateFromSnapshotValue(snap[@"sent_at"]);
    m.capturedAt = now;
    m.deletedAt = now;
    m.kind = kind;
    m.text = txt;
    m.previewText = txt;
    m.mediaURL = mu;
    m.thumbnailURL = tu;
    m.mediaMimeType = snap[@"media_mime"];
    m.durationSeconds = [snap[@"duration"] doubleValue];
    m.viewMode = [snap[@"view_mode"] isKindOfClass:[NSNumber class]] ? [snap[@"view_mode"] integerValue] : -1;
    m.mediaURLStaleAt = spkDateFromSnapshotValue(snap[@"media_url_stale_at"]);
    id wf = snap[@"waveform"];
    if ([wf isKindOfClass:[NSArray class]])
        m.waveform = wf;
    m.replyToMessageId = snap[@"reply_to_id"];
    m.shareSubtype = snap[@"share_subtype"];
    m.shareAuthor = snap[@"share_author"];

    if (![SPKDeletedMessagesStorage saveMessage:m forOwnerPK:owner])
        return NO;

    // Save the log entry before promoting media so an in-flight staged download
    // can attach itself even if it finishes while this unsend is being finalized.
    NSDictionary *latestCandidate = [SPKDeletedMessagesStorage pendingCandidateSnapshotForMessageId:sid ownerPK:owner] ?: snap;
    m.mediaMimeType = latestCandidate[@"media_mime"] ?: m.mediaMimeType;
    m.mediaPath = [SPKDeletedMessagesStorage promoteStagedRelativePath:latestCandidate[@"staged_media_path"]
                                                             messageId:sid
                                                               ownerPK:owner
                                                             thumbnail:NO];
    m.thumbnailPath = [SPKDeletedMessagesStorage promoteStagedRelativePath:latestCandidate[@"staged_thumbnail_path"]
                                                                 messageId:sid
                                                                   ownerPK:owner
                                                                 thumbnail:YES];
    if (m.mediaPath.length || m.thumbnailPath.length) {
        [SPKDeletedMessagesStorage saveMessage:m forOwnerPK:owner];
    }
    [SPKDeletedMessagesStorage removePendingCandidateForMessageId:sid ownerPK:owner];
    [SPKDeletedMessagesStorage removePendingRemovalForMessageId:sid ownerPK:owner];

    NSString *audioURL = snap[@"audio_url"];
    BOOL isDeeplinkOnly = (m.kind == SPKDeletedMessageKindShare || m.kind == SPKDeletedMessageKindLink);
    if (!m.mediaPath.length && m.kind == SPKDeletedMessageKindVideo && audioURL.length && m.mediaURL.length) {
        spkDownloadAndMuxVideo(m.mediaURL, audioURL, sid, owner, NO);
    } else if (!m.mediaPath.length && !isDeeplinkOnly && m.mediaURL.length) {
        spkDownloadMedia(m.mediaURL, sid, owner, NO, m.kind, NO);
    }
    if (!m.thumbnailPath.length && m.thumbnailURL.length)
        spkDownloadMedia(m.thumbnailURL, sid, owner, YES, m.kind, NO);
    return YES;
}

static NSMutableSet<NSString *> *spkPendingFetches(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static const NSTimeInterval kSPKPendingFetchCooldown = 60;

// Guarded by spkPendingFetches().
static NSMutableDictionary<NSString *, NSDate *> *spkLastFetchAttempts(void) {
    static NSMutableDictionary<NSString *, NSDate *> *attempts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        attempts = [NSMutableDictionary dictionary];
    });
    return attempts;
}

static void spkFetchThreadForPendingRemoval(id applicator, NSString *sid, NSString *thread, NSString *owner) {
    id cache = spkDirectCacheFromApplicator(applicator);
    if (!cache || !sid.length || !thread.length || !owner.length)
        return;
    NSString *fetchKey = [NSString stringWithFormat:@"%@:%@:%@", owner, thread, sid];
    @synchronized(spkPendingFetches()) {
        if ([spkPendingFetches() containsObject:fetchKey])
            return;
        // A removal Instagram's cache can't resolve would otherwise be fetched
        // again on every sync pass.
        NSDate *last = spkLastFetchAttempts()[fetchKey];
        if (last && -last.timeIntervalSinceNow < kSPKPendingFetchCooldown)
            return;
        if (spkLastFetchAttempts().count > 500)
            [spkLastFetchAttempts() removeAllObjects];
        spkLastFetchAttempts()[fetchKey] = [NSDate date];
        [spkPendingFetches() addObject:fetchKey];
    }

    void (^completion)(id) = ^(id fetchedThread) {
        @synchronized(spkPendingFetches()) {
            [spkPendingFetches() removeObject:fetchKey];
        }
        id message = spkFindMessageInFetchedThread(fetchedThread, sid, 4, [NSMutableSet set])
                         ?: spkFallbackLookupMessage(applicator, sid, thread);
        if (!message)
            return;
        NSDictionary *snap = spkBuildSnapshot(message, owner);
        if (!snap)
            return;
        dispatch_async(spkCaptureQueue(), ^{
            spkFinalizeSnapshot(snap, sid, thread, owner);
        });
    };

    SEL publicFetch = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
    SEL legacyFetch = NSSelectorFromString(@"_fetchThreadFromCacheWithThreadId:completion:");
    @try {
        if ([cache respondsToSelector:publicFetch]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, publicFetch, thread, completion);
        } else if ([cache respondsToSelector:legacyFetch]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, legacyFetch, thread, completion);
        } else {
            @synchronized(spkPendingFetches()) {
                [spkPendingFetches() removeObject:fetchKey];
            }
        }
    } @catch (__unused id e) {
        @synchronized(spkPendingFetches()) {
            [spkPendingFetches() removeObject:fetchKey];
        }
    }
}

void spkDMCaptureNoteRemoveKeys(NSArray *keys, id applicator,
                                NSString *ownerPk, NSString *threadId) {
    if (!spkCaptureEnabled() || !keys.count)
        return;
    NSString *owner = ownerPk.length ? [ownerPk copy] : @"";
    NSString *thread = threadId.length ? [threadId copy] : nil;

    // Resolve the real group name from IG's cache (deduped per thread).
    if (thread.length && owner.length)
        spkDMCaptureResolveThreadMeta(applicator, thread, owner);

    for (id key in keys) {
        NSString *sid = spkExtractKeySid(key);
        if (sid.length) {
            [SPKDeletedMessagesStorage savePendingRemovalForMessageId:sid
                                                             threadId:thread
                                                           mutationId:spkExtractKeyMutationId(key)
                                                              ownerPK:owner];
        }
    }
    NSMutableDictionary<NSString *, id> *strongRefs = spkStrongRefsForKeys(keys, applicator, thread);
    @synchronized(spkMessageRefsLock()) {
        NSMapTable *t = spkMessageRefs();
        for (id key in keys) {
            NSString *sid = spkExtractKeySid(key);
            if (sid.length)
                [t removeObjectForKey:sid];
        }
    }

    SPKDirectThreadContext *threadContext = SPKDirectActiveThreadContext();
    dispatch_async(spkCaptureQueue(), ^{
        for (id key in keys) {
            NSString *sid = spkExtractKeySid(key);
            NSDictionary *snap = [SPKDeletedMessagesStorage pendingCandidateSnapshotForMessageId:sid ownerPK:owner];
            if (!snap && strongRefs[sid])
                snap = spkBuildSnapshotWithContext(strongRefs[sid], owner, threadContext);
            if (snap)
                spkFinalizeSnapshot(snap, sid, thread, owner);
        }
    });
}

// Called around every sync pass, which during a backlog means hundreds of times
// in a row. A retry already queued for an owner reads the latest pending list
// when it runs, so further requests before then are dropped.
static NSMutableSet<NSString *> *spkQueuedRetryOwners(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
    });
    return set;
}

void spkDMCaptureRetryPendingRemovals(id applicator, NSString *ownerPk) {
    if (!spkCaptureEnabled() || !ownerPk.length)
        return;
    NSString *owner = [ownerPk copy];
    @synchronized(spkQueuedRetryOwners()) {
        if ([spkQueuedRetryOwners() containsObject:owner])
            return;
        [spkQueuedRetryOwners() addObject:owner];
    }
    SPKDirectThreadContext *threadContext = SPKDirectActiveThreadContext();
    dispatch_async(spkCaptureQueue(), ^{
        @synchronized(spkQueuedRetryOwners()) {
            [spkQueuedRetryOwners() removeObject:owner];
        }
        NSArray<NSDictionary *> *pending = [SPKDeletedMessagesStorage pendingRemovalsForOwnerPK:owner];
        for (NSDictionary *entry in pending) {
            @autoreleasepool {
                NSString *sid = entry[@"message_id"];
                NSString *thread = entry[@"thread_id"];
                NSDictionary *snap = [SPKDeletedMessagesStorage pendingCandidateSnapshotForMessageId:sid ownerPK:owner];
                if (!snap) {
                    id message = spkFallbackLookupMessage(applicator, sid, thread);
                    if (message)
                        snap = spkBuildSnapshotWithContext(message, owner, threadContext);
                }
                if (snap)
                    spkFinalizeSnapshot(snap, sid, thread, owner);
                else
                    spkFetchThreadForPendingRemoval(applicator, sid, thread, owner);
            }
        }
    });
}

#pragma mark - Group thread title resolution

static NSString *spkJoinThreadNames(NSArray<NSString *> *names) {
    if (!names.count)
        return nil;
    if (names.count <= 3)
        return [names componentsJoinedByString:@", "];
    NSArray *head = [names subarrayWithRange:NSMakeRange(0, 3)];
    return [NSString stringWithFormat:@"%@ +%lu", [head componentsJoinedByString:@", "], (unsigned long)(names.count - 3)];
}

static NSString *spkGroupCustomName(id metadata) {
    id groupMeta = spkTryObjectSelector(metadata, @"groupMetadata") ?: spkAnyIvar(metadata, "_groupMetadata");
    if (!groupMeta)
        return nil;
    NSString *name = spkTryStringSelectors(groupMeta, @[ @"customName" ]);
    if (!name.length)
        name = spkStrIvar(groupMeta, "_customName");
    return name.length ? name : nil;
}

// metadata.groupMetadata.groupPhotoIdentifier.groupImageSpecifier.remoteImageURL.url
// Only set for groups with an explicit custom photo.
static NSString *spkGroupPhotoURL(id metadata) {
    id groupMeta = spkTryObjectSelector(metadata, @"groupMetadata") ?: spkAnyIvar(metadata, "_groupMetadata");
    if (!groupMeta)
        return nil;
    id identifier = spkTryObjectSelector(groupMeta, @"groupPhotoIdentifier") ?: spkAnyIvar(groupMeta, "_groupPhotoIdentifier");
    if (!identifier)
        return nil;
    id specifier = spkTryObjectSelector(identifier, @"groupImageSpecifier") ?: spkAnyIvar(identifier, "_groupImageSpecifier");
    if (!specifier)
        return nil;
    id imageURL = spkTryObjectSelector(specifier, @"remoteImageURL") ?: spkAnyIvar(specifier, "_remoteImageURL");
    if (!imageURL)
        return nil;
    NSString *s = spkTryURLSelectors(imageURL, @[ @"url", @"fallbackURL" ]);
    return s.length ? s : nil;
}

static NSArray<NSString *> *spkThreadUserNames(id metadata) {
    id users = spkTryObjectSelector(metadata, @"users") ?: spkAnyIvar(metadata, "_users");
    if (![users isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id u in (NSArray *)users) {
        NSString *n = spkTryStringSelectors(u, @[ @"fullName" ]);
        if (!n.length) {
            id fc = spkAnyIvar(u, "_fieldCache");
            if ([fc isKindOfClass:[NSDictionary class]]) {
                id v = ((NSDictionary *)fc)[@"full_name"] ?: ((NSDictionary *)fc)[@"username"];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length])
                    n = v;
            }
        }
        if (!n.length)
            n = spkTryStringSelectors(u, @[ @"username" ]);
        if (n.length)
            [names addObject:n];
    }
    return names.count ? names : nil;
}

static id spkThreadMetadataFromObject(id threadObj) {
    if (!threadObj)
        return nil;
    Class metaCls = NSClassFromString(@"IGDirectThreadMetadata");
    id meta = spkTryObjectSelector(threadObj, @"threadMetadata") ?: spkAnyIvar(threadObj, "_threadMetadata");
    if (metaCls && [meta isKindOfClass:metaCls])
        return meta;
    id provider = spkTryObjectSelector(threadObj, @"threadInfoProvider") ?: spkAnyIvar(threadObj, "_threadInfoProvider");
    if (provider) {
        id pmeta = spkTryObjectSelector(provider, @"threadMetadata") ?: spkAnyIvar(provider, "_threadMetadata");
        if (metaCls && [pmeta isKindOfClass:metaCls])
            return pmeta;
        if (!meta)
            meta = pmeta;
    }
    if (metaCls) {
        id found = spkFindObjectWithClassNames(threadObj, @[ @"IGDirectThreadMetadata" ], 6);
        if (found)
            return found;
    }
    return meta;
}

// YES when metadata was read (group-ness known), even for a 1:1. *outTitle is
// set only for groups: the custom name, else IG-style joined participant names.
static BOOL spkExtractThreadMeta(id threadObj, BOOL *outIsGroup, NSString **outTitle, NSString **outPhotoURL) {
    id meta = spkThreadMetadataFromObject(threadObj);
    if (!meta)
        return NO;
    BOOL found = NO;
    BOOL isGroup = spkBoolSelector(meta, @"isGroup", &found);
    if (!found)
        isGroup = spkBoolIvar(meta, "_isGroup", &found);
    if (!found)
        return NO;
    NSString *title = nil;
    NSString *photo = nil;
    if (isGroup) {
        title = spkGroupCustomName(meta);
        if (!title.length)
            title = spkJoinThreadNames(spkThreadUserNames(meta));
        photo = spkGroupPhotoURL(meta);
    }
    if (outIsGroup)
        *outIsGroup = isGroup;
    if (outTitle)
        *outTitle = title;
    if (outPhotoURL)
        *outPhotoURL = photo;
    return YES;
}

static NSMutableSet<NSString *> *spkResolvedThreadMetaKeys(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
    });
    return set;
}

void spkDMCaptureResolveThreadMeta(id applicator, NSString *threadId, NSString *ownerPk) {
    if (!spkCaptureEnabled() || !threadId.length || !ownerPk.length)
        return;
    NSString *key = [NSString stringWithFormat:@"%@:%@", ownerPk, threadId];
    @synchronized(spkResolvedThreadMetaKeys()) {
        if ([spkResolvedThreadMetaKeys() containsObject:key])
            return;
        [spkResolvedThreadMetaKeys() addObject:key];
    }
    NSString *owner = [ownerPk copy];
    NSString *tid = [threadId copy];

    void (^clearKey)(void) = ^{
        @synchronized(spkResolvedThreadMetaKeys()) {
            [spkResolvedThreadMetaKeys() removeObject:key];
        }
    };
    // Returns YES once metadata was read (group or confirmed 1:1) so we stop
    // re-resolving; NO means try again on the next unsend in this thread.
    BOOL (^apply)(id) = ^BOOL(id threadObj) {
        BOOL isGroup = NO;
        NSString *title = nil;
        NSString *photo = nil;
        if (!spkExtractThreadMeta(threadObj, &isGroup, &title, &photo))
            return NO;
        if (isGroup)
            [SPKDeletedMessagesStorage backfillThreadTitle:title isGroup:YES photoURL:photo forThreadId:tid ownerPK:owner];
        return YES;
    };

    id cache = spkDirectCacheFromApplicator(applicator);
    if (!cache) {
        clearKey();
        return;
    }

    // Synchronous attempt via the in-memory client state.
    @try {
        SEL sel = NSSelectorFromString(@"threadClientStateForThreadId:");
        if ([cache respondsToSelector:sel]) {
            id state = ((id (*)(id, SEL, id))objc_msgSend)(cache, sel, tid);
            if (state && apply(state))
                return;
        }
    } @catch (__unused id e) {
    }

    // Async cache fetch — the thread object carries IGDirectThreadMetadata.
    SEL publicFetch = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
    @try {
        if ([cache respondsToSelector:publicFetch]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, publicFetch, tid, ^(id fetchedThread) {
                if (!apply(fetchedThread))
                    clearKey();
            });
            return;
        }
    } @catch (__unused id e) {
    }
    clearKey();
}

#pragma mark - Reaction unsend capture

static BOOL spkReactionCaptureEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_deleted_log_reactions"];
}

// Resolve the message a reaction targeted, by server id. Prefers the live weak
// ref cache (populated on insert), then falls back to the thread client state.
static id spkResolveReactionTargetMessage(NSString *messageId, id applicator, NSString *threadId) {
    if (!messageId.length)
        return nil;
    id msg = nil;
    @synchronized(spkMessageRefsLock()) {
        msg = [spkMessageRefs() objectForKey:messageId];
    }
    if (!msg)
        msg = spkFallbackLookupMessage(applicator, messageId, threadId);
    return msg;
}

// Best-effort one-line preview of the message a reaction was attached to. A
// target without text yields no preview and reports its kind through `kindOut`
// instead: naming the type here would freeze the capture-time language into the
// stored record, which is then read back long after the language may have changed.
static NSString *spkReactionTargetPreview(id targetMessage, SPKDeletedMessageKind *kindOut) {
    if (kindOut)
        *kindOut = SPKDeletedMessageKindUnknown;
    if (!targetMessage)
        return nil;
    @try {
        NSDictionary *snap = spkBuildSnapshot(targetMessage, nil);
        NSString *txt = snap[@"text"];
        if ([txt isKindOfClass:[NSString class]] && txt.length) {
            NSString *oneLine = [txt stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (oneLine.length > 80)
                oneLine = [[oneLine substringToIndex:77] stringByAppendingString:@"..."];
            return oneLine;
        }
        NSNumber *kindNum = snap[@"kind"];
        if ([kindNum isKindOfClass:[NSNumber class]]) {
            SPKDeletedMessageKind k = (SPKDeletedMessageKind)kindNum.integerValue;
            if (k != SPKDeletedMessageKindUnknown && k != SPKDeletedMessageKindText) {
                if (kindOut)
                    *kindOut = k;
            }
        }
    } @catch (__unused id e) {
    }
    return nil;
}

NSDictionary *spkDMCaptureNoteReactionUnsend(id reaction,
                                             NSString *reactorPk,
                                             id targetMessage,
                                             NSString *targetMessageId,
                                             id applicator,
                                             NSString *ownerPk,
                                             NSString *threadId) {
    if (!spkReactionCaptureEnabled() || !reaction)
        return nil;

    NSString *owner = ownerPk.length ? [ownerPk copy] : @"";

    // Emoji + reactor + timestamp from IGDirectMessageReaction.
    NSString *emoji = spkStrIvar(reaction, "_userBasedReaction_emojiUnicode");
    NSString *pk = reactorPk.length ? reactorPk : spkStrIvar(reaction, "_userBasedReaction_userId");
    if (!pk.length)
        return nil;

    NSDate *reactedAt = nil;
    id ts = spkAnyIvar(reaction, "_userBasedReaction_serverTimestamp");
    if ([ts isKindOfClass:[NSDate class]])
        reactedAt = ts;

    // The "message id" of a reaction record is synthetic but stable so repeated
    // deltas dedupe: target message id + reactor + emoji.
    NSString *recordId = [NSString stringWithFormat:@"reaction:%@:%@:%@",
                                                    targetMessageId.length ? targetMessageId : @"?",
                                                    pk,
                                                    emoji.length ? emoji : @"?"];

    if (!targetMessage && targetMessageId.length) {
        targetMessage = spkResolveReactionTargetMessage(targetMessageId, applicator, threadId);
    }
    SPKDeletedMessageKind targetKind = SPKDeletedMessageKindUnknown;
    NSString *targetPreview = spkReactionTargetPreview(targetMessage, &targetKind);

    NSString *u = nil, *fn = nil, *pic = nil;
    spkResolveSenderInfo(pk, &u, &fn, &pic);

    BOOL threadIsGroup = NO;
    NSString *threadTitle = nil;
    if (threadId.length) {
        SPKDirectThreadContext *ctx = SPKDirectActiveThreadContext();
        if (ctx && [ctx.threadId isEqualToString:threadId]) {
            threadIsGroup = ctx.isGroup;
            threadTitle = ctx.threadName.length ? ctx.threadName : nil;
        }
    }

    NSDate *now = [NSDate date];
    dispatch_async(spkCaptureQueue(), ^{
        if (pk.length && [SPKDeletedMessagesStorage isSenderBlocked:pk ownerPK:owner])
            return;

        SPKDeletedMessage *m = [SPKDeletedMessage new];
        m.messageId = recordId;
        m.threadId = threadId ?: @"";
        m.threadTitle = threadTitle;
        m.isGroup = threadIsGroup;
        m.senderPk = pk;
        m.senderUsername = u;
        m.senderFullName = fn;
        m.senderProfilePicURL = pic;
        m.sentAt = reactedAt ?: now;
        m.capturedAt = now;
        m.deletedAt = now;
        m.kind = SPKDeletedMessageKindReaction;
        m.reactionEmoji = emoji;
        m.reactionTargetPreview = targetPreview;
        m.reactionTargetKind = targetKind;
        // Stored body for exports and copied text. Kept English on purpose: the
        // record outlives the language it was captured in, so the on-screen
        // sentence is rebuilt from the fields above by SPKDeletedMessageDisplayBody.
        NSString *storedTarget = targetPreview.length ? targetPreview
                                                      : (targetKind != SPKDeletedMessageKindUnknown
                                                             ? SPKDeletedMessageKindToString(targetKind)
                                                             : nil);
        if (emoji.length && storedTarget.length) {
            m.text = [NSString stringWithFormat:@"Removed %@ from \"%@\"", emoji, storedTarget];
        } else if (emoji.length) {
            m.text = [NSString stringWithFormat:@"Removed %@ reaction", emoji];
        } else {
            m.text = @"Removed a reaction"; // SPK_I18N_IGNORE: stable persisted fallback; localized at display time
        }
        m.previewText = m.text;
        m.replyToMessageId = targetMessageId;

        [SPKDeletedMessagesStorage saveMessage:m forOwnerPK:owner];
    });

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (pk.length)
        info[@"senderPk"] = pk;
    if (u.length)
        info[@"senderUsername"] = u;
    if (fn.length)
        info[@"senderFullName"] = fn;
    if (emoji.length)
        info[@"emoji"] = emoji;
    if (targetPreview.length)
        info[@"targetPreview"] = targetPreview;
    return info.copy;
}

NSString *spkDMCaptureReactionTargetPreview(NSString *messageId, id applicator, NSString *threadId) {
    id targetMessage = spkResolveReactionTargetMessage(messageId, applicator, threadId);
    SPKDeletedMessageKind targetKind = SPKDeletedMessageKindUnknown;
    NSString *preview = spkReactionTargetPreview(targetMessage, &targetKind);
    // This one is shown, never stored, so a text-less target can be named here.
    if (!preview.length && targetKind != SPKDeletedMessageKindUnknown)
        preview = [SPKDeletedMessageKindLocalizedName(targetKind) lowercaseString];
    return preview;
}
