//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ключ и соль одной базы.
@interface MXSQLiteKeyMaterial : NSObject
- (instancetype)initWithKey:(NSData *)key salt:(NSData *)salt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// 32 байта.
@property (nonatomic, readonly) NSData *key;
/// 16 байт.
@property (nonatomic, readonly) NSData *salt;
@end

/// Источник ключей баз. Подменяется в тестах.
@protocol MXSQLiteKeyProviding <NSObject>
/**
 Ключ базы `identifier`.
 @param create YES — создать, если его нет (приложение). NO — только прочитать (NSE).
 @return nil — ключа нет или Keychain недоступен (до первой разблокировки); `error` заполнен.
 */
- (nullable MXSQLiteKeyMaterial *)keyMaterialForIdentifier:(NSString *)identifier create:(BOOL)create error:(NSError **)error;
/// Удалить ключ (выход из аккаунта, пересоздание базы).
- (void)removeKeyMaterialForIdentifier:(NSString *)identifier;
@end

/**
 Ключи в Keychain: 32 байта ключа + 16 байт соли из `SecRandomCopyBytes` одной записью `kSecClassGenericPassword`,
 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, без синхронизации с iCloud.

 Группа доступа — общая для приложения и NSE: NSE читает ту же базу. nil — группа по умолчанию (первая из
 `keychain-access-groups`; у Element это `$(KEYCHAIN_ACCESS_GROUP)` и в приложении, и в RiotNSE).
 */
@interface MXSQLiteKeychainKeyProvider : NSObject <MXSQLiteKeyProviding>

- (instancetype)initWithAccessGroup:(nullable NSString *)accessGroup NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property (nonatomic, readonly, nullable) NSString *accessGroup;

@end

/// `kSecAttrService` записей.
FOUNDATION_EXPORT NSString *const MXSQLiteKeychainService;

/// Ключи в памяти — для тестов.
@interface MXSQLiteMemoryKeyProvider : NSObject <MXSQLiteKeyProviding>
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLiteKeyMaterial *> *keys;
@end

NS_ASSUME_NONNULL_END
