//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLitePendingBatch.h"

#import "MXEvent.h"
#import "MXEventDecryptionResult.h"
#import "MXEventUnsignedData.h"
#import "MXEventContentRelatesTo.h"
#import "MXLog.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteRoomRegistry.h"
#import "MXSQLiteStoreComponent.h"

static NSData *MXSQLiteJSONData(NSDictionary *json)
{
    if (!json || ![NSJSONSerialization isValidJSONObject:json]) return nil;
    return [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
}

static NSDictionary *MXSQLiteJSONObject(NSData *data)
{
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

#pragma mark - Row

@implementation MXSQLiteEventRow
{
    MXEvent *_event;
    NSData *_json;
    NSData *_clear;
}

+ (NSString *)selectColumns
{
    return @"event_id, ord, sub, flags, type, sender, state_key, ts, thread_id, rel_type, relates_to, txn_id, json, clear";
}

- (instancetype)initWithEvent:(MXEvent *)event roomId:(NSString *)roomId ord:(int64_t)ord sub:(int64_t)sub exact:(BOOL)exact
{
    self = [super init];
    if (self)
    {
        _event = event;
        _eventId = [event.eventId copy];
        _roomId = [roomId copy];
        _ord = ord;
        _sub = sub;
        _type = [event.type copy] ?: @"";
        _sender = [event.sender copy];
        _stateKey = [event.stateKey copy];
        _ts = (int64_t)event.originServerTs;
        _threadId = [event.threadId copy];
        _relType = [event.relatesTo.relationType copy];
        _relatesTo = [event.relatesTo.eventId copy];
        _txnId = [event.unsignedData.transactionId copy];
        MXSQLiteEventFlags flags = 0;
        if (exact) flags |= MXSQLiteEventFlagExactOrder;
        if (event.isRedactedEvent) flags |= MXSQLiteEventFlagRedacted;
        if (event.isEncrypted) flags |= MXSQLiteEventFlagEncrypted;
        if (event.isEncrypted && event.decryptionError) flags |= MXSQLiteEventFlagDecryptFailed;
        _flags = flags;
    }
    return self;
}

- (instancetype)initWithStatement:(MXSQLiteStatement *)statement roomId:(NSString *)roomId
{
    self = [super init];
    if (self)
    {
        _roomId = [roomId copy];
        _eventId = [statement textAt:0] ?: @"";
        _ord = [statement int64At:1];
        _sub = [statement int64At:2];
        _flags = [statement int64At:3];
        _type = [statement textAt:4] ?: @"";
        _sender = [statement textAt:5];
        _stateKey = [statement textAt:6];
        _ts = [statement int64At:7];
        _threadId = [statement textAt:8];
        _relType = [statement textAt:9];
        _relatesTo = [statement textAt:10];
        _txnId = [statement textAt:11];
        _json = [statement blobAt:12];
        _clear = [statement isNullAt:13] ? nil : [statement blobAt:13];
    }
    return self;
}

- (BOOL)exactOrder
{
    return (_flags & MXSQLiteEventFlagExactOrder) != 0;
}

- (MXEvent *)event
{
    @synchronized (self)
    {
        if (!_event && _json)
        {
            NSDictionary *json = MXSQLiteJSONObject(_json);
            MXEvent *event = json ? [MXEvent modelFromJSON:json] : nil;
            if (event)
            {
                if (!event.roomId) event.roomId = _roomId;
                NSDictionary *clear = MXSQLiteJSONObject(_clear);
                if (clear && event.isEncrypted)
                {
                    // setClearData уведомляет только о «поздней» расшифровке (после ошибки) — у свежего события её нет.
                    MXEventDecryptionResult *result = [MXEventDecryptionResult new];
                    result.clearEvent = clear;
                    [event setClearData:result];
                }
            }
            _event = event;
        }
        return _event;
    }
}

- (NSData *)jsonData
{
    if (_json) return _json;
    MXEvent *event = self.event;
    NSMutableDictionary *json = [event.JSONDictionary mutableCopy];
    if (json && !json[@"room_id"]) json[@"room_id"] = _roomId;
    return MXSQLiteJSONData(json);
}

- (NSData *)clearData
{
    if (_clear || !_event) return _clear;
    if (_event.isEncrypted && _event.clearEvent && !(_flags & MXSQLiteEventFlagRedacted))
    {
        return MXSQLiteJSONData(_event.clearEvent.JSONDictionary);
    }
    return nil;
}

- (NSComparisonResult)compareOrder:(MXSQLiteEventRow *)other
{
    if (_ord != other.ord) return _ord < other.ord ? NSOrderedAscending : NSOrderedDescending;
    if (_sub != other.sub) return _sub < other.sub ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<row %@ %lld.%lld %@>", _eventId, _ord, _sub, _type];
}

@end

#pragma mark - Filter

@implementation MXSQLiteEventFilter

+ (instancetype)filterFromOrder:(int64_t)minOrder toOrder:(int64_t)maxOrder
{
    MXSQLiteEventFilter *filter = [self new];
    filter.minOrder = minOrder;
    filter.maxOrder = maxOrder;
    return filter;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _minOrder = INT64_MIN;
        _maxOrder = INT64_MAX;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    MXSQLiteEventFilter *copy = [MXSQLiteEventFilter new];
    copy.minOrder = _minOrder;
    copy.maxOrder = _maxOrder;
    copy.types = _types;
    copy.threadScope = _threadScope;
    copy.threadId = _threadId;
    copy.includeThreadRoot = _includeThreadRoot;
    copy.excludedSender = _excludedSender;
    copy.excludeRedacted = _excludeRedacted;
    copy.relatesTo = _relatesTo;
    copy.relType = _relType;
    copy.eventId = _eventId;
    return copy;
}

- (BOOL)matchesRow:(MXSQLiteEventRow *)row
{
    if (_eventId && ![row.eventId isEqualToString:_eventId]) return NO;
    if (row.ord < _minOrder || row.ord > _maxOrder) return NO;
    if (_types && ![_types containsObject:row.type]) return NO;
    switch (_threadScope)
    {
        case MXSQLiteThreadScopeAll:
            break;
        case MXSQLiteThreadScopeMain:
            if (row.threadId) return NO;
            break;
        case MXSQLiteThreadScopeThread:
        {
            BOOL inThread = [row.threadId isEqualToString:_threadId];
            BOOL isRoot = _includeThreadRoot && [row.eventId isEqualToString:_threadId];
            if (!inThread && !isRoot) return NO;
            break;
        }
    }
    if (_excludedSender && [row.sender isEqualToString:_excludedSender]) return NO;
    if (_excludeRedacted && (row.flags & MXSQLiteEventFlagRedacted)) return NO;
    if (_relatesTo && ![row.relatesTo isEqualToString:_relatesTo]) return NO;
    if (_relType && ![row.relType isEqualToString:_relType]) return NO;
    return YES;
}

/// Параметры по порядку с ?2 (rid — ?1) и текст условия — из одного обхода, чтобы не разъехались.
- (NSString *)sqlWithMinTimestamp:(int64_t)minTs values:(NSMutableArray *)values
{
    NSMutableString *sql = [NSMutableString stringWithString:@"rid = ?1"];
    __block int index = 1;
    NSString * (^param)(id) = ^NSString *(id value) {
        [values addObject:value];
        index++;
        return [NSString stringWithFormat:@"?%d", index];
    };
    if (_eventId)
    {
        [sql appendFormat:@" AND event_id = %@", param(_eventId)];
    }
    if (_minOrder != INT64_MIN) [sql appendFormat:@" AND ord >= %@", param(@(_minOrder))];
    if (_maxOrder != INT64_MAX) [sql appendFormat:@" AND ord <= %@", param(@(_maxOrder))];
    if (_types)
    {
        NSMutableArray *placeholders = [NSMutableArray array];
        for (NSString *type in [_types.allObjects sortedArrayUsingSelector:@selector(compare:)])
        {
            [placeholders addObject:param(type)];
        }
        [sql appendFormat:@" AND type IN (%@)", placeholders.count ? [placeholders componentsJoinedByString:@","] : @"NULL"];
    }
    switch (_threadScope)
    {
        case MXSQLiteThreadScopeAll:
            break;
        case MXSQLiteThreadScopeMain:
            [sql appendString:@" AND thread_id IS NULL"];
            break;
        case MXSQLiteThreadScopeThread:
            // Корень (если нужен) читается отдельной точечной выборкой: OR по event_id ломает индекс event_thread.
            [sql appendFormat:@" AND thread_id = %@", param(_threadId ?: @"")];
            break;
    }
    if (_excludedSender) [sql appendFormat:@" AND (sender IS NULL OR sender <> %@)", param(_excludedSender)];
    if (_excludeRedacted) [sql appendString:@" AND (flags & 2) = 0"];
    if (_relatesTo) [sql appendFormat:@" AND relates_to = %@", param(_relatesTo)];
    if (_relType) [sql appendFormat:@" AND rel_type = %@", param(_relType)];
    if (minTs != INT64_MIN) [sql appendFormat:@" AND (ts >= %@ OR state_key IS NOT NULL)", param(@(minTs))];
    return sql;
}

- (NSString *)sqlConditionWithMinTimestamp:(int64_t)minTs
{
    return [self sqlWithMinTimestamp:minTs values:[NSMutableArray array]];
}

- (int)nextParameterIndexWithMinTimestamp:(int64_t)minTs
{
    NSMutableArray *values = [NSMutableArray array];
    [self sqlWithMinTimestamp:minTs values:values];
    return (int)values.count + 2;
}

- (void)bindTo:(MXSQLiteStatement *)statement rid:(int64_t)rid minTimestamp:(int64_t)minTs
{
    NSMutableArray *values = [NSMutableArray array];
    [self sqlWithMinTimestamp:minTs values:values];
    [statement bindInt64:rid at:1];
    int index = 2;
    for (id value in values)
    {
        if ([value isKindOfClass:NSNumber.class]) [statement bindInt64:[value longLongValue] at:index];
        else [statement bindText:value at:index];
        index++;
    }
}

@end

#pragma mark - Pending room

@implementation MXSQLitePendingRoom

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _events = [NSMutableDictionary dictionary];
        _deletedEventIds = [NSMutableSet set];
        _holes = [NSMutableDictionary dictionary];
        _pendingRedactions = [NSMutableDictionary dictionary];
        _resolvedRedactions = [NSMutableSet set];
        _deleteBeforeTs = INT64_MIN;
    }
    return self;
}

- (NSUInteger)shadowCount
{
    return _events.count + _deletedEventIds.count;
}

- (BOOL)hasWrites
{
    return _events.count || _deletedEventIds.count || (_clearAll && !_deletedByFacade) || _deleteBeforeTs != INT64_MIN
        || _holes.count || _liveOrder || _reachedStart || _retentionFloorTs
        || _pendingRedactions.count || _resolvedRedactions.count;
}

@end

#pragma mark - Batch

@implementation MXSQLitePendingBatch

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _rooms = [NSMutableDictionary dictionary];
    }
    return self;
}

- (MXSQLitePendingRoom *)roomForWrite:(NSString *)roomId
{
    MXSQLitePendingRoom *room = _rooms[roomId];
    if (!room)
    {
        room = [MXSQLitePendingRoom new];
        _rooms[roomId] = room;
    }
    return room;
}

- (BOOL)hasWrites
{
    for (MXSQLitePendingRoom *room in _rooms.objectEnumerator)
    {
        if (room.hasWrites) return YES;
    }
    return NO;
}

#pragma mark Reads

+ (BOOL)layers:(NSArray<MXSQLitePendingBatch *> *)layers
 allowDatabaseRowsOfRoom:(NSString *)roomId
  minTimestamp:(int64_t *)minTs
   shadowCount:(NSUInteger *)shadowCount
{
    BOOL allow = YES;
    int64_t floorTs = INT64_MIN;
    NSUInteger shadow = 0;
    for (MXSQLitePendingBatch *layer in layers)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        if (!room) continue;
        if (room.clearAll) allow = NO;
        floorTs = MAX(floorTs, room.deleteBeforeTs);
        shadow += room.shadowCount;
    }
    if (minTs) *minTs = floorTs;
    if (shadowCount) *shadowCount = shadow;
    return allow;
}

+ (NSArray<MXSQLiteEventRow *> *)applyLayers:(NSArray<MXSQLitePendingBatch *> *)layers
                                      roomId:(NSString *)roomId
                                      toRows:(NSArray<MXSQLiteEventRow *> *)rows
                                      filter:(MXSQLiteEventFilter *)filter
{
    NSMutableDictionary<NSString *, MXSQLiteEventRow *> *result = nil;
    for (MXSQLitePendingBatch *layer in layers)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        if (!room) continue;
        if (!result)
        {
            result = [NSMutableDictionary dictionaryWithCapacity:rows.count + room.events.count];
            for (MXSQLiteEventRow *row in rows) result[row.eventId] = row;
        }
        if (room.clearAll) [result removeAllObjects];
        if (room.deleteBeforeTs != INT64_MIN)
        {
            for (MXSQLiteEventRow *row in result.allValues)
            {
                if (row.ts < room.deleteBeforeTs && !row.stateKey) [result removeObjectForKey:row.eventId];
            }
        }
        for (NSString *eventId in room.deletedEventIds) [result removeObjectForKey:eventId];
        for (MXSQLiteEventRow *row in room.events.objectEnumerator)
        {
            if ([filter matchesRow:row]) result[row.eventId] = row;
            else [result removeObjectForKey:row.eventId];
        }
    }
    NSArray<MXSQLiteEventRow *> *merged = result ? result.allValues : rows;
    return [merged sortedArrayUsingSelector:@selector(compareOrder:)];
}

#pragma mark Write

- (BOOL)writeWithConnection:(MXSQLiteConnection *)connection
                      rooms:(MXSQLiteRoomRegistry *)registry
                     commit:(MXSQLiteCommitContext *)commit
                      error:(NSError **)error
{
    for (NSString *roomId in _rooms)
    {
        MXSQLitePendingRoom *room = _rooms[roomId];
        if (!room.hasWrites) continue;
        int64_t rid = [registry ensureRidForRoomId:roomId connection:connection error:error];
        if (rid == MXSQLiteNoRoom) return NO;
        if (![self writeRoom:room rid:rid connection:connection commit:commit error:error]) return NO;
        [commit touchRoomId:roomId];
    }
    return YES;
}

- (BOOL)writeRoom:(MXSQLitePendingRoom *)room
              rid:(int64_t)rid
       connection:(MXSQLiteConnection *)connection
           commit:(MXSQLiteCommitContext *)commit
            error:(NSError **)error
{
    void (^bindRid)(MXSQLiteStatement *) = ^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; };

    if (room.clearAll)
    {
        for (NSString *sql in @[@"DELETE FROM event WHERE rid = ?1",
                                @"DELETE FROM hole WHERE rid = ?1",
                                @"DELETE FROM redaction_pending WHERE rid = ?1",
                                @"UPDATE room SET live_ord = NULL, reached_start = 0 WHERE rid = ?1"])
        {
            if (![connection run:sql bind:bindRid error:error]) return NO;
        }
    }
    if (room.deleteBeforeTs != INT64_MIN)
    {
        if (![connection run:@"DELETE FROM event WHERE rid = ?1 AND ts < ?2 AND state_key IS NULL" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindInt64:room.deleteBeforeTs at:2];
        } error:error]) return NO;
    }

    NSMutableSet<NSString *> *renamed = [NSMutableSet set];
    for (MXSQLiteEventRow *row in room.events.objectEnumerator)
    {
        if (row.replacesEventId) [renamed addObject:row.replacesEventId];
    }
    for (NSString *eventId in room.deletedEventIds)
    {
        if ([renamed containsObject:eventId]) continue;
        if (![connection run:@"DELETE FROM event WHERE event_id = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindText:eventId at:1];
        } error:error]) return NO;
    }

    NSUInteger written = 0;
    for (MXSQLiteEventRow *row in room.events.objectEnumerator)
    {
        NSData *json = row.jsonData;
        if (!json)
        {
            MXLogWarning(@"[MXSQLiteEventStore] event %@ is not JSON-serialisable, not stored", row.eventId);
            continue;
        }
        if (row.replacesEventId)
        {
            // Эхо и серверное событие — одна строка: строка эха получает серверный event_id и остаётся той же.
            if (![connection run:@"UPDATE event SET event_id = ?2 WHERE event_id = ?1 "
                                  "AND NOT EXISTS (SELECT 1 FROM event WHERE event_id = ?2)" bind:^(MXSQLiteStatement *s) {
                [s bindText:row.replacesEventId at:1];
                [s bindText:row.eventId at:2];
            } error:error]) return NO;
        }
        // Позиция занята другим событием (временный ord) — освободить, иначе UNIQUE(event_pos) откатит весь коммит.
        if (![connection run:@"DELETE FROM event WHERE rid = ?1 AND ord = ?2 AND sub = ?3 AND event_id <> ?4" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindInt64:row.ord at:2];
            [s bindInt64:row.sub at:3];
            [s bindText:row.eventId at:4];
        } error:error]) return NO;
        NSData *clear = row.clearData;
        if (![connection run:@"INSERT INTO event (rid, ord, sub, event_id, type, sender, state_key, ts, thread_id, rel_type, "
                              "relates_to, txn_id, flags, json, clear) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15) "
                              "ON CONFLICT(event_id) DO UPDATE SET rid = excluded.rid, ord = excluded.ord, sub = excluded.sub, "
                              "type = excluded.type, sender = excluded.sender, state_key = excluded.state_key, ts = excluded.ts, "
                              "thread_id = excluded.thread_id, rel_type = excluded.rel_type, relates_to = excluded.relates_to, "
                              "txn_id = COALESCE(excluded.txn_id, event.txn_id), flags = excluded.flags, json = excluded.json, "
                              "clear = CASE WHEN (excluded.flags & 2) <> 0 THEN NULL ELSE COALESCE(excluded.clear, event.clear) END"
                         bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindInt64:row.ord at:2];
            [s bindInt64:row.sub at:3];
            [s bindText:row.eventId at:4];
            [s bindText:row.type at:5];
            [s bindText:row.sender at:6];
            [s bindText:row.stateKey at:7];
            [s bindInt64:row.ts at:8];
            [s bindText:row.threadId at:9];
            [s bindText:row.relType at:10];
            [s bindText:row.relatesTo at:11];
            [s bindText:row.txnId at:12];
            [s bindInt64:row.flags at:13];
            [s bindBlob:json at:14];
            [s bindBlob:clear at:15];
        } error:error]) return NO;
        written++;
    }
    [commit countEvents:written];

    for (NSString *space in room.holes)
    {
        if (![connection run:@"DELETE FROM hole WHERE rid = ?1 AND space = ?2" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindText:space at:2];
        } error:error]) return NO;
        for (MXRoomHole *hole in room.holes[space].holes)
        {
            if (![connection run:@"INSERT INTO hole (rid, space, lo, hi, hi_token, lo_token) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
                            bind:^(MXSQLiteStatement *s) {
                [s bindInt64:rid at:1];
                [s bindText:space at:2];
                [s bindInt64:hole.lowerOrder at:3];
                [s bindInt64:hole.upperOrder at:4];
                [s bindText:hole.backwardToken at:5];
                [s bindText:hole.forwardToken at:6];
            } error:error]) return NO;
        }
    }

    if (room.liveOrder)
    {
        id live = room.liveOrder;
        if (![connection run:@"UPDATE room SET live_ord = ?2 WHERE rid = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            if ([live isKindOfClass:NSNumber.class]) [s bindInt64:[live longLongValue] at:2];
            else [s bindNullAt:2];
        } error:error]) return NO;
    }
    if (room.reachedStart)
    {
        if (![connection run:@"UPDATE room SET reached_start = ?2 WHERE rid = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindInt64:room.reachedStart.boolValue ? 1 : 0 at:2];
        } error:error]) return NO;
    }
    if (room.retentionFloorTs)
    {
        if (![connection run:@"UPDATE room SET retention_floor_ts = ?2 WHERE rid = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindInt64:room.retentionFloorTs.longLongValue at:2];
        } error:error]) return NO;
    }

    for (NSString *target in room.resolvedRedactions)
    {
        if (![connection run:@"DELETE FROM redaction_pending WHERE target_event_id = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindText:target at:1];
        } error:error]) return NO;
    }
    for (NSString *target in room.pendingRedactions)
    {
        NSData *json = MXSQLiteJSONData(room.pendingRedactions[target]);
        if (!json) continue;
        if (![connection run:@"INSERT OR REPLACE INTO redaction_pending (target_event_id, rid, json) VALUES (?1, ?2, ?3)"
                        bind:^(MXSQLiteStatement *s) {
            [s bindText:target at:1];
            [s bindInt64:rid at:2];
            [s bindBlob:json at:3];
        } error:error]) return NO;
    }
    return YES;
}

@end
