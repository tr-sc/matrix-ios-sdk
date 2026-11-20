//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteLegacyImport.h"

#import "MXEvent.h"
#import "MXLog.h"
#import "MXMemoryRoomOutgoingMessagesStore.h"
#import "MXSQLiteCoding.h"
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
    [store flush];

    MXLogDebug(@"[MXSQLiteLegacyImport] Imported %tu outgoing and %tu drafts of %tu rooms in %.0f ms",
               result.outgoingCount, result.draftCount, result.roomCount, (CFAbsoluteTimeGetCurrent() - start) * 1000);
    return result;
}

@end
