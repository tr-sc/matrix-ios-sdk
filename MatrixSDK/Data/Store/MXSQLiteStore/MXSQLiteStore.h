//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXTimelineStore.h"
#import "MXSQLiteKeyProvider.h"

@class MXSQLiteDatabase;

NS_ASSUME_NONNULL_BEGIN

/**
 Хранилище сессии на SQLCipher «события + дыры» (ADR-0022). Одна база на аккаунт:
 `<app group>/MXSQLiteStore/<sha256(userId)[0..16]>/store.sqlite`.

 Фасад: сам держит только открытие, коммит, удаление и сводки; остальные методы `MXStore` / `MXTimelineStore`
 уходят компонентам (`Components/MXSQLiteStoreComponents.h`).

 Включается флагом приложения и признаком сервера `im.trsc.event_count`; без них остаётся `MXFileStore`.
 */
@interface MXSQLiteStore : NSObject <MXTimelineStore>

/// Keychain с группой `keychainAccessGroup`, каталог `defaultRootDirectory`, запись.
- (instancetype)init;

/**
 @param keyProvider ключи базы.
 @param rootDirectory каталог, внутри которого лежат папки аккаунтов; nil — `defaultRootDirectory`.
 @param readOnly YES — для NSE: только читатели, запись — no-op, базу не создаёт и не пересоздаёт.
 */
- (instancetype)initWithKeyProvider:(id<MXSQLiteKeyProviding>)keyProvider
                      rootDirectory:(nullable NSURL *)rootDirectory
                           readOnly:(BOOL)readOnly NS_DESIGNATED_INITIALIZER;

/// Группа Keychain ключей для `init`. nil — группа по умолчанию (у приложения и RiotNSE она общая).
@property (class, nonatomic, copy, nullable) NSString *keychainAccessGroup;

/// `<app group>/MXSQLiteStore`, без app group — `Application Support/MXSQLiteStore`.
@property (class, nonatomic, readonly) NSURL *defaultRootDirectory;

/// Файл базы аккаунта.
+ (NSURL *)databaseURLForUserId:(NSString *)userId rootDirectory:(NSURL *)rootDirectory;

/// Имя ключа аккаунта в Keychain.
+ (NSString *)keyIdentifierForUserId:(NSString *)userId;

/// Удалить базу и ключ аккаунта без открытия стора (выход, откат флага).
+ (void)deleteDataForUserId:(NSString *)userId
              rootDirectory:(nullable NSURL *)rootDirectory
                keyProvider:(id<MXSQLiteKeyProviding>)keyProvider;

@property (nonatomic, readonly) BOOL readOnly;
/// nil до открытия и после `close` / `deleteAllData`.
@property (nonatomic, readonly, nullable) MXSQLiteDatabase *database;

/// Синхронно записать накладку (уход в фон, `close`). С main допустимо: пишет только накопленное.
- (void)flush;

/// Накладки всех компонентов — одной транзакцией на очереди писателя; затем `MXStoreDidCommitNotification`.
- (void)commit;
/// То же; `completion` — на main.
- (void)commitWithCompletion:(nullable void (^)(void))completion;
/// Сбросить накладку, чекпойнт, закрыть соединения. После — снова `openWithCredentials:`.
- (void)close;

@end

NS_ASSUME_NONNULL_END
