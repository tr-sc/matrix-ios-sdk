//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteLegacyImport.h"

#import "MXEvent.h"
#import "MXLog.h"
#import "MXFileRoomStore.h"
#import "MXFileRoomOutgoingMessagesStore.h"
#import "MXMemoryRoomOutgoingMessagesStore.h"
#import "MXSQLiteCoding.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteStore.h"
#import "MXSQLiteStoreComponents.h"
#import "MatrixSDKSwiftHeader.h"

// Имена файлов MXFileStore (MXFileStore.m).
static NSString *const kLegacyFolder = @"MXFileStore";
static NSString *const kLegacyRoomsFolder = @"rooms";
static NSString *const kLegacyMessagesFile = @"messages";
static NSString *const kLegacyOutgoingFile = @"outgoingMessages";
static NSString *const kLegacyDraftKey = @"partialAttributedTextMessage";

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

+ (NSAttributedString *)draftAtURL:(NSURL *)url
{
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length)
    {
        return nil;
    }
    @try
    {
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
        unarchiver.requiresSecureCoding = NO;
        [unarchiver setClass:MXSQLiteLegacyDraftReader.class forClassName:@"MXFileRoomStore"];
        MXSQLiteLegacyDraftReader *reader = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
        return [reader isKindOfClass:MXSQLiteLegacyDraftReader.class] ? reader.draft : nil;
    }
    @catch (NSException *exception)
    {
        MXLogWarning(@"[MXSQLiteLegacyImport] Draft is unreadable: %@", exception.reason);
        return nil;
    }
}

+ (NSArray<MXEvent *> *)outgoingMessagesAtURL:(NSURL *)url
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    MXMemoryRoomOutgoingMessagesStore *store = MXSQLiteUnarchive(data);
    if (![store isKindOfClass:MXMemoryRoomOutgoingMessagesStore.class])
    {
        return @[];
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
    if (!store.database || store.readOnly || components.legacyFileStoreImported)
    {
        result.skipped = YES;
        result.succeeded = store.database != nil && (store.readOnly || components.legacyFileStoreImported);
        if (!result.succeeded)
        {
            result.error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorClosed
                                           userInfo:@{NSLocalizedDescriptionKey: @"SQLite store is not open for legacy import"}];
        }
        return result;
    }

    NSURL *roomsURL = [fileStoreURL URLByAppendingPathComponent:kLegacyRoomsFolder isDirectory:YES];
    NSArray<NSURL *> *roomURLs = [NSFileManager.defaultManager contentsOfDirectoryAtURL:roomsURL
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil] ?: @[];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    for (NSURL *roomURL in roomURLs)
    {
        @autoreleasepool
        {
            NSString *roomId = roomURL.lastPathComponent;
            NSArray<MXEvent *> *outgoing = [self outgoingMessagesAtURL:[roomURL URLByAppendingPathComponent:kLegacyOutgoingFile]];
            for (MXEvent *event in outgoing)
            {
                [components storeOutgoingMessageForRoom:roomId outgoingMessage:event];
            }
            NSAttributedString *draft = [self draftAtURL:[roomURL URLByAppendingPathComponent:kLegacyMessagesFile]];
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

+ (BOOL)exportLocalOnlyDataFromStore:(MXSQLiteStore *)store toFileStoreAtURL:(NSURL *)fileStoreURL error:(NSError **)error
{
    // Export is read-only: deactivation opens the existing database in read-only mode so a failed
    // rollback can never trigger the normal writer's corrupt-database recreation path.
    if (!store.database)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:MXSQLiteErrorDomain code:MXSQLiteErrorClosed
                                     userInfo:@{NSLocalizedDescriptionKey: @"SQLite store is not open for rollback export"}];
        }
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

    for (NSString *roomId in store.roomIds)
    {
        NSArray<MXEvent *> *outgoing = [store outgoingMessagesInRoom:roomId] ?: @[];
        NSAttributedString *draft = [store partialAttributedTextMessageOfRoom:roomId];
        if (!outgoing.count && !draft.length)
        {
            continue;
        }

        NSURL *roomURL = [roomsURL URLByAppendingPathComponent:roomId isDirectory:YES];
        if (![fileManager createDirectoryAtURL:roomURL withIntermediateDirectories:YES attributes:nil error:&writeError])
        {
            if (error) *error = writeError;
            return NO;
        }

        if (draft.length)
        {
            NSURL *messagesURL = [roomURL URLByAppendingPathComponent:kLegacyMessagesFile];
            MXFileRoomStore *roomStore = nil;
            NSData *existingMessages = [NSData dataWithContentsOfURL:messagesURL options:NSDataReadingMappedIfSafe error:nil];
            if (existingMessages.length)
            {
                @try
                {
                    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:existingMessages error:nil];
                    unarchiver.requiresSecureCoding = NO;
                    id decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
                    [unarchiver finishDecoding];
                    if ([decoded isKindOfClass:MXFileRoomStore.class]) roomStore = decoded;
                }
                @catch (NSException *exception)
                {
                    MXLogWarning(@"[MXSQLiteLegacyImport] Existing MXFileStore room archive is unreadable during rollback: %@", exception.reason);
                }
            }
            if (!roomStore) roomStore = [MXFileRoomStore new];
            roomStore.partialAttributedTextMessage = draft;
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:roomStore requiringSecureCoding:NO error:&writeError];
            if (!archive || ![archive writeToURL:messagesURL options:NSDataWritingAtomic error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
        }

        if (outgoing.count)
        {
            NSURL *outgoingURL = [roomURL URLByAppendingPathComponent:kLegacyOutgoingFile];
            MXFileRoomOutgoingMessagesStore *outgoingStore = nil;
            NSData *existingOutgoing = [NSData dataWithContentsOfURL:outgoingURL options:0 error:nil];
            MXMemoryRoomOutgoingMessagesStore *decoded = MXSQLiteUnarchive(existingOutgoing);
            if ([decoded isKindOfClass:MXFileRoomOutgoingMessagesStore.class]) outgoingStore = (MXFileRoomOutgoingMessagesStore *)decoded;
            if (!outgoingStore) outgoingStore = [MXFileRoomOutgoingMessagesStore new];

            NSMutableSet<NSString *> *existingIds = [NSMutableSet set];
            for (MXEvent *event in outgoingStore.outgoingMessages)
            {
                if (event.eventId) [existingIds addObject:event.eventId];
            }
            for (MXEvent *event in outgoing)
            {
                if (event.eventId && ![existingIds containsObject:event.eventId])
                {
                    [outgoingStore storeOutgoingMessage:event];
                    [existingIds addObject:event.eventId];
                }
            }
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:outgoingStore requiringSecureCoding:NO error:&writeError];
            if (!archive || ![archive writeToURL:outgoingURL options:NSDataWritingAtomic error:&writeError])
            {
                if (error) *error = writeError;
                return NO;
            }
        }
    }
    return YES;
}

@end
