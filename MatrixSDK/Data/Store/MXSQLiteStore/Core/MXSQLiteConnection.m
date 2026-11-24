//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase_Private.h"

@interface MXSQLiteConnection ()
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLiteStatement *> *statements;
@end

@implementation MXSQLiteConnection

- (instancetype)initWithHandle:(sqlite3 *)handle readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self)
    {
        _handle = handle;
        _readOnly = readOnly;
        _statements = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)closeHandle
{
    for (MXSQLiteStatement *statement in _statements.allValues)
    {
        [statement finalizeStatement];
    }
    [_statements removeAllObjects];
    if (_handle)
    {
        sqlite3_close_v2(_handle);
        _handle = NULL;
    }
}

- (void)dealloc
{
    [self closeHandle];
}

- (BOOL)execute:(NSString *)sql error:(NSError **)error
{
    char *message = NULL;
    int rc = sqlite3_exec(_handle, sql.UTF8String, NULL, NULL, &message);
    if (rc == SQLITE_OK)
    {
        return YES;
    }
    NSString *text = message ? [NSString stringWithUTF8String:message] : MXSQLiteHandleMessage(_handle);
    sqlite3_free(message);
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, text);
    }
    return NO;
}

- (MXSQLiteStatement *)prepare:(NSString *)sql error:(NSError **)error
{
    MXSQLiteStatement *cached = _statements[sql];
    if (cached)
    {
        [cached resetStatement];
        return cached;
    }

    sqlite3_stmt *raw = NULL;
    int rc = sqlite3_prepare_v3(_handle, sql.UTF8String, -1, SQLITE_PREPARE_PERSISTENT, &raw, NULL);
    if (rc != SQLITE_OK || !raw)
    {
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
        }
        return nil;
    }
    MXSQLiteStatement *statement = [[MXSQLiteStatement alloc] initWithStatement:raw handle:_handle];
    _statements[sql] = statement;
    return statement;
}

- (BOOL)run:(NSString *)sql bind:(void (^NS_NOESCAPE)(MXSQLiteStatement *))bind error:(NSError **)error
{
    MXSQLiteStatement *statement = [self prepare:sql error:error];
    if (!statement)
    {
        return NO;
    }
    if (bind)
    {
        bind(statement);
    }
    BOOL ok = [statement execute:error];
    [statement resetStatement];
    return ok;
}

- (NSArray *)query:(NSString *)sql
              bind:(void (^NS_NOESCAPE)(MXSQLiteStatement *))bind
               row:(id (^NS_NOESCAPE)(MXSQLiteStatement *))row
             error:(NSError **)error
{
    MXSQLiteStatement *statement = [self prepare:sql error:error];
    if (!statement)
    {
        return nil;
    }
    if (bind)
    {
        bind(statement);
    }

    NSMutableArray *rows = [NSMutableArray array];
    NSError *stepError;
    while ([statement stepRow:&stepError])
    {
        id object = row(statement);
        if (object)
        {
            [rows addObject:object];
        }
    }
    [statement resetStatement];
    if (stepError)
    {
        if (error)
        {
            *error = stepError;
        }
        return nil;
    }
    return rows;
}

- (NSString *)stringForQuery:(NSString *)sql error:(NSError **)error
{
    return [self query:sql bind:nil row:^id(MXSQLiteStatement *statement) {
        return [statement textAt:0] ?: @"";
    } error:error].firstObject;
}

- (int64_t)int64ForQuery:(NSString *)sql defaultValue:(int64_t)defaultValue error:(NSError **)error
{
    NSNumber *value = [self query:sql bind:nil row:^id(MXSQLiteStatement *statement) {
        return @([statement int64At:0]);
    } error:error].firstObject;
    return value ? value.longLongValue : defaultValue;
}

- (int64_t)lastInsertRowId
{
    return sqlite3_last_insert_rowid(_handle);
}

- (int)changes
{
    return sqlite3_changes(_handle);
}

@end
