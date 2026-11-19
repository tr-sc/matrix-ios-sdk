//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteRoomRegistry.h"

#import <os/lock.h>

#import "MXSQLiteDatabase.h"

int64_t const MXSQLiteNoRoom = 0;

@interface MXSQLiteRoomRegistry ()
{
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, NSNumber *> *_ridByRoomId;
    NSMutableDictionary<NSNumber *, NSString *> *_roomIdByRid;
}
@end

@implementation MXSQLiteRoomRegistry

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _lock = OS_UNFAIR_LOCK_INIT;
        _ridByRoomId = [NSMutableDictionary dictionary];
        _roomIdByRid = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)remember:(NSString *)roomId rid:(int64_t)rid
{
    os_unfair_lock_lock(&_lock);
    _ridByRoomId[roomId] = @(rid);
    _roomIdByRid[@(rid)] = roomId;
    os_unfair_lock_unlock(&_lock);
}

- (int64_t)cachedRidForRoomId:(NSString *)roomId
{
    os_unfair_lock_lock(&_lock);
    NSNumber *rid = _ridByRoomId[roomId];
    os_unfair_lock_unlock(&_lock);
    return rid ? rid.longLongValue : MXSQLiteNoRoom;
}

- (NSString *)cachedRoomIdForRid:(int64_t)rid
{
    os_unfair_lock_lock(&_lock);
    NSString *roomId = _roomIdByRid[@(rid)];
    os_unfair_lock_unlock(&_lock);
    return roomId;
}

- (int64_t)lookupRoomId:(NSString *)roomId connection:(MXSQLiteConnection *)connection
{
    NSNumber *rid = [connection query:@"SELECT rid FROM room WHERE room_id = ?1"
                                 bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                                  row:^id(MXSQLiteStatement *statement) { return @([statement int64At:0]); }
                                error:nil].firstObject;
    return rid ? rid.longLongValue : MXSQLiteNoRoom;
}

- (int64_t)ridForRoomId:(NSString *)roomId connection:(MXSQLiteConnection *)connection
{
    int64_t rid = [self cachedRidForRoomId:roomId];
    if (rid != MXSQLiteNoRoom)
    {
        return rid;
    }
    rid = [self lookupRoomId:roomId connection:connection];
    if (rid != MXSQLiteNoRoom)
    {
        [self remember:roomId rid:rid];
    }
    return rid;
}

- (int64_t)ensureRidForRoomId:(NSString *)roomId connection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    int64_t rid = [self ridForRoomId:roomId connection:connection];
    if (rid != MXSQLiteNoRoom)
    {
        return rid;
    }
    if (![connection run:@"INSERT INTO room (room_id) VALUES (?1)"
                    bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                   error:error])
    {
        return MXSQLiteNoRoom;
    }
    rid = connection.lastInsertRowId;
    // Кеш пополняется сразу: если транзакция откатится, rid останется в кеше, но строки не будет. Следующая
    // транзакция найдёт его в кеше и вставит строки с несуществующим rid — поэтому откат обязан звать `reset`.
    [self remember:roomId rid:rid];
    return rid;
}

- (NSArray<NSString *> *)allRoomIdsWithConnection:(MXSQLiteConnection *)connection
{
    NSArray<NSArray *> *rows = [connection query:@"SELECT rid, room_id FROM room"
                                            bind:nil
                                             row:^id(MXSQLiteStatement *statement) {
        return @[@([statement int64At:0]), [statement textAt:1] ?: @""];
    } error:nil] ?: @[];
    NSMutableArray<NSString *> *roomIds = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSArray *row in rows)
    {
        [self remember:row[1] rid:[row[0] longLongValue]];
        [roomIds addObject:row[1]];
    }
    return roomIds;
}

- (void)forgetRoomId:(NSString *)roomId
{
    os_unfair_lock_lock(&_lock);
    NSNumber *rid = _ridByRoomId[roomId];
    [_ridByRoomId removeObjectForKey:roomId];
    if (rid)
    {
        [_roomIdByRid removeObjectForKey:rid];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)reset
{
    os_unfair_lock_lock(&_lock);
    [_ridByRoomId removeAllObjects];
    [_roomIdByRid removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

@end
