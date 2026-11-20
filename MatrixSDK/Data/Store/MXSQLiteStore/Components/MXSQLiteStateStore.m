//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStateStore.h"

#import <os/lock.h>

#import "MXEvent.h"
#import "MXRoomAccountData.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteOverlay.h"
#import "MXSQLiteRoomRegistry.h"

/// Колонки `room`, которыми владеет компонент.
static NSString *const kColumnLegacyToken = @"legacy_token";
static NSString *const kColumnReachedEnd = @"reached_end";
static NSString *const kColumnBackwardState = @"backward_state";
static NSString *const kColumnMembersLoaded = @"members_loaded";

/// Ключ строки `room_state`: type + 0x1F + state_key.
static NSString *MXSQLiteStateKey(NSString *type, NSString *stateKey)
{
    return [NSString stringWithFormat:@"%@\x1f%@", type ?: @"", stateKey ?: @""];
}

/// Незакоммиченное состояние комнаты: полный список (его отдаёт чтение) и разница с базой (её пишет коммит).
@interface MXSQLiteStateWrite : NSObject
@property (nonatomic, copy) NSArray<MXEvent *> *events;
/// ключ строки → событие (вставить или заменить) или NSNull (удалить).
@property (nonatomic, copy) NSDictionary<NSString *, id> *changes;
/// YES — отпечаток базы неизвестен (запись до открытия): коммит сносит все строки комнаты и пишет `events`.
@property (nonatomic) BOOL replacesAll;
@end

@implementation MXSQLiteStateWrite
@end

@interface MXSQLiteStateStore ()
{
    os_unfair_lock _fingerprintLock;
}
@property (nonatomic, weak, readonly) MXSQLiteStoreContext *context;
/// roomId → MXSQLiteStateWrite.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, MXSQLiteStateWrite *> *states;
/// roomId → MXRoomAccountData | NSNull.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *accountData;
/// @[roomId, column] → значение колонки `room`.
@property (nonatomic, readonly) MXSQLiteOverlay<NSArray *, id> *flags;
/// roomId → ключ строки → event_id. Отпечаток того, что уже записано или ждёт коммита: по нему считается разница.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *fingerprints;
@end

@implementation MXSQLiteStateStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
        _states = [MXSQLiteOverlay new];
        _accountData = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _flags = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _fingerprints = [NSMutableDictionary dictionary];
        _fingerprintLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

#pragma mark - State

/// Отпечаток комнаты из базы. nil — базы нет (до открытия).
- (NSDictionary<NSString *, NSString *> *)loadFingerprintOfRoom:(NSString *)roomId
{
    MXSQLiteDatabase *database = self.context.database;
    if (!database)
    {
        return nil;
    }
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    NSMutableDictionary *fingerprint = [NSMutableDictionary dictionary];
    [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom)
        {
            return nil;
        }
        [connection query:@"SELECT type, state_key, event_id FROM room_state WHERE rid = ?1"
                     bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                      row:^id(MXSQLiteStatement *statement) {
            fingerprint[MXSQLiteStateKey([statement textAt:0], [statement textAt:1])] = [statement textAt:2] ?: @"";
            return nil;
        } error:nil];
        return nil;
    }];
    return fingerprint;
}

- (void)storeStateForRoom:(NSString *)roomId stateEvents:(NSArray<MXEvent *> *)stateEvents
{
    os_unfair_lock_lock(&_fingerprintLock);
    NSDictionary<NSString *, NSString *> *fingerprint = self.fingerprints[roomId];
    os_unfair_lock_unlock(&_fingerprintLock);

    BOOL replacesAll = NO;
    if (!fingerprint)
    {
        fingerprint = [self loadFingerprintOfRoom:roomId];
        replacesAll = (fingerprint == nil);
        fingerprint = fingerprint ?: @{};
    }

    // Последнее событие на ключ побеждает (как в MXRoomState).
    NSMutableDictionary<NSString *, MXEvent *> *byKey = [NSMutableDictionary dictionaryWithCapacity:stateEvents.count];
    for (MXEvent *event in stateEvents)
    {
        byKey[MXSQLiteStateKey(event.type, event.stateKey)] = event;
    }

    NSMutableDictionary<NSString *, id> *changes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *updated = [NSMutableDictionary dictionaryWithCapacity:byKey.count];
    [byKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, MXEvent *event, BOOL *stop) {
        NSString *known = fingerprint[key];
        if (!known || !event.eventId || ![known isEqualToString:event.eventId])
        {
            changes[key] = event;
        }
        updated[key] = event.eventId ?: @"";
    }];
    for (NSString *key in fingerprint)
    {
        if (!byKey[key])
        {
            changes[key] = NSNull.null;
        }
    }

    // Несколько записей до коммита сливаются: разница копится, список — последний.
    MXSQLiteStateWrite *previous = [self.states pendingObjectForKey:roomId];
    MXSQLiteStateWrite *write = [MXSQLiteStateWrite new];
    write.events = stateEvents;
    write.replacesAll = replacesAll || previous.replacesAll;
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:previous.changes ?: @{}];
    [merged addEntriesFromDictionary:changes];
    write.changes = merged;

    if (!replacesAll)
    {
        // До открытия отпечаток не запоминаем: после открытия его надо прочитать из базы.
        os_unfair_lock_lock(&_fingerprintLock);
        self.fingerprints[roomId] = updated;
        os_unfair_lock_unlock(&_fingerprintLock);
    }

    if (write.changes.count || write.replacesAll)
    {
        [self.states setObject:write forKey:roomId];
    }
}

- (void)stateOfRoom:(NSString *)roomId success:(void (^)(NSArray<MXEvent *> *))success failure:(void (^)(NSError *))failure
{
    MXSQLiteStateWrite *write = [self.states objectForKey:roomId];
    if (write)
    {
        NSArray<MXEvent *> *events = write.events;
        dispatch_async(dispatch_get_main_queue(), ^{ success(events); });
        return;
    }
    MXSQLiteDatabase *database = self.context.database;
    if (!database)
    {
        dispatch_async(dispatch_get_main_queue(), ^{ success(@[]); });
        return;
    }
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<MXEvent *> *events = [database read:^id(MXSQLiteConnection *connection) {
            int64_t rid = [rooms ridForRoomId:roomId connection:connection];
            if (rid == MXSQLiteNoRoom)
            {
                return @[];
            }
            return [connection query:@"SELECT json FROM room_state WHERE rid = ?1"
                                bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                                 row:^id(MXSQLiteStatement *statement) {
                NSDictionary *json = MXSQLiteJSONObject([statement blobAt:0]);
                return json ? [MXEvent modelFromJSON:json] : nil;
            } error:nil];
        }] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{ success(events); });
    });
}

#pragma mark - Room account data

- (void)storeAccountDataForRoom:(NSString *)roomId userData:(MXRoomAccountData *)accountData
{
    [self.accountData setObject:accountData ?: NSNull.null forKey:roomId];
}

- (MXRoomAccountData *)accountDataOfRoom:(NSString *)roomId
{
    id value = [self.accountData cachedObjectForKey:roomId];
    if (!value)
    {
        value = [self readAccountDataOfRoom:roomId];
        if (!value)
        {
            return nil;
        }
        [self.accountData cacheObject:value forKey:roomId];
    }
    return [value isKindOfClass:MXRoomAccountData.class] ? value : nil;
}

/// nil — база не открыта; NSNull — данных нет.
- (id)readAccountDataOfRoom:(NSString *)roomId
{
    MXSQLiteDatabase *database = self.context.database;
    if (!database)
    {
        return nil;
    }
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    NSData *data = [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom)
        {
            return nil;
        }
        return [connection query:@"SELECT data FROM room_account_data WHERE rid = ?1"
                            bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                             row:^id(MXSQLiteStatement *statement) { return [statement blobAt:0]; }
                           error:nil].firstObject;
    }];
    return MXSQLiteUnarchive(data) ?: NSNull.null;
}

#pragma mark - Room flags

- (void)setFlag:(id)value column:(NSString *)column room:(NSString *)roomId
{
    [self.flags setObject:value ?: NSNull.null forKey:@[roomId, column]];
}

- (id)flagOfColumn:(NSString *)column room:(NSString *)roomId kind:(MXSQLiteValueKind)kind
{
    NSArray *key = @[roomId, column];
    id value = [self.flags cachedObjectForKey:key];
    if (!value)
    {
        value = MXSQLiteReadRoomColumn(self.context, roomId, column, kind);
        if (!value)
        {
            return nil;
        }
        [self.flags cacheObject:value forKey:key];
    }
    return value == NSNull.null ? nil : value;
}

- (void)storePaginationTokenOfRoom:(NSString *)roomId andToken:(NSString *)token
{
    [self setFlag:token column:kColumnLegacyToken room:roomId];
}

- (NSString *)paginationTokenOfRoom:(NSString *)roomId
{
    return [self flagOfColumn:kColumnLegacyToken room:roomId kind:MXSQLiteValueKindText];
}

- (void)storeHasReachedHomeServerPaginationEndForRoom:(NSString *)roomId andValue:(BOOL)value
{
    [self setFlag:@(value) column:kColumnReachedEnd room:roomId];
}

- (BOOL)hasReachedHomeServerPaginationEndForRoom:(NSString *)roomId
{
    return [[self flagOfColumn:kColumnReachedEnd room:roomId kind:MXSQLiteValueKindInteger] boolValue];
}

- (void)storeBackwardPaginationStateForRoom:(NSString *)roomId state:(MXRoomBackwardPaginationState)state
{
    [self setFlag:@(state) column:kColumnBackwardState room:roomId];
}

- (MXRoomBackwardPaginationState)backwardPaginationStateForRoom:(NSString *)roomId
{
    NSNumber *value = [self flagOfColumn:kColumnBackwardState room:roomId kind:MXSQLiteValueKindInteger];
    return value ? (MXRoomBackwardPaginationState)value.integerValue : MXRoomBackwardPaginationStateUnknown;
}

- (void)storeHasLoadedAllRoomMembersForRoom:(NSString *)roomId andValue:(BOOL)value
{
    [self setFlag:@(value) column:kColumnMembersLoaded room:roomId];
}

- (BOOL)hasLoadedAllRoomMembersForRoom:(NSString *)roomId
{
    return [[self flagOfColumn:kColumnMembersLoaded room:roomId kind:MXSQLiteValueKindInteger] boolValue];
}

#pragma mark - MXSQLiteStoreComponent

- (MXSQLiteCommitBody)takePendingWrites
{
    if (!self.states.hasPending && !self.accountData.hasPending && !self.flags.hasPending)
    {
        return nil;
    }
    NSDictionary<NSString *, MXSQLiteStateWrite *> *states = [self.states take];
    NSDictionary<NSString *, id> *accountData = [self.accountData take];
    NSDictionary<NSArray *, id> *flags = [self.flags take];
    MXSQLiteStoreContext *context = self.context;

    return ^BOOL(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error) {
        for (NSString *roomId in states)
        {
            if (![MXSQLiteStateStore writeState:states[roomId] room:roomId context:context connection:connection error:error])
            {
                return NO;
            }
            [commit touchRoomId:roomId];
        }
        for (NSString *roomId in accountData)
        {
            if (![MXSQLiteStateStore writeAccountData:accountData[roomId] room:roomId context:context connection:connection error:error])
            {
                return NO;
            }
            [commit touchRoomId:roomId];
        }
        for (NSArray *key in flags)
        {
            if (!MXSQLiteWriteRoomColumn(connection, context, key[0], key[1], flags[key], error))
            {
                return NO;
            }
        }
        return YES;
    };
}

+ (BOOL)writeAccountData:(id)accountData
                    room:(NSString *)roomId
                 context:(MXSQLiteStoreContext *)context
              connection:(MXSQLiteConnection *)connection
                   error:(NSError **)error
{
    int64_t rid = [context.rooms ensureRidForRoomId:roomId connection:connection error:error];
    if (rid == MXSQLiteNoRoom)
    {
        return NO;
    }
    NSData *data = accountData == NSNull.null ? nil : MXSQLiteArchive(accountData);
    if (!data)
    {
        return [connection run:@"DELETE FROM room_account_data WHERE rid = ?1"
                          bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; } error:error];
    }
    return [connection run:@"INSERT INTO room_account_data (rid, data) VALUES (?1, ?2) "
                            "ON CONFLICT(rid) DO UPDATE SET data = excluded.data"
                      bind:^(MXSQLiteStatement *statement) {
                          [statement bindInt64:rid at:1];
                          [statement bindBlob:data at:2];
                      } error:error];
}

+ (BOOL)writeState:(MXSQLiteStateWrite *)write
              room:(NSString *)roomId
           context:(MXSQLiteStoreContext *)context
        connection:(MXSQLiteConnection *)connection
             error:(NSError **)error
{
    int64_t rid = [context.rooms ensureRidForRoomId:roomId connection:connection error:error];
    if (rid == MXSQLiteNoRoom)
    {
        return NO;
    }

    NSDictionary<NSString *, id> *changes = write.changes;
    if (write.replacesAll)
    {
        if (![connection run:@"DELETE FROM room_state WHERE rid = ?1"
                        bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; } error:error])
        {
            return NO;
        }
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (MXEvent *event in write.events)
        {
            all[MXSQLiteStateKey(event.type, event.stateKey)] = event;
        }
        changes = all;
    }

    for (NSString *key in changes)
    {
        id change = changes[key];
        NSRange separator = [key rangeOfString:@"\x1f"];
        NSString *type = [key substringToIndex:separator.location];
        NSString *stateKey = [key substringFromIndex:NSMaxRange(separator)];
        BOOL ok;
        if (change == NSNull.null)
        {
            ok = [connection run:@"DELETE FROM room_state WHERE rid = ?1 AND type = ?2 AND state_key = ?3"
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindInt64:rid at:1];
                                [statement bindText:type at:2];
                                [statement bindText:stateKey at:3];
                            } error:error];
        }
        else
        {
            MXEvent *event = change;
            NSData *json = MXSQLiteJSONData(event.JSONDictionary);
            if (!json)
            {
                continue;
            }
            ok = [connection run:@"INSERT INTO room_state (rid, type, state_key, event_id, json) VALUES (?1, ?2, ?3, ?4, ?5) "
                                  "ON CONFLICT(rid, type, state_key) DO UPDATE SET event_id = excluded.event_id, json = excluded.json"
                            bind:^(MXSQLiteStatement *statement) {
                                [statement bindInt64:rid at:1];
                                [statement bindText:type at:2];
                                [statement bindText:stateKey at:3];
                                [statement bindText:event.eventId at:4];
                                [statement bindBlob:json at:5];
                            } error:error];
        }
        if (!ok)
        {
            return NO;
        }
    }
    return YES;
}

- (void)didFinishPendingWrites:(BOOL)committed
{
    [self.states finishOldestCommitted:committed];
    [self.accountData finishOldestCommitted:committed];
    [self.flags finishOldestCommitted:committed];
}

- (void)willDeleteRoom:(NSString *)roomId
{
    [self.states removeKeysPassingTest:^BOOL(NSString *key) { return [key isEqualToString:roomId]; }];
    [self.accountData removeKeysPassingTest:^BOOL(NSString *key) { return [key isEqualToString:roomId]; }];
    [self.flags removeKeysPassingTest:^BOOL(NSArray *key) { return [key[0] isEqualToString:roomId]; }];
    // Строки комнаты удалит фасад в следующем коммите: пустой отпечаток — следующая запись состояния пишет всё.
    os_unfair_lock_lock(&_fingerprintLock);
    self.fingerprints[roomId] = @{};
    os_unfair_lock_unlock(&_fingerprintLock);
}

- (void)didDeleteAllData
{
    [self.states removeAll];
    [self.accountData removeAll];
    [self.flags removeAll];
    os_unfair_lock_lock(&_fingerprintLock);
    [self.fingerprints removeAllObjects];
    os_unfair_lock_unlock(&_fingerprintLock);
}

@end
