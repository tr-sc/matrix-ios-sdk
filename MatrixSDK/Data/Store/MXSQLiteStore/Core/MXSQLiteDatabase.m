//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase.h"

#import <SQLCipher/sqlite3.h>
#import <dlfcn.h>
#import <os/lock.h>

#import "MXLog.h"

NSErrorDomain const MXSQLiteErrorDomain = @"org.matrix.sdk.sqlite";
NSString *const MXSQLiteErrorResultCodeKey = @"MXSQLiteErrorResultCode";
NSUInteger const MXSQLiteKeyLength = 32;
NSUInteger const MXSQLiteSaltLength = 16;
NSUInteger const MXSQLitePlaintextHeaderSize = 32;

static NSError *MXSQLiteMakeError(MXSQLiteErrorCode code, int resultCode, NSString *message)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"SQLite error";
    if (resultCode != SQLITE_OK)
    {
        userInfo[MXSQLiteErrorResultCodeKey] = @(resultCode);
    }
    return [NSError errorWithDomain:MXSQLiteErrorDomain code:code userInfo:userInfo];
}

static NSString *MXSQLiteHandleMessage(sqlite3 *handle)
{
    const char *message = handle ? sqlite3_errmsg(handle) : NULL;
    return message ? [NSString stringWithUTF8String:message] : @"unknown";
}

#pragma mark - Statement

@interface MXSQLiteStatement ()
{
    @package
    sqlite3_stmt *_statement;
    sqlite3 *_handle;
}
@end

@implementation MXSQLiteStatement

- (instancetype)initWithStatement:(sqlite3_stmt *)statement handle:(sqlite3 *)handle
{
    self = [super init];
    if (self)
    {
        _statement = statement;
        _handle = handle;
    }
    return self;
}

- (void)finalizeStatement
{
    if (_statement)
    {
        sqlite3_finalize(_statement);
        _statement = NULL;
    }
}

- (void)dealloc
{
    [self finalizeStatement];
}

- (void)resetStatement
{
    sqlite3_reset(_statement);
    sqlite3_clear_bindings(_statement);
}

- (void)bindInt64:(int64_t)value at:(int)index
{
    sqlite3_bind_int64(_statement, index, value);
}

- (void)bindDouble:(double)value at:(int)index
{
    sqlite3_bind_double(_statement, index, value);
}

- (void)bindText:(NSString *)value at:(int)index
{
    if (!value)
    {
        sqlite3_bind_null(_statement, index);
        return;
    }
    sqlite3_bind_text(_statement, index, value.UTF8String, -1, SQLITE_TRANSIENT);
}

- (void)bindBlob:(NSData *)value at:(int)index
{
    if (!value)
    {
        sqlite3_bind_null(_statement, index);
        return;
    }
    // Пустой blob — не NULL: у sqlite3_bind_blob с нулевым указателем получился бы NULL.
    sqlite3_bind_blob(_statement, index, value.length ? value.bytes : "", (int)value.length, SQLITE_TRANSIENT);
}

- (void)bindNullAt:(int)index
{
    sqlite3_bind_null(_statement, index);
}

- (BOOL)stepRow:(NSError **)error
{
    int rc = sqlite3_step(_statement);
    if (rc == SQLITE_ROW)
    {
        return YES;
    }
    if (rc != SQLITE_DONE && error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
    }
    else if (error)
    {
        *error = nil;
    }
    return NO;
}

- (BOOL)execute:(NSError **)error
{
    int rc = sqlite3_step(_statement);
    if (rc == SQLITE_DONE || rc == SQLITE_ROW)
    {
        return YES;
    }
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
    }
    return NO;
}

- (int)columnCount
{
    return sqlite3_column_count(_statement);
}

- (BOOL)isNullAt:(int)column
{
    return sqlite3_column_type(_statement, column) == SQLITE_NULL;
}

- (int64_t)int64At:(int)column
{
    return sqlite3_column_int64(_statement, column);
}

- (double)doubleAt:(int)column
{
    return sqlite3_column_double(_statement, column);
}

- (NSString *)textAt:(int)column
{
    const unsigned char *text = sqlite3_column_text(_statement, column);
    if (!text)
    {
        return nil;
    }
    return [[NSString alloc] initWithBytes:text length:(NSUInteger)sqlite3_column_bytes(_statement, column) encoding:NSUTF8StringEncoding];
}

- (NSData *)blobAt:(int)column
{
    if (sqlite3_column_type(_statement, column) == SQLITE_NULL)
    {
        return nil;
    }
    const void *bytes = sqlite3_column_blob(_statement, column);
    int length = sqlite3_column_bytes(_statement, column);
    return bytes ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
}

@end

#pragma mark - Connection

@interface MXSQLiteConnection ()
{
    @package
    sqlite3 *_handle;
}
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLiteStatement *> *statements;
@end

@implementation MXSQLiteConnection

- (instancetype)initWithHandle:(sqlite3 *)handle readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self)
    {
        _handle = handle;
        _readOnly = readOnly;
        _statements = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)closeHandle
{
    for (MXSQLiteStatement *statement in _statements.allValues)
    {
        [statement finalizeStatement];
    }
    [_statements removeAllObjects];
    if (_handle)
    {
        sqlite3_close_v2(_handle);
        _handle = NULL;
    }
}

- (void)dealloc
{
    [self closeHandle];
}

- (BOOL)execute:(NSString *)sql error:(NSError **)error
{
    char *message = NULL;
    int rc = sqlite3_exec(_handle, sql.UTF8String, NULL, NULL, &message);
    if (rc == SQLITE_OK)
    {
        return YES;
    }
    NSString *text = message ? [NSString stringWithUTF8String:message] : MXSQLiteHandleMessage(_handle);
    sqlite3_free(message);
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, text);
    }
    return NO;
}

- (MXSQLiteStatement *)prepare:(NSString *)sql error:(NSError **)error
{
    MXSQLiteStatement *cached = _statements[sql];
    if (cached)
    {
        [cached resetStatement];
        return cached;
    }

    sqlite3_stmt *raw = NULL;
    int rc = sqlite3_prepare_v3(_handle, sql.UTF8String, -1, SQLITE_PREPARE_PERSISTENT, &raw, NULL);
    if (rc != SQLITE_OK || !raw)
    {
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorStatementFailed, rc, MXSQLiteHandleMessage(_handle));
        }
        return nil;
    }
    MXSQLiteStatement *statement = [[MXSQLiteStatement alloc] initWithStatement:raw handle:_handle];
    _statements[sql] = statement;
    return statement;
}

- (BOOL)run:(NSString *)sql bind:(void (^NS_NOESCAPE)(MXSQLiteStatement *))bind error:(NSError **)error
{
    MXSQLiteStatement *statement = [self prepare:sql error:error];
    if (!statement)
    {
        return NO;
    }
    if (bind)
    {
        bind(statement);
    }
    BOOL ok = [statement execute:error];
    [statement resetStatement];
    return ok;
}

- (NSArray *)query:(NSString *)sql
              bind:(void (^NS_NOESCAPE)(MXSQLiteStatement *))bind
               row:(id (^NS_NOESCAPE)(MXSQLiteStatement *))row
             error:(NSError **)error
{
    MXSQLiteStatement *statement = [self prepare:sql error:error];
    if (!statement)
    {
        return nil;
    }
    if (bind)
    {
        bind(statement);
    }

    NSMutableArray *rows = [NSMutableArray array];
    NSError *stepError;
    while ([statement stepRow:&stepError])
    {
        id object = row(statement);
        if (object)
        {
            [rows addObject:object];
        }
    }
    [statement resetStatement];
    if (stepError)
    {
        if (error)
        {
            *error = stepError;
        }
        return nil;
    }
    return rows;
}

- (NSString *)stringForQuery:(NSString *)sql error:(NSError **)error
{
    return [self query:sql bind:nil row:^id(MXSQLiteStatement *statement) {
        return [statement textAt:0] ?: @"";
    } error:error].firstObject;
}

- (int64_t)int64ForQuery:(NSString *)sql defaultValue:(int64_t)defaultValue error:(NSError **)error
{
    NSNumber *value = [self query:sql bind:nil row:^id(MXSQLiteStatement *statement) {
        return @([statement int64At:0]);
    } error:error].firstObject;
    return value ? value.longLongValue : defaultValue;
}

- (int64_t)lastInsertRowId
{
    return sqlite3_last_insert_rowid(_handle);
}

- (int)changes
{
    return sqlite3_changes(_handle);
}

@end

#pragma mark - Database

static void *MXSQLiteWriterQueueKey = &MXSQLiteWriterQueueKey;
static NSString *const kMXSQLiteCipherVersionQuery = @"PRAGMA cipher_version;";
static NSString *gMXSQLiteCipherVersionQuery;

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
        NSURL *directory = url.URLByDeletingLastPathComponent;
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Ключ живёт в этом буфере только на время открытия и затирается в конце.
    NSMutableData *keySpec = [self keySpecWithKey:key salt:salt];

    NSError *openError;
    if (!readOnly)
    {
        database.writer = [self openConnectionAtURL:url keySpec:keySpec role:MXSQLiteRoleWriter error:&openError];
    }
    NSUInteger readers = MAX(readerCount, (NSUInteger)1);
    NSMutableArray *pool = [NSMutableArray arrayWithCapacity:readers];
    for (NSUInteger index = 0; index < readers && !openError; index++)
    {
        MXSQLiteConnection *reader = [self openConnectionAtURL:url keySpec:keySpec
                                                          role:readOnly ? MXSQLiteRoleReadOnly : MXSQLiteRoleReader
                                                         error:&openError];
        if (reader)
        {
            [pool addObject:reader];
        }
    }
    memset_s(keySpec.mutableBytes, keySpec.length, 0, keySpec.length);

    if (openError)
    {
        [database.writer closeHandle];
        for (MXSQLiteConnection *reader in pool)
        {
            [reader closeHandle];
        }
        if (error)
        {
            *error = openError;
        }
        return nil;
    }

    MXSQLiteConnection *probe = database.writer ?: pool.firstObject;
    database.cipherVersion = [probe stringForQuery:@"PRAGMA cipher_version;" error:nil] ?: @"";
    database.idleReaders = pool;
    database.readerCount = pool.count;
    database.readerSemaphore = dispatch_semaphore_create((long)pool.count);
    database.openMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000;

    if (!readOnly)
    {
        [self applyFileProtectionAtURL:url];
    }
    return database;
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

#pragma mark Opening

typedef NS_ENUM(NSInteger, MXSQLiteRole)
{
    MXSQLiteRoleWriter,
    MXSQLiteRoleReader,
    MXSQLiteRoleReadOnly,
};

/// `x'<64 hex ключа><32 hex соли>'`: такой blob SQLCipher берёт как сырой ключ с явной солью — без PBKDF2
/// (сотни миллисекунд на каждое открытие ради ключа, который и так 256 бит из CSPRNG) и без соли в файле.
/// Так же открывает базу Telegram (`SqliteValueBox.swift`, `PRAGMA key="x'…'"`).
+ (NSMutableData *)keySpecWithKey:(NSData *)key salt:(NSData *)salt
{
    static const char hex[] = "0123456789abcdef";
    NSUInteger hexLength = (key.length + salt.length) * 2;
    NSString *prefix = @"PRAGMA key = \"x'";
    NSString *suffix = @"'\";";
    NSMutableData *spec = [NSMutableData dataWithCapacity:prefix.length + hexLength + suffix.length + 1];
    [spec appendData:[prefix dataUsingEncoding:NSASCIIStringEncoding]];
    for (NSData *part in @[key, salt])
    {
        const uint8_t *bytes = part.bytes;
        for (NSUInteger index = 0; index < part.length; index++)
        {
            char pair[2] = { hex[bytes[index] >> 4], hex[bytes[index] & 0x0f] };
            [spec appendBytes:pair length:2];
        }
    }
    [spec appendData:[suffix dataUsingEncoding:NSASCIIStringEncoding]];
    [spec appendBytes:"\0" length:1];
    return spec;
}

+ (MXSQLiteConnection *)openConnectionAtURL:(NSURL *)url keySpec:(NSData *)keySpec role:(MXSQLiteRole)role error:(NSError **)error
{
    BOOL readOnly = role == MXSQLiteRoleReadOnly;
    int flags = SQLITE_OPEN_NOMUTEX | (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE));
    sqlite3 *handle = NULL;
    int rc = sqlite3_open_v2(url.fileSystemRepresentation, &handle, flags, NULL);
    if (rc != SQLITE_OK)
    {
        NSString *message = MXSQLiteHandleMessage(handle);
        sqlite3_close_v2(handle);
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorOpenFailed, rc, message);
        }
        return nil;
    }

    MXSQLiteConnection *connection = [[MXSQLiteConnection alloc] initWithHandle:handle readOnly:readOnly || role == MXSQLiteRoleReader];
    sqlite3_busy_timeout(handle, 5000);

    // Fail-closed (урок ADR-0012): MatrixSDKCrypto несёт свою копию SQLite и экспортирует те же sqlite3_*.
    // Если линковка отдала символы ей, база молча открылась бы и писалась открытым текстом. Пустой
    // cipher_version — признак именно этого.
    NSString *query;
    @synchronized (MXSQLiteDatabase.class)
    {
        query = gMXSQLiteCipherVersionQuery ?: kMXSQLiteCipherVersionQuery;
    }
    NSString *cipherVersion = [connection stringForQuery:query error:nil];
    if (cipherVersion.length == 0)
    {
        [connection closeHandle];
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorCipherUnavailable, SQLITE_OK,
                                       [NSString stringWithFormat:@"SQLCipher is not linked: sqlite3 resolves to %@", self.sqliteLibraryPath]);
        }
        return nil;
    }

    // Ключ, затем открытый заголовок: первые 32 байта файла остаются заголовком SQLite, и iOS видит в файле
    // базу SQLite. Без этого система убивает приложение с 0xdead10cc, когда при уходе в фон файл в app group
    // держит блокировку. Глобальный cipher_default_plaintext_header_size не трогаем: он поменял бы формат
    // других баз SQLCipher в процессе (кеши TRSC хранят соль в файле).
    rc = sqlite3_exec(handle, keySpec.bytes, NULL, NULL, NULL);
    NSError *pragmaError;
    if (rc != SQLITE_OK
        || ![connection execute:[NSString stringWithFormat:@"PRAGMA cipher_plaintext_header_size = %lu;", (unsigned long)MXSQLitePlaintextHeaderSize] error:&pragmaError]
        || ![connection execute:@"PRAGMA cipher_page_size = 4096;" error:&pragmaError])
    {
        [connection closeHandle];
        if (error)
        {
            *error = MXSQLiteMakeError(MXSQLiteErrorKeyRejected, rc, pragmaError.localizedDescription ?: @"PRAGMA key failed");
        }
        return nil;
    }

    // Ключ проверяется только чтением страницы: на пустом файле подходит любой.
    rc = sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", NULL, NULL, NULL);
    if (rc != SQLITE_OK)
    {
        NSString *message = MXSQLiteHandleMessage(handle);
        [connection closeHandle];
        if (error)
        {
            // С открытым заголовком SQLCipher на чужом ключе отвечает не только SQLITE_NOTADB: заголовок читается,
            // а расшифровка первой страницы падает как SQLITE_NOMEM (проверено на 4.10) или SQLITE_CORRUPT.
            BOOL keyRejected = rc == SQLITE_NOTADB || rc == SQLITE_NOMEM || rc == SQLITE_CORRUPT;
            *error = MXSQLiteMakeError(keyRejected ? MXSQLiteErrorKeyRejected : MXSQLiteErrorOpenFailed, rc, message);
        }
        return nil;
    }

    NSMutableArray<NSString *> *pragmas = [NSMutableArray arrayWithArray:@[
        @"PRAGMA temp_store = MEMORY;",
        @"PRAGMA mmap_size = 0;",
        @"PRAGMA foreign_keys = OFF;",
        // Освобождённые страницы и так шифротекст, а secure_delete удваивает записи (ADR-0022, вопрос 9).
        @"PRAGMA secure_delete = OFF;",
    ]];
    switch (role)
    {
        case MXSQLiteRoleWriter:
            [pragmas addObjectsFromArray:@[
                @"PRAGMA journal_mode = WAL;",
                @"PRAGMA synchronous = NORMAL;",
                @"PRAGMA cache_size = -8192;",
                @"PRAGMA journal_size_limit = 8388608;",
            ]];
            break;
        case MXSQLiteRoleReader:
        case MXSQLiteRoleReadOnly:
            [pragmas addObjectsFromArray:@[
                @"PRAGMA cache_size = -2048;",
                @"PRAGMA query_only = 1;",
            ]];
            break;
    }
    for (NSString *pragma in pragmas)
    {
        if (![connection execute:pragma error:&pragmaError])
        {
            [connection closeHandle];
            if (error)
            {
                *error = pragmaError;
            }
            return nil;
        }
    }
    return connection;
}

+ (void)setCipherVersionQueryForTesting:(NSString *)query
{
    @synchronized (MXSQLiteDatabase.class)
    {
        gMXSQLiteCipherVersionQuery = [query copy];
    }
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

+ (void)applyFileProtectionAtURL:(NSURL *)url
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSDictionary *attributes = @{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication};
    [fileManager setAttributes:attributes ofItemAtPath:url.URLByDeletingLastPathComponent.path error:nil];
    for (NSString *suffix in @[@"", @"-wal", @"-shm"])
    {
        NSString *path = [url.path stringByAppendingString:suffix];
        if ([fileManager fileExistsAtPath:path])
        {
            [fileManager setAttributes:attributes ofItemAtPath:path error:nil];
        }
    }
    // Шифротекст без ключа (ключ ThisDeviceOnly) на новом устройстве бесполезен — в бэкап не кладём.
    NSURL *resourceURL = url;
    [resourceURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
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
    for (NSString *suffix in @[@"", @"-wal", @"-shm", @"-journal"])
    {
        [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    }
}

@end
