//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteSessionStore.h"

#import "MXCredentials.h"
#import "MXLog.h"
#import "MXSQLiteLegacyImport.h"
#import "MatrixSDKSwiftHeader.h"

static NSString *const kOpenFailureKeyPrefix = @"MXSQLiteSessionStore.openFailed.";
static NSString *const kTransientOpenFailureKeyPrefix = @"MXSQLiteSessionStore.transientOpenFailures.";
NSInteger const MXSQLiteSessionStoreMaxTransientOpenFailures = 3;

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
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[self transientOpenFailureKeyForUserId:userId]];
}

+ (void)noteOpenFailureForUserId:(NSString *)userId
{
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:[self openFailureKeyForUserId:userId]];
}

+ (NSString *)transientOpenFailureKeyForUserId:(NSString *)userId
{
    return [kTransientOpenFailureKeyPrefix stringByAppendingString:[MXSQLiteStore keyIdentifierForUserId:userId]];
}

+ (NSInteger)transientOpenFailureCountForUserId:(NSString *)userId
{
    return [NSUserDefaults.standardUserDefaults integerForKey:[self transientOpenFailureKeyForUserId:userId]];
}

/// Отказ открытия: временный не запирает аккаунт на MXFileStore (переход туда стирает базу с неотправленными),
/// пока таких отказов подряд меньше `MXSQLiteSessionStoreMaxTransientOpenFailures`.
+ (void)noteOpenFailure:(NSError *)error forUserId:(NSString *)userId
{
    if ([MXSQLiteStore isTransientOpenError:error])
    {
        NSInteger count = [self transientOpenFailureCountForUserId:userId] + 1;
        [NSUserDefaults.standardUserDefaults setInteger:count forKey:[self transientOpenFailureKeyForUserId:userId]];
        if (count < MXSQLiteSessionStoreMaxTransientOpenFailures)
        {
            MXLogWarning(@"[MXSQLiteSessionStore] transient open failure %ld/%ld: the next launch retries SQLite",
                         (long)count, (long)MXSQLiteSessionStoreMaxTransientOpenFailures);
            return;
        }
        MXLogWarning(@"[MXSQLiteSessionStore] %ld transient open failures in a row: falling back", (long)count);
    }
    [self noteOpenFailureForUserId:userId];
}

#pragma mark - Deactivation

+ (void)deactivateForCredentials:(MXCredentials *)credentials
                   rootDirectory:(NSURL *)rootDirectory
                     keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
{
    NSString *userId = credentials.userId;
    if (!userId.length)
    {
        return;
    }
    MXLogDebug(@"[MXSQLiteSessionStore] deactivate: back to MXFileStore with a clean sync");
    [MXSQLiteStore deleteDataForUserId:userId rootDirectory:rootDirectory keyProvider:keyProvider];
    // Сводки общие (CoreData): без их сброса MXFileStore восстановил бы позицию Sliding Sync новой базы.
    [[[MXCoreDataRoomSummaryStore alloc] initWithCredentials:credentials] removeAllSummaries];
    [self clearOpenFailureForUserId:userId];
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
            [self removeLegacyFileStoreAtURL:legacy];
            MXLogDebug(@"[MXSQLiteSessionStore] switched from MXFileStore in %.0f ms: skipped=%d outgoing=%lu drafts=%lu",
                       (CFAbsoluteTimeGetCurrent() - start) * 1000, result.skipped,
                       (unsigned long)result.outgoingCount, (unsigned long)result.draftCount);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.legacyImportResult = result;
                if (onComplete)
                {
                    onComplete();
                }
            });
        });
    } failure:^(NSError *error) {
        [MXSQLiteSessionStore noteOpenFailure:error forUserId:userId];
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
