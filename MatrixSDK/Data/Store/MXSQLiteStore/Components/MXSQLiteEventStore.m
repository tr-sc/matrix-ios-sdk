//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteEventStore.h"

#import "MXEventsEnumeratorOnArray.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteRoomRegistry.h"

@interface MXSQLiteEventStore () <MXEventsEnumeratorDataSource>
@property (nonatomic, readonly) MXSQLiteStoreContext *context;
@end

@implementation MXSQLiteEventStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
    }
    return self;
}

#pragma mark - MXEventsEnumeratorDataSource

- (MXEvent *)eventWithEventId:(NSString *)eventId
{
    return nil;
}

#pragma mark - Rooms

- (NSArray<NSString *> *)roomIds
{
    MXSQLiteStoreContext *context = self.context;
    return [context.database read:^id(MXSQLiteConnection *connection) {
        return [context.rooms allRoomIdsWithConnection:connection];
    }] ?: @[];
}

#pragma mark - Events (iP2)

- (void)storeEventForRoom:(NSString *)roomId event:(MXEvent *)event direction:(MXTimelineDirection)direction {}
- (void)replaceEvent:(MXEvent *)event inRoom:(NSString *)roomId {}
- (BOOL)eventExistsWithEventId:(NSString *)eventId inRoom:(NSString *)roomId { return NO; }
- (MXEvent *)eventWithEventId:(NSString *)eventId inRoom:(NSString *)roomId { return nil; }
- (void)deleteAllMessagesInRoom:(NSString *)roomId {}

- (void)loadRoomMessagesForRoom:(NSString *)roomId completion:(void (^)(void))completion
{
    // Чат не читается целиком: загружать нечего (ADR-0022).
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (id<MXEventsEnumerator>)messagesEnumeratorForRoom:(NSString *)roomId
{
    return [[MXEventsEnumeratorOnArray alloc] initWithEventIds:@[] dataSource:self];
}

- (id<MXEventsEnumerator>)messagesEnumeratorForRoom:(NSString *)roomId withTypeIn:(NSArray *)types
{
    return [self messagesEnumeratorForRoom:roomId];
}

- (NSArray<MXEvent *> *)relationsForEvent:(NSString *)eventId inRoom:(NSString *)roomId relationType:(NSString *)relationType { return @[]; }
- (NSUInteger)localUnreadEventCount:(NSString *)roomId threadId:(NSString *)threadId withTypeIn:(NSArray *)types { return 0; }
- (NSDictionary<NSString *, NSNumber *> *)localUnreadEventCountPerThread:(NSString *)roomId withTypeIn:(NSArray *)types { return @{}; }
- (NSArray<MXEvent *> *)newIncomingEventsInRoom:(NSString *)roomId threadId:(NSString *)threadId withTypeIn:(NSArray<MXEventTypeString> *)types { return @[]; }
- (BOOL)removeAllMessagesSentBefore:(uint64_t)limitTs inRoom:(NSString *)roomId { return NO; }

- (void)removeExpiredMessagesWithRoomMinimumTimestamps:(NSDictionary<NSString *, NSNumber *> *)roomMinimumTimestamps
                                            completion:(void (^)(NSUInteger, NSUInteger, BOOL))completion
{
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(0, 0, NO); });
    }
}

#pragma mark - History gaps shim (iP2)

- (NSArray<MXRoomHistoryGap *> *)historyGapsForRoom:(NSString *)roomId { return @[]; }
- (NSUInteger)historyRevisionForRoom:(NSString *)roomId { return 0; }
- (NSArray<MXEvent *> *)continuousRecentMessagesForRoom:(NSString *)roomId { return @[]; }
- (void)storeHistoryGap:(MXRoomHistoryGap *)gap forRoom:(NSString *)roomId {}
- (void)removeHistoryGapWithId:(NSString *)gapId inRoom:(NSString *)roomId {}
- (void)insertHistoryEvents:(NSArray<MXEvent *> *)events inRoom:(NSString *)roomId beforeEventId:(NSString *)eventId {}
- (NSArray<MXEvent *> *)historyBlockBeforeGap:(MXRoomHistoryGap *)gap inRoom:(NSString *)roomId { return @[]; }
- (void)applyHistoryGap:(MXRoomHistoryGap *)gap inRoom:(NSString *)roomId events:(NSArray<MXEvent *> *)events nextToken:(NSString *)token {}

#pragma mark - History contexts: not stored (final behaviour, not a stub)

- (NSArray<MXRoomHistoryContext *> *)historyContextsForRoom:(NSString *)roomId { return @[]; }
- (MXRoomHistoryContext *)historyContextForEventId:(NSString *)eventId inRoom:(NSString *)roomId filter:(NSDictionary *)filter { return nil; }
- (NSString *)historyContextGenerationForRoom:(NSString *)roomId { return nil; }

- (BOOL)storeHistoryContext:(MXRoomHistoryContext *)context
                     inRoom:(NSString *)roomId
         expectedGeneration:(NSString *)generation
       expectedRoomRevision:(NSUInteger)roomRevision
  expectedComponentRevision:(NSUInteger)componentRevision
{
    return NO;
}

#pragma mark - MXTimelineStore (iP2)

- (MXStorePage *)latestPageInRoom:(NSString *)roomId thread:(NSString *)threadId limit:(NSUInteger)limit types:(NSSet<NSString *> *)types { return MXStorePage.emptyPage; }
- (MXStorePage *)pageInRoom:(NSString *)roomId thread:(NSString *)threadId beforeOrder:(int64_t)order limit:(NSUInteger)limit types:(NSSet<NSString *> *)types { return MXStorePage.emptyPage; }
- (MXStorePage *)pageInRoom:(NSString *)roomId thread:(NSString *)threadId afterOrder:(int64_t)order limit:(NSUInteger)limit types:(NSSet<NSString *> *)types { return MXStorePage.emptyPage; }
- (MXStorePage *)pageAroundEvent:(NSString *)eventId inRoom:(NSString *)roomId limit:(NSUInteger)limit { return nil; }
- (BOOL)orderOfEvent:(NSString *)eventId inRoom:(NSString *)roomId order:(int64_t *)order { return NO; }
- (NSArray<MXRoomHole *> *)holesInRoom:(NSString *)roomId thread:(NSString *)threadId { return @[]; }
- (NSUInteger)revisionOfRoom:(NSString *)roomId { return 0; }
- (MXEvent *)latestEventInRoom:(NSString *)roomId types:(NSSet<NSString *> *)types threadId:(NSString *)threadId beforeOrder:(int64_t)order { return nil; }

- (NSUInteger)countEventsInRoom:(NSString *)roomId
                   afterEventId:(NSString *)eventId
                          types:(NSSet<NSString *> *)types
                excludingSender:(NSString *)userId
                       threadId:(NSString *)threadId
                          limit:(NSUInteger)limit
{
    return NSNotFound;
}

- (void)noteSyncTimelineInRoom:(NSString *)roomId firstEvent:(MXEvent *)firstEvent limited:(BOOL)limited prevBatch:(NSString *)prevBatch {}
- (void)applyPage:(MXPaginationResponse *)response toHole:(MXRoomHole *)hole direction:(MXTimelineDirection)direction {}
- (void)insertContext:(MXEventContext *)context inRoom:(NSString *)roomId {}
- (BOOL)insertDetachedEvent:(MXEvent *)event inRoom:(NSString *)roomId { return NO; }

@end
