//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteOutgoingStore.h"

#import <os/lock.h>

#import "MXEvent.h"
#import "MXEventDecryptionResult.h"
#import "MXEventUnsignedData.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteOverlay.h"
#import "MXSQLiteRoomRegistry.h"

static NSString *const kColumnDraft = @"draft";

/// Строка `outgoing` в накладке. `event == nil` — строку удалить.
@interface MXSQLiteOutgoingRow : NSObject
@property (nonatomic, copy) NSString *roomId;
@property (nonatomic, nullable) MXEvent *event;
@property (nonatomic) int64_t createdTs;
@property (nonatomic, copy, nullable) NSString *transactionId;
@end

@implementation MXSQLiteOutgoingRow
@end

@interface MXSQLiteOutgoingStore ()
{
    os_unfair_lock _clockLock;
    int64_t _lastCreatedTs;
}
@property (nonatomic, weak, readonly) MXSQLiteStoreContext *context;
/// local_id → MXSQLiteOutgoingRow.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, MXSQLiteOutgoingRow *> *rows;
/// roomId → @YES: перед строками коммит удаляет все строки комнаты из базы.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *clears;
/// roomId → NSAttributedString | NSNull.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *drafts;
@end

@implementation MXSQLiteOutgoingStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
        _rows = [MXSQLiteOverlay new];
        _clears = [MXSQLiteOverlay new];
        _drafts = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _clockLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

/// Время создания строки, мс; строго растёт — порядок отправки сохраняется и для двух сообщений в одну мс.
- (int64_t)nextCreatedTs
{
    int64_t now = (int64_t)([NSDate date].timeIntervalSince1970 * 1000);
    os_unfair_lock_lock(&_clockLock);
    _lastCreatedTs = MAX(now, _lastCreatedTs + 1);
    int64_t result = _lastCreatedTs;
    os_unfair_lock_unlock(&_clockLock);
    return result;
}

#pragma mark - Coding

+ (NSString *)transactionIdOfEvent:(MXEvent *)event
{
    // txnId отправки = local_id эха (MXRoom `_sendEventOfType:… txnId:event.eventId`).
    return event.unsignedData.transactionId ?: event.eventId;
}

+ (MXEvent *)eventWithJSON:(NSData *)json clear:(NSData *)clear sentState:(int64_t)sentState
{
    NSDictionary *dictionary = MXSQLiteJSONObject(json);
    if (![dictionary isKindOfClass:NSDictionary.class])
    {
        return nil;
    }
    MXEvent *event = [MXEvent modelFromJSON:dictionary];
    NSDictionary *clearDictionary = MXSQLiteJSONObject(clear);
    if ([clearDictionary isKindOfClass:NSDictionary.class])
    {
        MXEventDecryptionResult *result = [MXEventDecryptionResult new];
        result.clearEvent = clearDictionary;
        [event setClearData:result];
    }
    event.sentState = (MXEventSentState)sentState;
    return event;
}

#pragma mark - Outgoing

- (void)storeOutgoingMessageForRoom:(NSString *)roomId outgoingMessage:(MXEvent *)outgoingMessage
{
    NSString *localId = outgoingMessage.eventId;
    if (!localId)
    {
        return;
    }
    MXSQLiteOutgoingRow *previous = [self.rows objectForKey:localId];
    MXSQLiteOutgoingRow *row = [MXSQLiteOutgoingRow new];
    row.roomId = roomId;
    row.event = outgoingMessage;
    // Обновление строки (смена sentState, шифрование) сохраняет её место в очереди.
    row.createdTs = previous.event ? previous.createdTs : [self nextCreatedTs];
    row.transactionId = [MXSQLiteOutgoingStore transactionIdOfEvent:outgoingMessage];
    [self.rows setObject:row forKey:localId];
}

- (void)removeOutgoingMessageFromRoom:(NSString *)roomId outgoingMessage:(NSString *)outgoingMessageEventId
{
    MXSQLiteOutgoingRow *row = [MXSQLiteOutgoingRow new];
    row.roomId = roomId;
    [self.rows setObject:row forKey:outgoingMessageEventId];
}

- (void)removeAllOutgoingMessagesFromRoom:(NSString *)roomId
{
    [[self.rows snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *localId, MXSQLiteOutgoingRow *row, BOOL *stop) {
        if ([row.roomId isEqualToString:roomId] && row.event)
        {
            [self removeOutgoingMessageFromRoom:roomId outgoingMessage:localId];
        }
    }];
    [self.clears setObject:@YES forKey:roomId];
}

/// Строки комнаты в базе: local_id → @[created_ts, MXEvent]. Пусто, если комнату очистили и коммит ещё идёт.
- (NSDictionary<NSString *, NSArray *> *)storedRowsInRoom:(NSString *)roomId
{
    MXSQLiteDatabase *database = self.context.database;
    if (!database || [self.clears objectForKey:roomId])
    {
        return @{};
    }
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    NSArray<NSArray *> *rows = [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom)
        {
            return @[];
        }
        return [connection query:@"SELECT local_id, created_ts, sent_state, json, clear FROM outgoing WHERE rid = ?1"
                            bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                             row:^id(MXSQLiteStatement *statement) {
            NSString *localId = [statement textAt:0];
            MXEvent *event = [MXSQLiteOutgoingStore eventWithJSON:[statement blobAt:3]
                                                            clear:[statement blobAt:4]
                                                        sentState:[statement int64At:2]];
            return localId && event ? @[localId, @([statement int64At:1]), event] : nil;
        } error:nil];
    }] ?: @[];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:rows.count];
    for (NSArray *row in rows)
    {
        result[row[0]] = @[row[1], row[2]];
    }
    return result;
}

- (NSArray<MXEvent *> *)outgoingMessagesInRoom:(NSString *)roomId
{
    // local_id → @[created_ts, MXEvent].
    NSMutableDictionary<NSString *, NSArray *> *merged = [[self storedRowsInRoom:roomId] mutableCopy];
    [[self.rows snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *localId, MXSQLiteOutgoingRow *row, BOOL *stop) {
        if (![row.roomId isEqualToString:roomId])
        {
            return;
        }
        if (!row.event)
        {
            [merged removeObjectForKey:localId];
            return;
        }
        // Строка из базы держит своё место в очереди (upsert не трогает created_ts).
        NSNumber *createdTs = merged[localId][0] ?: @(row.createdTs);
        merged[localId] = @[createdTs, row.event];
    }];
    NSArray<NSArray *> *ordered = [merged.allValues sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    NSMutableArray<MXEvent *> *events = [NSMutableArray arrayWithCapacity:ordered.count];
    for (NSArray *entry in ordered)
    {
        [events addObject:entry[1]];
    }
    return events;
}

- (NSString *)consumeOutgoingForTransactionId:(NSString *)transactionId inRoom:(NSString *)roomId
{
    if (!transactionId.length)
    {
        return nil;
    }
    __block NSString *localId;
    __block BOOL consumedBefore = NO;
    [[self.rows snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *key, MXSQLiteOutgoingRow *row, BOOL *stop) {
        if ([row.roomId isEqualToString:roomId] && ([row.transactionId isEqualToString:transactionId] || [key isEqualToString:transactionId]))
        {
            if (row.event)
            {
                localId = key;
            }
            else
            {
                consumedBefore = YES;
            }
            *stop = YES;
        }
    }];
    if (!localId && !consumedBefore && ![self.clears objectForKey:roomId])
    {
        MXSQLiteRoomRegistry *rooms = self.context.rooms;
        localId = [self.context.database read:^id(MXSQLiteConnection *connection) {
            int64_t rid = [rooms ridForRoomId:roomId connection:connection];
            if (rid == MXSQLiteNoRoom)
            {
                return nil;
            }
            return [connection query:@"SELECT local_id FROM outgoing WHERE txn_id = ?1 AND rid = ?2"
                                bind:^(MXSQLiteStatement *statement) {
                                    [statement bindText:transactionId at:1];
                                    [statement bindInt64:rid at:2];
                                }
                                 row:^id(MXSQLiteStatement *statement) { return [statement textAt:0]; }
                               error:nil].firstObject;
        }];
    }
    if (localId)
    {
        // Удаление строки уходит в тот же коммит, что и вставка серверного события (компонент событий раньше в
        // транзакции): эхо и событие не живут в базе вместе.
        [self removeOutgoingMessageFromRoom:roomId outgoingMessage:localId];
    }
    return localId;
}

#pragma mark - Drafts

- (void)storePartialAttributedTextMessageForRoom:(NSString *)roomId partialAttributedTextMessage:(NSAttributedString *)partialAttributedTextMessage
{
    [self.drafts setObject:partialAttributedTextMessage.length ? partialAttributedTextMessage : NSNull.null forKey:roomId];
}

- (NSAttributedString *)partialAttributedTextMessageOfRoom:(NSString *)roomId
{
    id value = [self.drafts cachedObjectForKey:roomId];
    if (!value)
    {
        NSData *data = MXSQLiteReadRoomColumn(self.context, roomId, kColumnDraft, MXSQLiteValueKindBlob);
        if (!data)
        {
            return nil;
        }
        value = [data isKindOfClass:NSData.class] ? (MXSQLiteUnarchive(data) ?: NSNull.null) : NSNull.null;
        [self.drafts cacheObject:value forKey:roomId];
    }
    return [value isKindOfClass:NSAttributedString.class] ? value : nil;
}

#pragma mark - MXSQLiteStoreComponent

- (MXSQLiteCommitBody)takePendingWrites
{
    if (!self.rows.hasPending && !self.clears.hasPending && !self.drafts.hasPending)
    {
        return nil;
    }
    NSDictionary<NSString *, id> *clears = [self.clears take];
    NSDictionary<NSString *, MXSQLiteOutgoingRow *> *rows = [self.rows take];
    NSDictionary<NSString *, id> *drafts = [self.drafts take];
    MXSQLiteStoreContext *context = self.context;

    return ^BOOL(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error) {
        for (NSString *roomId in clears)
        {
            int64_t rid = [context.rooms ridForRoomId:roomId connection:connection];
            if (rid != MXSQLiteNoRoom
                && ![connection run:@"DELETE FROM outgoing WHERE rid = ?1"
                               bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; } error:error])
            {
                return NO;
            }
        }
        for (NSString *localId in rows)
        {
            if (![MXSQLiteOutgoingStore writeRow:rows[localId] localId:localId context:context connection:connection error:error])
            {
                return NO;
            }
            [commit touchRoomId:rows[localId].roomId];
        }
        for (NSString *roomId in drafts)
        {
            id draft = drafts[roomId];
            NSData *data = draft == NSNull.null ? nil : MXSQLiteArchive(draft);
            if (!MXSQLiteWriteRoomColumn(connection, context, roomId, kColumnDraft, data, error))
            {
                return NO;
            }
        }
        return YES;
    };
}

+ (BOOL)writeRow:(MXSQLiteOutgoingRow *)row
         localId:(NSString *)localId
         context:(MXSQLiteStoreContext *)context
      connection:(MXSQLiteConnection *)connection
           error:(NSError **)error
{
    if (!row.event)
    {
        return [connection run:@"DELETE FROM outgoing WHERE local_id = ?1"
                          bind:^(MXSQLiteStatement *statement) { [statement bindText:localId at:1]; } error:error];
    }
    int64_t rid = [context.rooms ensureRidForRoomId:row.roomId connection:connection error:error];
    if (rid == MXSQLiteNoRoom)
    {
        return NO;
    }
    MXEvent *event = row.event;
    NSData *json = MXSQLiteJSONData(event.JSONDictionary);
    if (!json)
    {
        return YES;
    }
    NSData *clear = (event.isEncrypted && event.clearEvent) ? MXSQLiteJSONData(event.clearEvent.JSONDictionary) : nil;
    return [connection run:@"INSERT INTO outgoing (local_id, rid, txn_id, created_ts, sent_state, json, clear) "
                            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) "
                            "ON CONFLICT(local_id) DO UPDATE SET rid = excluded.rid, txn_id = excluded.txn_id, "
                            "sent_state = excluded.sent_state, json = excluded.json, clear = excluded.clear"
                      bind:^(MXSQLiteStatement *statement) {
                          [statement bindText:localId at:1];
                          [statement bindInt64:rid at:2];
                          [statement bindText:row.transactionId at:3];
                          [statement bindInt64:row.createdTs at:4];
                          [statement bindInt64:event.sentState at:5];
                          [statement bindBlob:json at:6];
                          [statement bindBlob:clear at:7];
                      } error:error];
}

- (void)didFinishPendingWrites:(BOOL)committed
{
    [self.clears finishOldestCommitted:committed];
    [self.rows finishOldestCommitted:committed];
    [self.drafts finishOldestCommitted:committed];
}

- (void)willDeleteRoom:(NSString *)roomId
{
    // Тест идёт под замком накладки: строки комнаты — заранее, по снимку.
    NSMutableSet<NSString *> *localIds = [NSMutableSet set];
    [[self.rows snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *localId, MXSQLiteOutgoingRow *row, BOOL *stop) {
        if ([row.roomId isEqualToString:roomId])
        {
            [localIds addObject:localId];
        }
    }];
    [self.rows removeKeysPassingTest:^BOOL(NSString *localId) { return [localIds containsObject:localId]; }];
    [self.clears removeKeysPassingTest:^BOOL(NSString *key) { return [key isEqualToString:roomId]; }];
    [self.drafts removeKeysPassingTest:^BOOL(NSString *key) { return [key isEqualToString:roomId]; }];
}

- (void)didDeleteAllData
{
    [self.rows removeAll];
    [self.clears removeAll];
    [self.drafts removeAll];
}

@end
