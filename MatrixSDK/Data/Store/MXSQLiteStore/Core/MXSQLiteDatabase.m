//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase_Private.h"

#import <dlfcn.h>
#import <os/lock.h>

#import "MXLog.h"

NSErrorDomain const MXSQLiteErrorDomain = @"org.matrix.sdk.sqlite";
NSString *const MXSQLiteErrorResultCodeKey = @"MXSQLiteErrorResultCode";
NSUInteger const MXSQLiteKeyLength = 32;
NSUInteger const MXSQLiteSaltLength = 16;
NSUInteger const MXSQLitePlaintextHeaderSize = 32;

NSError *MXSQLiteMakeError(MXSQLiteErrorCode code, int resultCode, NSString *message)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"SQLite error";
    if (resultCode != SQLITE_OK)
    {
        userInfo[MXSQLiteErrorResultCodeKey] = @(resultCode);
    }
    return [NSError errorWithDomain:MXSQLiteErrorDomain code:code userInfo:userInfo];
}

NSString *MXSQLiteHandleMessage(sqlite3 *handle)
{
    const char *message = handle ? sqlite3_errmsg(handle) : NULL;
    return message ? [NSString stringWithUTF8String:message] : @"unknown";
}

#pragma mark - Database

static void *MXSQLiteWriterQueueKey = &MXSQLiteWriterQueueKey;

@interface MXSQLiteDatabase ()
{
    os_unfair_lock _readerLock;
}
@property (nonatomic) MXSQLiteConnection *writer;
@property (nonatomic) NSMutableArray<MXSQLiteConnection *> *idleReaders;
@property (nonatomic) NSUInteger readerCount;
@property (nonatomic) dispatch_semaphore_t readerSemaphore;
@property (nonatomic) dispatch_queue_t writerQueue;
@property (nonatomic, readwrite) NSString *cipherVersion;
@property (nonatomic, readwrite) double openMilliseconds;
@property (atomic, readwrite, getter=isClosed) BOOL closed;
@end

@implementation MXSQLiteDatabase

+ (instancetype)openAtURL:(NSURL *)url
                      key:(NSData *)key
                     salt:(NSData *)salt
                 readOnly:(BOOL)readOnly
              readerCount:(NSUInteger)readerCount
                    error:(NSError **)error
{
    if (key.length != MXSQLiteKeyLength || salt.length != MXSQLiteSaltLength)
    {
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorInvalidKey, SQLITE_OK,
                                       [NSString stringWithFormat:@"key %lu / salt %lu bytes", (unsigned long)key.length, (unsigned long)salt.length]);
        }
        return nil;
    }

    MXSQLiteDatabase *database = [[MXSQLiteDatabase alloc] initWithURL:url readOnly:readOnly];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    if (!readOnly)
    {
        [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        // До первого байта базы: -wal и -shm не должны попасть в бэкап даже при неудачном открытии.
        [MXSQLiteDatabaseFiles excludeDirectoryFromBackupOfURL:url];
    }

    NSMutableData *keySpec = [MXSQLiteConnectionOpener keySpecWithKey:key salt:salt];
    BOOL opened = [database openConnectionsWithKeySpec:keySpec readerCount:MAX(readerCount, (NSUInteger)1) error:error];
    memset_s(keySpec.mutableBytes, keySpec.length, 0, keySpec.length);
    if (!opened)
    {
        return nil;
    }

    MXSQLiteConnection *probe = database.writer ?: database.idleReaders.firstObject;
    database.cipherVersion = [probe stringForQuery:@"PRAGMA cipher_version;" error:nil] ?: @"";
    database.openMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    if (!readOnly)
    {
        [MXSQLiteDatabaseFiles protectFilesAtURL:url];
    }
    return database;
}

/// Писатель (если не только чтение) и пул читателей. При ошибке все открытые соединения закрыты.
- (BOOL)openConnectionsWithKeySpec:(NSData *)keySpec readerCount:(NSUInteger)readerCount error:(NSError **)error
{
    NSError *openError;
    if (!self.readOnly)
    {
        self.writer = [MXSQLiteConnectionOpener openConnectionAtURL:self.url keySpec:keySpec role:MXSQLiteRoleWriter error:&openError];
    }
    NSMutableArray<MXSQLiteConnection *> *pool = [NSMutableArray arrayWithCapacity:readerCount];
    MXSQLiteRole readerRole = self.readOnly ? MXSQLiteRoleReadOnly : MXSQLiteRoleReader;
    for (NSUInteger index = 0; index < readerCount && !openError; index++)
    {
        MXSQLiteConnection *reader = [MXSQLiteConnectionOpener openConnectionAtURL:self.url keySpec:keySpec role:readerRole error:&openError];
        if (reader)
        {
            [pool addObject:reader];
        }
    }
    if (openError)
    {
        [self.writer closeHandle];
        self.writer = nil;
        for (MXSQLiteConnection *reader in pool)
        {
            [reader closeHandle];
        }
        if (error)
        {
            *error = openError;
        }
        return NO;
    }
    self.idleReaders = pool;
    self.readerCount = pool.count;
    self.readerSemaphore = dispatch_semaphore_create((long)pool.count);
    return YES;
}

- (instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self)
    {
        _url = url;
        _readOnly = readOnly;
        _readerLock = OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _writerQueue = dispatch_queue_create("org.matrix.sdk.sqlite.write", attributes);
        dispatch_queue_set_specific(_writerQueue, MXSQLiteWriterQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (void)dealloc
{
    [self close];
}


+ (NSString *)sqliteLibraryPath
{
    Dl_info info;
    if (dladdr((const void *)&sqlite3_open_v2, &info) && info.dli_fname)
    {
        return [NSString stringWithUTF8String:info.dli_fname];
    }
    return @"unknown";
}

#pragma mark Writing

- (BOOL)isOnWriterQueue
{
    return dispatch_get_specific(MXSQLiteWriterQueueKey) == (__bridge void *)self;
}

- (BOOL)performTransaction:(MXSQLiteWriteBody NS_NOESCAPE)body error:(NSError **)error
{
    if (self.closed || !self.writer)
    {
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorClosed, SQLITE_OK, self.readOnly ? @"read-only database" : @"database is closed");
        }
        return NO;
    }

    MXSQLiteConnection *connection = self.writer;
    if (![connection execute:@"BEGIN IMMEDIATE;" error:error])
    {
        return NO;
    }

    NSError *bodyError;
    BOOL ok = body(connection, &bodyError);
    if (ok)
    {
        ok = [connection execute:@"COMMIT;" error:&bodyError];
    }
    if (!ok)
    {
        [connection execute:@"ROLLBACK;" error:nil];
        if (error)
        {
            *error = bodyError ?: MXSQLiteMakeError(MXSQLiteErrorStatementFailed, SQLITE_OK, @"transaction rolled back");
        }
    }
    return ok;
}

- (void)write:(MXSQLiteWriteBody)body completion:(void (^)(NSError *))completion
{
    dispatch_async(self.writerQueue, ^{
        NSError *error;
        [self performTransaction:body error:&error];
        if (completion)
        {
            completion(error);
        }
    });
}

- (BOOL)writeSync:(MXSQLiteWriteBody NS_NOESCAPE)body error:(NSError **)error
{
    NSAssert(!self.isOnWriterQueue, @"[MXSQLiteDatabase] writeSync on the writer queue would deadlock");
    if (self.isOnWriterQueue)
    {
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, SQLITE_MISUSE, @"writeSync on the writer queue");
        }
        return NO;
    }

    __block BOOL ok;
    __block NSError *blockError;
    dispatch_sync(self.writerQueue, ^{
        ok = [self performTransaction:body error:&blockError];
    });
    if (!ok && error)
    {
        *error = blockError;
    }
    return ok;
}

- (BOOL)withWriter:(BOOL (^NS_NOESCAPE)(MXSQLiteConnection *, NSError **))body error:(NSError **)error
{
    __block BOOL ok = NO;
    __block NSError *blockError;
    void (^run)(void) = ^{
        if (self.closed || !self.writer)
        {
            blockError = MXSQLiteMakeError(MXSQLiteErrorClosed, SQLITE_OK, @"no writer");
            return;
        }
        ok = body(self.writer, &blockError);
    };
    if (self.isOnWriterQueue)
    {
        run();
    }
    else
    {
        dispatch_sync(self.writerQueue, run);
    }
    if (!ok && error)
    {
        *error = blockError;
    }
    return ok;
}

#pragma mark Reading

- (id)read:(id (^NS_NOESCAPE)(MXSQLiteConnection *))body
{
    if (self.closed)
    {
        return nil;
    }

    dispatch_semaphore_wait(self.readerSemaphore, DISPATCH_TIME_FOREVER);
    os_unfair_lock_lock(&_readerLock);
    MXSQLiteConnection *reader = self.idleReaders.lastObject;
    [self.idleReaders removeLastObject];
    os_unfair_lock_unlock(&_readerLock);

    id result = reader ? body(reader) : nil;

    os_unfair_lock_lock(&_readerLock);
    if (reader)
    {
        [self.idleReaders addObject:reader];
    }
    os_unfair_lock_unlock(&_readerLock);
    dispatch_semaphore_signal(self.readerSemaphore);
    return result;
}

#pragma mark Maintenance

- (void)checkpoint:(MXSQLiteCheckpointMode)mode
{
    [self withWriter:^BOOL(MXSQLiteConnection *connection, NSError **error) {
        int rc = sqlite3_wal_checkpoint_v2(connection->_handle, NULL,
                                           mode == MXSQLiteCheckpointTruncate ? SQLITE_CHECKPOINT_TRUNCATE : SQLITE_CHECKPOINT_PASSIVE,
                                           NULL, NULL);
        if (rc != SQLITE_OK && rc != SQLITE_BUSY)
        {
            MXLogWarning(@"[MXSQLiteDatabase] checkpoint rc=%d", rc);
        }
        return YES;
    } error:nil];
}

- (uint64_t)fileSize
{
    uint64_t total = 0;
    for (NSString *suffix in @[@"", @"-wal"])
    {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[self.url.path stringByAppendingString:suffix] error:nil];
        total += attributes.fileSize;
    }
    return total;
}

- (void)close
{
    if (self.closed)
    {
        return;
    }
    self.closed = YES;

    void (^closeWriter)(void) = ^{
        [self.writer closeHandle];
        self.writer = nil;
    };
    if (self.isOnWriterQueue)
    {
        closeWriter();
    }
    else
    {
        dispatch_sync(self.writerQueue, closeWriter);
    }

    // Дождаться всех читателей: занятые вернутся в пул и только потом закроются.
    for (NSUInteger index = 0; index < self.readerCount; index++)
    {
        dispatch_semaphore_wait(self.readerSemaphore, DISPATCH_TIME_FOREVER);
    }
    os_unfair_lock_lock(&_readerLock);
    for (MXSQLiteConnection *reader in self.idleReaders)
    {
        [reader closeHandle];
    }
    [self.idleReaders removeAllObjects];
    os_unfair_lock_unlock(&_readerLock);
    for (NSUInteger index = 0; index < self.readerCount; index++)
    {
        dispatch_semaphore_signal(self.readerSemaphore);
    }
}


+ (void)removeFilesAtURL:(NSURL *)url
{
    [MXSQLiteDatabaseFiles removeFilesAtURL:url];
}

@end
