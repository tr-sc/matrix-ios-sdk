//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase.h"

#import <SQLCipher/sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSError *MXSQLiteMakeError(MXSQLiteErrorCode code, int resultCode, NSString * _Nullable message);
FOUNDATION_EXTERN NSString *MXSQLiteHandleMessage(sqlite3 * _Nullable handle);

@interface MXSQLiteStatement ()
{
    @package
    sqlite3_stmt *_statement;
    sqlite3 *_handle;
}
- (instancetype)initWithStatement:(sqlite3_stmt *)statement handle:(sqlite3 *)handle;
- (void)finalizeStatement;
- (void)resetStatement;
@end

@interface MXSQLiteConnection ()
{
    @package
    sqlite3 *_handle;
}
- (instancetype)initWithHandle:(sqlite3 *)handle readOnly:(BOOL)readOnly;
- (void)closeHandle;
@end

typedef NS_ENUM(NSInteger, MXSQLiteRole)
{
    MXSQLiteRoleWriter,
    MXSQLiteRoleReader,
    MXSQLiteRoleReadOnly,
};

/// Открывает одно соединение: SQLCipher подтверждён, ключ применён и проверен чтением, PRAGMA роли выставлены.
@interface MXSQLiteConnectionOpener : NSObject

/// `PRAGMA key = "x'<ключ><соль>'"` с завершающим нулём. Вызывающий затирает буфер после открытия.
+ (NSMutableData *)keySpecWithKey:(NSData *)key salt:(NSData *)salt;

+ (nullable MXSQLiteConnection *)openConnectionAtURL:(NSURL *)url
                                             keySpec:(NSData *)keySpec
                                                role:(MXSQLiteRole)role
                                               error:(NSError **)error;

@end

/// Атрибуты и удаление файлов базы (сам файл, `-wal`, `-shm`).
@interface MXSQLiteDatabaseFiles : NSObject

/// Класс защиты на каталог и файлы, исключение из бэкапа.
+ (void)protectFilesAtURL:(NSURL *)url;

/// Исключить из бэкапа каталог базы: признак накрывает и файлы, которые появятся в нём позже.
+ (void)excludeDirectoryFromBackupOfURL:(NSURL *)url;

+ (void)removeFilesAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
