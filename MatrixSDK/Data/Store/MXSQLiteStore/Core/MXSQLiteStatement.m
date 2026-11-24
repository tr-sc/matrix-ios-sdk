//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase_Private.h"

@implementation MXSQLiteStatement

- (instancetype)initWithStatement:(sqlite3_stmt *)statement handle:(sqlite3 *)handle
{
    self = [super init];
    if (self)
    {
        _statement = statement;
        _handle = handle;
    }
    return self;
}

- (void)finalizeStatement
{
    if (_statement)
    {
        sqlite3_finalize(_statement);
        _statement = NULL;
    }
}

- (void)dealloc
{
    [self finalizeStatement];
}

- (void)resetStatement
{
    sqlite3_reset(_statement);
    sqlite3_clear_bindings(_statement);
}

- (void)bindInt64:(int64_t)value at:(int)index
{
    sqlite3_bind_int64(_statement, index, value);
}

- (void)bindDouble:(double)value at:(int)index
{
    sqlite3_bind_double(_statement, index, value);
}

- (void)bindText:(NSString *)value at:(int)index
{
    if (!value)
    {
        sqlite3_bind_null(_statement, index);
        return;
    }
    sqlite3_bind_text(_statement, index, value.UTF8String, -1, SQLITE_TRANSIENT);
}

- (void)bindBlob:(NSData *)value at:(int)index
{
    if (!value)
    {
        sqlite3_bind_null(_statement, index);
        return;
    }
    // Пустой blob — не NULL: у sqlite3_bind_blob с нулевым указателем получился бы NULL.
    sqlite3_bind_blob(_statement, index, value.length ? value.bytes : "", (int)value.length, SQLITE_TRANSIENT);
}

- (void)bindNullAt:(int)index
{
    sqlite3_bind_null(_statement, index);
}

- (BOOL)stepRow:(NSError **)error
{
    int rc = sqlite3_step(_statement);
    if (rc == SQLITE_ROW)
    {
        return YES;
    }
    if (rc != SQLITE_DONE && error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
    }
    else if (error)
    {
        *error = nil;
    }
    return NO;
}

- (BOOL)execute:(NSError **)error
{
    int rc = sqlite3_step(_statement);
    if (rc == SQLITE_DONE || rc == SQLITE_ROW)
    {
        return YES;
    }
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
    }
    return NO;
}

- (int)columnCount
{
    return sqlite3_column_count(_statement);
}

- (BOOL)isNullAt:(int)column
{
    return sqlite3_column_type(_statement, column) == SQLITE_NULL;
}

- (int64_t)int64At:(int)column
{
    return sqlite3_column_int64(_statement, column);
}

- (double)doubleAt:(int)column
{
    return sqlite3_column_double(_statement, column);
}

- (NSString *)textAt:(int)column
{
    const unsigned char *text = sqlite3_column_text(_statement, column);
    if (!text)
    {
        return nil;
    }
    return [[NSString alloc] initWithBytes:text length:(NSUInteger)sqlite3_column_bytes(_statement, column) encoding:NSUTF8StringEncoding];
}

- (NSData *)blobAt:(int)column
{
    if (sqlite3_column_type(_statement, column) == SQLITE_NULL)
    {
        return nil;
    }
    const void *bytes = sqlite3_column_blob(_statement, column);
    int length = sqlite3_column_bytes(_statement, column);
    return bytes ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
}

@end
