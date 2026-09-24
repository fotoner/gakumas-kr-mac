// End-to-end fixture for the game dylib (Mac Catalyst, never part of it). Linked against the
// built GakuPlayChainCompat.dylib and a PlayTools-like libPlayTools.dylib whose class keeps its
// real runtime name, PlayTools.PlayKeychain. SecItem* are dispatched through objc_msgSend like
// PlayLoader.m's interposers. Fake data only; GAKU_POC_DB names a throwaway database.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/message.h>

#define K(x) ((__bridge id)(x))

static Class PK(void) { return NSClassFromString(@"PlayTools.PlayKeychain"); }

static OSStatus add(NSDictionary *attributes) {
    return ((OSStatus (*)(id, SEL, id, CFTypeRef *))objc_msgSend)(PK(), sel_registerName("add:result:"), attributes, NULL);
}

static OSStatus update(NSDictionary *query, NSDictionary *attributes) {
    return ((OSStatus (*)(id, SEL, id, id))objc_msgSend)(PK(), sel_registerName("update:attributesToUpdate:"), query, attributes);
}

static OSStatus delete(NSDictionary *query) {
    return ((OSStatus (*)(id, SEL, id))objc_msgSend)(PK(), sel_registerName("delete:"), query);
}

static OSStatus copyMatching(NSDictionary *query, id *result) {
    CFTypeRef raw = NULL;
    OSStatus status = ((OSStatus (*)(id, SEL, id, CFTypeRef *))objc_msgSend)(PK(), sel_registerName("copyMatching:result:"),
                                                                            query, &raw);
    *result = CFBridgingRelease(raw);
    return status;
}

static NSData *value(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

int main(void) {
    @autoreleasepool {
        NSString *db = NSProcessInfo.processInfo.environment[@"GAKU_POC_DB"];
        if (!db.length || [db containsString:@"io.playcover.PlayCover"]) {
            printf("FAIL: GAKU_POC_DB must name a synthetic database\n");
            return 3;
        }
        printf("OUT bundle=%s\n", NSBundle.mainBundle.bundleIdentifier ? "set" : "none");
        if (!PK()) { printf("OUT class=missing\n"); return 1; }
        printf("OUT class=found\n");

        NSDictionary *query = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrAccount): @"e2e-account",
                                K(kSecAttrService): @"e2e-service"};
        NSMutableDictionary *item = [query mutableCopy];
        item[K(kSecValueData)] = value(@"E-v1");
        printf("OUT add=%d\n", (int)add(item));
        item[K(kSecValueData)] = value(@"E-v2");
        OSStatus again = add(item);
        printf("OUT add-again=%d\n", (int)again);
        if (again == errSecDuplicateItem) printf("OUT update=%d\n", (int)update(query, @{K(kSecValueData): value(@"E-v2")}));

        NSMutableDictionary *read = [query mutableCopy];
        read[K(kSecMatchLimit)] = @2;
        read[K(kSecReturnAttributes)] = @YES;
        read[K(kSecReturnData)] = @YES;
        id result = nil;
        OSStatus status = copyMatching(read, &result);
        if (status == errSecSuccess && [result isKindOfClass:NSArray.class]) {
            NSData *data = [result count] ? [result firstObject][K(kSecValueData)] : nil;
            printf("OUT read=array:%lu:%s\n", (unsigned long)[result count],
                   data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String : "nil");
        } else {
            printf("OUT read=%d:%s\n", (int)status, [result isKindOfClass:NSDictionary.class] ? "dictionary" : "other");
        }
        printf("OUT delete=%d\n", (int)delete(query));
        printf("OUT delete-again=%d\n", (int)delete(query));
    }
    return 0;
}
