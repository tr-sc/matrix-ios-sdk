//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteMetaStore.h"

#import <os/lock.h>

#import "MXFilterJSONModel.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteOverlay.h"
#import "MXTools.h"

// Ключи таблицы `meta` (ADR-0022 §1.3). Значение — NSKeyedArchiver объекта, как в MXFileStore.
NSString *const MXSQLiteMetaKeyEventStreamToken = @"event_stream_token";
static NSString *const kKeyUserAccountData = @"user_account_data";
static NSString *const kKeyTermsAgreed = @"is_terms_agreed";
static NSString *const kKeySyncFilterId = @"sync_filter_id";
static NSString *const kKeyWellKnown = @"well_known";
static NSString *const kKeyCapabilities = @"capabilities";
static NSString *const kKeyVersions = @"versions";
static NSString *const kKeyAuthMetadata = @"auth_metadata";
static NSString *const kKeyMaxUploadSize = @"max_upload_size";
NSString *const MXSQLiteMetaKeyLegacyImportDone = @"legacy_import_done";

@interface MXSQLiteMetaStore ()
{
    os_unfair_lock _loadLock;
    BOOL _metaLoaded;
}
@property (nonatomic, weak, readonly) MXSQLiteStoreContext *context;
/// ключ meta → объект | NSNull. Кеш держит всю таблицу (она маленькая): свойства читаются с main часто.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *meta;
/// userId → MXUser.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *userOverlay;
/// filterId → JSON-строка фильтра.
@property (nonatomic, readonly) MXSQLiteOverlay<NSString *, id> *filters;
/// Группы удалены из Matrix; храним их только в памяти, как и раньше читали — без базы.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXGroup *> *groupsById;
@end

@implementation MXSQLiteMetaStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
        _meta = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _userOverlay = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _filters = [[MXSQLiteOverlay alloc] initWithCommittedCache:YES];
        _groupsById = [NSMutableDictionary dictionary];
        _loadLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

#pragma mark - meta

/// Вся таблица `meta` в кеш накладки при первом чтении после открытия.
- (void)loadMetaIfNeeded
{
    os_unfair_lock_lock(&_loadLock);
    BOOL loaded = _metaLoaded;
    os_unfair_lock_unlock(&_loadLock);
    MXSQLiteDatabase *database = self.context.database;
    if (loaded || !database)
    {
        return;
    }
    NSArray<NSArray *> *rows = [database read:^id(MXSQLiteConnection *connection) {
        return [connection query:@"SELECT key, value FROM meta"
                            bind:nil
                             row:^id(MXSQLiteStatement *statement) {
            NSString *key = [statement textAt:0];
            id value = MXSQLiteUnarchive([statement blobAt:1]);
            return key && value ? @[key, value] : nil;
        } error:nil];
    }] ?: @[];
    for (NSArray *row in rows)
    {
        [self.meta cacheObject:row[1] forKey:row[0]];
    }
    os_unfair_lock_lock(&_loadLock);
    _metaLoaded = YES;
    os_unfair_lock_unlock(&_loadLock);
}

- (id)metaObjectForKey:(NSString *)key
{
    [self loadMetaIfNeeded];
    id value = [self.meta cachedObjectForKey:key];
    return value == NSNull.null ? nil : value;
}

- (void)setMetaObject:(id)object forKey:(NSString *)key
{
    [self.meta setObject:object ?: NSNull.null forKey:key];
}

- (NSString *)eventStreamToken { return [self metaObjectForKey:MXSQLiteMetaKeyEventStreamToken]; }
- (void)setEventStreamToken:(NSString *)token { [self setMetaObject:token forKey:MXSQLiteMetaKeyEventStreamToken]; }

- (NSDictionary *)userAccountData { return [self metaObjectForKey:kKeyUserAccountData]; }
- (void)setUserAccountData:(NSDictionary *)data { [self setMetaObject:data forKey:kKeyUserAccountData]; }

- (BOOL)areAllIdentityServerTermsAgreed { return [[self metaObjectForKey:kKeyTermsAgreed] boolValue]; }
- (void)setAreAllIdentityServerTermsAgreed:(BOOL)agreed { [self setMetaObject:@(agreed) forKey:kKeyTermsAgreed]; }

- (NSString *)syncFilterId { return [self metaObjectForKey:kKeySyncFilterId]; }
- (void)setSyncFilterId:(NSString *)filterId { [self setMetaObject:filterId forKey:kKeySyncFilterId]; }

- (MXWellKnown *)homeserverWellknown { return [self metaObjectForKey:kKeyWellKnown]; }
- (void)storeHomeserverWellknown:(MXWellKnown *)wellknown { [self setMetaObject:wellknown forKey:kKeyWellKnown]; }

- (MXCapabilities *)homeserverCapabilities { return [self metaObjectForKey:kKeyCapabilities]; }
- (void)storeHomeserverCapabilities:(MXCapabilities *)capabilities { [self setMetaObject:capabilities forKey:kKeyCapabilities]; }

- (MXMatrixVersions *)supportedMatrixVersions { return [self metaObjectForKey:kKeyVersions]; }
- (void)storeSupportedMatrixVersions:(MXMatrixVersions *)versions { [self setMetaObject:versions forKey:kKeyVersions]; }

- (MXAuthMetadata *)authMetadata { return [self metaObjectForKey:kKeyAuthMetadata]; }
- (void)storeAuthMetadata:(MXAuthMetadata *)metadata { [self setMetaObject:metadata forKey:kKeyAuthMetadata]; }

- (NSInteger)maxUploadSize
{
    NSNumber *size = [self metaObjectForKey:kKeyMaxUploadSize];
    return size ? size.integerValue : -1;
}

- (void)storeMaxUploadSize:(NSInteger)size { [self setMetaObject:@(size) forKey:kKeyMaxUploadSize]; }

- (BOOL)legacyFileStoreImported { return [[self metaObjectForKey:MXSQLiteMetaKeyLegacyImportDone] boolValue]; }
- (void)setLegacyFileStoreImported:(BOOL)imported { [self setMetaObject:@(imported) forKey:MXSQLiteMetaKeyLegacyImportDone]; }

#pragma mark - Users

- (void)storeUser:(MXUser *)user
{
    if (user.userId)
    {
        [self.userOverlay setObject:user forKey:user.userId];
    }
}

- (NSArray<MXUser *> *)users
{
    NSMutableDictionary<NSString *, MXUser *> *users = [NSMutableDictionary dictionary];
    MXSQLiteDatabase *database = self.context.database;
    NSArray<MXUser *> *stored = [database read:^id(MXSQLiteConnection *connection) {
        return [connection query:@"SELECT data FROM user"
                            bind:nil
                             row:^id(MXSQLiteStatement *statement) { return MXSQLiteUnarchive([statement blobAt:0]); }
                           error:nil];
    }] ?: @[];
    for (MXUser *user in stored)
    {
        if ([user isKindOfClass:MXUser.class] && user.userId)
        {
            users[user.userId] = user;
        }
    }
    [[self.userOverlay snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *userId, id user, BOOL *stop) {
        users[userId] = user;
    }];
    return users.allValues;
}

- (MXUser *)userWithUserId:(NSString *)userId
{
    id user = [self.userOverlay cachedObjectForKey:userId];
    if (!user)
    {
        MXSQLiteDatabase *database = self.context.database;
        if (!database)
        {
            return nil;
        }
        NSData *data = [database read:^id(MXSQLiteConnection *connection) {
            return [connection query:@"SELECT data FROM user WHERE user_id = ?1"
                                bind:^(MXSQLiteStatement *statement) { [statement bindText:userId at:1]; }
                                 row:^id(MXSQLiteStatement *statement) { return [statement blobAt:0]; }
                               error:nil].firstObject;
        }];
        user = MXSQLiteUnarchive(data) ?: NSNull.null;
        [self.userOverlay cacheObject:user forKey:userId];
    }
    return [user isKindOfClass:MXUser.class] ? user : nil;
}

#pragma mark - Groups (в памяти)

- (void)storeGroup:(MXGroup *)group
{
    if (!group.groupId)
    {
        return;
    }
    @synchronized (self.groupsById)
    {
        self.groupsById[group.groupId] = group;
    }
}

- (NSArray<MXGroup *> *)groups
{
    @synchronized (self.groupsById)
    {
        return self.groupsById.allValues;
    }
}

- (MXGroup *)groupWithGroupId:(NSString *)groupId
{
    @synchronized (self.groupsById)
    {
        return self.groupsById[groupId];
    }
}

- (void)deleteGroup:(NSString *)groupId
{
    @synchronized (self.groupsById)
    {
        [self.groupsById removeObjectForKey:groupId];
    }
}

#pragma mark - Filters

- (void)storeFilter:(MXFilterJSONModel *)filter withFilterId:(NSString *)filterId
{
    NSString *json = filter.jsonString;
    if (json)
    {
        [self.filters setObject:json forKey:filterId];
    }
}

/// filterId → JSON-строка: база, поверх неё накладка.
- (NSDictionary<NSString *, NSString *> *)allFilters
{
    NSMutableDictionary<NSString *, NSString *> *filters = [NSMutableDictionary dictionary];
    NSArray<NSArray *> *rows = [self.context.database read:^id(MXSQLiteConnection *connection) {
        return [connection query:@"SELECT filter_id, json FROM filter"
                            bind:nil
                             row:^id(MXSQLiteStatement *statement) {
            NSString *filterId = [statement textAt:0];
            NSData *json = [statement blobAt:1];
            NSString *string = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
            return filterId && string ? @[filterId, string] : nil;
        } error:nil];
    }] ?: @[];
    for (NSArray *row in rows)
    {
        filters[row[0]] = row[1];
    }
    [[self.filters snapshot] enumerateKeysAndObjectsUsingBlock:^(NSString *filterId, id json, BOOL *stop) {
        if ([json isKindOfClass:NSString.class])
        {
            filters[filterId] = json;
        }
    }];
    return filters;
}

- (NSArray<NSString *> *)allFilterIds
{
    return [self allFilters].allKeys;
}

- (void)filterWithFilterId:(NSString *)filterId success:(void (^)(MXFilterJSONModel *))success failure:(void (^)(NSError *))failure
{
    NSString *json = [self allFilters][filterId];
    MXFilterJSONModel *filter = json ? [MXFilterJSONModel modelFromJSON:[MXTools deserialiseJSONString:json]] : nil;
    success(filter);
}

- (void)filterIdForFilter:(MXFilterJSONModel *)filter success:(void (^)(NSString *))success failure:(void (^)(NSError *))failure
{
    __block NSString *found;
    [[self allFilters] enumerateKeysAndObjectsUsingBlock:^(NSString *filterId, NSString *json, BOOL *stop) {
        MXFilterJSONModel *cached = [MXFilterJSONModel modelFromJSON:[MXTools deserialiseJSONString:json]];
        if ([cached isEqual:filter])
        {
            found = filterId;
            *stop = YES;
        }
    }];
    success(found);
}

#pragma mark - MXSQLiteStoreComponent

- (MXSQLiteCommitBody)takePendingWrites
{
    if (!self.meta.hasPending && !self.userOverlay.hasPending && !self.filters.hasPending)
    {
        return nil;
    }
    NSDictionary<NSString *, id> *meta = [self.meta take];
    NSDictionary<NSString *, id> *users = [self.userOverlay take];
    NSDictionary<NSString *, id> *filters = [self.filters take];

    return ^BOOL(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error) {
        for (NSString *key in meta)
        {
            NSData *value = meta[key] == NSNull.null ? nil : MXSQLiteArchive(meta[key]);
            BOOL ok = value
                ? [connection run:@"INSERT INTO meta (key, value) VALUES (?1, ?2) "
                                   "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
                             bind:^(MXSQLiteStatement *statement) {
                                 [statement bindText:key at:1];
                                 [statement bindBlob:value at:2];
                             } error:error]
                : [connection run:@"DELETE FROM meta WHERE key = ?1"
                             bind:^(MXSQLiteStatement *statement) { [statement bindText:key at:1]; } error:error];
            if (!ok)
            {
                return NO;
            }
        }
        for (NSString *userId in users)
        {
            NSData *data = MXSQLiteArchive(users[userId]);
            if (data && ![connection run:@"INSERT INTO user (user_id, data) VALUES (?1, ?2) "
                                          "ON CONFLICT(user_id) DO UPDATE SET data = excluded.data"
                                    bind:^(MXSQLiteStatement *statement) {
                                        [statement bindText:userId at:1];
                                        [statement bindBlob:data at:2];
                                    } error:error])
            {
                return NO;
            }
        }
        for (NSString *filterId in filters)
        {
            NSData *json = [filters[filterId] dataUsingEncoding:NSUTF8StringEncoding];
            if (json && ![connection run:@"INSERT INTO filter (filter_id, json) VALUES (?1, ?2) "
                                          "ON CONFLICT(filter_id) DO UPDATE SET json = excluded.json"
                                    bind:^(MXSQLiteStatement *statement) {
                                        [statement bindText:filterId at:1];
                                        [statement bindBlob:json at:2];
                                    } error:error])
            {
                return NO;
            }
        }
        return YES;
    };
}

- (void)didFinishPendingWrites:(BOOL)committed
{
    [self.meta finishOldestCommitted:committed];
    [self.userOverlay finishOldestCommitted:committed];
    [self.filters finishOldestCommitted:committed];
}

- (void)didDeleteAllData
{
    [self.meta removeAll];
    [self.userOverlay removeAll];
    [self.filters removeAll];
    @synchronized (self.groupsById)
    {
        [self.groupsById removeAllObjects];
    }
    os_unfair_lock_lock(&_loadLock);
    _metaLoaded = NO;
    os_unfair_lock_unlock(&_loadLock);
}

@end
