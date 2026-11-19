//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

@class MXSQLiteConnection;

NS_ASSUME_NONNULL_BEGIN

/// rid 0 — «комнаты нет».
FOUNDATION_EXPORT int64_t const MXSQLiteNoRoom;

/**
 `room_id ↔ rid` (короткий суррогат во всех таблицах). Потокобезопасный кеш поверх таблицы `room`.
 Создание строки — только внутри транзакции писателя.
 */
@interface MXSQLiteRoomRegistry : NSObject

/// rid из кеша или из базы через читателя `connection`. `MXSQLiteNoRoom`, если комнаты нет.
- (int64_t)ridForRoomId:(NSString *)roomId connection:(MXSQLiteConnection *)connection;

/// rid, создавая строку `room`. `connection` — писатель внутри транзакции.
- (int64_t)ensureRidForRoomId:(NSString *)roomId connection:(MXSQLiteConnection *)connection error:(NSError **)error;

/// Только кеш, без базы.
- (int64_t)cachedRidForRoomId:(NSString *)roomId;
- (nullable NSString *)cachedRoomIdForRid:(int64_t)rid;

/// Все комнаты базы (заполняет кеш).
- (NSArray<NSString *> *)allRoomIdsWithConnection:(MXSQLiteConnection *)connection;

/// После удаления комнаты из базы.
- (void)forgetRoomId:(NSString *)roomId;
/// После удаления всех данных.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
