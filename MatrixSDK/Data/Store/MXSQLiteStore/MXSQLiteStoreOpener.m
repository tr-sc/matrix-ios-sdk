//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreOpener.h"

#import "MXLog.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteKeyProvider.h"
#import "MXSQLiteSchema.h"
#import "MXSQLiteStore.h"
#import "MXTimelineStore.h"

@interface MXSQLiteStoreOpener ()
@property (nonatomic, weak, readonly) MXSQLiteStore *store;
@property (nonatomic, readonly) id<MXSQLiteKeyProviding> keyProvider;
@property (nonatomic, readonly) NSURL *rootDirectory;
@property (nonatomic, readonly) NSUInteger readerCount;
@end

@implementation MXSQLiteStoreOpener

- (instancetype)initWithStore:(MXSQLiteStore *)store
                  keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
                rootDirectory:(NSURL *)rootDirectory
                  readerCount:(NSUInteger)readerCount
{
    self = [super init];
    if (self)
    {
        _store = store;
        _keyProvider = keyProvider;
        _rootDirectory = rootDirectory;
        _readerCount = readerCount;
    }
    return self;
}

/// NSE (только чтение или стор расширения) ничего не создаёт и не пересоздаёт: нет базы приложения — нет SQLite.
- (BOOL)existingOnly
{
    return self.store.readOnly || self.store.extensionMode;
}

- (MXSQLiteDatabase *)openDatabaseForUserId:(NSString *)userId error:(NSError **)error
{
    NSURL *url = [MXSQLiteStore databaseURLForUserId:userId rootDirectory:self.rootDirectory];
    NSString *keyIdentifier = [MXSQLiteStore keyIdentifierForUserId:userId];
    if (self.existingOnly && ![NSFileManager.defaultManager fileExistsAtPath:url.path])
    {
        if (error)
        {
            *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorOpenFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"no store file"}];
        }
        return nil;
    }

    NSError *openError;
    MXSQLiteKeyMaterial *material = [self.keyProvider keyMaterialForIdentifier:keyIdentifier create:!self.existingOnly error:&openError];
    MXSQLiteDatabase *database = material ? [self openAtURL:url material:material error:&openError] : nil;
    if (!database && material && !self.existingOnly && [self isRecoverableOpenError:openError])
    {
        MXSQLiteKeyMaterial *fresh = [self resetFilesAndKeyAtURL:url keyIdentifier:keyIdentifier openError:openError error:error];
        if (!fresh)
        {
            return nil;
        }
        database = [self openAtURL:url material:fresh error:&openError];
    }
    if (database && ![self prepareSchemaOfDatabase:database error:&openError])
    {
        [database close];
        database = nil;
    }
    if (!database)
    {
        [self reportOpenFailure:openError];
        if (error)
        {
            *error = openError;
        }
        return nil;
    }
    if (self.store.extensionMode && ![self applyExtensionBusyTimeoutToDatabase:database error:error])
    {
        [database close];
        return nil;
    }
    return database;
}

#pragma mark - Steps

- (MXSQLiteDatabase *)openAtURL:(NSURL *)url material:(MXSQLiteKeyMaterial *)material error:(NSError **)error
{
    return [MXSQLiteDatabase openAtURL:url key:material.key salt:material.salt readOnly:self.store.readOnly
                           readerCount:self.readerCount error:error];
}

/// Удалить файлы и ключ, создать новый ключ. nil — ключ не создан (`error`).
- (MXSQLiteKeyMaterial *)resetFilesAndKeyAtURL:(NSURL *)url keyIdentifier:(NSString *)keyIdentifier openError:(NSError *)openError error:(NSError **)error
{
    NSString *reason = openError.code == MXSQLiteErrorKeyRejected ? @"key_rejected" : @"corrupt";
    MXLogWarning(@"[MXSQLiteStore] Recreating the store (%@): %@", reason, openError.localizedDescription);
    [MXSQLiteDatabase removeFilesAtURL:url];
    [self.keyProvider removeKeyMaterialForIdentifier:keyIdentifier];
    MXSQLiteKeyMaterial *material = [self.keyProvider keyMaterialForIdentifier:keyIdentifier create:YES error:error];
    if (material)
    {
        [self reportResetWithReason:reason];
    }
    return material;
}

/// Пересоздать: чужой ключ (`SQLITE_NOTADB`, `SQLITE_CORRUPT`, `SQLITE_NOMEM` с несошедшимся HMAC страницы 1)
/// или битый файл. Временный отказ и отказ без SQLCipher сюда не попадают: снести базу без SQLCipher значит молча
/// продолжить открытым текстом.
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
    if (database.readOnly || self.store.extensionMode)
    {
        return [self checkSchemaOfDatabase:database error:error];
    }
    return [self migrateSchemaOfDatabase:database error:error];
}

/// NSE схему не трогает: чужая версия — работаем как без стора.
- (BOOL)checkSchemaOfDatabase:(MXSQLiteDatabase *)database error:(NSError **)error
{
    int64_t version = [[database read:^id(MXSQLiteConnection *connection) {
        return @([connection int64ForQuery:@"PRAGMA user_version;" defaultValue:0 error:nil]);
    }] longLongValue];
    if (version == MXSQLiteSchema.currentVersion)
    {
        return YES;
    }
    if (error)
    {
        *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorSchema
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"schema %lld", version]}];
    }
    return NO;
}

- (BOOL)migrateSchemaOfDatabase:(MXSQLiteDatabase *)database error:(NSError **)error
{
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

/// Приложение не ждёт NSE (его транзакции — миллисекунды), а NSE не висит за долгой транзакцией приложения.
- (BOOL)applyExtensionBusyTimeoutToDatabase:(MXSQLiteDatabase *)database error:(NSError **)error
{
    NSString *pragma = [NSString stringWithFormat:@"PRAGMA busy_timeout = %ld;", (long)MXSQLiteExtensionBusyTimeoutMilliseconds];
    return [database withWriter:^BOOL(MXSQLiteConnection *connection, NSError **blockError) {
        return [connection execute:pragma error:blockError];
    } error:error];
}

#pragma mark - Metrics

- (void)reportResetWithReason:(NSString *)reason
{
    id<MXStoreMetricsDelegate> delegate = self.store.metricsDelegate;
    if ([delegate respondsToSelector:@selector(store:didResetWithReason:)])
    {
        [delegate store:self.store didResetWithReason:reason];
    }
}

- (void)reportOpenFailure:(NSError *)error
{
    NSString *reason = [MXSQLiteStore openFailureReasonForError:error];
    MXLogWarning(@"[MXSQLiteStore] Open failed without recreating the store (%@): %@", reason, error.localizedDescription);
    id<MXStoreMetricsDelegate> delegate = self.store.metricsDelegate;
    if ([delegate respondsToSelector:@selector(store:didFailToOpenWithReason:)])
    {
        [delegate store:self.store didFailToOpenWithReason:reason];
    }
}

@end
