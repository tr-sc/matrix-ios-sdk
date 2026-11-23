//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXAggregationsStore.h"

@class MXSQLiteStore;

NS_ASSUME_NONNULL_BEGIN

/**
 Реакции в таблицах `reaction_count` и `reaction_relation` базы `MXSQLiteStore` (ADR-0022, iP6) вместо Realm.

 Запись — накладкой (`MXSQLiteOverlay`): видна чтению сразу, на диск уходит отдельной короткой транзакцией писателя
 в следующем проходе своей очереди. Строки ссылаются на `room.rid`; комнату создаёт стор событий. Если строки
 `room` ещё нет (реакция пришла в том же синке, что и новая комната), запись ждёт ближайшего коммита стора —
 так реакции не плодят комнат, которых нет в `roomIds`.

 Удаление комнаты в сторе (`deleteRoom`) сносит её реакции вместе с остальными таблицами комнаты.
 */
@interface MXSQLiteAggregationsStore : NSObject <MXAggregationsStore>

- (instancetype)initWithStore:(MXSQLiteStore *)store NS_DESIGNATED_INITIALIZER;
/// Требование протокола: без стора сессии — только память.
- (instancetype)initWithCredentials:(MXCredentials *)credentials;
- (instancetype)init NS_UNAVAILABLE;

/// Синхронно записать накладку (тесты, уход в фон). Не с очереди писателя.
- (void)flush;

/// Папка старого Realm-стора агрегаций аккаунта (`Caches/<userId>/Aggregations`).
+ (NSURL *)legacyRealmFolderForUserId:(NSString *)userId;

/// Удалить старый Realm-стор агрегаций аккаунта, если он есть.
+ (void)removeLegacyRealmStoreForUserId:(NSString *)userId;

@end

NS_ASSUME_NONNULL_END
