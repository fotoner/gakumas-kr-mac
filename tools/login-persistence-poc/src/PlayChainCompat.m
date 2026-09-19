// Game-local PoC for Firebase's numeric kSecMatchLimit queries.
// Uses the installed PlayChain implementation; never logs query values or payloads.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef OSStatus (*CopyMatchingIMP)(id, SEL, NSDictionary *, CFTypeRef *);
static CopyMatchingIMP originalCopyMatching;

static OSStatus compatibleCopyMatching(id cls, SEL cmd, NSDictionary *query, CFTypeRef *result) {
    id limit = query[(__bridge id)kSecMatchLimit];
    BOOL supported = [query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
        && [limit isKindOfClass:NSNumber.class] && [limit integerValue] > 1
        && [query[(__bridge id)kSecReturnAttributes] boolValue]
        && [query[(__bridge id)kSecReturnData] boolValue]
        && ![query[(__bridge id)kSecReturnRef] boolValue]
        && ![query[(__bridge id)kSecReturnPersistentRef] boolValue];
    if (!supported || !result) return originalCopyMatching(cls, cmd, query, result);

    CFTypeRef firstRaw = NULL;
    OSStatus status = originalCopyMatching(cls, cmd, query, &firstRaw);
    id first = CFBridgingRelease(firstRaw);
    // A future PlayTools implementation may already return the correct array.
    if (status != errSecSuccess || ![first isKindOfClass:NSDictionary.class]) {
        *result = first ? CFBridgingRetain(first) : NULL;
        return status;
    }

    NSMutableDictionary *allQuery = [query mutableCopy];
    allQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    CFTypeRef allRaw = NULL;
    status = originalCopyMatching(cls, cmd, allQuery, &allRaw);
    id all = CFBridgingRelease(allRaw);
    if (status != errSecSuccess || ![all isKindOfClass:NSArray.class]) {
        *result = NULL;
        return status != errSecSuccess ? status : errSecInternalError;
    }

    NSMutableArray *items = [NSMutableArray array];
    NSUInteger count = MIN([all count], [limit unsignedIntegerValue]);
    for (NSUInteger index = 0; index < count; index++) {
        // PlayChain's 'all' path strips data, so retrieve the requested data through
        // its normal single-item path. Preserve the number of matches (no dedup).
        id attributes = all[index];
        if (![attributes isKindOfClass:NSDictionary.class]) {
            *result = NULL;
            return errSecInternalError;
        }
        NSMutableDictionary *oneQuery = [query mutableCopy];
        for (id key in @[(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccount,
                         (__bridge id)kSecAttrService]) {
            if (attributes[key]) oneQuery[key] = attributes[key];
        }
        oneQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef oneRaw = NULL;
        status = originalCopyMatching(cls, cmd, oneQuery, &oneRaw);
        id one = CFBridgingRelease(oneRaw);
        if (status != errSecSuccess || ![one isKindOfClass:NSDictionary.class]) {
            *result = NULL;
            return status != errSecSuccess ? status : errSecInternalError;
        }
        [items addObject:one];
    }
    *result = CFBridgingRetain(items);
    NSLog(@"[GakuPlayChainCompat] numeric-limit dictionary -> array; matches=%lu; no credential values logged",
          (unsigned long)items.count);
    return errSecSuccess;
}

BOOL GakuInstallPlayChainCompat(Class cls) {
    Method method = class_getClassMethod(cls, NSSelectorFromString(@"copyMatching:result:"));
    if (!method || originalCopyMatching) return NO;
    originalCopyMatching = (CopyMatchingIMP)method_getImplementation(method);
    method_setImplementation(method, (IMP)compatibleCopyMatching);
    return YES;
}

#ifndef GAKU_POC_FIXTURE
__attribute__((constructor)) static void installGameCompat(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"jp.co.bandainamcoent.BNEI0421"]) return;
        Class cls = NSClassFromString(@"PlayTools.PlayKeychain");
        NSLog(@"[GakuPlayChainCompat] %@", GakuInstallPlayChainCompat(cls) ? @"installed" : @"not installed");
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
