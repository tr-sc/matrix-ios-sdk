//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase_Private.h"

#import "MXLog.h"

@implementation MXSQLiteDatabaseFiles

+ (NSArray<NSURL *> *)existingFilesAtURL:(NSURL *)url
{
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSString *suffix in @[@"", @"-wal", @"-shm"])
    {
        NSString *path = [url.path stringByAppendingString:suffix];
        if ([NSFileManager.defaultManager fileExistsAtPath:path])
        {
            [files addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return files;
}

/// Шифротекст без ключа (ключ ThisDeviceOnly) на новом устройстве бесполезен, поэтому в бэкап не идёт ни каталог,
/// ни файлы: в -wal и -shm лежат ещё не слитые коммиты.
+ (void)protectFilesAtURL:(NSURL *)url
{
    NSDictionary *attributes = @{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication};
    [NSFileManager.defaultManager setAttributes:attributes ofItemAtPath:url.URLByDeletingLastPathComponent.path error:nil];
    [self excludeDirectoryFromBackupOfURL:url];
    for (NSURL *file in [self existingFilesAtURL:url])
    {
        [NSFileManager.defaultManager setAttributes:attributes ofItemAtPath:file.path error:nil];
        [file setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

+ (void)excludeDirectoryFromBackupOfURL:(NSURL *)url
{
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSError *error;
    if (![directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error])
    {
        MXLogWarning(@"[MXSQLiteDatabase] database folder not excluded from backup: %@", error.localizedDescription);
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
