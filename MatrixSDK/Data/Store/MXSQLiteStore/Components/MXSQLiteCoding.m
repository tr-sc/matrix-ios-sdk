//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteCoding.h"

#import "MXLog.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteRoomRegistry.h"
#import "MXSQLiteStoreComponent.h"

NSData *MXSQLiteArchive(id object)
{
    if (!object)
    {
        return nil;
    }
    NSError *error;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:&error];
    if (!data)
    {
        MXLogWarning(@"[MXSQLiteStore] Cannot archive %@: %@", NSStringFromClass([object class]), error);
    }
    return data;
}

id MXSQLiteUnarchive(NSData *data)
{
    if (!data.length)
    {
        return nil;
    }
    @try
    {
        NSError *error;
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
        if (!unarchiver)
        {
            MXLogWarning(@"[MXSQLiteStore] Cannot unarchive: %@", error);
            return nil;
        }
        unarchiver.requiresSecureCoding = NO;
        id object = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
        return object;
    }
    @catch (NSException *exception)
    {
        MXLogWarning(@"[MXSQLiteStore] Cannot unarchive: %@", exception);
        return nil;
    }
}

NSData *MXSQLiteJSONData(id object)
{
    if (!object || ![NSJSONSerialization isValidJSONObject:object])
    {
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

id MXSQLiteJSONObject(NSData *data)
{
    if (!data.length)
    {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

void MXSQLiteBindValue(MXSQLiteStatement *statement, id value, int index)
{
    if ([value isKindOfClass:NSString.class])
    {
        [statement bindText:value at:index];
    }
    else if ([value isKindOfClass:NSNumber.class])
    {
        [statement bindInt64:[value longLongValue] at:index];
    }
    else if ([value isKindOfClass:NSData.class])
    {
        [statement bindBlob:value at:index];
    }
    else
    {
        [statement bindNullAt:index];
    }
}

static id MXSQLiteColumnValue(MXSQLiteStatement *statement, int column, MXSQLiteValueKind kind)
{
    if ([statement isNullAt:column])
    {
        return NSNull.null;
    }
    switch (kind)
    {
        case MXSQLiteValueKindText:
            return [statement textAt:column] ?: NSNull.null;
        case MXSQLiteValueKindInteger:
            return @([statement int64At:column]);
        case MXSQLiteValueKindBlob:
            return [statement blobAt:column] ?: NSNull.null;
    }
    return NSNull.null;
}

id MXSQLiteReadRoomColumn(MXSQLiteStoreContext *context, NSString *roomId, NSString *column, MXSQLiteValueKind kind)
{
    MXSQLiteDatabase *database = context.database;
    if (!database)
    {
        return nil;
    }
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM room WHERE room_id = ?1", column];
    id value = [database read:^id(MXSQLiteConnection *connection) {
        return [connection query:sql
                            bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                             row:^id(MXSQLiteStatement *statement) { return MXSQLiteColumnValue(statement, 0, kind); }
                           error:nil].firstObject;
    }];
    return value ?: NSNull.null;
}

BOOL MXSQLiteWriteRoomColumn(MXSQLiteConnection *connection, MXSQLiteStoreContext *context, NSString *roomId,
                             NSString *column, id value, NSError **error)
{
    int64_t rid = [context.rooms ensureRidForRoomId:roomId connection:connection error:error];
    if (rid == MXSQLiteNoRoom)
    {
        return NO;
    }
    NSString *sql = [NSString stringWithFormat:@"UPDATE room SET %@ = ?1 WHERE rid = ?2", column];
    return [connection run:sql bind:^(MXSQLiteStatement *statement) {
        MXSQLiteBindValue(statement, value, 1);
        [statement bindInt64:rid at:2];
    } error:error];
}
