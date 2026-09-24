// Fixture-only: dispatch SecItem* the way PlayTools' PlayLoader.m interposers do
// ([PlayKeychain ...] via objc_msgSend), so the shim's method swizzles apply.
#import "fixture-bridge.h"
#import <objc/message.h>

static Class PK(void) { return NSClassFromString(@"PlayKeychainFixture"); }

OSStatus fx_add(NSDictionary *attributes) {
    return ((OSStatus (*)(id, SEL, id, CFTypeRef *))objc_msgSend)(PK(), sel_registerName("add:result:"), attributes, NULL);
}

OSStatus fx_update(NSDictionary *query, NSDictionary *attributesToUpdate) {
    return ((OSStatus (*)(id, SEL, id, id))objc_msgSend)(PK(), sel_registerName("update:attributesToUpdate:"),
                                                         query, attributesToUpdate);
}

OSStatus fx_delete(NSDictionary *query) {
    return ((OSStatus (*)(id, SEL, id))objc_msgSend)(PK(), sel_registerName("delete:"), query);
}

OSStatus fx_copy(NSDictionary *query, id __autoreleasing *result) {
    CFTypeRef raw = NULL;
    OSStatus status = ((OSStatus (*)(id, SEL, id, CFTypeRef *))objc_msgSend)(PK(), sel_registerName("copyMatching:result:"),
                                                                            query, &raw);
    *result = CFBridgingRelease(raw);
    return status;
}

@interface GakuFixturePartialKeychain : NSObject
@end
@implementation GakuFixturePartialKeychain
+ (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result { return errSecItemNotFound; }
@end

Class fx_partial_class(void) { return GakuFixturePartialKeychain.class; }
