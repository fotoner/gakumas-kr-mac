// Fixture-only declarations imported by main.swift (never part of the game dylib).
#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN
// SecItem* routed like PlayLoader.m's interposers: [PlayKeychain ...] through objc_msgSend.
OSStatus fx_add(NSDictionary *attributes);
OSStatus fx_update(NSDictionary *query, NSDictionary *attributesToUpdate);
OSStatus fx_delete(NSDictionary *query);
OSStatus fx_copy(NSDictionary *query, id _Nullable __autoreleasing *_Nonnull result);

// src/PlayChainCompat.m
uint32_t GakuInstallPlayChainCompat(Class _Nullable cls);
NS_ASSUME_NONNULL_END
