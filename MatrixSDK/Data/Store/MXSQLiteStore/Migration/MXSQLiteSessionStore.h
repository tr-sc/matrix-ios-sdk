//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStore.h"

@class MXCredentials;
@class MXSQLiteLegacyImportResult;

NS_ASSUME_NONNULL_BEGIN

/**
 Стор сессии приложения при включённом флаге. Это `MXSQLiteStore` плюс переключение с MXFileStore
 при открытии:

 1. База открыта (или создана пустой — история не переносится, её принесёт синк).
 2. Если папка MXFileStore аккаунта есть: перенос неотправленных и черновиков (`MXSQLiteLegacyImport`, один раз —
    отметка в `meta`), затем удаление папки MXFileStore и сводок старого стора. Без сводок счётчик комнат 0, и сессия
    не восстанавливает позицию Sliding Sync старого стора: первый синк — начальный.
 3. Только потом `onComplete`: сессия монтируется уже с перенесённым.

 Неудачное открытие запоминается (`hasOpenFailureForUserId:`), чтобы следующий запуск вернулся на MXFileStore.
 Кроме временного отказа (`+[MXSQLiteStore isTransientOpenError:]`, памяти не хватило, ключ свой): база и ключ целы,
 отметка не ставится, и следующий холодный старт снова открывает SQLite. Только после
 `MXSQLiteSessionStoreMaxTransientOpenFailures` временных отказов подряд он считается обычным — иначе аккаунт без
 конца стартовал бы без сессии.
 */
/// Сколько временных отказов открытия подряд терпится, прежде чем отказ запоминается как обычный.
FOUNDATION_EXPORT NSInteger const MXSQLiteSessionStoreMaxTransientOpenFailures;

@interface MXSQLiteSessionStore : MXSQLiteStore

/// Папка MXFileStore аккаунта. nil — `+[MXSQLiteLegacyImport fileStoreURLForUserId:]`.
@property (nonatomic, copy, nullable) NSURL *legacyFileStoreURL;

/// Итог переноса последнего открытия; nil — папки MXFileStore не было.
@property (nonatomic, readonly, nullable) MXSQLiteLegacyImportResult *legacyImportResult;

/// Флаг выключен, а база осталась: удалить базу, ключ и сводки, чтобы MXFileStore начал с чистого синка.
/// Неотправленные и черновики новой базы при этом теряются (обратного переноса нет).
+ (void)deactivateForCredentials:(MXCredentials *)credentials
                   rootDirectory:(nullable NSURL *)rootDirectory
                     keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
    NS_SWIFT_NAME(deactivate(for:rootDirectory:keyProvider:));

/// Последнее открытие базы аккаунта не удалось.
+ (BOOL)hasOpenFailureForUserId:(NSString *)userId;
+ (void)clearOpenFailureForUserId:(NSString *)userId;
/// Временных отказов открытия подряд с последнего удачного.
+ (NSInteger)transientOpenFailureCountForUserId:(NSString *)userId;

@end

NS_ASSUME_NONNULL_END
