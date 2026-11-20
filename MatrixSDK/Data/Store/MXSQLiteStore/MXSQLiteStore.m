//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStore.h"

#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MXBackgroundModeHandler.h"
#import "MXCredentials.h"
#import "MXLog.h"
#import "MXSDKOptions.h"
#import "MatrixSDKSwiftHeader.h"

#import "MXSQLiteDatabase.h"
#import "MXSQLiteRoomRegistry.h"
#import "MXSQLiteSchema.h"
#import "MXSQLiteStoreComponent.h"
#import "MXSQLiteEventStore.h"
#import "MXSQLiteStateStore.h"
#import "MXSQLiteMetaStore.h"
#import "MXSQLiteReceiptStore.h"
#import "MXSQLiteOutgoingStore.h"

static NSString *const kMXSQLiteStoreFolder = @"MXSQLiteStore";
static NSString *const kMXSQLiteStoreFile = @"store.sqlite";
static NSUInteger const kMXSQLiteStoreReaderCount = 2;

static NSString *gKeychainAccessGroup;

@interface MXSQLiteStore ()
{
    os_unfair_lock _pendingLock;
}
@property (nonatomic, readonly) id<MXSQLiteKeyProviding> keyProvider;
@property (nonatomic, readonly) NSURL *rootDirectory;
@property (nonatomic, readonly) MXSQLiteStoreContext *context;
@property (nonatomic, readonly) MXSQLiteRoomRegistry *rooms;
@property (nonatomic, readonly) NSArray<id<MXSQLiteStoreComponent>> *components;
/// selector → компонент. Строится один раз по протоколам компонентов, не меняется.
@property (nonatomic, readonly) NSDictionary<NSString *, id<MXSQLiteStoreComponent>> *routes;
@property (nonatomic, readonly) dispatch_queue_t openQueue;
/// Комнаты, строки которых удаляются в следующем коммите.
@property (nonatomic) NSMutableOrderedSet<NSString *> *pendingRoomDeletions;
@property (nonatomic) id<MXBackgroundTask> commitBackgroundTask;
@end

// Методы MXStore / MXTimelineStore, которых фасад не реализует, реализуют компоненты: их отдаёт
// forwardingTargetForSelector:, полноту проверяет MXSQLiteStoreFacadeTests.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"
@implementation MXSQLiteStore

@synthesize roomSummaryStore = _roomSummaryStore;
@synthesize storeService = _storeService;
@synthesize metricsDelegate = _metricsDelegate;

#pragma mark - Class

+ (NSString *)keychainAccessGroup
{
    @synchronized (self)
    {
        return gKeychainAccessGroup;
    }
}

+ (void)setKeychainAccessGroup:(NSString *)keychainAccessGroup
{
    @synchronized (self)
    {
        gKeychainAccessGroup = [keychainAccessGroup copy];
    }
}

+ (NSURL *)defaultRootDirectory
{
    NSURL *container = [NSFileManager.defaultManager applicationGroupContainerURL];
    if (!container)
    {
        container = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    }
    return [container URLByAppendingPathComponent:kMXSQLiteStoreFolder isDirectory:YES];
}

/// Первые 16 hex sha256(userId): в пути не светится MXID, длина постоянная.
+ (NSString *)hashedUserId:(NSString *)userId
{
    NSData *data = [userId dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (NSUInteger index = 0; index < 8; index++)
    {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

+ (NSURL *)databaseURLForUserId:(NSString *)userId rootDirectory:(NSURL *)rootDirectory
{
    return [[rootDirectory URLByAppendingPathComponent:[self hashedUserId:userId] isDirectory:YES]
            URLByAppendingPathComponent:kMXSQLiteStoreFile isDirectory:NO];
}

+ (NSString *)keyIdentifierForUserId:(NSString *)userId
{
    return [@"store." stringByAppendingString:[self hashedUserId:userId]];
}

+ (void)deleteDataForUserId:(NSString *)userId rootDirectory:(NSURL *)rootDirectory keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
{
    NSURL *url = [self databaseURLForUserId:userId rootDirectory:rootDirectory ?: self.defaultRootDirectory];
    [MXSQLiteDatabase removeFilesAtURL:url];
    [NSFileManager.defaultManager removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];
    [keyProvider removeKeyMaterialForIdentifier:[self keyIdentifierForUserId:userId]];
}

#pragma mark - Init

- (instancetype)init
{
    return [self initWithKeyProvider:[[MXSQLiteKeychainKeyProvider alloc] initWithAccessGroup:MXSQLiteStore.keychainAccessGroup]
                       rootDirectory:nil
                            readOnly:NO];
}

- (instancetype)initWithKeyProvider:(id<MXSQLiteKeyProviding>)keyProvider rootDirectory:(NSURL *)rootDirectory readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self)
    {
        _keyProvider = keyProvider;
        _rootDirectory = rootDirectory ?: MXSQLiteStore.defaultRootDirectory;
        _readOnly = readOnly;
        _pendingLock = OS_UNFAIR_LOCK_INIT;
        _pendingRoomDeletions = [NSMutableOrderedSet orderedSet];
        _openQueue = dispatch_queue_create("org.matrix.sdk.sqlite.open", DISPATCH_QUEUE_SERIAL);

        _rooms = [MXSQLiteRoomRegistry new];
        _context = [[MXSQLiteStoreContext alloc] initWithRooms:_rooms];
        _context.store = self;

        // Компоненты живут с самого начала: до open база nil, чтение пустое — как у MXFileStore до загрузки.
        MXSQLiteOutgoingStore *outgoing = [[MXSQLiteOutgoingStore alloc] initWithContext:_context];
        _context.outgoing = outgoing;
        _components = @[
            [[MXSQLiteEventStore alloc] initWithContext:_context],
            [[MXSQLiteStateStore alloc] initWithContext:_context],
            [[MXSQLiteMetaStore alloc] initWithContext:_context],
            [[MXSQLiteReceiptStore alloc] initWithContext:_context],
            outgoing,
        ];
        _routes = [MXSQLiteStore routesForComponents:_components];
    }
    return self;
}

#pragma mark - Routing

/// Компонент — владелец каждого метода своего протокола (без унаследованных из `MXSQLiteStoreComponent`).
+ (NSDictionary<NSString *, id<MXSQLiteStoreComponent>> *)routesForComponents:(NSArray<id<MXSQLiteStoreComponent>> *)components
{
    NSArray<Protocol *> *protocols = @[@protocol(MXSQLiteEventStoring), @protocol(MXSQLiteStateStoring),
                                       @protocol(MXSQLiteMetaStoring), @protocol(MXSQLiteReceiptStoring),
                                       @protocol(MXSQLiteOutgoingStoring)];
    NSMutableDictionary *routes = [NSMutableDictionary dictionary];
    for (id<MXSQLiteStoreComponent> component in components)
    {
        for (Protocol *protocol in protocols)
        {
            if (![component conformsToProtocol:protocol])
            {
                continue;
            }
            for (BOOL required = YES; ; required = NO)
            {
                unsigned int count = 0;
                struct objc_method_description *methods = protocol_copyMethodDescriptionList(protocol, required, YES, &count);
                for (unsigned int index = 0; index < count; index++)
                {
                    NSString *name = NSStringFromSelector(methods[index].name);
                    NSAssert(!routes[name], @"[MXSQLiteStore] %@ is declared by two components", name);
                    routes[name] = component;
                }
                free(methods);
                if (!required)
                {
                    break;
                }
            }
        }
    }
    return routes;
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    id target = _routes[NSStringFromSelector(selector)];
    return target ?: [super forwardingTargetForSelector:selector];
}

- (BOOL)respondsToSelector:(SEL)selector
{
    if ([super respondsToSelector:selector])
    {
        return YES;
    }
    id<MXSQLiteStoreComponent> target = _routes[NSStringFromSelector(selector)];
    return [target respondsToSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    NSMethodSignature *signature = [super methodSignatureForSelector:selector];
    if (!signature)
    {
        signature = [(NSObject *)_routes[NSStringFromSelector(selector)] methodSignatureForSelector:selector];
    }
    return signature;
}

#pragma mark - MXStore: lifecycle

- (BOOL)isPermanent
{
    return YES;
}

- (MXSQLiteDatabase *)database
{
    return self.context.database;
}

- (void)openWithCredentials:(MXCredentials *)credentials onComplete:(void (^)(void))onComplete failure:(void (^)(NSError *))failure
{
    NSParameterAssert(credentials.userId);
    self.context.credentials = credentials;
    if (!_roomSummaryStore)
    {
        // До iP5 сводки остаются в CoreData (отдельный протокол, переход прозрачен).
        _roomSummaryStore = [[MXCoreDataRoomSummaryStore alloc] initWithCredentials:credentials];
    }

    id<MXBackgroundModeHandler> handler = [MXSDKOptions sharedInstance].backgroundModeHandler;
    id<MXBackgroundTask> backgroundTask = [handler startBackgroundTaskWithName:@"[MXSQLiteStore] openWithCredentials"];

    dispatch_async(self.openQueue, ^{
        NSError *error;
        MXSQLiteDatabase *database = [self openDatabaseForUserId:credentials.userId error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [backgroundTask stop];
            if (!database)
            {
                MXLogErrorDetails(@"[MXSQLiteStore] open failed", @{@"error": error ?: NSNull.null});
                if (failure)
                {
                    failure(error);
                }
                return;
            }
            self.context.database = database;
            if ([self.metricsDelegate respondsToSelector:@selector(store:didOpenInMilliseconds:databaseBytes:)])
            {
                [self.metricsDelegate store:self didOpenInMilliseconds:database.openMilliseconds databaseBytes:database.fileSize];
            }
            if (onComplete)
            {
                onComplete();
            }
        });
    });
}

/// Открытие с самовосстановлением. Отказ без пересоздания — только когда под нами не SQLCipher: снести базу тут
/// значит молча продолжить открытым текстом.
- (MXSQLiteDatabase *)openDatabaseForUserId:(NSString *)userId error:(NSError **)error
{
    NSURL *url = [MXSQLiteStore databaseURLForUserId:userId rootDirectory:self.rootDirectory];
    NSString *keyIdentifier = [MXSQLiteStore keyIdentifierForUserId:userId];

    if (self.readOnly && ![NSFileManager.defaultManager fileExistsAtPath:url.path])
    {
        if (error)
        {
            *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorOpenFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"no store file"}];
        }
        return nil;
    }

    MXSQLiteKeyMaterial *material = [self.keyProvider keyMaterialForIdentifier:keyIdentifier create:!self.readOnly error:error];
    if (!material)
    {
        return nil;
    }

    NSError *openError;
    MXSQLiteDatabase *database = [MXSQLiteDatabase openAtURL:url key:material.key salt:material.salt readOnly:self.readOnly
                                                 readerCount:kMXSQLiteStoreReaderCount error:&openError];
    if (!database && !self.readOnly && [self isRecoverableOpenError:openError])
    {
        NSString *reason = openError.code == MXSQLiteErrorKeyRejected ? @"key_rejected" : @"corrupt";
        MXLogWarning(@"[MXSQLiteStore] Recreating the store (%@): %@", reason, openError.localizedDescription);
        [MXSQLiteDatabase removeFilesAtURL:url];
        [self.keyProvider removeKeyMaterialForIdentifier:keyIdentifier];
        material = [self.keyProvider keyMaterialForIdentifier:keyIdentifier create:YES error:error];
        if (!material)
        {
            return nil;
        }
        [self reportResetWithReason:reason];
        database = [MXSQLiteDatabase openAtURL:url key:material.key salt:material.salt readOnly:NO
                                   readerCount:kMXSQLiteStoreReaderCount error:&openError];
    }
    if (!database)
    {
        if (error)
        {
            *error = openError;
        }
        return nil;
    }

    if (![self prepareSchemaOfDatabase:database error:error])
    {
        [database close];
        return nil;
    }
    return database;
}

- (BOOL)isRecoverableOpenError:(NSError *)error
{
    if (![error.domain isEqualToString:MXSQLiteErrorDomain])
    {
        return NO;
    }
    if (error.code == MXSQLiteErrorKeyRejected)
    {
        return YES;
    }
    int resultCode = [error.userInfo[MXSQLiteErrorResultCodeKey] intValue];
    return error.code == MXSQLiteErrorOpenFailed && (resultCode == 11 /* SQLITE_CORRUPT */ || resultCode == 26 /* SQLITE_NOTADB */);
}

- (BOOL)prepareSchemaOfDatabase:(MXSQLiteDatabase *)database error:(NSError **)error
{
    if (database.readOnly)
    {
        // NSE схему не трогает: чужая версия — работаем как без стора.
        int64_t version = [[database read:^id(MXSQLiteConnection *connection) {
            return @([connection int64ForQuery:@"PRAGMA user_version;" defaultValue:0 error:nil]);
        }] longLongValue];
        if (version != MXSQLiteSchema.currentVersion)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorSchema
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"schema %lld", version]}];
            }
            return NO;
        }
        return YES;
    }

    __block MXSQLiteSchemaOutcome outcome = MXSQLiteSchemaOutcomeUpToDate;
    BOOL ok = [database withWriter:^BOOL(MXSQLiteConnection *connection, NSError **blockError) {
        return [MXSQLiteSchema prepareConnection:connection
                                   targetVersion:MXSQLiteSchema.currentVersion
                                      statements:MXSQLiteSchema.statements
                                      migrations:@{}
                                         outcome:&outcome
                                           error:blockError];
    } error:error];
    if (ok && outcome == MXSQLiteSchemaOutcomeRebuilt)
    {
        [self reportResetWithReason:@"schema_mismatch"];
    }
    return ok;
}

- (void)reportResetWithReason:(NSString *)reason
{
    if ([self.metricsDelegate respondsToSelector:@selector(store:didResetWithReason:)])
    {
        [self.metricsDelegate store:self didResetWithReason:reason];
    }
}

#pragma mark - MXStore: commit

- (void)commit
{
    [self commitWithCompletion:nil];
}

/// Накладки всех компонентов и отложенные удаления комнат. Тела компонентов — в том порядке, в котором
/// компоненты созданы; транзакция одна.
- (NSArray<NSArray *> *)takePendingWrites
{
    NSMutableArray<NSArray *> *parts = [NSMutableArray array];
    for (id<MXSQLiteStoreComponent> component in self.components)
    {
        if ([component respondsToSelector:@selector(takePendingWrites)])
        {
            MXSQLiteCommitBody body = [component takePendingWrites];
            if (body)
            {
                [parts addObject:@[component, body]];
            }
        }
    }
    return parts;
}

- (NSArray<NSString *> *)takePendingRoomDeletions
{
    os_unfair_lock_lock(&_pendingLock);
    // copy: -[NSMutableOrderedSet array] — живой прокси, removeAllObjects опустошил бы и его.
    NSArray<NSString *> *roomIds = [self.pendingRoomDeletions.array copy];
    [self.pendingRoomDeletions removeAllObjects];
    os_unfair_lock_unlock(&_pendingLock);
    return roomIds;
}

- (void)restorePendingRoomDeletions:(NSArray<NSString *> *)roomIds
{
    os_unfair_lock_lock(&_pendingLock);
    [self.pendingRoomDeletions addObjectsFromArray:roomIds];
    os_unfair_lock_unlock(&_pendingLock);
}

/// Тело общей транзакции коммита.
- (MXSQLiteWriteBody)transactionBodyWithParts:(NSArray<NSArray *> *)parts
                                    deletions:(NSArray<NSString *> *)deletions
                                       commit:(MXSQLiteCommitContext *)commit
                                    revisions:(NSMutableDictionary<NSString *, NSNumber *> *)revisions
{
    return ^BOOL(MXSQLiteConnection *connection, NSError **error) {
        for (NSString *roomId in deletions)
        {
            if (![self deleteRowsOfRoom:roomId connection:connection error:error])
            {
                return NO;
            }
        }
        for (NSArray *part in parts)
        {
            MXSQLiteCommitBody body = part[1];
            if (!body(connection, commit, error))
            {
                return NO;
            }
        }
        for (NSString *roomId in commit.touchedRoomIds)
        {
            int64_t rid = [self.rooms ridForRoomId:roomId connection:connection];
            if (rid == MXSQLiteNoRoom)
            {
                continue;
            }
            if (![connection run:@"UPDATE room SET revision = revision + 1 WHERE rid = ?1"
                            bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; } error:error])
            {
                return NO;
            }
            NSNumber *revision = [connection query:@"SELECT revision FROM room WHERE rid = ?1"
                                              bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid at:1]; }
                                               row:^id(MXSQLiteStatement *statement) { return @([statement int64At:0]); }
                                             error:nil].firstObject;
            if (revision)
            {
                revisions[roomId] = revision;
            }
        }
        return YES;
    };
}

- (BOOL)deleteRowsOfRoom:(NSString *)roomId connection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    NSNumber *rid = [connection query:@"SELECT rid FROM room WHERE room_id = ?1"
                                 bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; }
                                  row:^id(MXSQLiteStatement *statement) { return @([statement int64At:0]); }
                                error:error].firstObject;
    if (!rid)
    {
        return YES;
    }
    for (NSString *table in MXSQLiteSchema.roomScopedTables)
    {
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE rid = ?1", table];
        if (![connection run:sql bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid.longLongValue at:1]; } error:error])
        {
            return NO;
        }
    }
    if (![connection run:@"DELETE FROM room WHERE rid = ?1"
                    bind:^(MXSQLiteStatement *statement) { [statement bindInt64:rid.longLongValue at:1]; }
                   error:error])
    {
        return NO;
    }
    // Иначе запись в эту комнату в той же транзакции возьмёт из кеша rid удалённой строки `room`.
    [self.rooms forgetRoomId:roomId];
    return YES;
}

- (void)finishParts:(NSArray<NSArray *> *)parts deletions:(NSArray<NSString *> *)deletions committed:(BOOL)committed
{
    for (NSArray *part in parts)
    {
        id<MXSQLiteStoreComponent> component = part[0];
        if ([component respondsToSelector:@selector(didFinishPendingWrites:)])
        {
            [component didFinishPendingWrites:committed];
        }
    }
    if (!committed)
    {
        // rid, выданные откатившейся транзакцией, в базе не появились.
        [self.rooms reset];
        [self restorePendingRoomDeletions:deletions];
    }
}

- (void)commitWithCompletion:(void (^)(void))completion
{
    MXSQLiteDatabase *database = self.context.database;
    NSArray<NSArray *> *parts = (database && !self.readOnly) ? [self takePendingWrites] : @[];
    NSArray<NSString *> *deletions = (database && !self.readOnly) ? [self takePendingRoomDeletions] : @[];
    if (!parts.count && !deletions.count)
    {
        if (completion)
        {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    // Как у MXFileStore: запись переживает уход в фон.
    if (!self.commitBackgroundTask.isRunning)
    {
        id<MXBackgroundModeHandler> handler = [MXSDKOptions sharedInstance].backgroundModeHandler;
        self.commitBackgroundTask = [handler startBackgroundTaskWithName:@"[MXSQLiteStore commit]"];
    }

    MXSQLiteCommitContext *commit = [MXSQLiteCommitContext new];
    NSMutableDictionary<NSString *, NSNumber *> *revisions = [NSMutableDictionary dictionary];
    MXSQLiteWriteBody body = [self transactionBodyWithParts:parts deletions:deletions commit:commit revisions:revisions];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

    [database write:body completion:^(NSError *error) {
        double milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        [self finishParts:parts deletions:deletions committed:error == nil];
        if (error)
        {
            MXLogErrorDetails(@"[MXSQLiteStore] commit failed", @{@"error": error});
        }
        else if ([self.metricsDelegate respondsToSelector:@selector(store:didCommitInMilliseconds:events:rooms:)])
        {
            [self.metricsDelegate store:self didCommitInMilliseconds:milliseconds events:commit.eventCount rooms:revisions.count];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && revisions.count)
            {
                [NSNotificationCenter.defaultCenter postNotificationName:MXStoreDidCommitNotification object:self userInfo:revisions];
            }
            [self.commitBackgroundTask stop];
            self.commitBackgroundTask = nil;
            if (completion)
            {
                completion();
            }
        });
    }];
}

- (void)flush
{
    MXSQLiteDatabase *database = self.context.database;
    if (!database || self.readOnly || database.isOnWriterQueue)
    {
        return;
    }
    NSArray<NSArray *> *parts = [self takePendingWrites];
    NSArray<NSString *> *deletions = [self takePendingRoomDeletions];
    if (!parts.count && !deletions.count)
    {
        return;
    }
    MXSQLiteCommitContext *commit = [MXSQLiteCommitContext new];
    NSMutableDictionary *revisions = [NSMutableDictionary dictionary];
    NSError *error;
    BOOL ok = [database writeSync:[self transactionBodyWithParts:parts deletions:deletions commit:commit revisions:revisions] error:&error];
    [self finishParts:parts deletions:deletions committed:ok];
    if (!ok)
    {
        MXLogErrorDetails(@"[MXSQLiteStore] flush failed", @{@"error": error ?: NSNull.null});
    }
}

- (void)close
{
    [self flush];
    MXSQLiteDatabase *database = self.context.database;
    if (database && !self.readOnly)
    {
        [database checkpoint:MXSQLiteCheckpointPassive];
    }
    self.context.database = nil;
    [database close];
}

#pragma mark - MXStore: deletion

- (void)deleteRoom:(NSString *)roomId
{
    for (id<MXSQLiteStoreComponent> component in self.components)
    {
        if ([component respondsToSelector:@selector(willDeleteRoom:)])
        {
            [component willDeleteRoom:roomId];
        }
    }
    os_unfair_lock_lock(&_pendingLock);
    [self.pendingRoomDeletions addObject:roomId];
    os_unfair_lock_unlock(&_pendingLock);
    [_roomSummaryStore removeSummaryOfRoom:roomId];
}

- (void)deleteAllData
{
    MXLogDebug(@"[MXSQLiteStore] deleteAllData");
    MXSQLiteDatabase *database = self.context.database;
    self.context.database = nil;
    [database close];

    NSString *userId = self.context.credentials.userId;
    if (userId && !self.readOnly)
    {
        [MXSQLiteStore deleteDataForUserId:userId rootDirectory:self.rootDirectory keyProvider:self.keyProvider];
    }
    [self takePendingRoomDeletions];
    [self.rooms reset];
    for (id<MXSQLiteStoreComponent> component in self.components)
    {
        if ([component respondsToSelector:@selector(didDeleteAllData)])
        {
            [component didDeleteAllData];
        }
    }
    [_roomSummaryStore removeAllSummaries];
}

#pragma mark - MXTimelineStore: summaries (iP5)

- (NSArray<id<MXRoomSummaryProtocol>> *)summariesOrderedByActivity:(NSUInteger)limit
{
    // iP5: `MXSQLiteRoomSummaryStore` и запрос по `summary_activity`. До него CoreData не умеет «первые N».
    return @[];
}

@end
#pragma clang diagnostic pop
