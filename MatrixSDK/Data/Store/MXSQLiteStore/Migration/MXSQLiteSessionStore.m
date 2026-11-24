//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteSessionStore.h"

#import "MXCredentials.h"
#import "MXLog.h"
#import "MXSQLiteLegacyImport.h"
#import "MXSQLiteDatabase.h"
#import "MatrixSDKSwiftHeader.h"

static NSString *const kOpenFailureKeyPrefix = @"MXSQLiteSessionStore.openFailed.";

@interface MXSQLiteSessionStore ()
@property (nonatomic, readwrite, nullable) MXSQLiteLegacyImportResult *legacyImportResult;
@end

@implementation MXSQLiteSessionStore

#pragma mark - Open failure marker

+ (NSString *)openFailureKeyForUserId:(NSString *)userId
{
    return [kOpenFailureKeyPrefix stringByAppendingString:[MXSQLiteStore keyIdentifierForUserId:userId]];
}

+ (BOOL)hasOpenFailureForUserId:(NSString *)userId
{
    return [NSUserDefaults.standardUserDefaults boolForKey:[self openFailureKeyForUserId:userId]];
}

+ (void)clearOpenFailureForUserId:(NSString *)userId
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[self openFailureKeyForUserId:userId]];
}

+ (void)noteOpenFailureForUserId:(NSString *)userId
{
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:[self openFailureKeyForUserId:userId]];
}

#pragma mark - Deactivation

+ (BOOL)deactivateForCredentials:(MXCredentials *)credentials
                   rootDirectory:(NSURL *)rootDirectory
                     keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
{
    NSString *userId = credentials.userId;
    if (!userId.length)
    {
        return NO;
    }

    // Open the existing DB read-only: the regular writer can recreate a corrupt database, which
    // would turn a rollback attempt into silent deletion of the only copy of local-only data.
    MXSQLiteStore *store = [[MXSQLiteStore alloc] initWithKeyProvider:keyProvider rootDirectory:rootDirectory readOnly:YES];
    NSError *error;
    if (![store openSynchronouslyWithCredentials:credentials error:&error])
    {
        MXLogWarning(@"[MXSQLiteSessionStore] rollback export could not open SQLite store: %@", error.localizedDescription);
        return NO;
    }
    NSURL *legacy = [MXSQLiteLegacyImport fileStoreURLForUserId:userId];
    if (![MXSQLiteLegacyImport exportLocalOnlyDataFromStore:store toFileStoreAtURL:legacy credentials:credentials error:&error])
    {
        [store close];
        MXLogWarning(@"[MXSQLiteSessionStore] rollback export failed; keeping SQLite store: %@", error.localizedDescription);
        return NO;
    }
    [store close];

    MXLogDebug(@"[MXSQLiteSessionStore] deactivate: back to MXFileStore with a clean sync");
    [MXSQLiteStore deleteDataForUserId:userId rootDirectory:rootDirectory keyProvider:keyProvider];
    // Сводки общие (CoreData): без их сброса MXFileStore восстановил бы позицию Sliding Sync новой базы.
    [[[MXCoreDataRoomSummaryStore alloc] initWithCredentials:credentials] removeAllSummaries];
    [self clearOpenFailureForUserId:userId];
    return YES;
}

#pragma mark - Open

- (void)openWithCredentials:(MXCredentials *)credentials onComplete:(void (^)(void))onComplete failure:(void (^)(NSError *))failure
{
    NSString *userId = credentials.userId;
    [super openWithCredentials:credentials onComplete:^{
        [MXSQLiteSessionStore clearOpenFailureForUserId:userId];
        NSURL *legacy = self.legacyFileStoreURL ?: [MXSQLiteLegacyImport fileStoreURLForUserId:userId];
        if (![NSFileManager.defaultManager fileExistsAtPath:legacy.path])
        {
            if (onComplete)
            {
                onComplete();
            }
            return;
        }
        // Перенос читает архивы комнат: вне main. Сессия ждёт его — монтирование должно увидеть перенесённое.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            MXSQLiteLegacyImportResult *result = [MXSQLiteLegacyImport importFromFileStoreAtURL:legacy intoStore:self];
            if (result.succeeded)
            {
                [self removeLegacyFileStoreAtURL:legacy];
            }
            else
            {
                MXLogErrorDetails(@"[MXSQLiteSessionStore] legacy import failed; preserving MXFileStore", @{@"error": result.error ?: NSNull.null});
            }
            MXLogDebug(@"[MXSQLiteSessionStore] switched from MXFileStore in %.0f ms: skipped=%d outgoing=%lu drafts=%lu",
                       (CFAbsoluteTimeGetCurrent() - start) * 1000, result.skipped,
                       (unsigned long)result.outgoingCount, (unsigned long)result.draftCount);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.legacyImportResult = result;
                if (!result.succeeded)
                {
                    [MXSQLiteSessionStore noteOpenFailureForUserId:userId];
                    if (failure)
                    {
                        failure(result.error ?: [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorOpenFailed
                                                                  userInfo:@{NSLocalizedDescriptionKey: @"Legacy MXFileStore import failed"}]);
                    }
                    return;
                }
                if (onComplete)
                {
                    onComplete();
                }
            });
        });
    } failure:^(NSError *error) {
        [MXSQLiteSessionStore noteOpenFailureForUserId:userId];
        if (failure)
        {
            failure(error);
        }
    }];
}

/// Отметка «перенесено» уже на диске (импорт пишет её в одной транзакции с данными), поэтому папку можно удалять:
/// если процесс умрёт до удаления, следующее открытие перенос пропустит и удалит папку.
- (void)removeLegacyFileStoreAtURL:(NSURL *)url
{
    NSError *error;
    if (![NSFileManager.defaultManager removeItemAtURL:url error:&error])
    {
        MXLogWarning(@"[MXSQLiteSessionStore] MXFileStore folder not removed: %@", error.localizedDescription);
    }
    // Сводки старого стора (CoreData) — тот же объект, что у этой базы до iP5; после iP5 — пустая таблица.
    [self.roomSummaryStore removeAllSummaries];
}

@end
