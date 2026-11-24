//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteLegacyImport.h"

#import "MXEvent.h"
#import "MXCredentials.h"
#import "MXLog.h"
#import "MXFileRoomStore.h"
#import "MXFileRoomOutgoingMessagesStore.h"
#import "MXFileStore.h"
#import "MXFileStoreMetaData.h"
#import "MXMemoryRoomOutgoingMessagesStore.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteStore.h"
#import "MXSQLiteStoreComponents.h"
#import "MatrixSDKSwiftHeader.h"

// Имена файлов MXFileStore (MXFileStore.m).
static NSString *const kLegacyFolder = @"MXFileStore";
static NSString *const kLegacyRoomsFolder = @"rooms";
static NSString *const kLegacyBackupFolder = @"backup";
static NSString *const kLegacyMessagesFile = @"messages";
static NSString *const kLegacyOutgoingFile = @"outgoingMessages";
static NSString *const kLegacyMetadataFile = @"MXFileStore";
static NSString *const kLegacyDraftKey = @"partialAttributedTextMessage";

static NSError *MXSQLiteLegacyImportMakeError(NSString *description, NSError *underlyingError)
{
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorOpenFailed userInfo:userInfo];
}

/// Подменяет `MXFileRoomStore` при разархивировании: берёт только черновик, историю не трогает.
@interface MXSQLiteLegacyDraftReader : NSObject <NSCoding>
@property (nonatomic, nullable) NSAttributedString *draft;
@end

@implementation MXSQLiteLegacyDraftReader

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
    {
        id draft = [coder decodeObjectForKey:kLegacyDraftKey];
        _draft = [draft isKindOfClass:NSAttributedString.class] ? draft : nil;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

@end

@interface MXSQLiteLegacyImportResult ()
@property (nonatomic, readwrite) BOOL skipped;
@property (nonatomic, readwrite) NSUInteger outgoingCount;
@property (nonatomic, readwrite) NSUInteger draftCount;
@property (nonatomic, readwrite) NSUInteger roomCount;
@property (nonatomic, readwrite) BOOL succeeded;
@property (nonatomic, readwrite, nullable) NSError *error;
@end

@implementation MXSQLiteLegacyImportResult
@end

@implementation MXSQLiteLegacyImport

+ (NSURL *)fileStoreURLForUserId:(NSString *)userId
{
    NSURL *container = [NSFileManager.defaultManager applicationGroupContainerURL];
    if (!container)
    {
        container = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    }
    return [[container URLByAppendingPathComponent:kLegacyFolder isDirectory:YES] URLByAppendingPathComponent:userId isDirectory:YES];
}

+ (NSAttributedString *)draftAtURL:(NSURL *)url error:(NSError **)error
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
    {
        return nil;
    }
    NSError *readError;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (!data)
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot read legacy room messages archive", readError);
        return nil;
    }
    @try
    {
        NSError *decodeError;
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&decodeError];
        if (!unarchiver)
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot decode legacy room messages archive", decodeError);
            return nil;
        }
        unarchiver.requiresSecureCoding = NO;
        [unarchiver setClass:MXSQLiteLegacyDraftReader.class forClassName:@"MXFileRoomStore"];
        MXSQLiteLegacyDraftReader *reader = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
        if (![reader isKindOfClass:MXSQLiteLegacyDraftReader.class])
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"Legacy room messages archive has an unexpected root object", nil);
            return nil;
        }
        return reader.draft;
    }
    @catch (NSException *exception)
    {
        MXLogWarning(@"[MXSQLiteLegacyImport] Draft is unreadable: %@", exception.reason);
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Legacy room messages archive is unreadable", nil);
        return nil;
    }
}

+ (NSArray<MXEvent *> *)outgoingMessagesAtURL:(NSURL *)url error:(NSError **)error
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
    {
        return nil;
    }
    NSError *readError;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (!data)
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot read legacy outgoing messages archive", readError);
        return nil;
    }
    MXMemoryRoomOutgoingMessagesStore *store = MXSQLiteUnarchive(data);
    if (![store isKindOfClass:MXMemoryRoomOutgoingMessagesStore.class])
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Legacy outgoing messages archive is unreadable", nil);
        return nil;
    }
    NSMutableArray<MXEvent *> *events = [NSMutableArray array];
    for (id event in store.outgoingMessages)
    {
        if ([event isKindOfClass:MXEvent.class] && [event eventId])
        {
            [events addObject:event];
        }
    }
    return events;
}

+ (MXSQLiteLegacyImportResult *)importFromFileStoreAtURL:(NSURL *)fileStoreURL intoStore:(MXSQLiteStore *)store
{
    MXSQLiteLegacyImportResult *result = [MXSQLiteLegacyImportResult new];
    id<MXSQLiteMetaStoring, MXSQLiteOutgoingStoring> components = (id<MXSQLiteMetaStoring, MXSQLiteOutgoingStoring>)store;
    if (components.legacyFileStoreImported)
    {
        result.skipped = YES;
        result.succeeded = YES;
        return result;
    }
    if (!store.database || store.readOnly)
    {
        result.skipped = YES;
        result.error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorClosed
                                       userInfo:@{NSLocalizedDescriptionKey: @"SQLite store is not writable for legacy import"}];
        return result;
    }

    NSURL *roomsURL = [fileStoreURL URLByAppendingPathComponent:kLegacyRoomsFolder isDirectory:YES];
    NSError *enumerationError;
    NSArray<NSURL *> *roomURLs = [NSFileManager.defaultManager contentsOfDirectoryAtURL:roomsURL
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:&enumerationError];
    if (!roomURLs && enumerationError && !(enumerationError.code == NSFileReadNoSuchFileError
                                            && [enumerationError.domain isEqualToString:NSCocoaErrorDomain]))
    {
        result.error = MXSQLiteLegacyImportMakeError(@"Cannot enumerate legacy MXFileStore rooms", enumerationError);
        return result;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    for (NSURL *roomURL in roomURLs ?: @[])
    {
        @autoreleasepool
        {
            NSString *roomId = roomURL.lastPathComponent;
            NSError *archiveError = nil;
            NSArray<MXEvent *> *outgoing = [self outgoingMessagesAtURL:[roomURL URLByAppendingPathComponent:kLegacyOutgoingFile]
                                                                  error:&archiveError];
            if (archiveError)
            {
                result.error = archiveError;
                return result;
            }
            outgoing = outgoing ?: @[];
            for (MXEvent *event in outgoing)
            {
                [components storeOutgoingMessageForRoom:roomId outgoingMessage:event];
            }
            archiveError = nil;
            NSAttributedString *draft = [self draftAtURL:[roomURL URLByAppendingPathComponent:kLegacyMessagesFile]
                                                    error:&archiveError];
            if (archiveError)
            {
                result.error = archiveError;
                return result;
            }
            if (draft.length)
            {
                [components storePartialAttributedTextMessageForRoom:roomId partialAttributedTextMessage:draft];
            }
            result.outgoingCount += outgoing.count;
            result.draftCount += draft.length ? 1 : 0;
            result.roomCount += (outgoing.count || draft.length) ? 1 : 0;
        }
    }
    // Отметка в той же транзакции: перенос или целиком, или повторится при следующем переключении.
    components.legacyFileStoreImported = YES;
    NSError *flushError;
    if (![store flushWithError:&flushError])
    {
        result.error = flushError;
        if (!result.error)
        {
            result.error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorOpenFailed
                                           userInfo:@{NSLocalizedDescriptionKey: @"Legacy import transaction failed"}];
        }
        return result;
    }
    result.succeeded = YES;

    MXLogDebug(@"[MXSQLiteLegacyImport] Imported %tu outgoing and %tu drafts of %tu rooms in %.0f ms",
               result.outgoingCount, result.draftCount, result.roomCount, (CFAbsoluteTimeGetCurrent() - start) * 1000);
    return result;
}

+ (MXFileRoomStore *)existingRoomStoreAtURL:(NSURL *)url error:(NSError **)error
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;
    NSError *readError;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (!data)
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot read MXFileStore room archive during rollback", readError);
        return nil;
    }
    @try
    {
        NSError *decodeError;
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&decodeError];
        if (!unarchiver)
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot decode MXFileStore room archive during rollback", decodeError);
            return nil;
        }
        unarchiver.requiresSecureCoding = NO;
        id decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
        if (![decoded isKindOfClass:MXFileRoomStore.class])
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"MXFileStore room archive has an unexpected root object", nil);
            return nil;
        }
        return decoded;
    }
    @catch (NSException *exception)
    {
        MXLogWarning(@"[MXSQLiteLegacyImport] Existing MXFileStore room archive is unreadable during rollback: %@", exception.reason);
        if (error) *error = MXSQLiteLegacyImportMakeError(@"MXFileStore room archive is unreadable during rollback", nil);
        return nil;
    }
}

+ (MXFileRoomOutgoingMessagesStore *)existingOutgoingStoreAtURL:(NSURL *)url error:(NSError **)error
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;
    NSError *readError;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (!data)
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot read MXFileStore outgoing archive during rollback", readError);
        return nil;
    }
    id decoded = MXSQLiteUnarchive(data);
    if (![decoded isKindOfClass:MXFileRoomOutgoingMessagesStore.class])
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"MXFileStore outgoing archive is unreadable during rollback", nil);
        return nil;
    }
    return decoded;
}

+ (BOOL)writeRollbackMetadataAtURL:(NSURL *)fileStoreURL credentials:(MXCredentials *)credentials error:(NSError **)error
{
    NSURL *metadataURL = [fileStoreURL URLByAppendingPathComponent:kLegacyMetadataFile];
    MXFileStoreMetaData *metadata = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:metadataURL.path])
    {
        NSError *readError;
        NSData *data = [NSData dataWithContentsOfURL:metadataURL options:NSDataReadingMappedIfSafe error:&readError];
        if (!data)
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot read MXFileStore metadata during rollback", readError);
            return NO;
        }
        @try
        {
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&readError];
            if (unarchiver)
            {
                unarchiver.requiresSecureCoding = NO;
                id decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
                [unarchiver finishDecoding];
                if ([decoded isKindOfClass:MXFileStoreMetaData.class]) metadata = decoded;
            }
        }
        @catch (NSException *exception)
        {
            MXLogWarning(@"[MXSQLiteLegacyImport] Existing MXFileStore metadata is unreadable during rollback: %@", exception.reason);
        }
        if (!metadata)
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"MXFileStore metadata is unreadable during rollback", readError);
            return NO;
        }
    }
    if (!metadata) metadata = [MXFileStoreMetaData new];
    metadata.homeServer = credentials.homeServer;
    metadata.userId = credentials.userId;
    metadata.version = MXFileStoreCurrentVersion;
    // This explicit metadata bit prevents MXFileStore's missing-token recovery from deleting the
    // exported local-only files, without pretending that an empty string is a valid sync token.
    metadata.eventStreamToken = nil;
    metadata.preserveLocalDataWithoutSyncToken = YES;
    NSError *writeError;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:metadata requiringSecureCoding:NO error:&writeError];
    if (!archive || ![archive writeToURL:metadataURL options:NSDataWritingAtomic error:&writeError])
    {
        if (error) *error = writeError ?: MXSQLiteLegacyImportMakeError(@"Cannot archive MXFileStore rollback metadata", nil);
        return NO;
    }
    return YES;
}

+ (BOOL)exportLocalOnlyDataFromStore:(MXSQLiteStore *)store
                   toFileStoreAtURL:(NSURL *)fileStoreURL
                        credentials:(MXCredentials *)credentials
                              error:(NSError **)error
{
    // Export is read-only: deactivation opens the existing database read-only so a failed rollback
    // can never trigger the normal writer's corrupt-database recreation path.
    if (!store.database)
    {
        if (error) *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorClosed
                                           userInfo:@{NSLocalizedDescriptionKey: @"SQLite store is not open for rollback export"}];
        return NO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *roomsURL = [fileStoreURL URLByAppendingPathComponent:kLegacyRoomsFolder isDirectory:YES];
    NSError *writeError;
    if (![fileManager createDirectoryAtURL:roomsURL withIntermediateDirectories:YES attributes:nil error:&writeError])
    {
        if (error) *error = writeError;
        return NO;
    }

    NSError *enumerationError;
    NSArray<NSURL *> *legacyRoomURLs = [fileManager contentsOfDirectoryAtURL:roomsURL includingPropertiesForKeys:nil
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles error:&enumerationError];
    if (!legacyRoomURLs && enumerationError && !(enumerationError.code == NSFileReadNoSuchFileError
                                                  && [enumerationError.domain isEqualToString:NSCocoaErrorDomain]))
    {
        if (error) *error = MXSQLiteLegacyImportMakeError(@"Cannot enumerate MXFileStore rooms during rollback", enumerationError);
        return NO;
    }
    NSMutableOrderedSet<NSString *> *roomIds = [NSMutableOrderedSet orderedSetWithArray:store.roomIds ?: @[]];
    for (NSURL *roomURL in legacyRoomURLs ?: @[])
    {
        [roomIds addObject:roomURL.lastPathComponent];
    }

    id<MXSQLiteMetaStoring> meta = (id<MXSQLiteMetaStoring>)store;
    BOOL legacyAlreadyImported = meta.legacyFileStoreImported;
    NSURL *backupURL = [fileStoreURL URLByAppendingPathComponent:kLegacyBackupFolder isDirectory:YES];
    if ([fileManager fileExistsAtPath:backupURL.path])
    {
        if (!legacyAlreadyImported)
        {
            if (error) *error = MXSQLiteLegacyImportMakeError(@"MXFileStore has an unfinished backup; refusing unsafe rollback", nil);
            return NO;
        }
        // After a completed import SQLite is authoritative; an old file-store recovery backup
        // would otherwise restore stale metadata and make MXFileStore delete the exported files.
        if (![fileManager removeItemAtURL:backupURL error:&writeError])
        {
            if (error) *error = writeError;
            return NO;
        }
    }
    for (NSString *roomId in roomIds)
    {
        NSArray<MXEvent *> *sqliteOutgoing = [store outgoingMessagesInRoom:roomId] ?: @[];
        NSAttributedString *sqliteDraft = [store partialAttributedTextMessageOfRoom:roomId];
        NSURL *roomURL = [roomsURL URLByAppendingPathComponent:roomId isDirectory:YES];
        NSURL *messagesURL = [roomURL URLByAppendingPathComponent:kLegacyMessagesFile];
        NSURL *outgoingURL = [roomURL URLByAppendingPathComponent:kLegacyOutgoingFile];
        BOOL hasExistingMessages = [fileManager fileExistsAtPath:messagesURL.path];
        BOOL hasExistingOutgoing = [fileManager fileExistsAtPath:outgoingURL.path];

        NSError *archiveError = nil;
        MXFileRoomStore *roomStore = [self existingRoomStoreAtURL:messagesURL error:&archiveError];
        if (archiveError)
        {
            if (error) *error = archiveError;
            return NO;
        }
        if (sqliteDraft.length || (legacyAlreadyImported && hasExistingMessages))
        {
            if (![fileManager createDirectoryAtURL:roomURL withIntermediateDirectories:YES attributes:nil error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
            if (!roomStore) roomStore = [MXFileRoomStore new];
            if (sqliteDraft.length)
            {
                roomStore.partialAttributedTextMessage = sqliteDraft;
            }
            else
            {
                // SQLite is authoritative after a completed migration: do not resurrect a cleared draft.
                roomStore.partialAttributedTextMessage = nil;
            }
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:roomStore requiringSecureCoding:NO error:&writeError];
            if (!archive || ![archive writeToURL:messagesURL options:NSDataWritingAtomic error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
        }

        archiveError = nil;
        MXFileRoomOutgoingMessagesStore *outgoingStore = [self existingOutgoingStoreAtURL:outgoingURL error:&archiveError];
        if (archiveError)
        {
            if (error) *error = archiveError;
            return NO;
        }
        if (legacyAlreadyImported)
        {
            if (sqliteOutgoing.count)
            {
                outgoingStore = [MXFileRoomOutgoingMessagesStore new];
                for (MXEvent *event in sqliteOutgoing) [outgoingStore storeOutgoingMessage:event];
            }
            else if (hasExistingOutgoing)
            {
                if (![fileManager removeItemAtURL:outgoingURL error:&writeError])
                {
                    if (error) *error = writeError;
                    return NO;
                }
                outgoingStore = nil;
            }
        }
        else if (sqliteOutgoing.count)
        {
            if (!outgoingStore) outgoingStore = [MXFileRoomOutgoingMessagesStore new];
            NSMutableSet<NSString *> *existingIds = [NSMutableSet set];
            for (MXEvent *event in outgoingStore.outgoingMessages)
            {
                if (event.eventId) [existingIds addObject:event.eventId];
            }
            for (MXEvent *event in sqliteOutgoing)
            {
                if (!event.eventId) continue;
                if ([existingIds containsObject:event.eventId]) [outgoingStore removeOutgoingMessage:event.eventId];
                [outgoingStore storeOutgoingMessage:event];
                [existingIds addObject:event.eventId];
            }
        }
        if (outgoingStore && (legacyAlreadyImported || sqliteOutgoing.count))
        {
            if (![fileManager createDirectoryAtURL:roomURL withIntermediateDirectories:YES attributes:nil error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:outgoingStore requiringSecureCoding:NO error:&writeError];
            if (!archive || ![archive writeToURL:outgoingURL options:NSDataWritingAtomic error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
        }
    }

    if (![self writeRollbackMetadataAtURL:fileStoreURL credentials:credentials error:error]) return NO;
    return YES;
}

@end
