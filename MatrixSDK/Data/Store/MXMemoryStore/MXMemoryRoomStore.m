/*
 Copyright 2014 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXMemoryRoomStore.h"

#import "MXEventsEnumeratorOnArray.h"
#import "MXEventsByTypesEnumeratorOnArray.h"

@interface MXMemoryRoomStore () <MXEventsEnumeratorDataSource>
{
}

@end

@implementation MXRoomHistoryGap
- (instancetype)init
{
    if ((self = [super init])) { _gapId = NSUUID.UUID.UUIDString; _olderAnchorEventId = @""; _newerAnchorEventId = @""; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _gapId = [coder decodeObjectForKey:@"id"] ?: _gapId;
        _olderAnchorEventId = [coder decodeObjectForKey:@"older"] ?: @"";
        _newerAnchorEventId = [coder decodeObjectForKey:@"newer"] ?: @"";
        _backwardToken = [coder decodeObjectForKey:@"token"];
        _recoveryBlocked = [coder decodeBoolForKey:@"blocked"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_gapId forKey:@"id"];
    [coder encodeObject:_olderAnchorEventId forKey:@"older"];
    [coder encodeObject:_newerAnchorEventId forKey:@"newer"];
    [coder encodeObject:_backwardToken forKey:@"token"];
    [coder encodeBool:_recoveryBlocked forKey:@"blocked"];
}
- (id)copyWithZone:(NSZone *)zone
{
    MXRoomHistoryGap *copy = [[MXRoomHistoryGap allocWithZone:zone] init];
    copy.gapId = _gapId; copy.olderAnchorEventId = _olderAnchorEventId;
    copy.newerAnchorEventId = _newerAnchorEventId; copy.backwardToken = _backwardToken;
    copy.recoveryBlocked = _recoveryBlocked;
    return copy;
}
@end

static NSArray<MXEvent *> *MXCopyContextEvents(NSArray<MXEvent *> *events)
{
    NSMutableArray *copies = [NSMutableArray arrayWithCapacity:events.count];
    for (MXEvent *event in events) [copies addObject:[event copy]];
    return copies;
}

@implementation MXRoomHistoryContext
- (instancetype)init
{
    if ((self = [super init])) {
        _componentId = NSUUID.UUID.UUIDString; _targetEventId = @"";
        _replayRoots = @[]; _initialBackwardEventIds = @[];
        _events = @[]; _initialEvents = @[]; _initialState = @[]; _pageUpdates = @[]; _filter = @{};
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _componentId = [coder decodeObjectForKey:@"id"] ?: _componentId;
        _targetEventId = [coder decodeObjectForKey:@"target"] ?: @"";
        _replayRoots = [coder decodeObjectForKey:@"roots"] ?: @[];
        _selectedRootId = [coder decodeObjectForKey:@"selectedRoot"];
        _backwardRootId = [coder decodeObjectForKey:@"backwardRoot"];
        _forwardRootId = [coder decodeObjectForKey:@"forwardRoot"];
        _events = [coder decodeObjectForKey:@"events"] ?: @[];
        _initialEvents = [coder decodeObjectForKey:@"initialEvents"] ?: @[];
        _initialAnchorEventId = [coder decodeObjectForKey:@"initialAnchor"];
        _initialBackwardEventIds = [coder decodeObjectForKey:@"initialBackwards"] ?: @[];
        _initialState = [coder decodeObjectForKey:@"initialState"] ?: @[];
        _pageUpdates = [coder decodeObjectForKey:@"updates"] ?: @[];
        _filter = [coder decodeObjectForKey:@"filter"] ?: @{};
        _backwardToken = [coder decodeObjectForKey:@"backwardToken"];
        _forwardToken = [coder decodeObjectForKey:@"forwardToken"];
        _backwardBlocked = [coder decodeBoolForKey:@"backwardBlocked"];
        _forwardBlocked = [coder decodeBoolForKey:@"forwardBlocked"];
        _backwardConnected = [coder decodeBoolForKey:@"backwardConnected"];
        _forwardConnected = [coder decodeBoolForKey:@"forwardConnected"];
        _attachedToLive = [coder decodeBoolForKey:@"attachedToLive"];
        _revision = [coder decodeIntegerForKey:@"revision"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_componentId forKey:@"id"];
    [coder encodeObject:_targetEventId forKey:@"target"];
    [coder encodeObject:_replayRoots forKey:@"roots"];
    [coder encodeObject:_selectedRootId forKey:@"selectedRoot"];
    [coder encodeObject:_backwardRootId forKey:@"backwardRoot"];
    [coder encodeObject:_forwardRootId forKey:@"forwardRoot"];
    [coder encodeObject:_events forKey:@"events"];
    [coder encodeObject:_initialEvents forKey:@"initialEvents"];
    [coder encodeObject:_initialAnchorEventId forKey:@"initialAnchor"];
    [coder encodeObject:_initialBackwardEventIds forKey:@"initialBackwards"];
    [coder encodeObject:_initialState forKey:@"initialState"];
    [coder encodeObject:_pageUpdates forKey:@"updates"];
    [coder encodeObject:_filter forKey:@"filter"];
    [coder encodeObject:_backwardToken forKey:@"backwardToken"];
    [coder encodeObject:_forwardToken forKey:@"forwardToken"];
    [coder encodeBool:_backwardBlocked forKey:@"backwardBlocked"];
    [coder encodeBool:_forwardBlocked forKey:@"forwardBlocked"];
    [coder encodeBool:_backwardConnected forKey:@"backwardConnected"];
    [coder encodeBool:_forwardConnected forKey:@"forwardConnected"];
    [coder encodeBool:_attachedToLive forKey:@"attachedToLive"];
    [coder encodeInteger:_revision forKey:@"revision"];
}
- (id)copyWithZone:(NSZone *)zone
{
    MXRoomHistoryContext *copy = [[MXRoomHistoryContext allocWithZone:zone] init];
    copy.componentId = _componentId; copy.targetEventId = _targetEventId;
    copy.replayRoots = [[NSArray alloc] initWithArray:_replayRoots copyItems:YES];
    copy.selectedRootId = _selectedRootId;
    copy.backwardRootId = _backwardRootId; copy.forwardRootId = _forwardRootId;
    copy.initialAnchorEventId = _initialAnchorEventId; copy.initialBackwardEventIds = _initialBackwardEventIds;
    copy.events = MXCopyContextEvents(_events); copy.initialEvents = MXCopyContextEvents(_initialEvents);
    copy.initialState = MXCopyContextEvents(_initialState);
    NSMutableArray *updates = [NSMutableArray array];
    for (NSDictionary *update in _pageUpdates) {
        [updates addObject:@{@"direction": update[@"direction"] ?: @0,
                             @"events": MXCopyContextEvents(update[@"events"] ?: @[]),
                             @"state": MXCopyContextEvents(update[@"state"] ?: @[])}];
    }
    copy.pageUpdates = updates;
    NSData *filterData = [NSJSONSerialization dataWithJSONObject:_filter options:0 error:nil];
    copy.filter = filterData ? [NSJSONSerialization JSONObjectWithData:filterData options:0 error:nil] : @{};
    copy.backwardToken = _backwardToken; copy.forwardToken = _forwardToken;
    copy.backwardBlocked = _backwardBlocked; copy.forwardBlocked = _forwardBlocked;
    copy.backwardConnected = _backwardConnected; copy.forwardConnected = _forwardConnected;
    copy.attachedToLive = _attachedToLive; copy.revision = _revision;
    return copy;
}
@end

static void MXSetContextBoundaryOwners(MXRoomHistoryContext *context);

@implementation MXMemoryRoomStore
@synthesize historyContexts = _historyContexts;

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        messages = [NSMutableArray array];
        _historyGaps = @[];
        _historyRedactions = @{};
        _historyContexts = @[];
        _historyContextGeneration = NSUUID.UUID.UUIDString;
        _historyRevision = 1;
        messagesByEventIds = [NSMutableDictionary dictionary];
        _backwardPaginationState = MXRoomBackwardPaginationStateUnknown;
        _hasLoadedAllRoomMembersForRoom = NO;
    }
    return self;
}

- (void)setHasReachedHomeServerPaginationEnd:(BOOL)hasReachedHomeServerPaginationEnd
{
    self.backwardPaginationState = hasReachedHomeServerPaginationEnd
        ? MXRoomBackwardPaginationStateExhausted
        : MXRoomBackwardPaginationStateUnknown;
}

- (BOOL)hasReachedHomeServerPaginationEnd
{
    return self.backwardPaginationState == MXRoomBackwardPaginationStateExhausted;
}

// Удаление монотонно: более старый ответ не возвращает содержимое цели.
- (MXEvent *)eventByApplyingHistoryRedaction:(MXEvent *)event
{
    NSDictionary *redaction = event.eventId.length ? self.historyRedactions[event.eventId] : nil;
    if (!redaction && event.eventId.length) redaction = messagesByEventIds[event.eventId].redactedBecause;
    redaction = redaction ?: event.redactedBecause;
    if (!redaction) return event;
    MXEvent *pruned = [event prune];
    pruned.redactedBecause = redaction;
    return pruned;
}

- (void)rememberHistoryRedactionForEvent:(MXEvent *)event
{
    if (!event.eventId.length || !event.redactedBecause || self.historyRedactions[event.eventId]) return;
    NSMutableDictionary *redactions = [self.historyRedactions mutableCopy];
    redactions[event.eventId] = event.redactedBecause;
    self.historyRedactions = redactions;
    _historyRevision++;
}

- (NSArray<MXEvent *> *)eventsByApplyingHistoryRedactions:(NSArray<MXEvent *> *)events
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:events.count];
    for (MXEvent *event in events) [result addObject:[self eventByApplyingHistoryRedaction:event]];
    return result;
}

- (void)applyHistoryRedactionsToContext:(MXRoomHistoryContext *)context
{
    context.events = [self eventsByApplyingHistoryRedactions:context.events];
    context.initialEvents = [self eventsByApplyingHistoryRedactions:context.initialEvents];
    context.initialState = [self eventsByApplyingHistoryRedactions:context.initialState];
    NSMutableArray *updates = [NSMutableArray array];
    for (NSDictionary *update in context.pageUpdates) {
        [updates addObject:@{@"direction": update[@"direction"],
                             @"events": [self eventsByApplyingHistoryRedactions:update[@"events"]],
                             @"state": [self eventsByApplyingHistoryRedactions:update[@"state"]]}];
    }
    context.pageUpdates = updates;
    for (MXRoomHistoryContext *root in context.replayRoots) [self applyHistoryRedactionsToContext:root];
}

- (void)rememberHistoryRedactionsInEvents:(NSArray<MXEvent *> *)events
{
    for (MXEvent *event in events) {
        if (event.eventType == MXEventTypeRoomRedaction && event.redacts.length && !self.historyRedactions[event.redacts]) {
            NSMutableDictionary *redactions = [self.historyRedactions mutableCopy];
            redactions[event.redacts] = event.JSONDictionary;
            self.historyRedactions = redactions;
            _historyRevision++;
        }
        if (event.redactedBecause) [self replaceEvent:event];
    }
}

- (void)rememberHistoryRedactionsInContext:(MXRoomHistoryContext *)context
{
    [self rememberHistoryRedactionsInEvents:context.events];
    [self rememberHistoryRedactionsInEvents:context.initialEvents];
    [self rememberHistoryRedactionsInEvents:context.initialState];
    for (NSDictionary *update in context.pageUpdates) {
        [self rememberHistoryRedactionsInEvents:update[@"events"]];
        [self rememberHistoryRedactionsInEvents:update[@"state"]];
    }
    for (MXRoomHistoryContext *root in context.replayRoots) [self rememberHistoryRedactionsInContext:root];
}

- (void)storeEvent:(MXEvent *)event direction:(MXTimelineDirection)direction
{
    [self rememberHistoryRedactionForEvent:event];
    event = [self eventByApplyingHistoryRedaction:event];
    if (event.eventId && messagesByEventIds[event.eventId]) {
        if (event.redactedBecause) [self replaceEvent:event];
        return;
    }
    _historyRevision++;
    if (MXTimelineDirectionForwards == direction)
    {
        [messages addObject:event];
    }
    else
    {
        [messages insertObject:event atIndex:0];
    }

    if (event.eventId)
    {
        messagesByEventIds[event.eventId] = event;
    }
}

static NSArray *MXReplaceContextEvent(NSArray<MXEvent *> *events, MXEvent *replacement)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:events.count];
    for (MXEvent *event in events) [result addObject:[event.eventId isEqualToString:replacement.eventId] ? [replacement copy] : event];
    return result;
}

- (void)replaceEvent:(MXEvent*)event
{
    [self rememberHistoryRedactionForEvent:event];
    event = [self eventByApplyingHistoryRedaction:event];
    // Содержимое контекста — альтернативные проекции одного события, а не
    // независимый источник истины. Обновляем каждый источник воспроизведения и упорядоченное покрытие.
    NSMutableArray *projections = [NSMutableArray arrayWithArray:_historyContexts];
    for (MXRoomHistoryContext *context in _historyContexts) [projections addObjectsFromArray:context.replayRoots];
    for (MXRoomHistoryContext *context in projections) {
        BOOL affected = NO;
        NSMutableArray *sources = [NSMutableArray arrayWithArray:context.events];
        [sources addObjectsFromArray:context.initialState];
        for (NSDictionary *update in context.pageUpdates) [sources addObjectsFromArray:update[@"state"]];
        for (MXEvent *candidate in sources) if ([candidate.eventId isEqualToString:event.eventId]) { affected = YES; break; }
        if (!affected) continue;
        context.events = MXReplaceContextEvent(context.events, event);
        context.initialEvents = MXReplaceContextEvent(context.initialEvents, event);
        context.initialState = MXReplaceContextEvent(context.initialState, event);
        NSMutableArray *updates = [NSMutableArray array];
        for (NSDictionary *update in context.pageUpdates) [updates addObject:@{@"direction": update[@"direction"], @"events": MXReplaceContextEvent(update[@"events"], event), @"state": MXReplaceContextEvent(update[@"state"], event)}];
        context.pageUpdates = updates; context.revision++; _historyRevision++;
    }
    NSUInteger index = messages.count;
    while (index--)
    {
        MXEvent *anEvent = [messages objectAtIndex:index];
        if ([anEvent.eventId isEqualToString:event.eventId])
        {
            [messages replaceObjectAtIndex:index withObject:event];

            messagesByEventIds[event.eventId] = event;
            _historyRevision++;
            break;
        }
    }
}

- (MXEvent *)eventWithEventId:(NSString *)eventId
{
    return messagesByEventIds[eventId];
}

- (void)removeAllMessages
{
    _historyGaps = @[];
    _historyRedactions = @{};
    _historyContexts = @[];
    _historyContextGeneration = NSUUID.UUID.UUIDString;
    _historyRevision++;
    [messages removeAllObjects];
    [messagesByEventIds removeAllObjects];
}

- (NSArray <NSString *>*)allEventIds
{
    NSMutableArray *eventIds = [[NSMutableArray alloc] initWithCapacity:messages.count];
    for (MXEvent *event in messages) {
        [eventIds addObject:event.eventId];
    }
    return eventIds.copy;
}

- (id<MXEventsEnumerator>)messagesEnumerator
{
    return [[MXEventsEnumeratorOnArray alloc] initWithEventIds:[self allEventIds] dataSource:self];
}

- (id<MXEventsEnumerator>)enumeratorForMessagesWithTypeIn:(NSArray*)types
{
    return [[MXEventsByTypesEnumeratorOnArray alloc] initWithEventIds:[self allEventIds] andTypesIn:types dataSource:self];
}

- (NSArray<MXEvent*>*)eventsInThreadWithThreadId:(NSString *)threadId except:(NSString *)userId withTypeIn:(NSSet<MXEventTypeString>*)types
{
    NSMutableArray* list = [[NSMutableArray alloc] init];
    
    if (threadId == nil || [threadId isEqualToString:kMXEventTimelineMain])
    {
        MXLogWarning(@"[MXMemoryRoomStore] eventsInThreadWithThreadId: invalid thread ID %@", threadId);
        return list;
    }

    // Check messages from the most recent
    for (NSInteger i = messages.count - 1; i >= 0 ; i--)
    {
        MXEvent *event = messages[i];

        // Check if the event is the root event of the thread
        if (NO == [event.eventId isEqualToString:threadId])
        {
            // Keep events matching filters
            BOOL typeAllowed = !types || [types containsObject:event.type];
            BOOL threadAllowed = [event.threadId isEqualToString:threadId];
            BOOL senderAllowed = ![event.sender isEqualToString:userId];
            if (typeAllowed && threadAllowed && senderAllowed)
            {
                [list insertObject:event atIndex:0];
            }
        }
        else
        {
            // We are done
            break;
        }
    }

    return list;
}

- (NSArray<MXEvent*>*)eventsAfter:(NSString *)eventId threadId:(NSString *)threadId except:(NSString *)userId withTypeIn:(NSSet<MXEventTypeString>*)types
{
    NSMutableArray* list = [[NSMutableArray alloc] init];

    if (eventId)
    {
        NSString *_threadId = ![threadId isEqualToString:kMXEventTimelineMain] ? threadId : nil;
        // Check messages from the most recent
        for (NSInteger i = messages.count - 1; i >= 0 ; i--)
        {
            MXEvent *event = messages[i];

            if (NO == [event.eventId isEqualToString:eventId])
            {
                // Keep events matching filters
                BOOL typeAllowed = !types || [types containsObject:event.type];
                BOOL threadAllowed = (!_threadId && !event.isInThread) || [event.threadId isEqualToString:_threadId];
                BOOL senderAllowed = ![event.sender isEqualToString:userId];
                if (typeAllowed && threadAllowed && senderAllowed)
                {
                    [list insertObject:event atIndex:0];
                }
            }
            else
            {
                // We are done
                break;
            }
        }
    }

    return list;
}

- (NSArray<MXEvent*>*)relationsForEvent:(NSString*)eventId relationType:(NSString*)relationType
{
    NSMutableArray<MXEvent*>* referenceEvents = [NSMutableArray new];
    
    for (MXEvent* event in messages)
    {
        MXEventContentRelatesTo *relatesTo = event.relatesTo;
        
        if (relatesTo && [relatesTo.eventId isEqualToString:eventId] && [relatesTo.relationType isEqualToString:relationType])
        {
            [referenceEvents addObject:event];
        }
    }
    
    return referenceEvents;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%tu messages - paginationToken: %@ - backwardPaginationState: %tu - hasLoadedAllRoomMembersForRoom: %@", messages.count, _paginationToken, self.backwardPaginationState, @(_hasLoadedAllRoomMembersForRoom)];
}

static NSArray<MXEvent *> *MXRetainedContextEvents(NSArray<MXEvent *> *events, uint64_t timestamp)
{
    NSMutableArray *result = [NSMutableArray array];
    for (MXEvent *event in events) if (event.isState || event.originServerTs >= timestamp) [result addObject:event];
    return result;
}

- (BOOL)trimHistoryContext:(MXRoomHistoryContext *)context before:(uint64_t)timestamp
{
    if (!context.initialAnchorEventId) {
        context.initialAnchorEventId = context.targetEventId;
        NSUInteger anchor = [[context.initialEvents valueForKey:@"eventId"] indexOfObject:context.targetEventId];
        if (anchor != NSNotFound) context.initialBackwardEventIds = [[context.initialEvents subarrayWithRange:NSMakeRange(0, anchor)] valueForKey:@"eventId"];
    }
    NSUInteger previousCount = context.events.count;
    context.events = MXRetainedContextEvents(context.events, timestamp);
    context.initialEvents = MXRetainedContextEvents(context.initialEvents, timestamp);
    NSMutableArray *updates = [NSMutableArray array];
    for (NSDictionary *update in context.pageUpdates) [updates addObject:@{@"direction": update[@"direction"], @"state": update[@"state"], @"events": MXRetainedContextEvents(update[@"events"], timestamp)}];
    context.pageUpdates = updates;
    if (![[context.events valueForKey:@"eventId"] containsObject:context.targetEventId]) context.targetEventId = context.events.firstObject.eventId ?: @"";
    NSMutableArray *roots = [NSMutableArray array];
    for (MXRoomHistoryContext *root in context.replayRoots) {
        [self trimHistoryContext:root before:timestamp];
        if (root.events.count) [roots addObject:root];
    }
    context.replayRoots = roots;
    if (previousCount != context.events.count) { context.revision++; context.backwardConnected = NO; context.forwardConnected = NO; context.attachedToLive = NO; }
    return previousCount != context.events.count;
}

- (BOOL)removeAllMessagesSentBefore:(uint64_t)limitTs
{
    // Сохраняем исходный блок каждой границы до удаления ID событий при ограничении хранения.
    // Перенос границы внутри того же блока не утверждает непрерывности через разрыв.
    NSMutableDictionary<NSString *, NSArray<MXEvent *> *> *olderBlocks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSArray<MXEvent *> *> *newerBlocks = [NSMutableDictionary dictionary];
    NSArray<MXRoomHistoryGap *> *gaps = self.historyGaps;
    for (MXRoomHistoryGap *gap in gaps) {
        olderBlocks[gap.gapId] = [self historyBlockBeforeGap:gap];
        NSUInteger start = [self indexOfHistoryEvent:gap.newerAnchorEventId];
        if (start == NSNotFound) continue;
        NSUInteger end = messages.count;
        for (MXRoomHistoryGap *next in gaps) {
            NSUInteger nextStart = [self indexOfHistoryEvent:next.newerAnchorEventId];
            if (nextStart > start) end = MIN(end, nextStart);
        }
        newerBlocks[gap.gapId] = [messages subarrayWithRange:NSMakeRange(start, end - start)];
    }
    NSUInteger index = 0;
    BOOL didChange = NO;
    while (index < messages.count)
    {
        MXEvent *anEvent = [messages objectAtIndex:index];
        if (anEvent.isState)
        {
            // Keep state event
            index ++;
        }
        else if (anEvent.originServerTs < limitTs)
        {
            [messages removeObjectAtIndex:index];
            [messagesByEventIds removeObjectForKey:anEvent.eventId];
            didChange = YES;
        }
        else
        {
            // Серверные метки времени не определяют смежность сохранённых блоков.
            index++;
        }
    }
    if (didChange) {
        _historyRevision++;
        for (MXRoomHistoryGap *gap in gaps) {
            BOOL changed = NO;
            if (!messagesByEventIds[gap.olderAnchorEventId]) {
                for (MXEvent *event in olderBlocks[gap.gapId].reverseObjectEnumerator) {
                    if (messagesByEventIds[event.eventId]) { gap.olderAnchorEventId = event.eventId; changed = YES; break; }
                }
            }
            if (!messagesByEventIds[gap.newerAnchorEventId]) {
                for (MXEvent *event in newerBlocks[gap.gapId]) {
                    if (messagesByEventIds[event.eventId]) { gap.newerAnchorEventId = event.eventId; changed = YES; break; }
                }
            }
            if (changed) [self storeHistoryGap:gap];
        }
    }
    if (limitTs > self.historyContextRetentionTimestamp) { didChange = YES; _historyRevision++; }
    self.historyContextRetentionTimestamp = MAX(self.historyContextRetentionTimestamp, limitTs);
    NSMutableArray *retainedContexts = [NSMutableArray array];
    for (MXRoomHistoryContext *context in _historyContexts) {
        MXRoomHistoryContext *trimmed = [context copy];
        if ([self trimHistoryContext:trimmed before:limitTs]) { didChange = YES; _historyRevision++; }
        if (trimmed.events.count) { MXSetContextBoundaryOwners(trimmed); [retainedContexts addObject:trimmed]; }
    }
    _historyContexts = retainedContexts;
    return didChange;
}


- (void)setPaginationToken:(NSString *)token
{
    if (![_paginationToken isEqualToString:token]) _historyRevision++;
    _paginationToken = [token copy];
}
- (void)setBackwardPaginationState:(MXRoomBackwardPaginationState)state
{
    if (_backwardPaginationState != state) _historyRevision++;
    _backwardPaginationState = state;
}
- (NSArray<MXRoomHistoryGap *> *)historyGaps
{
    return [[NSArray alloc] initWithArray:_historyGaps copyItems:YES];
}
- (NSUInteger)indexOfHistoryEvent:(NSString *)eventId
{
    if (!eventId) return NSNotFound;
    return [messages indexOfObjectPassingTest:^BOOL(MXEvent *event, NSUInteger idx, BOOL *stop) {
        return [event.eventId isEqualToString:eventId];
    }];
}
- (void)storeHistoryGap:(MXRoomHistoryGap *)gap
{
    NSMutableArray *gaps = [_historyGaps mutableCopy];
    NSIndexSet *matches = [gaps indexesOfObjectsPassingTest:^BOOL(MXRoomHistoryGap *other, NSUInteger idx, BOOL *stop) {
        return [other.gapId isEqualToString:gap.gapId];
    }];
    [gaps removeObjectsAtIndexes:matches];
    [gaps addObject:[gap copy]];
    [gaps sortUsingComparator:^NSComparisonResult(MXRoomHistoryGap *a, MXRoomHistoryGap *b) {
        NSUInteger ai = [self indexOfHistoryEvent:a.newerAnchorEventId], bi = [self indexOfHistoryEvent:b.newerAnchorEventId];
        return ai < bi ? NSOrderedAscending : ai > bi ? NSOrderedDescending : NSOrderedSame;
    }];
    _historyGaps = gaps;
    _historyRevision++;
}
- (void)removeHistoryGapWithId:(NSString *)gapId
{
    NSMutableArray *gaps = [_historyGaps mutableCopy];
    NSIndexSet *matches = [gaps indexesOfObjectsPassingTest:^BOOL(MXRoomHistoryGap *gap, NSUInteger idx, BOOL *stop) {
        return [gap.gapId isEqualToString:gapId];
    }];
    if (!matches.count) return;
    [gaps removeObjectsAtIndexes:matches]; _historyGaps = gaps; _historyRevision++;
}
- (NSArray<MXEvent *> *)continuousRecentMessages
{
    NSUInteger start = 0;
    for (MXRoomHistoryGap *gap in _historyGaps) {
        NSUInteger index = [self indexOfHistoryEvent:gap.newerAnchorEventId];
        // Опорное событие могло быть удалено при ограничении хранения. Его отсутствие не доказывает непрерывность.
        if (index == NSNotFound) return @[];
        start = MAX(start, index);
    }
    return [messages subarrayWithRange:NSMakeRange(start, messages.count - start)];
}
- (NSArray<MXEvent *> *)historyBlockBeforeGap:(MXRoomHistoryGap *)gap
{
    NSUInteger end = [self indexOfHistoryEvent:gap.olderAnchorEventId];
    if (end == NSNotFound) return @[];
    NSUInteger start = 0;
    for (MXRoomHistoryGap *other in _historyGaps) {
        if ([other.gapId isEqualToString:gap.gapId]) continue;
        NSUInteger index = [self indexOfHistoryEvent:other.newerAnchorEventId];
        if (index != NSNotFound && index <= end) start = MAX(start, index);
    }
    return [messages subarrayWithRange:NSMakeRange(start, end - start + 1)];
}
- (void)insertHistoryEvents:(NSArray<MXEvent *> *)events beforeEventId:(NSString *)eventId
{
    NSUInteger index = eventId ? [self indexOfHistoryEvent:eventId] : 0;
    if (index == NSNotFound) return; // Устаревшая или удалённая граница: не добавляем события в предполагаемое место.
    [self rememberHistoryRedactionsInEvents:events];
    for (MXEvent *incoming in events) {
        MXEvent *event = [self eventByApplyingHistoryRedaction:incoming];
        if (!event.eventId.length || messagesByEventIds[event.eventId]) continue;
        [messages insertObject:event atIndex:index++];
        messagesByEventIds[event.eventId] = event; _historyRevision++;
    }
}
- (void)applyHistoryGap:(MXRoomHistoryGap *)gap events:(NSArray<MXEvent *> *)events nextToken:(NSString *)token
{
    MXRoomHistoryGap *current;
    for (MXRoomHistoryGap *candidate in _historyGaps) if ([candidate.gapId isEqualToString:gap.gapId]) current = candidate;
    if (!current || ![current.newerAnchorEventId isEqualToString:gap.newerAnchorEventId]
        || ![current.olderAnchorEventId isEqualToString:gap.olderAnchorEventId]
        || !((current.backwardToken == gap.backwardToken) || [current.backwardToken isEqualToString:gap.backwardToken])) return;
    NSArray<MXRoomHistoryGap *> *beforeGaps = self.historyGaps;
    NSArray<MXEvent *> *beforeMessages = [messages copy];
    NSSet *targetOlderIds = [NSSet setWithArray:[[self historyBlockBeforeGap:gap] valueForKey:@"eventId"]];
    // Ограничиваем доказательство монотонным префиксом, связанным с этим запросом. Одно лишь
    // упоминание другого более старого островка на странице не устраняет посторонние границы.
    NSMutableArray *validated = [NSMutableArray array];
    NSUInteger scanPosition = [self indexOfHistoryEvent:gap.newerAnchorEventId];
    BOOL scanReachedOlder = NO;
    for (MXEvent *event in events) {
        NSUInteger index = [self indexOfHistoryEvent:event.eventId];
        if (index != NSNotFound && index < scanPosition) {
            if ([targetOlderIds containsObject:event.eventId]) scanReachedOlder = YES;
            if (!scanReachedOlder) break;
            scanPosition = index;
        }
        [validated addObject:event];
    }
    events = validated;
    NSMutableSet *pageIds = [NSMutableSet set];
    for (MXEvent *event in events) if (event.eventId.length) [pageIds addObject:event.eventId];
    NSMutableSet *resolved = [NSMutableSet set];
    for (MXRoomHistoryGap *boundary in beforeGaps) {
        NSSet *olderIds = [NSSet setWithArray:[[self historyBlockBeforeGap:boundary] valueForKey:@"eventId"]];
        NSUInteger start = [self indexOfHistoryEvent:boundary.newerAnchorEventId];
        NSUInteger end = beforeMessages.count;
        for (MXRoomHistoryGap *next in beforeGaps) {
            NSUInteger nextStart = [self indexOfHistoryEvent:next.newerAnchorEventId];
            if (start != NSNotFound && nextStart > start) end = MIN(end, nextStart);
        }
        if (start == NSNotFound) continue;
        NSSet *newerIds = [NSSet setWithArray:[[beforeMessages subarrayWithRange:NSMakeRange(start, end - start)] valueForKey:@"eventId"]];
        BOOL reachesNewer = [boundary.gapId isEqualToString:gap.gapId] || [newerIds intersectsSet:pageIds];
        if (reachesNewer && [olderIds intersectsSet:pageIds]) [resolved addObject:boundary.gapId];
    }
    if ([self indexOfHistoryEvent:gap.newerAnchorEventId] == NSNotFound) {
        MXRoomHistoryGap *blocked = [gap copy]; blocked.recoveryBlocked = YES;
        [self storeHistoryGap:blocked];
        return;
    }
    // Только проверенный префикс действующего разрыва может обновить содержимое.
    // Совпавшие ID не добавляются повторно, но подтверждённые удаления нельзя терять при дедупликации.
    [self rememberHistoryRedactionsInEvents:events];
    NSString *anchor = gap.newerAnchorEventId;
    BOOL reachedTargetOlder = NO;
    NSMutableDictionary<NSString *, MXRoomHistoryGap *> *advanced = [NSMutableDictionary dictionary];
    NSUInteger inserted = 0;
    for (MXEvent *event in events) {
        if (!event.eventId.length) continue;
        NSUInteger existing = [self indexOfHistoryEvent:event.eventId];
        NSUInteger position = [self indexOfHistoryEvent:anchor];
        if (existing != NSNotFound) {
            if (existing >= position) continue;
            if ([targetOlderIds containsObject:event.eventId]) reachedTargetOlder = YES;
            // Не используем посторонний блок как основание для перехода через разрыв.
            if (!reachedTargetOlder) break;
            anchor = event.eventId;
            continue;
        }
        for (MXRoomHistoryGap *boundary in beforeGaps) {
            NSUInteger older = [self indexOfHistoryEvent:boundary.olderAnchorEventId];
            NSUInteger newer = [self indexOfHistoryEvent:boundary.newerAnchorEventId];
            if (older != NSNotFound && newer != NSNotFound && position > older && position <= newer) {
                MXRoomHistoryGap *updated = advanced[boundary.gapId] ?: [boundary copy];
                updated.newerAnchorEventId = event.eventId;
                advanced[boundary.gapId] = updated;
            }
        }
        [self insertHistoryEvents:@[event] beforeEventId:anchor];
        inserted++;
        anchor = event.eventId;
    }
    for (MXRoomHistoryGap *boundary in beforeGaps) {
        if ([resolved containsObject:boundary.gapId]) {
            [self removeHistoryGapWithId:boundary.gapId];
        } else if (advanced[boundary.gapId] || [boundary.gapId isEqualToString:gap.gapId]) {
            MXRoomHistoryGap *updated = advanced[boundary.gapId] ?: [boundary copy];
            updated.recoveryBlocked = !inserted || !token.length || [token isEqualToString:gap.backwardToken];
            if (token.length && ![token isEqualToString:gap.backwardToken]) updated.backwardToken = token;
            [self storeHistoryGap:updated];
        }
    }
}

// Повторно проверяем присоединение после обычной синхронизации или восстановления разрыва, не вставляя
// и не изменяя историю при чтении дескриптора. Новые разрывы limited могут снова отделить ранее
// связанный блок от самого нового непрерывного блока.
- (void)refreshHistoryContextAttachment:(MXRoomHistoryContext *)context
{
    context.attachedToLive = NO;
    NSUInteger first = NSNotFound, last = NSNotFound;
    for (MXEvent *event in context.events) {
        NSUInteger index = [self indexOfHistoryEvent:event.eventId];
        if (index == NSNotFound || (last != NSNotFound && index <= last)) { context.backwardConnected = NO; context.forwardConnected = NO; return; }
        if (first == NSNotFound) first = index;
        last = index;
    }
    if (first == NSNotFound) return;
    for (MXRoomHistoryGap *gap in _historyGaps) {
        NSUInteger boundary = [self indexOfHistoryEvent:gap.newerAnchorEventId];
        if (boundary > first && boundary <= last) { context.backwardConnected = NO; context.forwardConnected = NO; return; }
        if ([gap.newerAnchorEventId isEqualToString:context.events.firstObject.eventId]) context.backwardConnected = NO;
        if ([gap.olderAnchorEventId isEqualToString:context.events.lastObject.eventId]) context.forwardConnected = NO;
    }
    context.attachedToLive = [[self.continuousRecentMessages valueForKey:@"eventId"] containsObject:context.events.lastObject.eventId];
    if (context.attachedToLive) context.forwardConnected = YES;
}

- (NSArray<MXRoomHistoryContext *> *)historyContexts
{
    @synchronized (self) {
        NSArray *snapshots = [[NSArray alloc] initWithArray:_historyContexts copyItems:YES];
        for (MXRoomHistoryContext *context in snapshots) [self refreshHistoryContextAttachment:context];
        return snapshots;
    }
}
- (void)setHistoryContexts:(NSArray<MXRoomHistoryContext *> *)contexts
{
    @synchronized (self) { _historyContexts = [[NSArray alloc] initWithArray:contexts ?: @[] copyItems:YES]; }
}
- (MXRoomHistoryContext *)historyContextForEventId:(NSString *)eventId filter:(NSDictionary *)filter
{
    @synchronized (self) {
        for (MXRoomHistoryContext *context in _historyContexts) {
            if (![context.filter isEqualToDictionary:filter ?: @{}]) continue;
            for (MXEvent *event in context.events) {
                if ([event.eventId isEqualToString:eventId]) {
                    MXRoomHistoryContext *snapshot = [context copy];
                    [self refreshHistoryContextAttachment:snapshot];
                    for (MXRoomHistoryContext *root in snapshot.replayRoots) if ([root.targetEventId isEqualToString:eventId]) { snapshot.selectedRootId = root.componentId; return snapshot; }
                    for (MXRoomHistoryContext *root in snapshot.replayRoots) if ([[root.events valueForKey:@"eventId"] containsObject:eventId]) { snapshot.selectedRootId = root.componentId; return snapshot; }
                    return snapshot;
                }
            }
        }
        return nil;
    }
}

/** Определяем присоединение только по единому доказательству упорядоченного интервала. Дескриптор от
 вызывающего кода не служит доказательством даже с правдоподобным ID разрыва или меткой времени. */
- (void)reconcileHistoryContext:(MXRoomHistoryContext *)context
{
    context.backwardConnected = NO; context.forwardConnected = NO; context.attachedToLive = NO;
    NSArray *ids = [context.events valueForKey:@"eventId"];
    NSUInteger firstMissing = NSNotFound, lastMissing = NSNotFound, previousLiveIndex = NSNotFound;
    NSMutableArray<MXEvent *> *missing = [NSMutableArray array];
    for (NSUInteger i = 0; i < context.events.count; i++) {
        MXEvent *event = context.events[i];
        NSUInteger liveIndex = [self indexOfHistoryEvent:event.eventId];
        if (liveIndex == NSNotFound) {
            if (firstMissing == NSNotFound) firstMissing = i;
            lastMissing = i; [missing addObject:event];
        } else {
            if (previousLiveIndex != NSNotFound && liveIndex <= previousLiveIndex) return;
            previousLiveIndex = liveIndex;
        }
    }
    if (missing.count) {
        // Для чередующихся отсутствующих последовательностей одной границы вставки недостаточно.
        if (lastMissing - firstMissing + 1 != missing.count) return;
        NSMutableArray<MXRoomHistoryGap *> *candidates = [NSMutableArray array];
        for (MXRoomHistoryGap *gap in _historyGaps) {
            NSUInteger older = [ids indexOfObject:gap.olderAnchorEventId];
            NSUInteger newer = [ids indexOfObject:gap.newerAnchorEventId];
            if ((older != NSNotFound && older < firstMissing) || (newer != NSNotFound && newer > lastMissing)) [candidates addObject:gap];
        }
        if (!candidates.count && !_historyGaps.count && firstMissing == 0 && lastMissing + 1 < ids.count) {
            // /context может расширить самый старый блок live без зарегистрированного разрыва.
            // Только непрерывный суффикс, совпадающий с префиксом live, доказывает положение.
            NSUInteger expected = 0;
            for (NSUInteger i = lastMissing + 1; i < ids.count; i++) {
                if ([self indexOfHistoryEvent:ids[i]] != expected++) return;
            }
            [self insertHistoryEvents:missing beforeEventId:ids[lastMissing + 1]];
            context.forwardConnected = YES;
            [self refreshHistoryContextAttachment:context];
            return;
        }
        if (candidates.count != 1) return;
        MXRoomHistoryGap *gap = candidates.firstObject;
        NSUInteger olderIndex = [self indexOfHistoryEvent:gap.olderAnchorEventId];
        NSUInteger newerIndex = [self indexOfHistoryEvent:gap.newerAnchorEventId];
        if (olderIndex == NSNotFound || newerIndex == NSNotFound || olderIndex >= newerIndex) return;
        NSSet *olderIds = [NSSet setWithArray:[[self historyBlockBeforeGap:gap] valueForKey:@"eventId"]];
        NSUInteger newerEnd = messages.count;
        for (MXRoomHistoryGap *other in _historyGaps) {
            NSUInteger index = [self indexOfHistoryEvent:other.newerAnchorEventId];
            if (index > newerIndex && index < newerEnd) newerEnd = index;
        }
        NSSet *newerIds = [NSSet setWithArray:[[messages subarrayWithRange:NSMakeRange(newerIndex, newerEnd - newerIndex)] valueForKey:@"eventId"]];
        for (NSUInteger i = 0; i < firstMissing; i++) if (![olderIds containsObject:ids[i]]) return;
        for (NSUInteger i = lastMissing + 1; i < ids.count; i++) if (![newerIds containsObject:ids[i]]) return;
        BOOL olderProof = firstMissing > 0, newerProof = lastMissing + 1 < ids.count;
        if (!olderProof && !newerProof) return;
        // Позиционное перекрытие не доказывает покрытие исключённых типов/отправителей.
        // Сохраняем полный разрыв и его курсор; после независимого восстановления блок присоединится.
        for (NSString *key in context.filter) {
            if (![key isEqualToString:@"lazy_load_members"] && ![key isEqualToString:@"include_redundant_members"]) return;
        }
        [self insertHistoryEvents:missing beforeEventId:gap.newerAnchorEventId];
        [self removeHistoryGapWithId:gap.gapId];
        if (!olderProof) {
            MXRoomHistoryGap *remaining = [gap copy];
            remaining.newerAnchorEventId = missing.firstObject.eventId;
            remaining.backwardToken = context.backwardToken;
            remaining.recoveryBlocked = context.backwardBlocked || !context.backwardToken.length;
            [self storeHistoryGap:remaining];
        }
        if (!newerProof) {
            MXRoomHistoryGap *remaining = [gap copy];
            remaining.olderAnchorEventId = missing.lastObject.eventId;
            [self storeHistoryGap:remaining];
        }
        context.backwardConnected = olderProof;
        context.forwardConnected = newerProof;
    } else if (context.events.count) {
        NSUInteger first = [self indexOfHistoryEvent:context.events.firstObject.eventId];
        NSUInteger last = [self indexOfHistoryEvent:context.events.lastObject.eventId];
        for (MXRoomHistoryGap *gap in _historyGaps) {
            NSUInteger boundary = [self indexOfHistoryEvent:gap.newerAnchorEventId];
            if (boundary > first && boundary <= last) return;
        }
        context.backwardConnected = YES; context.forwardConnected = YES;
        for (MXRoomHistoryGap *gap in _historyGaps) {
            if ([gap.newerAnchorEventId isEqualToString:context.events.firstObject.eventId]) context.backwardConnected = NO;
            if ([gap.olderAnchorEventId isEqualToString:context.events.lastObject.eventId]) context.forwardConnected = NO;
        }
    }
    if (context.forwardConnected) {
        NSSet *recentIds = [NSSet setWithArray:[self.continuousRecentMessages valueForKey:@"eventId"]];
        context.attachedToLive = [recentIds containsObject:context.events.lastObject.eventId];
    }
    // Сохраняем метаданные целевого состояния и прогресса, пока вызывающий код не сможет восстановить их из
    // live-истории. Для содержимого, уже размещённого в live-истории, используем актуальные версии из неё.
    NSMutableArray *canonical = [NSMutableArray array];
    for (MXEvent *event in context.events) [canonical addObject:messagesByEventIds[event.eventId] ?: event];
    context.events = canonical;
}

// Общее событие задаёт выравнивание только при совпадении всех перекрывающихся позиций.
// Так отклоняется переупорядоченное, чередующееся или неоднозначное покрытие независимо от времени.
static NSArray<MXEvent *> *MXUnionContextEvents(NSArray<MXEvent *> *left, NSArray<MXEvent *> *right)
{
    NSArray *leftIds = [left valueForKey:@"eventId"], *rightIds = [right valueForKey:@"eventId"];
    NSInteger offset = NSNotFound;
    for (NSUInteger i = 0; i < right.count; i++) {
        NSUInteger j = [leftIds indexOfObject:rightIds[i]];
        if (j != NSNotFound) { offset = (NSInteger)j - (NSInteger)i; break; }
    }
    if (offset == NSNotFound) return nil;
    NSInteger start = MIN(0, offset), end = MAX((NSInteger)left.count, offset + (NSInteger)right.count);
    NSMutableArray *result = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSInteger i = start; i < end; i++) {
        MXEvent *a = i >= 0 && i < left.count ? left[i] : nil;
        NSInteger r = i - offset;
        MXEvent *b = r >= 0 && r < right.count ? right[r] : nil;
        if (a && b && ![a.eventId isEqualToString:b.eventId]) return nil;
        MXEvent *event = b.redactedBecause ? b : (a ?: b);
        if (!event || [seen containsObject:event.eventId]) return nil;
        [seen addObject:event.eventId]; [result addObject:event];
    }
    return result;
}

static void MXSetContextBoundaryOwners(MXRoomHistoryContext *context)
{
    for (MXRoomHistoryContext *root in context.replayRoots) {
        if ([root.events.firstObject.eventId isEqualToString:context.events.firstObject.eventId]) {
            context.backwardRootId = root.componentId; context.backwardToken = root.backwardToken;
            context.backwardBlocked = root.backwardBlocked;
        }
        if ([root.events.lastObject.eventId isEqualToString:context.events.lastObject.eventId]) {
            context.forwardRootId = root.componentId; context.forwardToken = root.forwardToken;
            context.forwardBlocked = root.forwardBlocked;
        }
    }
}

- (BOOL)storeHistoryContext:(MXRoomHistoryContext *)context expectedGeneration:(NSString *)generation expectedRoomRevision:(NSUInteger)roomRevision expectedComponentRevision:(NSUInteger)componentRevision
{
    @synchronized (self) {
        if (!generation.length || ![generation isEqualToString:_historyContextGeneration] || roomRevision != _historyRevision
            || !context.componentId.length || !context.targetEventId.length || !context.events.count) return NO;
        NSUInteger index = [_historyContexts indexOfObjectPassingTest:^BOOL(MXRoomHistoryContext *existing, NSUInteger idx, BOOL *stop) {
            return [existing.componentId isEqualToString:context.componentId];
        }];
        if (index == NSNotFound) {
            if (componentRevision != 0) return NO;
        } else {
            MXRoomHistoryContext *existing = _historyContexts[index];
            if (existing.revision != componentRevision
                || ![existing.filter isEqualToDictionary:context.filter]) return NO;
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (MXEvent *event in context.events) {
            if (!event.eventId.length || [seen containsObject:event.eventId]) return NO;
            [seen addObject:event.eventId];
        }
        if (![seen containsObject:context.targetEventId]) return NO;
        MXRoomHistoryContext *saved = [context copy];
        saved.revision = componentRevision + 1;
        saved.backwardConnected = index != NSNotFound && _historyContexts[index].backwardConnected;
        saved.forwardConnected = index != NSNotFound && _historyContexts[index].forwardConnected;
        if (!saved.replayRoots.count) {
            MXRoomHistoryContext *root = [saved copy]; root.replayRoots = @[];
            saved.replayRoots = @[root]; saved.selectedRootId = root.componentId;
        }
        // Пересчитываем каноническое покрытие по независимым корням воспроизведения, никогда
        // не объединяя их снимки состояния или журналы с отметками направления.
        NSArray *coverage = saved.events;
        NSMutableArray *pendingRoots = [saved.replayRoots mutableCopy];
        while (pendingRoots.count) {
            BOOL advanced = NO;
            for (MXRoomHistoryContext *root in [pendingRoots copy]) {
                NSArray *expanded = MXUnionContextEvents(coverage, root.events);
                if (!expanded) continue;
                coverage = expanded; [pendingRoots removeObject:root]; advanced = YES;
            }
            if (!advanced) return NO;
        }
        saved.events = coverage;
        NSMutableArray *contexts = [_historyContexts mutableCopy];
        if (index != NSNotFound) [contexts removeObjectAtIndex:index];
        BOOL merged;
        do {
            merged = NO;
            for (MXRoomHistoryContext *other in [contexts copy]) {
                if (![saved.filter isEqualToDictionary:other.filter]) continue;
                NSArray *unionEvents = MXUnionContextEvents(other.events, saved.events);
                if (!unionEvents) continue;
                // Существующий канонический идентификатор имеет приоритет. Для каждого поглощённого идентификатора
                // выполняемый CAS завершается неудачей; чтение разрешается по цели, а не по старым записям.
                saved.componentId = other.componentId;
                saved.backwardConnected = NO; saved.forwardConnected = NO;
                saved.revision = MAX(saved.revision, other.revision) + 1;
                saved.events = unionEvents;
                NSMutableArray *roots = [other.replayRoots mutableCopy];
                if (!roots.count) { roots = [NSMutableArray arrayWithObject:[other copy]]; }
                [roots addObjectsFromArray:saved.replayRoots]; saved.replayRoots = roots;
                [contexts removeObject:other]; merged = YES; break;
            }
        } while (merged);
        [self trimHistoryContext:saved before:self.historyContextRetentionTimestamp];
        if (!saved.events.count) return NO;
        // Старые архивы ещё не содержат индекс удалений: учитываем сохранённые проекции до замены.
        for (MXRoomHistoryContext *other in _historyContexts) [self rememberHistoryRedactionsInContext:other];
        [self rememberHistoryRedactionsInContext:saved];
        [self applyHistoryRedactionsToContext:saved];
        for (MXRoomHistoryContext *other in contexts) [self applyHistoryRedactionsToContext:other];
        for (MXEvent *event in [messages copy]) {
            if (self.historyRedactions[event.eventId]) [self replaceEvent:[self eventByApplyingHistoryRedaction:event]];
        }
        MXSetContextBoundaryOwners(saved);
        [self reconcileHistoryContext:saved];
        [contexts addObject:saved];
        _historyContexts = contexts;
        _historyRevision++;
        return YES;
    }
}

@end
