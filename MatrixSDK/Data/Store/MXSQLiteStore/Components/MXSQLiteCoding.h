//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

@class MXSQLiteConnection, MXSQLiteStatement, MXSQLiteStoreContext;

NS_ASSUME_NONNULL_BEGIN

/// NSKeyedArchiver без secure coding — как `MXFileStore` (модели SDK его не поддерживают). nil — не вышло.
FOUNDATION_EXPORT NSData * _Nullable MXSQLiteArchive(id _Nullable object);
/// Обратно; битые данные — nil, а не исключение.
FOUNDATION_EXPORT id _Nullable MXSQLiteUnarchive(NSData * _Nullable data);

/// JSON-объект → UTF-8. nil — не сериализуется.
FOUNDATION_EXPORT NSData * _Nullable MXSQLiteJSONData(id _Nullable object);
FOUNDATION_EXPORT id _Nullable MXSQLiteJSONObject(NSData * _Nullable data);

/// Привязать NSString / NSNumber (целое) / NSData; nil и NSNull — NULL.
FOUNDATION_EXPORT void MXSQLiteBindValue(MXSQLiteStatement *statement, id _Nullable value, int index);

typedef NS_ENUM(NSInteger, MXSQLiteValueKind)
{
    MXSQLiteValueKindText,
    MXSQLiteValueKindInteger,
    MXSQLiteValueKindBlob,
};

/// Колонка строки `room` с читателя. `NSNull` — NULL или комнаты нет; nil — база не открыта.
FOUNDATION_EXPORT id _Nullable MXSQLiteReadRoomColumn(MXSQLiteStoreContext *context, NSString *roomId,
                                                     NSString *column, MXSQLiteValueKind kind);

/// `UPDATE room SET column = value`, создавая строку `room`. Только в транзакции писателя.
FOUNDATION_EXPORT BOOL MXSQLiteWriteRoomColumn(MXSQLiteConnection *connection, MXSQLiteStoreContext *context,
                                               NSString *roomId, NSString *column, id _Nullable value,
                                               NSError **error);

NS_ASSUME_NONNULL_END
