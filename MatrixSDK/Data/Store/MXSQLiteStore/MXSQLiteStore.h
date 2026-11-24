//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXTimelineStore.h"
#import "MXSQLiteKeyProvider.h"

@class MXSQLiteDatabase;
@class MXCredentials;
@class MXEvent;

NS_ASSUME_NONNULL_BEGIN

/// Сколько NSE ждёт писателя приложения (`PRAGMA busy_timeout` стора расширения).
FOUNDATION_EXPORT NSInteger const MXSQLiteExtensionBusyTimeoutMilliseconds;

/**
 Хранилище сессии на SQLCipher «события + дыры». Одна база на аккаунт:
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

/**
 Стор NSE: та же база аккаунта в app group и тот же ключ из Keychain. Открывает только существующий файл
 (ключ не создаёт, базу не пересоздаёт, схему не трогает — чужая версия схемы = ошибка открытия). Писатель есть,
 но `commit` / `flush` ничего не пишут: на диск попадает только `insertPushEvent:inRoom:error:`. Ожидание
 писателя приложения — не дольше `MXSQLiteExtensionBusyTimeoutMilliseconds`, потом отказ (пуш показывается и так).
 */
- (instancetype)initForExtensionWithKeyProvider:(id<MXSQLiteKeyProviding>)keyProvider
                                  rootDirectory:(nullable NSURL *)rootDirectory;

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

/// Есть ли база аккаунта. Приложение держит правило: база есть ⇔ стор сессии — SQLite (`MXSQLiteSessionStore`);
/// по нему NSE выбирает стор без флага приложения.
+ (BOOL)hasDatabaseForUserId:(NSString *)userId rootDirectory:(nullable NSURL *)rootDirectory;

/// Отказ открытия временный (`MXSQLiteErrorTransient`: не хватило памяти, ключ свой): база и ключ целы, следующий
/// холодный старт пробует снова.
+ (BOOL)isTransientOpenError:(nullable NSError *)error;

/// Причина отказа открытия для метрик (`store_open_failed`): `transient`, `cipher_unavailable`, `key_unavailable`,
/// `invalid_key`, `schema`, `key_rejected` (пересоздание не помогло), `open_failed`.
+ (NSString *)openFailureReasonForError:(nullable NSError *)error;

@property (nonatomic, readonly) BOOL readOnly;
/// Стор NSE (`initForExtensionWithKeyProvider:rootDirectory:`).
@property (nonatomic, readonly) BOOL extensionMode;

/// Состояние Sliding Sync сессии: пишется до `commit` ответа и попадает в ту же транзакцию, что его события
/// (у MXFileStore оно в NSUserDefaults после коммита). Реализует компонент меты.
@property (nonatomic, copy, nullable) NSDictionary *trscSlidingSyncState;

/// Открыть на вызывающем потоке (NSE: процесс короткий, стор нужен сразу). Не звать с main приложения.
- (BOOL)openSynchronouslyWithCredentials:(MXCredentials *)credentials error:(NSError **)error;

/**
 Событие из пуша — одной строкой между дырами (`insertDetachedEvent:inRoom:`) и сразу на диск отдельной короткой
 транзакцией. Синк потом закрывает дыры по `noteSyncTimelineInRoom:…` и заменяет строку на месте (ключ — event_id).
 NO и `error`: стор не открыт, комнаты нет в базе (без её состояния чат не откроется), нет `trsc.count`, событие
 уже есть, писатель занят дольше busy_timeout.
 */
- (BOOL)insertPushEvent:(MXEvent *)event inRoom:(NSString *)roomId error:(NSError **)error
    NS_SWIFT_NAME(insertPushEvent(_:inRoom:));
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
