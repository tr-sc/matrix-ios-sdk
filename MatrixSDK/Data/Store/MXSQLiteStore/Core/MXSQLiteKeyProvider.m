//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteKeyProvider.h"

#import <Security/Security.h>

#import "MXSQLiteDatabase.h"

NSString *const MXSQLiteKeychainService = @"org.matrix.sdk.sqlite-store";

@implementation MXSQLiteKeyMaterial

- (instancetype)initWithKey:(NSData *)key salt:(NSData *)salt
{
    self = [super init];
    if (self)
    {
        _key = [key copy];
        _salt = [salt copy];
    }
    return self;
}

- (NSString *)description
{
    // Ни ключа, ни соли в логах.
    return [NSString stringWithFormat:@"<MXSQLiteKeyMaterial %lu+%lu bytes>", (unsigned long)_key.length, (unsigned long)_salt.length];
}

@end

static NSError *MXSQLiteKeyError(OSStatus status, NSString *what)
{
    return [NSError errorWithDomain:MXSQLiteErrorDomain
                               code:MXSQLiteErrorKeyUnavailable
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: OSStatus %d", what, (int)status]}];
}

@implementation MXSQLiteKeychainKeyProvider

- (instancetype)init
{
    return [self initWithAccessGroup:nil];
}

- (instancetype)initWithAccessGroup:(NSString *)accessGroup
{
    self = [super init];
    if (self)
    {
        _accessGroup = [accessGroup copy];
    }
    return self;
}

- (NSMutableDictionary *)baseQueryForIdentifier:(NSString *)identifier
{
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: MXSQLiteKeychainService,
        (__bridge id)kSecAttrAccount: identifier,
        (__bridge id)kSecAttrSynchronizable: @NO,
    } mutableCopy];
    if (_accessGroup)
    {
        query[(__bridge id)kSecAttrAccessGroup] = _accessGroup;
    }
    return query;
}

- (MXSQLiteKeyMaterial *)keyMaterialForIdentifier:(NSString *)identifier create:(BOOL)create error:(NSError **)error
{
    NSMutableDictionary *query = [self baseQueryForIdentifier:identifier];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess)
    {
        NSData *stored = (__bridge_transfer NSData *)result;
        MXSQLiteKeyMaterial *material = [self materialFromData:stored];
        if (material)
        {
            return material;
        }
        // Запись битая (другая длина): ключ к базе всё равно не подойдёт, заменяем.
        [self removeKeyMaterialForIdentifier:identifier];
    }
    else if (status != errSecItemNotFound)
    {
        // errSecInteractionNotAllowed — до первой разблокировки. Новый ключ тут создавать нельзя:
        // он затёр бы старый, и база стала бы нечитаемой.
        if (error)
        {
            *error = MXSQLiteKeyError(status, @"SecItemCopyMatching");
        }
        return nil;
    }

    if (!create)
    {
        if (error)
        {
            *error = MXSQLiteKeyError(errSecItemNotFound, @"no key");
        }
        return nil;
    }

    NSMutableData *bytes = [NSMutableData dataWithLength:MXSQLiteKeyLength + MXSQLiteSaltLength];
    status = SecRandomCopyBytes(kSecRandomDefault, bytes.length, bytes.mutableBytes);
    if (status != errSecSuccess)
    {
        if (error)
        {
            *error = MXSQLiteKeyError(status, @"SecRandomCopyBytes");
        }
        return nil;
    }

    NSMutableDictionary *attributes = [self baseQueryForIdentifier:identifier];
    attributes[(__bridge id)kSecValueData] = bytes;
    attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    if (status != errSecSuccess)
    {
        memset_s(bytes.mutableBytes, bytes.length, 0, bytes.length);
        if (error)
        {
            *error = MXSQLiteKeyError(status, @"SecItemAdd");
        }
        return nil;
    }

    MXSQLiteKeyMaterial *material = [self materialFromData:bytes];
    memset_s(bytes.mutableBytes, bytes.length, 0, bytes.length);
    return material;
}

- (MXSQLiteKeyMaterial *)materialFromData:(NSData *)data
{
    if (data.length != MXSQLiteKeyLength + MXSQLiteSaltLength)
    {
        return nil;
    }
    return [[MXSQLiteKeyMaterial alloc] initWithKey:[data subdataWithRange:NSMakeRange(0, MXSQLiteKeyLength)]
                                               salt:[data subdataWithRange:NSMakeRange(MXSQLiteKeyLength, MXSQLiteSaltLength)]];
}

- (void)removeKeyMaterialForIdentifier:(NSString *)identifier
{
    SecItemDelete((__bridge CFDictionaryRef)[self baseQueryForIdentifier:identifier]);
}

@end

@implementation MXSQLiteMemoryKeyProvider

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _keys = [NSMutableDictionary dictionary];
    }
    return self;
}

- (MXSQLiteKeyMaterial *)keyMaterialForIdentifier:(NSString *)identifier create:(BOOL)create error:(NSError **)error
{
    @synchronized (self)
    {
        MXSQLiteKeyMaterial *material = _keys[identifier];
        if (!material && create)
        {
            NSMutableData *key = [NSMutableData dataWithLength:MXSQLiteKeyLength];
            NSMutableData *salt = [NSMutableData dataWithLength:MXSQLiteSaltLength];
            (void)SecRandomCopyBytes(kSecRandomDefault, key.length, key.mutableBytes);
            (void)SecRandomCopyBytes(kSecRandomDefault, salt.length, salt.mutableBytes);
            material = [[MXSQLiteKeyMaterial alloc] initWithKey:key salt:salt];
            _keys[identifier] = material;
        }
        if (!material && error)
        {
            *error = MXSQLiteKeyError(errSecItemNotFound, @"no key");
        }
        return material;
    }
}

- (void)removeKeyMaterialForIdentifier:(NSString *)identifier
{
    @synchronized (self)
    {
        [_keys removeObjectForKey:identifier];
    }
}

@end
