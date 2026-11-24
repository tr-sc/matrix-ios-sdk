//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase_Private.h"
#import "MXSQLiteDatabase+Testing.h"

#import "MXLog.h"

static NSString *const kMXSQLiteCipherVersionQuery = @"PRAGMA cipher_version;";
/// Пауза перед повтором после SQLITE_NOMEM: дать системе освободить память.
static useconds_t const kMXSQLiteNoMemoryRetryDelayMicroseconds = 150 * 1000;

// Подменники тестов (`MXSQLiteDatabase+Testing.h`), под `@synchronized (MXSQLiteConnectionOpener.class)`.
static NSString *gMXSQLiteCipherVersionQuery;
static NSMutableArray<NSNumber *> *gMXSQLiteKeyCheckResultCodes;
static NSNumber *gMXSQLiteNoMemoryRetryDelay;

static int MXSQLiteCollectFirstColumn(void *context, int columns, char **values, char **names)
{
    NSMutableArray<NSString *> *rows = (__bridge NSMutableArray<NSString *> *)context;
    if (columns > 0 && values[0])
    {
        [rows addObject:[NSString stringWithUTF8String:values[0]]];
    }
    return SQLITE_OK;
}

@implementation MXSQLiteConnectionOpener

/// Сырой ключ с явной солью: без PBKDF2 (сотни миллисекунд на открытие ради ключа, который и так 256 бит из CSPRNG)
/// и без соли в файле.
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
    MXSQLiteConnection *connection = [self keyedConnectionAtURL:url keySpec:keySpec role:role error:error];
    if (!connection)
    {
        return nil;
    }

    int rc = [self checkKeyOfConnection:connection];
    if (rc == SQLITE_NOMEM)
    {
        // Неудачная расшифровка навсегда ломает кодек соединения, поэтому повтор — на свежем.
        [connection closeHandle];
        usleep(self.noMemoryRetryDelay);
        connection = [self keyedConnectionAtURL:url keySpec:keySpec role:role error:error];
        if (!connection)
        {
            return nil;
        }
        rc = [self checkKeyOfConnection:connection];
        if (rc == SQLITE_OK)
        {
            MXLogWarning(@"[MXSQLiteDatabase] key check passed on retry after SQLITE_NOMEM");
        }
    }
    if (rc != SQLITE_OK)
    {
        NSString *message = MXSQLiteHandleMessage(connection->_handle);
        [connection closeHandle];
        if (error)
        {
            *error = MXSQLiteMakeError([self errorCodeForKeyCheckResult:rc url:url keySpec:keySpec role:role], rc, message);
        }
        return nil;
    }

    if (![self applyPragmasForRole:role toConnection:connection error:error])
    {
        [connection closeHandle];
        return nil;
    }
    return connection;
}

#pragma mark - Steps

/// Соединение с ключом и открытым заголовком; ключ ещё не проверен чтением.
+ (MXSQLiteConnection *)keyedConnectionAtURL:(NSURL *)url keySpec:(NSData *)keySpec role:(MXSQLiteRole)role error:(NSError **)error
{
    MXSQLiteConnection *connection = [self rawConnectionAtURL:url role:role error:error];
    if (!connection)
    {
        return nil;
    }
    if (![self verifyCipherOfConnection:connection error:error] || ![self applyKeySpec:keySpec toConnection:connection error:error])
    {
        [connection closeHandle];
        return nil;
    }
    return connection;
}

+ (MXSQLiteConnection *)rawConnectionAtURL:(NSURL *)url role:(MXSQLiteRole)role error:(NSError **)error
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
    sqlite3_busy_timeout(handle, 5000);
    return [[MXSQLiteConnection alloc] initWithHandle:handle readOnly:readOnly || role == MXSQLiteRoleReader];
}

/// Fail-closed: MatrixSDKCrypto несёт свою копию SQLite с теми же sqlite3_*. Если линковка отдала символы ей, база
/// молча писалась бы открытым текстом; пустой cipher_version — признак именно этого.
+ (BOOL)verifyCipherOfConnection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    NSString *query;
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        query = gMXSQLiteCipherVersionQuery ?: kMXSQLiteCipherVersionQuery;
    }
    if ([connection stringForQuery:query error:nil].length > 0)
    {
        return YES;
    }
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorCipherUnavailable, SQLITE_OK,
                                   [NSString stringWithFormat:@"SQLCipher is not linked: sqlite3 resolves to %@", MXSQLiteDatabase.sqliteLibraryPath]);
    }
    return NO;
}

/// Открытый заголовок: первые 32 байта файла остаются заголовком SQLite, иначе iOS убивает приложение с 0xdead10cc
/// за блокировку файла в app group при уходе в фон. Глобальный cipher_default_plaintext_header_size не трогаем:
/// он поменял бы формат других баз SQLCipher в процессе.
+ (BOOL)applyKeySpec:(NSData *)keySpec toConnection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    int rc = sqlite3_exec(connection->_handle, keySpec.bytes, NULL, NULL, NULL);
    NSError *pragmaError;
    if (rc == SQLITE_OK
        && [connection execute:[NSString stringWithFormat:@"PRAGMA cipher_plaintext_header_size = %lu;", (unsigned long)MXSQLitePlaintextHeaderSize] error:&pragmaError]
        && [connection execute:@"PRAGMA cipher_page_size = 4096;" error:&pragmaError])
    {
        return YES;
    }
    if (error)
    {
        *error = MXSQLiteMakeError(MXSQLiteErrorKeyRejected, rc, pragmaError.localizedDescription ?: @"PRAGMA key failed");
    }
    return NO;
}

/// Ключ проверяется только чтением страницы: на пустом файле подходит любой.
+ (int)checkKeyOfConnection:(MXSQLiteConnection *)connection
{
    NSNumber *injected;
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        injected = gMXSQLiteKeyCheckResultCodes.firstObject;
        if (injected)
        {
            [gMXSQLiteKeyCheckResultCodes removeObjectAtIndex:0];
        }
    }
    if (injected.intValue != SQLITE_OK)
    {
        return injected.intValue;
    }
    return sqlite3_exec(connection->_handle, "SELECT count(*) FROM sqlite_master;", NULL, NULL, NULL);
}

/// С открытым заголовком SQLCipher 4.10 отдаёт неудачную расшифровку первой страницы как SQLITE_NOMEM, поэтому
/// NOMEM после повтора — это либо чужой ключ, либо память, и решает HMAC страницы 1.
+ (MXSQLiteErrorCode)errorCodeForKeyCheckResult:(int)rc url:(NSURL *)url keySpec:(NSData *)keySpec role:(MXSQLiteRole)role
{
    switch (rc)
    {
        case SQLITE_NOTADB:
        case SQLITE_CORRUPT:
            return MXSQLiteErrorKeyRejected;
        case SQLITE_NOMEM:
            return [self pageOneFailsHMACAtURL:url keySpec:keySpec role:role] ? MXSQLiteErrorKeyRejected : MXSQLiteErrorTransient;
        default:
            return MXSQLiteErrorOpenFailed;
    }
}

/// `cipher_integrity_check` читает страницы с диска мимо пейджера и сверяет HMAC ключом. Несошедшийся HMAC страницы 1 —
/// ключ не подходит к файлу (или страница испорчена). Пусто или сама проверка не прошла — ключ свой.
/// Проверка берёт один страничный буфер, поэтому и под давлением памяти обычно проходит.
+ (BOOL)pageOneFailsHMACAtURL:(NSURL *)url keySpec:(NSData *)keySpec role:(MXSQLiteRole)role
{
    MXSQLiteConnection *probe = [self keyedConnectionAtURL:url keySpec:keySpec role:role error:nil];
    if (!probe)
    {
        return NO;
    }
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    int rc = sqlite3_exec(probe->_handle, "PRAGMA cipher_integrity_check;", MXSQLiteCollectFirstColumn, (__bridge void *)rows, NULL);
    [probe closeHandle];
    if (rc != SQLITE_OK)
    {
        MXLogWarning(@"[MXSQLiteDatabase] cipher_integrity_check failed: %d", rc);
        return NO;
    }
    return [rows containsObject:@"HMAC verification failed for page 1"];
}

+ (BOOL)applyPragmasForRole:(MXSQLiteRole)role toConnection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    for (NSString *pragma in [self pragmasForRole:role])
    {
        if (![connection execute:pragma error:error])
        {
            return NO;
        }
    }
    return YES;
}

+ (NSArray<NSString *> *)pragmasForRole:(MXSQLiteRole)role
{
    NSArray<NSString *> *common = @[
        @"PRAGMA temp_store = MEMORY;",
        @"PRAGMA mmap_size = 0;",
        @"PRAGMA foreign_keys = OFF;",
        // Освобождённые страницы и так шифротекст, а secure_delete удваивает записи.
        @"PRAGMA secure_delete = OFF;",
    ];
    switch (role)
    {
        case MXSQLiteRoleWriter:
            return [common arrayByAddingObjectsFromArray:@[
                @"PRAGMA journal_mode = WAL;",
                @"PRAGMA synchronous = NORMAL;",
                @"PRAGMA cache_size = -8192;",
                @"PRAGMA journal_size_limit = 8388608;",
            ]];
        case MXSQLiteRoleReader:
        case MXSQLiteRoleReadOnly:
            return [common arrayByAddingObjectsFromArray:@[
                @"PRAGMA cache_size = -2048;",
                @"PRAGMA query_only = 1;",
            ]];
    }
}

+ (useconds_t)noMemoryRetryDelay
{
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        return gMXSQLiteNoMemoryRetryDelay ? (useconds_t)(gMXSQLiteNoMemoryRetryDelay.doubleValue * 1000) : kMXSQLiteNoMemoryRetryDelayMicroseconds;
    }
}

@end

@implementation MXSQLiteDatabase (Testing)

+ (void)setCipherVersionQueryForTesting:(NSString *)query
{
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        gMXSQLiteCipherVersionQuery = [query copy];
    }
}

+ (void)setKeyCheckResultCodesForTesting:(NSArray<NSNumber *> *)codes
{
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        gMXSQLiteKeyCheckResultCodes = codes ? [codes mutableCopy] : nil;
    }
}

+ (void)setNoMemoryRetryDelayForTesting:(NSNumber *)milliseconds
{
    @synchronized (MXSQLiteConnectionOpener.class)
    {
        gMXSQLiteNoMemoryRetryDelay = milliseconds;
    }
}

@end
