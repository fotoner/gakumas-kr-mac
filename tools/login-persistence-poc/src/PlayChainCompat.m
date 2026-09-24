// Game-local PlayChain compatibility shim (v2) for PlayTools f2bfbd7.
// Makes PlayChain answer the game's generic-password calls like the real Keychain:
//   read   : numeric kSecMatchLimit returns an array, one entry per distinct item
//   add    : SecItemAdd on exactly one existing item -> errSecDuplicateItem
//            (Firebase then calls SecItemUpdate, which rewrites that single row).
//            Only string (agrp?, acct, svce) identities; anything else keeps PlayChain's append.
//            A row found behind a not-found numeric-limit read of the same identity
//            (PlayChain reports a busy DB as not found) is appended, never overwritten.
//   delete : a DELETE that removed its rows returns errSecSuccess, not errSecIO
// No SQL and no row deletion here: duplicates left by older builds are only reported;
// tools/login-persistence-poc/playchain-recover.py cleans them with the game closed.
// Logs counts and status codes only, never queries, attributes or payloads.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define K(x) ((__bridge id)(x))

typedef OSStatus (*CopyMatchingIMP)(id, SEL, NSDictionary *, CFTypeRef *);
typedef OSStatus (*AddIMP)(id, SEL, NSDictionary *, CFTypeRef *);
typedef OSStatus (*DeleteIMP)(id, SEL, NSDictionary *);

enum { GakuCompatRead = 1, GakuCompatAdd = 2, GakuCompatDelete = 4 };

// PlayChain's own implementations, captured before swizzling.
static CopyMatchingIMP originalCopyMatching;
static AddIMP originalAdd;
static DeleteIMP originalDelete;
static SEL copySelector;
static Class installedClass;

#ifdef GAKU_POC_FIXTURE
static BOOL fixtureNaiveAdd; // control only: duplicate on any match, i.e. without the count>1 guard
#endif

static NSArray *genericPrimaries(void) {
    return @[K(kSecAttrAccessGroup), K(kSecAttrAccount), K(kSecAttrService)];
}

// (agrp|NSNull, acct, svce) of a generic password with string primaries, else nil.
// Other shapes are left to PlayChain: its WHERE builder drops absent primaries (so a
// probe would match other items) and traps on non-UTF-8 data.
static NSArray *stringIdentity(NSDictionary *attributes) {
    id agrp = attributes[K(kSecAttrAccessGroup)];
    id account = attributes[K(kSecAttrAccount)];
    id service = attributes[K(kSecAttrService)];
    if (![attributes[K(kSecClass)] isEqual:K(kSecClassGenericPassword)]
        || ![account isKindOfClass:NSString.class] || ![service isKindOfClass:NSString.class]
        || (agrp && ![agrp isKindOfClass:NSString.class])) return nil;
    return @[agrp ?: NSNull.null, account, service];
}

static NSObject *writeLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Identities whose last numeric-limit read was errSecItemNotFound, i.e. the caller holds no
// item for them. Cleared by a successful read or add. Guarded by writeLock().
static NSMutableSet *unseenIdentities(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// ---------------------------------------------------------------- read ---
// Numeric-limit read answered as the real Keychain does: an array, one item per identity.
static OSStatus readAsArray(id cls, SEL cmd, NSDictionary *query, NSUInteger max, CFTypeRef *result) {
    CFTypeRef firstRaw = NULL;
    OSStatus status = originalCopyMatching(cls, cmd, query, &firstRaw);
    id first = CFBridgingRelease(firstRaw);
    // A future PlayTools may already return the correct array.
    if (status != errSecSuccess || ![first isKindOfClass:NSDictionary.class]) {
        *result = first ? CFBridgingRetain(first) : NULL;
        return status;
    }

    NSMutableDictionary *allQuery = [query mutableCopy];
    allQuery[K(kSecMatchLimit)] = K(kSecMatchLimitAll);
    CFTypeRef allRaw = NULL;
    status = originalCopyMatching(cls, cmd, allQuery, &allRaw);
    id all = CFBridgingRelease(allRaw); // the 'all' path strips v_Data
    if (status != errSecSuccess || ![all isKindOfClass:NSArray.class]) {
        *result = NULL;
        return status != errSecSuccess ? status : errSecInternalError;
    }

    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id attributes in all) {
        if (![attributes isKindOfClass:NSDictionary.class]) { *result = NULL; return errSecInternalError; }
        // PlayChain cannot address rows sharing (agrp, acct, svce) separately and the real
        // Keychain cannot hold them at all, so each identity is returned once (first row).
        NSMutableArray *identity = [NSMutableArray array];
        for (id key in genericPrimaries()) [identity addObject:attributes[key] ?: NSNull.null];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        NSMutableDictionary *oneQuery = [query mutableCopy];
        for (id key in genericPrimaries()) {
            if (attributes[key]) oneQuery[key] = attributes[key];
        }
        oneQuery[K(kSecMatchLimit)] = K(kSecMatchLimitOne);
        CFTypeRef oneRaw = NULL;
        status = originalCopyMatching(cls, cmd, oneQuery, &oneRaw);
        id one = CFBridgingRelease(oneRaw);
        if (status != errSecSuccess || ![one isKindOfClass:NSDictionary.class]) {
            *result = NULL;
            return status != errSecSuccess ? status : errSecInternalError;
        }
        [items addObject:one];
        if (items.count == max) break;
    }
    *result = CFBridgingRetain(items);
    NSLog(@"[GakuPlayChainCompat] read rows=%lu items=%lu", (unsigned long)[all count], (unsigned long)items.count);
    return errSecSuccess;
}

static OSStatus compatibleCopyMatching(id cls, SEL cmd, NSDictionary *query, CFTypeRef *result) {
    id limit = query[K(kSecMatchLimit)];
    BOOL supported = [query[K(kSecClass)] isEqual:K(kSecClassGenericPassword)]
        && [limit isKindOfClass:NSNumber.class] && [limit integerValue] > 1
        && [query[K(kSecReturnAttributes)] boolValue]
        && [query[K(kSecReturnData)] boolValue]
        && ![query[K(kSecReturnRef)] boolValue]
        && ![query[K(kSecReturnPersistentRef)] boolValue];
    if (!supported || !result) return originalCopyMatching(cls, cmd, query, result);

    @synchronized (writeLock()) { // a read and its not-found record must not interleave with an add
        OSStatus status = readAsArray(cls, cmd, query, [limit unsignedIntegerValue], result);
        NSArray *identity = stringIdentity(query);
        if (identity && status == errSecItemNotFound) [unseenIdentities() addObject:identity];
        else if (identity && status == errSecSuccess) [unseenIdentities() removeObject:identity];
        return status;
    }
}

// --------------------------------------------------------------- probe ---
// Rows PlayChain's own WHERE builder selects for the primaries in `source`: exactly the rows
// its update/delete would touch (an absent agrp is left out of the WHERE, matching any).
// Primaries only, no data requested; the 'all' path strips v_Data anyway.
// Returns -1 when PlayChain answers unexpectedly.
static NSInteger playChainCount(id cls, NSDictionary *source) {
    NSMutableDictionary *probe;
    if ([source[K(kSecClass)] isEqual:K(kSecClassGenericPassword)]) {
        probe = [NSMutableDictionary dictionaryWithObject:K(kSecClassGenericPassword) forKey:K(kSecClass)];
        for (id key in genericPrimaries()) {
            id value = source[key];
            if (value && value != NSNull.null) probe[key] = value;
        }
    } else {
        probe = [source mutableCopy];
        [probe removeObjectsForKeys:@[K(kSecValueData), K(kSecValueRef), K(kSecValuePersistentRef),
                                      K(kSecReturnData), K(kSecReturnRef), K(kSecReturnPersistentRef)]];
    }
    probe[K(kSecMatchLimit)] = K(kSecMatchLimitAll);
    probe[K(kSecReturnAttributes)] = @YES;
    CFTypeRef raw = NULL;
    OSStatus status = originalCopyMatching(cls, copySelector, probe, &raw);
    id all = CFBridgingRelease(raw);
    if (status == errSecItemNotFound) return 0;
    if (status != errSecSuccess || ![all isKindOfClass:NSArray.class]) return -1;
    return (NSInteger)[all count];
}

// ----------------------------------------------------------------- add ---
static OSStatus compatibleAdd(id cls, SEL cmd, NSDictionary *attributes, CFTypeRef *result) {
    NSArray *identity = stringIdentity(attributes);
    if (!identity) return originalAdd(cls, cmd, attributes, result);
    @synchronized (writeLock()) { // probe + insert must not interleave with another add
        NSInteger existing = playChainCount(cls, attributes);
        // The caller's read saw nothing, so this row was hidden from it (e.g. a busy DB):
        // overwriting it could replace the restored account with a fresh login.
        BOOL unseen = [unseenIdentities() containsObject:identity];
        BOOL duplicate = existing == 1 && !unseen;
#ifdef GAKU_POC_FIXTURE
        duplicate = duplicate || (fixtureNaiveAdd && existing > 1);
#endif
        if (duplicate) {
            NSLog(@"[GakuPlayChainCompat] add existing=%ld -> errSecDuplicateItem", (long)existing);
            return errSecDuplicateItem;
        }
        OSStatus status = originalAdd(cls, cmd, attributes, result);
        if (status == errSecSuccess) [unseenIdentities() removeObject:identity];
        if (existing == 1) {
            NSLog(@"[GakuPlayChainCompat] WARNING add existing=1 after a not-found read -> legacy append status=%d; "
                  @"quit the game and run: python3 tools/login-persistence-poc/playchain-recover.py check", (int)status);
        } else if (existing > 1) {
            // SecItemUpdate would rewrite every duplicate with whichever row was restored
            // (possibly another account), so keep PlayChain's append and ask for a cleanup.
            NSLog(@"[GakuPlayChainCompat] WARNING add existing=%ld (duplicate rows) -> legacy append status=%d; "
                  @"quit the game and run: python3 tools/login-persistence-poc/playchain-recover.py check",
                  (long)existing, (int)status);
        } else if (existing < 0) {
            NSLog(@"[GakuPlayChainCompat] WARNING add probe failed -> legacy append status=%d", (int)status);
        } else {
            NSLog(@"[GakuPlayChainCompat] add existing=0 -> insert status=%d", (int)status);
        }
        return status;
    }
}

// -------------------------------------------------------------- delete ---
static OSStatus compatibleDelete(id cls, SEL cmd, NSDictionary *query) {
    @synchronized (writeLock()) {
        OSStatus status = originalDelete(cls, cmd, query);
        // PlayChain compares sqlite3_step() with SQLITE_OK, so a DELETE that ran reports errSecIO.
        if (status != errSecIO) return status;
        NSInteger remaining = playChainCount(cls, query);
        NSLog(@"[GakuPlayChainCompat] delete errSecIO remaining=%ld -> %@", (long)remaining,
              remaining == 0 ? @"errSecSuccess" : @"errSecIO");
        return remaining == 0 ? errSecSuccess : status;
    }
}

// ------------------------------------------------------------- install ---
static BOOL swizzle(Class cls, NSString *name, IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, NSSelectorFromString(name));
    if (!method) {
        NSLog(@"[GakuPlayChainCompat] +%@ missing; that part stays off", name);
        return NO;
    }
    if (method_getImplementation(method) == replacement) return YES; // already installed
    if (*original) return NO; // never chain onto a second implementation
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}

// Idempotent. Returns bit 0 read, bit 1 add, bit 2 delete for the parts now active.
uint32_t GakuInstallPlayChainCompat(Class cls) {
    uint32_t installed = 0;
    @synchronized (writeLock()) {
        if (!cls) {
            NSLog(@"[GakuPlayChainCompat] PlayKeychain class missing; nothing installed");
            return 0;
        }
        if (installedClass && installedClass != cls) {
            NSLog(@"[GakuPlayChainCompat] already installed on another class; nothing installed");
            return 0;
        }
        copySelector = NSSelectorFromString(@"copyMatching:result:");
        if (swizzle(cls, @"copyMatching:result:", (IMP)compatibleCopyMatching, (IMP *)&originalCopyMatching))
            installed |= GakuCompatRead;
        // add/delete probe through PlayChain's original copyMatching.
        if (originalCopyMatching) {
            if (swizzle(cls, @"add:result:", (IMP)compatibleAdd, (IMP *)&originalAdd)) installed |= GakuCompatAdd;
            if (swizzle(cls, @"delete:", (IMP)compatibleDelete, (IMP *)&originalDelete)) installed |= GakuCompatDelete;
        }
        if (installed) installedClass = cls;
    }
    NSLog(@"[GakuPlayChainCompat] read=%d add=%d delete=%d", !!(installed & GakuCompatRead),
          !!(installed & GakuCompatAdd), !!(installed & GakuCompatDelete));
    return installed;
}

#ifdef GAKU_POC_FIXTURE
// Controls for the test harness only; never compiled into the game dylib.
uint32_t GakuFixtureInstallReadOnly(Class cls) { // v1 behaviour
    copySelector = NSSelectorFromString(@"copyMatching:result:");
    return swizzle(cls, @"copyMatching:result:", (IMP)compatibleCopyMatching, (IMP *)&originalCopyMatching)
        ? GakuCompatRead : 0;
}
void GakuFixtureSetNaiveAdd(BOOL enabled) { fixtureNaiveAdd = enabled; }
#endif

#ifndef GAKU_POC_FIXTURE
__attribute__((constructor)) static void installGameCompat(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"jp.co.bandainamcoent.BNEI0421"]) return;
        GakuInstallPlayChainCompat(NSClassFromString(@"PlayTools.PlayKeychain"));
        // Read-only verification after Firebase's startup queue has completed.
        // Only presence is recorded; no user identifier, token, or profile is read.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            Class appClass = NSClassFromString(@"FIRApp");
            Class authClass = NSClassFromString(@"FIRAuth");
            SEL defaultApp = NSSelectorFromString(@"defaultApp");
            SEL auth = NSSelectorFromString(@"auth");
            SEL currentUser = NSSelectorFromString(@"currentUser");
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            if (![appClass respondsToSelector:defaultApp] || !send(appClass, defaultApp)
                || ![authClass respondsToSelector:auth]) return;
            id instance = send(authClass, auth);
            if ([instance respondsToSelector:currentUser]) {
                NSLog(@"[GakuPlayChainCompat] Firebase currentUser present=%@",
                      send(instance, currentUser) ? @"yes" : @"no");
            }
        });
    }
}
#endif
