//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/**
 События, дыры, страницы и перечислители (ADR-0022, пакет iP2).

 Запись идёт в накладку (`MXSQLitePendingBatch`): видна чтению сразу, на диск уходит одной транзакцией на `commit`.
 Чтение — строки базы, поверх которых по порядку накладываются незакоммиченные пачки. Дыры одной ленты —
 `MXSQLiteHoleSet` (алгебра без базы); набор комнаты в накладке хранится целиком и на коммите переписывается.
 Эхо и серверное событие — одна строка: по `unsigned.transaction_id` снимается строка `outgoing` (хук компонента
 исходящих) и переименовывается строка эха, если она есть в `event`.
 */
@interface MXSQLiteEventStore : NSObject <MXSQLiteEventStoring>
@end

NS_ASSUME_NONNULL_END
