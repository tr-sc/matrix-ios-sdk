//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteReceiptStore.h"

#import "MXEvent.h"
#import "MXReceiptData.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteOverlay.h"
#import "MXSQLiteRoomRegistry.h"

static NSString *const kColumnMarkedUnread = @"marked_unread";

/// Тред в базе: основная лента — '' (kMXEventTimelineMain в API).
static NSString *MXSQLiteThreadColumn(NSString *threadId)
{
    return (!threadId.length || [threadId isEqualToString:kMXEventTimelineMain]) ? @"" : threadId;
}

static NSString *MXSQLiteThreadIdentifier(NSString *column)
{
    return column.length ? column : kMXEventTimelineMain;
}

@interface MXSQLiteReceiptStore ()
@property (nonatomic, weak, readonly) MXSQLiteStoreContext *context;
/// @[roomId, тред (колонка), userId] → MXReceiptData.
@property (nonatomic, readonly) MXSQLiteOverlay<NSArray *, id> *receipts;
/// roomId → @(BOOL).
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *unread;
@end

@implementation MXSQLiteReceiptStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
        _receipts = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _unread = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
    }
    return self;
}

#pragma mark - Reads

/// Строки базы запросом `sql` (первый параметр — rid): [тред, userId, MXReceiptData].
- (NSArray<NSArray *> *)rowsInRoom:(NSString *)roomId sql:(NSString *)sql bind:(void (^)(MXSQLiteStatement *))bind
{
    MXSQLiteDatabase *database = self.context.database;
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    return [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom)
        {
            return @[];
        }
        return [connection query:sql
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindInt64:rid at:1];
                                if (bind)
                                {
                                    bind(statement);
                                }
                            }
                             row:^id(MXSQLiteStatement *statement) {
            MXReceiptData *receipt = MXSQLiteUnarchive([statement blobAt:2]);
            NSString *thread = [statement textAt:0] ?: @"";
            NSString *userId = [statement textAt:1];
            return [receipt isKindOfClass:MXReceiptData.class] && userId ? @[thread, userId, receipt] : nil;
        } error:nil];
    }] ?: @[];
}

/// Незакоммиченные квитанции комнаты: ключ @[roomId, тред, userId] → квитанция.
- (NSDictionary<NSArray *, MXReceiptData *> *)overlayInRoom:(NSString *)roomId
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [[self.receipts snapshot] enumerateKeysAndObjectsUsingBlock:^(NSArray *key, id receipt, BOOL *stop) {
        if ([key[0] isEqualToString:roomId] && [receipt isKindOfClass:MXReceiptData.class])
        {
            result[key] = receipt;
        }
    }];
    return result;
}

- (MXReceiptData *)currentReceiptInRoom:(NSString *)roomId thread:(NSString *)thread userId:(NSString *)userId
{
    NSArray *key = @[roomId, thread, userId];
    id receipt = [self.receipts cachedObjectForKey:key];
    if (!receipt)
    {
        if (!self.context.database)
        {
            return nil;
        }
        receipt = [self rowsInRoom:roomId
                               sql:@"SELECT thread, user_id, data FROM receipt WHERE rid = ?1 AND thread = ?2 AND user_id = ?3"
                              bind:^(MXSQLiteStatement *statement) {
                                  [statement bindText:thread at:2];
                                  [statement bindText:userId at:3];
                              }].firstObject[2] ?: NSNull.null;
        [self.receipts cacheObject:receipt forKey:key];
    }
    return [receipt isKindOfClass:MXReceiptData.class] ? receipt : nil;
}

/// Треды комнаты, в которых уже есть квитанции (база и накладка), кроме основной ленты.
- (NSSet<NSString *> *)knownThreadsInRoom:(NSString *)roomId
{
    NSMutableSet<NSString *> *threads = [NSMutableSet set];
    MXSQLiteDatabase *database = self.context.database;
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    NSArray<NSString *> *stored = [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom)
        {
            return @[];
        }
        return [connection query:@"SELECT DISTINCT thread FROM receipt WHERE rid = ?1 AND thread != ''"
                            bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                             row:^id(MXSQLiteStatement *statement) { return [statement textAt:0]; }
                           error:nil];
    }] ?: @[];
    [threads addObjectsFromArray:stored];
    for (NSArray *key in [self overlayInRoom:roomId])
    {
        if ([key[1] length])
        {
            [threads addObject:key[1]];
        }
    }
    return threads;
}

#pragma mark - MXSQLiteReceiptStoring

- (BOOL)storeReceipt:(MXReceiptData *)receipt inRoom:(NSString *)roomId
{
    if (!receipt.userId || !receipt.eventId)
    {
        return NO;
    }
    if (receipt.threadId)
    {
        return [self storeReceipt:receipt inRoom:roomId thread:MXSQLiteThreadColumn(receipt.threadId)];
    }
    // Квитанция без треда — для основной ленты и всех известных тредов (как MXMemoryStore).
    BOOL stored = [self storeReceipt:receipt inRoom:roomId thread:@""];
    for (NSString *thread in [self knownThreadsInRoom:roomId])
    {
        stored |= [self storeReceipt:receipt inRoom:roomId thread:thread];
    }
    return stored;
}

- (BOOL)storeReceipt:(MXReceiptData *)receipt inRoom:(NSString *)roomId thread:(NSString *)thread
{
    MXReceiptData *current = [self currentReceiptInRoom:roomId thread:thread userId:receipt.userId];
    // Нет квитанции или новое событие с более поздним временем (правило MXMemoryStore).
    if (current && ([receipt.eventId isEqualToString:current.eventId] || receipt.ts <= current.ts))
    {
        return NO;
    }
    [self.receipts setObject:[receipt copy] forKey:@[roomId, thread, receipt.userId]];
    return YES;
}

- (void)getEventReceipts:(NSString *)roomId
                 eventId:(NSString *)eventId
                threadId:(NSString *)threadId
                  sorted:(BOOL)sort
              completion:(void (^)(NSArray<MXReceiptData *> *))completion
{
    NSString *thread = MXSQLiteThreadColumn(threadId);
    NSDictionary<NSArray *, MXReceiptData *> *overlay = [self overlayInRoom:roomId];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, MXReceiptData *> *byUser = [NSMutableDictionary dictionary];
        NSArray<NSArray *> *rows = [self rowsInRoom:roomId
                                                sql:@"SELECT thread, user_id, data FROM receipt WHERE rid = ?1 AND event_id = ?2 AND thread = ?3"
                                               bind:^(MXSQLiteStatement *statement) {
                                                   [statement bindText:eventId at:2];
                                                   [statement bindText:thread at:3];
                                               }];
        for (NSArray *row in rows)
        {
            byUser[row[1]] = row[2];
        }
        // Накладка новее базы: пользователь мог уже уйти на другое событие.
        [overlay enumerateKeysAndObjectsUsingBlock:^(NSArray *key, MXReceiptData *receipt, BOOL *stop) {
            if (![key[1] isEqualToString:thread])
            {
                return;
            }
            if ([receipt.eventId isEqualToString:eventId])
            {
                byUser[key[2]] = receipt;
            }
            else
            {
                [byUser removeObjectForKey:key[2]];
            }
        }];
        NSArray<MXReceiptData *> *receipts = byUser.allValues;
        if (sort)
        {
            receipts = [receipts sortedArrayUsingComparator:^NSComparisonResult(MXReceiptData *first, MXReceiptData *second) {
                return (first.ts < second.ts) ? NSOrderedDescending : NSOrderedAscending;
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(receipts); });
    });
}

- (NSDictionary<NSString *, MXReceiptData *> *)getReceiptsInRoom:(NSString *)roomId forUserId:(NSString *)userId
{
    NSMutableDictionary<NSString *, MXReceiptData *> *result = [NSMutableDictionary dictionary];
    if (self.context.database)
    {
        NSArray<NSArray *> *rows = [self rowsInRoom:roomId
                                                sql:@"SELECT thread, user_id, data FROM receipt WHERE rid = ?1 AND user_id = ?2"
                                               bind:^(MXSQLiteStatement *statement) { [statement bindText:userId at:2]; }];
        for (NSArray *row in rows)
        {
            result[MXSQLiteThreadIdentifier(row[0])] = row[2];
        }
    }
    [[self overlayInRoom:roomId] enumerateKeysAndObjectsUsingBlock:^(NSArray *key, MXReceiptData *receipt, BOOL *stop) {
        if ([key[2] isEqualToString:userId])
        {
            result[MXSQLiteThreadIdentifier(key[1])] = receipt;
        }
    }];
    return result;
}

- (MXReceiptData *)getReceiptInRoom:(NSString *)roomId threadId:(NSString *)threadId forUserId:(NSString *)userId
{
    return [[self currentReceiptInRoom:roomId thread:MXSQLiteThreadColumn(threadId) userId:userId] copy];
}

- (void)loadReceiptsForRoom:(NSString *)roomId completion:(void (^)(void))completion
{
    // Квитанции читаются запросом, прогревать нечего (ADR-0022).
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

#pragma mark - Marked unread

- (void)setUnreadForRoom:(NSString *)roomId
{
    [self.unread setObject:@YES forKey:roomId];
}

- (void)resetUnreadForRoom:(NSString *)roomId
{
    [self.unread setObject:@NO forKey:roomId];
}

- (BOOL)isRoomMarkedAsUnread:(NSString *)roomId
{
    id value = [self.unread cachedObjectForKey:roomId];
    if (!value)
    {
        value = MXSQLiteReadRoomColumn(self.context, roomId, kColumnMarkedUnread, MXSQLiteValueKindInteger);
        if (!value)
        {
            return NO;
        }
        [self.unread cacheObject:value forKey:roomId];
    }
    return value != NSNull.null && [value boolValue];
}

#pragma mark - MXSQLiteStoreComponent

- (MXSQLiteCommitBody)takePendingWrites
{
    if (!self.receipts.hasPending && !self.unread.hasPending)
    {
        return nil;
    }
    NSDictionary<NSArray *, MXReceiptData *> *receipts = [self.receipts take];
    NSDictionary<NSString *, NSNumber *> *unread = [self.unread take];
    MXSQLiteStoreContext *context = self.context;

    return ^BOOL(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error) {
        for (NSArray *key in receipts)
        {
            MXReceiptData *receipt = receipts[key];
            if (![receipt isKindOfClass:MXReceiptData.class])
            {
                continue;
            }
            int64_t rid = [context.rooms ensureRidForRoomId:key[0] connection:connection error:error];
            NSData *data = MXSQLiteArchive(receipt);
            if (rid == MXSQLiteNoRoom)
            {
                return NO;
            }
            if (!data)
            {
                continue;
            }
            if (![connection run:@"INSERT INTO receipt (rid, thread, user_id, event_id, ts, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6) "
                                  "ON CONFLICT(rid, thread, user_id) DO UPDATE SET "
                                  "event_id = excluded.event_id, ts = excluded.ts, data = excluded.data"
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindInt64:rid at:1];
                                [statement bindText:key[1] at:2];
                                [statement bindText:key[2] at:3];
                                [statement bindText:receipt.eventId at:4];
                                [statement bindInt64:(int64_t)receipt.ts at:5];
                                [statement bindBlob:data at:6];
                            } error:error])
            {
                return NO;
            }
            [commit touchRoomId:key[0]];
        }
        for (NSString *roomId in unread)
        {
            if (!MXSQLiteWriteRoomColumn(connection, context, roomId, kColumnMarkedUnread, unread[roomId], error))
            {
                return NO;
            }
            [commit touchRoomId:roomId];
        }
        return YES;
    };
}

- (void)didFinishPendingWrites:(BOOL)committed
{
    [self.receipts finishOldestCommitted:committed];
    [self.unread finishOldestCommitted:committed];
}

- (void)willDeleteRoom:(NSString *)roomId
{
    [self.receipts removeKeysPassingTest:^BOOL(NSArray *key) { return [key[0] isEqualToString:roomId]; }];
    [self.unread removeKeysPassingTest:^BOOL(NSString *key) { return [key isEqualToString:roomId]; }];
}

- (void)didDeleteAllData
{
    [self.receipts removeAll];
    [self.unread removeAll];
}

@end
