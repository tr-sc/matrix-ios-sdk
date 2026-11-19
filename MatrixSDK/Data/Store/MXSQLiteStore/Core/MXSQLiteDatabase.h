//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const MXSQLiteErrorDomain;

typedef NS_ERROR_ENUM(MXSQLiteErrorDomain, MXSQLiteErrorCode)
{
    /// `sqlite3_open_v2` не открыл файл (нет каталога, нет прав, файла нет при открытии только на чтение).
    MXSQLiteErrorOpenFailed = 1,
    /// Под нами не SQLCipher: `PRAGMA cipher_version` пустой. База завелась бы открытым текстом — отказ.
    MXSQLiteErrorCipherUnavailable,
    /// Ключ не подошёл к файлу (чужой файл, сброшенный Keychain, открытый текст на том же пути).
    MXSQLiteErrorKeyRejected,
    /// Ключ или соль неверной длины.
    MXSQLiteErrorInvalidKey,
    /// Ошибка выполнения SQL. `userInfo[MXSQLiteErrorResultCodeKey]` — код SQLite.
    MXSQLiteErrorStatementFailed,
    /// Ключа нет в Keychain и создать его нельзя (до первой разблокировки, только чтение).
    MXSQLiteErrorKeyUnavailable,
    /// Схема не подготовилась.
    MXSQLiteErrorSchema,
    /// База закрыта.
    MXSQLiteErrorClosed,
};

/// Код результата SQLite (`NSNumber`) в `userInfo` ошибок `MXSQLiteErrorStatementFailed` и `MXSQLiteErrorOpenFailed`.
FOUNDATION_EXPORT NSString *const MXSQLiteErrorResultCodeKey;

/// Длина ключа SQLCipher в байтах (сырой ключ AES-256, без KDF).
FOUNDATION_EXPORT NSUInteger const MXSQLiteKeyLength;
/// Длина соли в байтах. Соль не лежит в файле: первые 32 байта — открытый заголовок SQLite (против 0xdead10cc).
FOUNDATION_EXPORT NSUInteger const MXSQLiteSaltLength;
/// Размер открытого заголовка файла.
FOUNDATION_EXPORT NSUInteger const MXSQLitePlaintextHeaderSize;

/**
 Подготовленный запрос. Индексы привязки с 1, колонок — с 0, как в SQLite.
 Живёт в кеше соединения; использовать только внутри блока, который выдал соединение.
 */
@interface MXSQLiteStatement : NSObject

- (void)bindInt64:(int64_t)value at:(int)index;
- (void)bindDouble:(double)value at:(int)index;
/// nil — NULL.
- (void)bindText:(nullable NSString *)value at:(int)index;
/// nil — NULL.
- (void)bindBlob:(nullable NSData *)value at:(int)index;
- (void)bindNullAt:(int)index;

/// Следующая строка. NO — строк больше нет или ошибка (тогда `error` заполнен).
- (BOOL)stepRow:(NSError **)error;
/// Выполнить запрос без строк (INSERT/UPDATE/DELETE).
- (BOOL)execute:(NSError **)error;

- (int)columnCount;
- (BOOL)isNullAt:(int)column;
- (int64_t)int64At:(int)column;
- (double)doubleAt:(int)column;
- (nullable NSString *)textAt:(int)column;
- (nullable NSData *)blobAt:(int)column;

@end

/**
 Одно соединение SQLite. Не потокобезопасно: выдаётся только внутри блоков `MXSQLiteDatabase`.
 */
@interface MXSQLiteConnection : NSObject

@property (nonatomic, readonly) BOOL readOnly;

/// Один или несколько запросов без параметров.
- (BOOL)execute:(NSString *)sql error:(NSError **)error;

/// Подготовленный запрос из кеша соединения, сброшенный и без привязок.
- (nullable MXSQLiteStatement *)prepare:(NSString *)sql error:(NSError **)error;

/// Запрос без строк с привязкой параметров.
- (BOOL)run:(NSString *)sql bind:(nullable void (^NS_NOESCAPE)(MXSQLiteStatement *statement))bind error:(NSError **)error;

/// Запрос со строками: `row` превращает текущую строку в объект (nil — строка пропускается).
- (nullable NSArray *)query:(NSString *)sql
                       bind:(nullable void (^NS_NOESCAPE)(MXSQLiteStatement *statement))bind
                        row:(id _Nullable (^NS_NOESCAPE)(MXSQLiteStatement *statement))row
                      error:(NSError **)error;

/// Первая колонка первой строки как текст (для PRAGMA).
- (nullable NSString *)stringForQuery:(NSString *)sql error:(NSError **)error;

/// Первая колонка первой строки как число; `defaultValue`, если строк нет.
- (int64_t)int64ForQuery:(NSString *)sql defaultValue:(int64_t)defaultValue error:(NSError **)error;

@property (nonatomic, readonly) int64_t lastInsertRowId;
@property (nonatomic, readonly) int changes;

@end

typedef NS_ENUM(NSInteger, MXSQLiteCheckpointMode)
{
    MXSQLiteCheckpointPassive,
    MXSQLiteCheckpointTruncate,
};

/// Блок записи. Вернуть NO — откат транзакции (заполните `error`).
typedef BOOL (^MXSQLiteWriteBody)(MXSQLiteConnection *connection, NSError **error);

/**
 Зашифрованная база SQLCipher (ADR-0022 §iOS): сырой ключ без KDF, соль вне файла, открытый заголовок 32 байта,
 WAL, один писатель на последовательной очереди и пул читателей.

 Открытие fail-closed: пустой `cipher_version` (символы sqlite3 разрешились не в SQLCipher, а в копию SQLite внутри
 MatrixSDKCrypto) — ошибка, а не база открытым текстом.
 */
@interface MXSQLiteDatabase : NSObject

/**
 Открыть или создать базу.

 @param url файл базы; каталог создаётся.
 @param key 32 байта.
 @param salt 16 байт.
 @param readOnly YES — только читатели (`SQLITE_OPEN_READONLY`, `query_only`), писателя нет. Для NSE. Файл должен существовать.
 @param readerCount размер пула читателей (минимум 1).
 */
+ (nullable instancetype)openAtURL:(NSURL *)url
                               key:(NSData *)key
                              salt:(NSData *)salt
                          readOnly:(BOOL)readOnly
                       readerCount:(NSUInteger)readerCount
                             error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) BOOL readOnly;
/// `PRAGMA cipher_version` писателя (или первого читателя). Непустой у открытой базы.
@property (nonatomic, readonly) NSString *cipherVersion;
/// Сколько длилось открытие (все соединения, ключ, PRAGMA), мс.
@property (nonatomic, readonly) double openMilliseconds;
@property (atomic, readonly, getter=isClosed) BOOL closed;

/**
 Транзакция записи `BEGIN IMMEDIATE … COMMIT` на очереди писателя, асинхронно.
 `completion` — на очереди писателя, nil при успехе.
 */
- (void)write:(MXSQLiteWriteBody)body completion:(nullable void (^)(NSError * _Nullable error))completion;

/// То же синхронно. Нельзя звать с очереди писателя (assert) — используйте соединение, которое уже есть.
- (BOOL)writeSync:(MXSQLiteWriteBody NS_NOESCAPE)body error:(NSError **)error;

/// Выполнить блок на очереди писателя без транзакции (схема, PRAGMA, чекпойнт). Синхронно.
- (BOOL)withWriter:(BOOL (^NS_NOESCAPE)(MXSQLiteConnection *connection, NSError **error))body error:(NSError **)error;

/// YES, если текущий поток — очередь писателя этой базы.
@property (nonatomic, readonly) BOOL isOnWriterQueue;

/**
 Чтение на свободном читателе пула; с любого потока, включая main. Видит только закоммиченное.
 Блокирует, пока все читатели заняты.
 */
- (nullable id)read:(id _Nullable (^NS_NOESCAPE)(MXSQLiteConnection *connection))body;

/// Чекпойнт WAL на очереди писателя.
- (void)checkpoint:(MXSQLiteCheckpointMode)mode;

/// Размер базы с WAL в байтах.
- (uint64_t)fileSize;

/// Закрыть все соединения; ждёт текущую запись. Повторный вызов безопасен.
- (void)close;

/// Удалить файл базы и `-wal`, `-shm`, `-journal`. База должна быть закрыта.
+ (void)removeFilesAtURL:(NSURL *)url;

/// Только для тестов fail-closed: запрос вместо `PRAGMA cipher_version;` (nil — вернуть обычный).
/// `SELECT ''` изображает SQLite без SQLCipher.
+ (void)setCipherVersionQueryForTesting:(nullable NSString *)query;

/// Образ, в который разрешился `sqlite3_open_v2` при линковке MatrixSDK. Должен быть SQLCipher, а не MatrixSDKCrypto.
@property (class, nonatomic, readonly) NSString *sqliteLibraryPath;

@end

NS_ASSUME_NONNULL_END
