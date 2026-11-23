//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteAggregationsStore.h"

#import <os/lock.h>

#import "MXLog.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteOverlay.h"
#import "MXSQLiteStore.h"
#import "MXTimelineStore.h"

/// Строка накладки: реакция или связь и комната, к которой она относится.
@interface MXSQLiteReactionEntry : NSObject
@property (nonatomic, copy) NSString *roomId;
@property (nonatomic, nullable) MXReactionCount *count;
@property (nonatomic, nullable) MXReactionRelation *relation;
@end

@implementation MXSQLiteReactionEntry
@end

/// Копия полей, которые хранит стор (как у Realm: `localEchoesOperations` не хранятся). Накладка не делит объекты с
/// вызывающим: тот меняет полученный `MXReactionCount` и только потом сохраняет.
static MXReactionCount *MXSQLiteCopyCount(MXReactionCount *source)
{
    MXReactionCount *count = [MXReactionCount new];
    count.reaction = source.reaction;
    count.count = source.count;
    count.originServerTs = source.originServerTs;
    count.myUserReactionEventId = source.myUserReactionEventId;
    return count;
}

static MXReactionRelation *MXSQLiteCopyRelation(MXReactionRelation *source)
{
    MXReactionRelation *relation = [MXReactionRelation new];
    relation.eventId = source.eventId;
    relation.reaction = source.reaction;
    relation.reactionEventId = source.reactionEventId;
    relation.originServerTs = source.originServerTs;
    return relation;
}

@interface MXSQLiteAggregationsStore ()
{
    os_unfair_lock _stateLock;
    /// `deleteAll` без открытой базы: строки базы не видны, пока очистка не записана.
    BOOL _pendingDeleteAll;
    /// Есть записи, отложенные до появления строки `room`.
    BOOL _waitingForRooms;
}
@property (nonatomic, weak, readonly) MXSQLiteStore *store;
/// `@[eventId, reaction]` → `MXSQLiteReactionEntry` или `NSNull`.
@property (nonatomic, readonly) MXSQLiteOverlay<NSArray<NSString *> *, id> *counts;
/// `reactionEventId` → `MXSQLiteReactionEntry` или `NSNull`.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *relations;
@property (nonatomic, readonly) dispatch_queue_t flushQueue;
/// `take` и постановка тела в очередь писателя — атомарно (порядок тел = порядок `take`), и против `deleteAll`.
@property (nonatomic, readonly) NSLock *flushLock;
@property (atomic) BOOL flushScheduled;
@property (nonatomic) id commitObserver;
@end

@implementation MXSQLiteAggregationsStore

- (instancetype)initWithCredentials:(MXCredentials *)credentials
{
    return [self initWithStore:nil];
}

- (instancetype)initWithStore:(MXSQLiteStore *)store
{
    self = [super init];
    if (self)
    {
        _store = store;
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _counts = [MXSQLiteOverlay new];
        _relations = [MXSQLiteOverlay new];
        _flushQueue = dispatch_queue_create("org.matrix.sdk.sqlite.aggregations", DISPATCH_QUEUE_SERIAL);
        _flushLock = [NSLock new];

        if (store)
        {
            __weak typeof(self) weakSelf = self;
            _commitObserver = [NSNotificationCenter.defaultCenter addObserverForName:MXStoreDidCommitNotification
                                                                              object:store
                                                                               queue:nil
                                                                          usingBlock:^(NSNotification *notification) {
                [weakSelf storeDidCommit];
            }];
        }
    }
    return self;
}

- (void)dealloc
{
    if (_commitObserver)
    {
        [NSNotificationCenter.defaultCenter removeObserver:_commitObserver];
    }
}

#pragma mark - Legacy Realm

+ (NSURL *)legacyRealmFolderForUserId:(NSString *)userId
{
    // Путь MXRealmAggregationsStore: Caches/<userId>/Aggregations/Aggregations.realm.
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [[caches URLByAppendingPathComponent:userId isDirectory:YES] URLByAppendingPathComponent:@"Aggregations" isDirectory:YES];
}

+ (void)removeLegacyRealmStoreForUserId:(NSString *)userId
{
    if (!userId.length)
    {
        return;
    }
    NSURL *folder = [self legacyRealmFolderForUserId:userId];
    if ([NSFileManager.defaultManager fileExistsAtPath:folder.path])
    {
        NSError *error;
        if ([NSFileManager.defaultManager removeItemAtURL:folder error:&error])
        {
            MXLogDebug(@"[MXSQLiteAggregationsStore] Removed the Realm aggregations store");
        }
        else
        {
            MXLogWarning(@"[MXSQLiteAggregationsStore] Cannot remove the Realm aggregations store: %@", error);
        }
    }
}

#pragma mark - Reads

- (BOOL)hidesDatabase
{
    os_unfair_lock_lock(&_stateLock);
    BOOL result = _pendingDeleteAll;
    os_unfair_lock_unlock(&_stateLock);
    return result;
}

/// Закоммиченные строки с читателя; база не открыта или спрятана `deleteAll` — пусто.
- (NSArray *)readRows:(NSString *)sql bind:(void (^)(MXSQLiteStatement *statement))bind row:(id (^)(MXSQLiteStatement *statement))row
{
    MXSQLiteDatabase *database = self.store.database;
    if (!database || self.hidesDatabase)
    {
        return @[];
    }
    return [database read:^id(MXSQLiteConnection *connection) {
        return [connection query:sql bind:bind row:row error:nil];
    }] ?: @[];
}

static MXReactionCount *MXSQLiteCountFromRow(MXSQLiteStatement *statement, int first)
{
    MXReactionCount *count = [MXReactionCount new];
    count.reaction = [statement textAt:first] ?: @"";
    count.count = (NSUInteger)MAX([statement int64At:first + 1], 0);
    count.originServerTs = (uint64_t)[statement int64At:first + 2];
    // Колонка `mine` — id своего события реакции; '' — своей реакции нет.
    NSString *mine = [statement textAt:first + 3];
    count.myUserReactionEventId = mine.length ? mine : nil;
    return count;
}

static MXReactionRelation *MXSQLiteRelationFromRow(MXSQLiteStatement *statement)
{
    MXReactionRelation *relation = [MXReactionRelation new];
    relation.reactionEventId = [statement textAt:0] ?: @"";
    relation.eventId = [statement textAt:1] ?: @"";
    relation.reaction = [statement textAt:2] ?: @"";
    relation.originServerTs = (uint64_t)[statement int64At:3];
    return relation;
}

/// Все реакции события: база, поверх — накладка. reaction → count.
- (NSMutableDictionary<NSString *, MXReactionCount *> *)countsByReactionOnEvent:(NSString *)eventId
{
    NSMutableDictionary<NSString *, MXReactionCount *> *result = [NSMutableDictionary dictionary];
    NSArray<MXReactionCount *> *rows = [self readRows:@"SELECT reaction, count, origin_ts, mine FROM reaction_count WHERE event_id = ?1"
                                                 bind:^(MXSQLiteStatement *statement) { [statement bindText:eventId at:1]; }
                                                  row:^id(MXSQLiteStatement *statement) { return MXSQLiteCountFromRow(statement, 0); }];
    for (MXReactionCount *count in rows)
    {
        result[count.reaction] = count;
    }
    [[self.counts snapshot] enumerateKeysAndObjectsUsingBlock:^(NSArray<NSString *> *key, id value, BOOL *stop) {
        if (![key[0] isEqualToString:eventId])
        {
            return;
        }
        result[key[1]] = [value isKindOfClass:MXSQLiteReactionEntry.class] ? MXSQLiteCopyCount(((MXSQLiteReactionEntry *)value).count) : nil;
    }];
    return result;
}

#pragma mark - MXAggregationsStore: reaction counts

- (void)addOrUpdateReactionCount:(MXReactionCount *)reactionCount onEvent:(NSString *)eventId inRoom:(NSString *)roomId
{
    MXSQLiteReactionEntry *entry = [MXSQLiteReactionEntry new];
    entry.roomId = roomId;
    entry.count = MXSQLiteCopyCount(reactionCount);
    [self.counts setObject:entry forKey:@[eventId, reactionCount.reaction]];
    [self scheduleFlush];
}

- (BOOL)hasReactionCountsOnEvent:(NSString *)eventId
{
    return [self countsByReactionOnEvent:eventId].count > 0;
}

- (MXReactionCount *)reactionCountForReaction:(NSString *)reaction onEvent:(NSString *)eventId
{
    id value = [self.counts objectForKey:@[eventId, reaction]];
    if (value)
    {
        return [value isKindOfClass:MXSQLiteReactionEntry.class] ? MXSQLiteCopyCount(((MXSQLiteReactionEntry *)value).count) : nil;
    }
    return [self readRows:@"SELECT reaction, count, origin_ts, mine FROM reaction_count WHERE event_id = ?1 AND reaction = ?2"
                     bind:^(MXSQLiteStatement *statement) {
                         [statement bindText:eventId at:1];
                         [statement bindText:reaction at:2];
                     }
                      row:^id(MXSQLiteStatement *statement) { return MXSQLiteCountFromRow(statement, 0); }].firstObject;
}

- (void)deleteReactionCountsForReaction:(NSString *)reaction onEvent:(NSString *)eventId
{
    [self.counts setObject:NSNull.null forKey:@[eventId, reaction]];
    [self scheduleFlush];
}

- (void)setReactionCounts:(NSArray<MXReactionCount *> *)reactionCounts onEvent:(NSString *)eventId inRoom:(NSString *)roomId
{
    NSMutableSet<NSString *> *stale = [NSMutableSet setWithArray:[self countsByReactionOnEvent:eventId].allKeys];
    for (MXReactionCount *count in reactionCounts)
    {
        [stale removeObject:count.reaction];
        MXSQLiteReactionEntry *entry = [MXSQLiteReactionEntry new];
        entry.roomId = roomId;
        entry.count = MXSQLiteCopyCount(count);
        [self.counts setObject:entry forKey:@[eventId, count.reaction]];
    }
    for (NSString *reaction in stale)
    {
        [self.counts setObject:NSNull.null forKey:@[eventId, reaction]];
    }
    [self scheduleFlush];
}

- (NSArray<MXReactionCount *> *)reactionCountsOnEvent:(NSString *)eventId
{
    NSArray<MXReactionCount *> *counts = [self countsByReactionOnEvent:eventId].allValues;
    if (!counts.count)
    {
        return nil;
    }
    // Как у Realm-стора: по времени первой реакции.
    return [counts sortedArrayUsingComparator:^NSComparisonResult(MXReactionCount *first, MXReactionCount *second) {
        if (first.originServerTs != second.originServerTs)
        {
            return first.originServerTs < second.originServerTs ? NSOrderedAscending : NSOrderedDescending;
        }
        return [first.reaction compare:second.reaction];
    }];
}

- (void)deleteAllReactionCountsInRoom:(NSString *)roomId
{
    NSArray<NSArray<NSString *> *> *keys = [self readRows:@"SELECT c.event_id, c.reaction FROM reaction_count c "
                                                           "JOIN room r ON r.rid = c.rid WHERE r.room_id = ?1"
                                                     bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                                                      row:^id(MXSQLiteStatement *statement) {
        return @[[statement textAt:0] ?: @"", [statement textAt:1] ?: @""];
    }];
    for (NSArray<NSString *> *key in keys)
    {
        [self.counts setObject:NSNull.null forKey:key];
    }
    [[self.counts snapshot] enumerateKeysAndObjectsUsingBlock:^(NSArray<NSString *> *key, id value, BOOL *stop) {
        if ([value isKindOfClass:MXSQLiteReactionEntry.class] && [((MXSQLiteReactionEntry *)value).roomId isEqualToString:roomId])
        {
            [self.counts setObject:NSNull.null forKey:key];
        }
    }];
    [self scheduleFlush];
}

#pragma mark - MXAggregationsStore: reaction relations

- (void)addReactionRelation:(MXReactionRelation *)relation inRoom:(NSString *)roomId
{
    MXSQLiteReactionEntry *entry = [MXSQLiteReactionEntry new];
    entry.roomId = roomId;
    entry.relation = MXSQLiteCopyRelation(relation);
    [self.relations setObject:entry forKey:relation.reactionEventId];
    [self scheduleFlush];
}

- (MXReactionRelation *)reactionRelationWithReactionEventId:(NSString *)reactionEventId
{
    id value = [self.relations objectForKey:reactionEventId];
    if (value)
    {
        return [value isKindOfClass:MXSQLiteReactionEntry.class] ? MXSQLiteCopyRelation(((MXSQLiteReactionEntry *)value).relation) : nil;
    }
    return [self readRows:@"SELECT reaction_event_id, event_id, reaction, ts FROM reaction_relation WHERE reaction_event_id = ?1"
                     bind:^(MXSQLiteStatement *statement) { [statement bindText:reactionEventId at:1]; }
                      row:^id(MXSQLiteStatement *statement) { return MXSQLiteRelationFromRow(statement); }].firstObject;
}

- (void)deleteReactionRelation:(MXReactionRelation *)relation
{
    [self.relations setObject:NSNull.null forKey:relation.reactionEventId];
    [self scheduleFlush];
}

- (NSArray<MXReactionRelation *> *)reactionRelationsOnEvent:(NSString *)eventId
{
    NSMutableDictionary<NSString *, MXReactionRelation *> *byReactionEvent = [NSMutableDictionary dictionary];
    NSArray<MXReactionRelation *> *rows = [self readRows:@"SELECT reaction_event_id, event_id, reaction, ts FROM reaction_relation WHERE event_id = ?1"
                                                    bind:^(MXSQLiteStatement *statement) { [statement bindText:eventId at:1]; }
                                                     row:^id(MXSQLiteStatement *statement) { return MXSQLiteRelationFromRow(statement); }];
    for (MXReactionRelation *relation in rows)
    {
        byReactionEvent[relation.reactionEventId] = relation;
    }
    [[self.relations snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        MXReactionRelation *relation = [value isKindOfClass:MXSQLiteReactionEntry.class] ? ((MXSQLiteReactionEntry *)value).relation : nil;
        byReactionEvent[key] = [relation.eventId isEqualToString:eventId] ? MXSQLiteCopyRelation(relation) : nil;
    }];
    if (!byReactionEvent.count)
    {
        return nil;
    }
    return [byReactionEvent.allValues sortedArrayUsingComparator:^NSComparisonResult(MXReactionRelation *first, MXReactionRelation *second) {
        if (first.originServerTs != second.originServerTs)
        {
            return first.originServerTs < second.originServerTs ? NSOrderedAscending : NSOrderedDescending;
        }
        return [first.reactionEventId compare:second.reactionEventId];
    }];
}

- (void)deleteAllReactionRelationsInRoom:(NSString *)roomId
{
    NSArray<NSString *> *keys = [self readRows:@"SELECT x.reaction_event_id FROM reaction_relation x "
                                                "JOIN room r ON r.rid = x.rid WHERE r.room_id = ?1"
                                          bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                                           row:^id(MXSQLiteStatement *statement) { return [statement textAt:0]; }];
    for (NSString *key in keys)
    {
        [self.relations setObject:NSNull.null forKey:key];
    }
    [[self.relations snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([value isKindOfClass:MXSQLiteReactionEntry.class] && [((MXSQLiteReactionEntry *)value).roomId isEqualToString:roomId])
        {
            [self.relations setObject:NSNull.null forKey:key];
        }
    }];
    [self scheduleFlush];
}

#pragma mark - MXAggregationsStore: global

- (void)deleteAll
{
    [self.flushLock lock];
    [self.counts removeAll];
    [self.relations removeAll];
    MXSQLiteDatabase *database = self.store.database;
    BOOL deleted = NO;
    if (database && !database.readOnly && !database.isOnWriterQueue)
    {
        // Тела, уже поставленные писателю, выполнятся раньше этого: порядок очереди писателя.
        NSError *error;
        deleted = [database writeSync:^BOOL(MXSQLiteConnection *connection, NSError **blockError) {
            return [connection execute:@"DELETE FROM reaction_count; DELETE FROM reaction_relation;" error:blockError];
        } error:&error];
        if (!deleted)
        {
            MXLogErrorDetails(@"[MXSQLiteAggregationsStore] deleteAll failed", @{@"error": error ?: NSNull.null});
        }
    }
    os_unfair_lock_lock(&_stateLock);
    _pendingDeleteAll = !deleted;
    os_unfair_lock_unlock(&_stateLock);
    [self.flushLock unlock];
}

#pragma mark - Writes

- (void)scheduleFlush
{
    if (self.flushScheduled)
    {
        return;
    }
    self.flushScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.flushQueue, ^{
        typeof(self) strongSelf = weakSelf;
        strongSelf.flushScheduled = NO;
        [strongSelf writePending:NO];
    });
}

- (void)storeDidCommit
{
    os_unfair_lock_lock(&_stateLock);
    BOOL waiting = _waitingForRooms;
    _waitingForRooms = NO;
    os_unfair_lock_unlock(&_stateLock);
    if (waiting)
    {
        [self scheduleFlush];
    }
}

- (void)flush
{
    [self writePending:YES];
}

/// Забрать накладку и записать одной транзакцией. synchronously — `writeSync` (ждёт и тела, поставленные раньше).
- (void)writePending:(BOOL)synchronously
{
    [self.flushLock lock];
    MXSQLiteDatabase *database = self.store.database;
    os_unfair_lock_lock(&_stateLock);
    BOOL clear = _pendingDeleteAll;
    os_unfair_lock_unlock(&_stateLock);
    if (!database || database.readOnly || database.isOnWriterQueue
        || (!self.counts.hasPending && !self.relations.hasPending && !clear))
    {
        [self.flushLock unlock];
        return;
    }

    NSDictionary<NSArray<NSString *> *, id> *counts = [self.counts take];
    NSDictionary<NSString *, id> *relations = [self.relations take];
    // Записи без строки `room`: вернуть в накладку после коммита.
    NSMutableDictionary<NSArray<NSString *> *, id> *deferredCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, id> *deferredRelations = [NSMutableDictionary dictionary];

    MXSQLiteWriteBody body = ^BOOL(MXSQLiteConnection *connection, NSError **error) {
        [deferredCounts removeAllObjects];
        [deferredRelations removeAllObjects];
        if (clear && ![connection execute:@"DELETE FROM reaction_count; DELETE FROM reaction_relation;" error:error])
        {
            return NO;
        }
        NSMutableDictionary<NSString *, NSNumber *> *rids = [NSMutableDictionary dictionary];
        int64_t (^ridOf)(NSString *) = ^int64_t(NSString *roomId) {
            NSNumber *rid = rids[roomId];
            if (!rid)
            {
                rid = [connection query:@"SELECT rid FROM room WHERE room_id = ?1"
                                   bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                                    row:^id(MXSQLiteStatement *statement) { return @([statement int64At:0]); }
                                  error:nil].firstObject ?: @0;
                rids[roomId] = rid;
            }
            return rid.longLongValue;
        };

        for (NSArray<NSString *> *key in counts)
        {
            id value = counts[key];
            if (![value isKindOfClass:MXSQLiteReactionEntry.class])
            {
                if (![connection run:@"DELETE FROM reaction_count WHERE event_id = ?1 AND reaction = ?2"
                                bind:^(MXSQLiteStatement *statement) {
                                    [statement bindText:key[0] at:1];
                                    [statement bindText:key[1] at:2];
                                } error:error])
                {
                    return NO;
                }
                continue;
            }
            MXSQLiteReactionEntry *entry = value;
            int64_t rid = ridOf(entry.roomId);
            if (!rid)
            {
                deferredCounts[key] = entry;
                continue;
            }
            if (![connection run:@"INSERT INTO reaction_count (event_id, reaction, count, origin_ts, mine, rid) "
                                  "VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(event_id, reaction) DO UPDATE SET "
                                  "count = excluded.count, origin_ts = excluded.origin_ts, mine = excluded.mine, rid = excluded.rid"
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindText:key[0] at:1];
                                [statement bindText:key[1] at:2];
                                [statement bindInt64:(int64_t)entry.count.count at:3];
                                [statement bindInt64:(int64_t)entry.count.originServerTs at:4];
                                [statement bindText:entry.count.myUserReactionEventId ?: @"" at:5];
                                [statement bindInt64:rid at:6];
                            } error:error])
            {
                return NO;
            }
        }

        for (NSString *key in relations)
        {
            id value = relations[key];
            if (![value isKindOfClass:MXSQLiteReactionEntry.class])
            {
                if (![connection run:@"DELETE FROM reaction_relation WHERE reaction_event_id = ?1"
                                bind:^(MXSQLiteStatement *statement) { [statement bindText:key at:1]; } error:error])
                {
                    return NO;
                }
                continue;
            }
            MXSQLiteReactionEntry *entry = value;
            int64_t rid = ridOf(entry.roomId);
            if (!rid)
            {
                deferredRelations[key] = entry;
                continue;
            }
            if (![connection run:@"INSERT INTO reaction_relation (reaction_event_id, event_id, reaction, sender, ts, rid) "
                                  "VALUES (?1, ?2, ?3, NULL, ?4, ?5) ON CONFLICT(reaction_event_id) DO UPDATE SET "
                                  "event_id = excluded.event_id, reaction = excluded.reaction, ts = excluded.ts, rid = excluded.rid"
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindText:key at:1];
                                [statement bindText:entry.relation.eventId at:2];
                                [statement bindText:entry.relation.reaction at:3];
                                [statement bindInt64:(int64_t)entry.relation.originServerTs at:4];
                                [statement bindInt64:rid at:5];
                            } error:error])
            {
                return NO;
            }
        }
        return YES;
    };

    void (^finish)(NSError *) = ^(NSError *error) {
        [self finishWrite:error == nil clear:clear deferredCounts:deferredCounts deferredRelations:deferredRelations];
    };

    if (clear)
    {
        os_unfair_lock_lock(&_stateLock);
        _pendingDeleteAll = NO;
        os_unfair_lock_unlock(&_stateLock);
    }

    if (synchronously)
    {
        NSError *error;
        [database writeSync:body error:&error];
        finish(error);
    }
    else
    {
        [database write:body completion:finish];
    }
    [self.flushLock unlock];
}

- (void)finishWrite:(BOOL)committed
              clear:(BOOL)clear
     deferredCounts:(NSDictionary<NSArray<NSString *> *, id> *)deferredCounts
  deferredRelations:(NSDictionary<NSString *, id> *)deferredRelations
{
    if (!committed)
    {
        MXLogError(@"[MXSQLiteAggregationsStore] write failed, will retry");
    }
    if (committed)
    {
        // Отложенное (нет строки `room`) — обратно в накладку, если эта партия всё ещё самая новая для ключа. До
        // снятия партии: иначе между снятием и возвратом чтение его не увидит.
        [deferredCounts enumerateKeysAndObjectsUsingBlock:^(NSArray<NSString *> *key, id value, BOOL *stop) {
            if ([self.counts objectForKey:key] == value)
            {
                [self.counts setObject:value forKey:key];
            }
        }];
        [deferredRelations enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            if ([self.relations objectForKey:key] == value)
            {
                [self.relations setObject:value forKey:key];
            }
        }];
    }
    [self.counts finishOldestCommitted:committed];
    [self.relations finishOldestCommitted:committed];
    if (!committed)
    {
        os_unfair_lock_lock(&_stateLock);
        _pendingDeleteAll = _pendingDeleteAll || clear;
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    if (deferredCounts.count || deferredRelations.count)
    {
        os_unfair_lock_lock(&_stateLock);
        _waitingForRooms = YES;
        os_unfair_lock_unlock(&_stateLock);
    }
}

@end
