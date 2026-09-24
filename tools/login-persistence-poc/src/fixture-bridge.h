// Fixture-only declarations imported by main.swift (never part of the game dylib).
#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN
// SecItem* routed like PlayLoader.m's interposers: [PlayKeychain ...] through objc_msgSend.
OSStatus fx_add(NSDictionary *attributes);
OSStatus fx_update(NSDictionary *query, NSDictionary *attributesToUpdate);
OSStatus fx_delete(NSDictionary *query);
OSStatus fx_copy(NSDictionary *query, id _Nullable __autoreleasing *_Nonnull result);
// A keychain class that only implements +copyMatching:result: (missing add/delete selectors).
Class fx_partial_class(void);

// src/PlayChainCompat.m
uint32_t GakuInstallPlayChainCompat(Class _Nullable cls);
uint32_t GakuFixtureInstallReadOnly(Class cls);
void GakuFixtureSetNaiveAdd(BOOL enabled);
NS_ASSUME_NONNULL_END
