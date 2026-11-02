/*
 Copyright 2016 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 Copyright 2018 New Vector Ltd
 Copyright 2019 The Matrix.org Foundation C.I.C

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

#import "MXRoomEventTimeline.h"
#import "MXHTTPOperation_Private.h"

#import "MXSession.h"
#import "MXMemoryStore.h"
#import "MXAggregations_Private.h"
#import "MXEventRelations.h"
#import "MXRoomEventFilter.h"

#import "MXTools.h"
#import "MXSDKOptions.h"

#import "MXEventsEnumeratorOnArray.h"

#import "MXRoomSync.h"
#import "MatrixSDKSwiftHeader.h"

// Используется копиями лент совместно, но не продлевает время жизни сессии или хранилища.
static NSMapTable *MXHistoryModes;
static NSMapTable *MXHistoryRequests;
static void MXPrepareHistoryRegistries(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MXHistoryModes = [NSMapTable weakToStrongObjectsMapTable];
        MXHistoryRequests = [NSMapTable weakToStrongObjectsMapTable];
    });
}

NSString *const MXRoomHistoryGapsDidChangeNotification = @"MXRoomHistoryGapsDidChangeNotification";

NSString *const kMXRoomInviteStateEventIdPrefix = @"invite-";

@interface MXRoomEventTimeline ()
{
    // The list of event listeners (`MXEventListener`) of this timeline.
    NSMutableArray<MXEventListener *> *eventListeners;

    // The historical state of the room when paginating back.
    MXRoomState *backState;

    // The state that was in the `state` property before it changed.
    // It is cached because it costs time to recompute it from the current state.
    // This is particularly noticeable for rooms with a lot of members (ie a lot of
    // room members state events).
    MXRoomState *previousState;

    // The associated room.
    __weak MXRoom *room;

    // The store to store events,
    id<MXStore> store;

    // The events enumerator to paginate messages from the store.
    id<MXEventsEnumerator> storeMessagesEnumerator;
 
    // MXStore does only back pagination. So, the forward pagination token for
    // past timelines is managed locally.
    NSString *forwardsPaginationToken;
    BOOL hasReachedHomeServerForwardsPaginationEnd;
    
    /**
     The current pending request.
     */
    MXHTTPOperation *httpOperation;

    // Copies have their own pagination cursors but share the room store. A
    // history flush must invalidate pending pages on every copy as well.
    NSHashTable<MXHTTPOperation *> *paginationOperations;
    NSMutableSet<NSString *> *backwardDeliveredEventIds;
    NSString *persistedContextId;
    NSString *persistedContextGeneration;
    NSString *persistedContextRootId;
    NSMutableSet<NSString *> *deliveredContextRootIds;
    NSSet<NSString *> *restoreAllowedContextRootIds;
    BOOL restoringHistoryContext;
}

- (BOOL)preservesHistoryGaps;
- (void)notifyHistoryGapChange;
- (void)persistProvenContext:(MXEventContext *)context;
- (BOOL)preservesContextHistory;
- (BOOL)restoreHistoryContextRoot:(NSString *)rootId;
- (BOOL)persistContextPage:(MXPaginationResponse *)response direction:(MXTimelineDirection)direction;
- (void)applyContextPageState:(NSArray<MXEvent *> *)events direction:(MXTimelineDirection)direction;
- (MXRoomBackwardPaginationState)backwardPaginationState;
- (void)setBackwardPaginationState:(MXRoomBackwardPaginationState)state reason:(NSString *)reason;
@end

@implementation MXRoomEventTimeline

@synthesize initialEventId = _initialEventId;
@synthesize timelineId = _timelineId;
@synthesize isLiveTimeline = _isLiveTimeline;
@synthesize state = _state;
@synthesize roomEventFilter = _roomEventFilter;
@synthesize paginationMaxNumberOfTries = _paginationMaxNumberOfTries;

#pragma mark - Initialisation

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _timelineId = [[NSUUID UUID] UUIDString];
        eventListeners = [NSMutableArray array];
        paginationOperations = [NSHashTable weakObjectsHashTable];
        backwardDeliveredEventIds = [NSMutableSet set];
    }
    return self;
}

- (instancetype)initWithRoom:(MXRoom*)theRoom andInitialEventId:(NSString*)initialEventId
{
    // Is it a past or live timeline?
    if (initialEventId)
    {
        // Events for a past timeline are stored in memory
        MXMemoryStore *memoryStore = [[MXMemoryStore alloc] init];
        [memoryStore openWithCredentials:theRoom.mxSession.matrixRestClient.credentials onComplete:nil failure:nil];

        self = [self initWithRoom:theRoom initialEventId:initialEventId andStore:memoryStore];
    }
    else
    {
        // Live: store events in the session store
        self = [self initWithRoom:theRoom initialEventId:initialEventId andStore:theRoom.mxSession.store];
    }
    return self;
}

- (instancetype)initWithRoom:(MXRoom*)theRoom initialEventId:(NSString*)initialEventId andStore:(id<MXStore>)theStore
{
    if (self = [self init])
    {
        _initialEventId = initialEventId;
        room = theRoom;
        store = theStore;
        [self observeRoomHistoryFlush];

        if (!initialEventId)
        {
            _isLiveTimeline = YES;
        }

        _state = [[MXRoomState alloc] initWithRoomId:room.roomId andMatrixSession:room.mxSession andDirection:YES];

        // If the event stream runs with lazy loading, the timeline must do the same
        if (room.mxSession.syncWithLazyLoadOfRoomMembers)
        {
            _roomEventFilter = [MXRoomEventFilter new];
            _roomEventFilter.lazyLoadMembers = YES;
        }
    }
    return self;
}

- (void)initialiseState:(NSArray<MXEvent *> *)stateEvents
{
    [self handleStateEvents:stateEvents direction:MXTimelineDirectionForwards];
}

- (void)destroy
{
    [self cancelPendingPaginations];
    if (httpOperation)
    {
        // Cancel the current server request
        [httpOperation cancel];
        httpOperation = nil;
    }
    
    if (!_isLiveTimeline && !store.isPermanent)
    {
        // Release past timeline events stored in memory
        [store deleteAllData];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeRoomHistoryFlush
{
    // Past timelines with their own memory store are independent of live sync.
    if (!room || store != room.mxSession.store) return;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(roomHistoryDidFlush:)
                                                 name:kMXRoomDidFlushDataNotification
                                               object:room];
}

- (void)roomHistoryDidFlush:(NSNotification *)notification
{
    [self cancelPendingPaginations];
}

- (void)cancelPendingPaginations
{
    for (MXHTTPOperation *operation in paginationOperations.allObjects)
    {
        [operation cancel];
    }
    [paginationOperations removeAllObjects];
}


#pragma mark - Pagination
- (MXRoomBackwardPaginationState)backwardPaginationState
{
    if ([store respondsToSelector:@selector(backwardPaginationStateForRoom:)])
    {
        return [store backwardPaginationStateForRoom:_state.roomId];
    }

    return [store hasReachedHomeServerPaginationEndForRoom:_state.roomId]
        ? MXRoomBackwardPaginationStateExhausted
        : MXRoomBackwardPaginationStateUnknown;
}

- (void)setBackwardPaginationState:(MXRoomBackwardPaginationState)state reason:(NSString *)reason
{
    MXRoomBackwardPaginationState previousState = [self backwardPaginationState];
    if (previousState == state)
    {
        return;
    }

    if ([store respondsToSelector:@selector(storeBackwardPaginationStateForRoom:state:)])
    {
        [store storeBackwardPaginationStateForRoom:_state.roomId state:state];
    }
    else
    {
        [store storeHasReachedHomeServerPaginationEndForRoom:_state.roomId
                                                   andValue:state == MXRoomBackwardPaginationStateExhausted];
    }

    MXLogDebug(@"[MXRoomEventTimeline] backward pagination state changed for %@: %tu -> %tu (%@)",
               _state.roomId, previousState, state, reason);
}

- (BOOL)canPaginate:(MXTimelineDirection)direction
{
    BOOL canPaginate = NO;
    MXRoomHistoryContext *component = self.historyContextComponent;
    for (MXRoomHistoryContext *root in component.replayRoots) {
        if (![root.componentId isEqualToString:persistedContextRootId]) continue;
        if (direction == MXTimelineDirectionBackwards && ![root.events.firstObject.eventId isEqualToString:component.events.firstObject.eventId]) return YES;
        if (direction == MXTimelineDirectionForwards && ![root.events.lastObject.eventId isEqualToString:component.events.lastObject.eventId]) return YES;
    }

    if (direction == MXTimelineDirectionBackwards)
    {
        // canPaginate depends on two things:
        //  - did we end to paginate from the MXStore?
        //  - did we reach the top of the pagination in our requests to the home server?
        if ([self preservesHistoryGaps]) {
            if ([store historyGapsForRoom:_state.roomId].count) return YES;
            for (MXEvent *event in [store continuousRecentMessagesForRoom:_state.roomId]) {
                if (![backwardDeliveredEventIds containsObject:event.eventId]) return YES;
            }
            return [self backwardPaginationState] != MXRoomBackwardPaginationStateExhausted;
        }
        canPaginate = ([self preservesHistoryGaps] && [store historyGapsForRoom:_state.roomId].count > 0)
            || (0 < storeMessagesEnumerator.remaining)
            || [self backwardPaginationState] != MXRoomBackwardPaginationStateExhausted;
    }
    else
    {
        if (_isLiveTimeline)
        {
            // Matrix is not yet able to guess the future
            canPaginate = NO;
        }
        else
        {
            canPaginate = !hasReachedHomeServerForwardsPaginationEnd;
        }
    }

    return canPaginate;
}

- (void)resetPagination
{
    [self cancelPendingPaginations];
    [backwardDeliveredEventIds removeAllObjects];
    // Reset the back state to the current room state
    backState = [[MXRoomState alloc] initBackStateWith:_state];

    // Reset store pagination
    storeMessagesEnumerator = [store messagesEnumeratorForRoom:_state.roomId];
}

- (MXHTTPOperation *)resetPaginationAroundInitialEventWithLimit:(NSUInteger)limit success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    NSParameterAssert(success);
    NSAssert(_initialEventId, @"[MXRoomEventTimeline] resetPaginationAroundInitialEventWithLimit cannot be called on live timeline");
    
    if (!MXSDKOptions.sharedInstance.preserveHistoryOnSlidingSyncGaps)
    {
        // Flag off: the stock context load (no wrapper operation, no history context bookkeeping).
        // Reset the store
        if (!store.isPermanent)
        {
            [store deleteAllData];
        }

        forwardsPaginationToken = nil;
        hasReachedHomeServerForwardsPaginationEnd = NO;

        // Get the context around the initial event
        MXWeakify(self);
        return [room.mxSession.matrixRestClient contextOfEvent:_initialEventId inRoom:room.roomId limit:limit filter:_roomEventFilter success:^(MXEventContext *eventContext) {
            MXStrongifyAndReturnIfNil(self);

            // And fill the timelime with received data
            [self initialiseState:eventContext.state];

            // Reset pagination state from here
            [self resetPagination];

            NSMutableArray *events = [NSMutableArray array];
            [events addObject:eventContext.event];
            [events addObjectsFromArray:eventContext.eventsBefore];
            [events addObjectsFromArray:eventContext.eventsAfter];

            [self decryptEvents:events onComplete:^{
                [self addEvent:eventContext.event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];

                for (MXEvent *event in eventContext.eventsBefore)
                {
                    [self addEvent:event direction:MXTimelineDirectionBackwards fromStore:NO isRoomInitialSync:NO];
                }

                for (MXEvent *event in eventContext.eventsAfter)
                {
                    [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];
                }

                [self->store storePaginationTokenOfRoom:self->room.roomId andToken:eventContext.start];
                self->forwardsPaginationToken = eventContext.end;

                success();
            }];

        } failure:failure];
    }

    [self cancelPendingPaginations];
    if ([self restoreHistoryContextFromStore]) {
        MXHTTPOperation *restored = [MXHTTPOperation new];
        [paginationOperations addObject:restored];
        MXWeakify(self);
        dispatch_async(dispatch_get_main_queue(), [restored processingBlock:^{
            MXStrongifyAndReturnIfNil(self);
            [self->paginationOperations removeObject:restored];
            if (!restored.isCancelled) success();
        }]);
        return restored;
    }
    persistedContextId = nil; persistedContextGeneration = nil;
    __weak MXSession *contextSession = room.mxSession;
    id<MXStore> contextStore = contextSession.store;
    [contextStore historyContextsForRoom:room.roomId];
    NSString *contextGeneration = [contextStore historyContextGenerationForRoom:room.roomId];
    NSString *contextTarget = [_initialEventId copy];
    NSDictionary *contextFilter = [_roomEventFilter.dictionary copy] ?: @{};
    MXRoomHistoryContext *contextComponent = [contextStore historyContextForEventId:contextTarget inRoom:room.roomId filter:contextFilter];
    BOOL durableContext = [self preservesContextHistory] && contextGeneration.length;

    // A live append changes the room revision, not this request's validity. The
    // store still checks the current room/component revisions at commit time.
    BOOL (^contextIsCurrent)(MXRoomEventTimeline *) = ^BOOL(MXRoomEventTimeline *timeline) {
        if (!contextSession || timeline->room.mxSession != contextSession || contextSession.store != contextStore
            || ![contextSession hasRoomWithRoomId:timeline->room.roomId]
            || ![contextGeneration isEqualToString:[contextStore historyContextGenerationForRoom:timeline->room.roomId]]
            || ![contextTarget isEqualToString:timeline->_initialEventId]
            || ![contextFilter isEqualToDictionary:timeline->_roomEventFilter.dictionary ?: @{}]) return NO;
        if (!contextComponent) return YES;
        MXRoomHistoryContext *current = [contextStore historyContextForEventId:contextTarget inRoom:timeline->room.roomId filter:contextFilter];
        return [current.componentId isEqualToString:contextComponent.componentId] && current.revision == contextComponent.revision;
    };

    // Reset the store
    if (!store.isPermanent)
    {
        [store deleteAllData];
    }

    forwardsPaginationToken = nil;
    hasReachedHomeServerForwardsPaginationEnd = NO;

    // Получить контекст вокруг начального события.
    MXHTTPOperation *contextOperation = [MXHTTPOperation new];
    [paginationOperations addObject:contextOperation];
    MXWeakify(self);
    MXHTTPOperation *request = [room.mxSession.matrixRestClient contextOfEvent:_initialEventId inRoom:room.roomId limit:limit filter:_roomEventFilter success:^(MXEventContext *eventContext) {
        MXStrongifyAndReturnIfNil(self);

        if (contextOperation.isCancelled) return;
        if (durableContext && !contextIsCurrent(self)) {
            if (failure) failure([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
            return;
        }
        // Классический путь сохраняет порядок; durable-контекст сначала получает версии из live-хранилища.
        if (!durableContext) {
            [self initialiseState:eventContext.state];
            [self->paginationOperations removeObject:contextOperation];
            [self resetPagination];
            [self->paginationOperations addObject:contextOperation];
        }

        NSMutableArray *events = [NSMutableArray array];
        [events addObject:eventContext.event];
        [events addObjectsFromArray:eventContext.eventsBefore];
        [events addObjectsFromArray:eventContext.eventsAfter];

        [self decryptEvents:events onComplete:[contextOperation processingBlock:^{
            if (contextOperation.isCancelled || !self->room.mxSession) return;
            if (durableContext && !contextIsCurrent(self)) {
                if (failure) failure([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
                return;
            }
            [self persistProvenContext:eventContext];
            if (durableContext) {
                MXRoomHistoryContext *saved = self.historyContextComponent;
                MXRoomHistoryContext *root;
                for (MXRoomHistoryContext *candidate in saved.replayRoots) {
                    if ([candidate.componentId isEqualToString:self->persistedContextRootId]) { root = candidate; break; }
                }
                NSMutableDictionary<NSString *, MXEvent *> *retained = [NSMutableDictionary dictionary];
                for (MXEvent *event in saved.events) retained[event.eventId] = event;
                MXEvent *target = retained[eventContext.event.eventId];
                if (!root || !target) { if (failure) failure([NSError errorWithDomain:@"MXRoomHistoryContext" code:3 userInfo:nil]); return; }
                // Совпадения ID недостаточно: в приватный timeline передаём очищенные объекты и состояние корня.
                NSMutableArray *before = [NSMutableArray array], *after = [NSMutableArray array];
                for (MXEvent *event in eventContext.eventsBefore) if (retained[event.eventId]) [before addObject:retained[event.eventId]];
                for (MXEvent *event in eventContext.eventsAfter) if (retained[event.eventId]) [after addObject:retained[event.eventId]];
                eventContext.event = target;
                eventContext.eventsBefore = before;
                eventContext.eventsAfter = after;
                eventContext.state = root.initialState;
                [self initialiseState:eventContext.state];
                [self->paginationOperations removeObject:contextOperation];
                [self resetPagination];
                [self->paginationOperations addObject:contextOperation];
            }
            self->_historyContext = eventContext;
            [self addEvent:eventContext.event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];
            
            for (MXEvent *event in eventContext.eventsBefore)
            {
                [self addEvent:event direction:MXTimelineDirectionBackwards fromStore:NO isRoomInitialSync:NO];
            }
            
            for (MXEvent *event in eventContext.eventsAfter)
            {
                [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];
            }
            
            [self->store storePaginationTokenOfRoom:self->room.roomId andToken:eventContext.start];
            self->forwardsPaginationToken = eventContext.end;
            if (self->persistedContextId) {
                [self setBackwardPaginationState:eventContext.start.length ? MXRoomBackwardPaginationStateAvailable : MXRoomBackwardPaginationStateExhausted reason:@"context_initial_availability"];
                self->hasReachedHomeServerForwardsPaginationEnd = !eventContext.end.length;
            }
            success();
        }]];

    } failure:failure];
    [contextOperation mutateTo:request];
    return contextOperation;
}


- (void)paginateFromStore:(NSUInteger)numItems direction:(MXTimelineDirection)direction onComplete:(void (^)(NSArray<MXEvent *>*))onComplete
{
    if (direction == MXTimelineDirectionBackwards)
    {
        // For back pagination, try to get messages from the store first
        NSArray<MXEvent *> *eventsFromStore = [storeMessagesEnumerator nextEventsBatch:numItems threadId:nil];
        
        // messagesFromStore are in chronological order
        // Handle events from the most recent
        //?
        
        [self decryptEvents:eventsFromStore onComplete:^{
            
            MXLogDebug(@"[MXRoomEventTimeline] paginateFromStore %tu messages in %@ (%tu are retrieved from the store)", numItems, self.state.roomId, eventsFromStore.count);

            onComplete(eventsFromStore);
        }];
    }
    else
    {
        onComplete(nil);
    }
}

// Переход через уже покрытый компонент выполняется локально. Воспроизводим целевой корень
// в прокси вне live-ленты, чтобы каждая строка получила фактическое состояние этого корня, а не предполагаемое
// наложение состояния исходного корня. Слушателям передаются только ранее не встречавшиеся ID.
- (NSUInteger)crossHistoryContextLocally:(MXTimelineDirection)direction
{
    MXRoomHistoryContext *canonical = self.historyContextComponent;
    MXRoomHistoryContext *current;
    for (MXRoomHistoryContext *root in canonical.replayRoots) if ([root.componentId isEqualToString:persistedContextRootId]) current = root;
    if (!current) return 0;
    NSArray *coverage = [canonical.events valueForKey:@"eventId"];
    NSMutableSet *delivered = [NSMutableSet setWithArray:[[[store messagesEnumeratorForRoom:room.roomId] nextEventsBatch:NSUIntegerMax threadId:nil] valueForKey:@"eventId"] ?: @[]];
    NSUInteger total = 0;
    NSString *ownerId = direction == MXTimelineDirectionBackwards ? canonical.backwardRootId : canonical.forwardRootId;
    NSMutableSet *visited = [NSMutableSet setWithObject:current.componentId];
    while (YES) {
        NSUInteger first = [coverage indexOfObject:current.events.firstObject.eventId];
        NSUInteger last = [coverage indexOfObject:current.events.lastObject.eventId];
        MXRoomHistoryContext *next;
        NSUInteger best = direction == MXTimelineDirectionBackwards ? first : last;
        for (MXRoomHistoryContext *root in canonical.replayRoots) {
            if ([visited containsObject:root.componentId] || (restoreAllowedContextRootIds && ![restoreAllowedContextRootIds containsObject:root.componentId])) continue;
            NSUInteger start = [coverage indexOfObject:root.events.firstObject.eventId];
            NSUInteger end = [coverage indexOfObject:root.events.lastObject.eventId];
            if (start == NSNotFound || end == NSNotFound || start > last || end < first) continue;
            if ((direction == MXTimelineDirectionBackwards && start < best) || (direction == MXTimelineDirectionForwards && end > best)) {
                next = root; best = direction == MXTimelineDirectionBackwards ? start : end;
            }
        }
        if (!next && ![current.componentId isEqualToString:ownerId]) {
            for (MXRoomHistoryContext *root in canonical.replayRoots) {
                if ([root.componentId isEqualToString:ownerId] && ![visited containsObject:root.componentId]
                    && (!restoreAllowedContextRootIds || [restoreAllowedContextRootIds containsObject:root.componentId])
                    && [[root.events valueForKey:@"eventId"] containsObject:direction == MXTimelineDirectionBackwards ? current.events.firstObject.eventId : current.events.lastObject.eventId]) { next = root; break; }
            }
        }
        if (!next) break;
        MXRoomEventTimeline *proxy = [[MXRoomEventTimeline alloc] initWithRoom:room andInitialEventId:next.targetEventId];
        proxy.roomEventFilter = [[MXRoomEventFilter alloc] initWithDictionary:canonical.filter];
        NSMutableDictionary<NSString *, MXRoomState *> *states = [NSMutableDictionary dictionary];
        MXEventListener *capture = [proxy listenToEvents:^(MXEvent *event, MXTimelineDirection eventDirection, MXRoomState *state) {
            if (event.eventId && state) states[event.eventId] = [state copy];
        }];
        BOOL restored = [proxy restoreHistoryContextRoot:next.componentId];
        [proxy removeListener:capture];
        if (!restored) break;
        // Конечные точки прокси в обоих направлениях теперь определяют достоверное состояние
        // этого корня. Сохраняем всё уже переданное покрытие во временном хранилище.
        NSArray *localEvents = [[store messagesEnumeratorForRoom:room.roomId] nextEventsBatch:NSUIntegerMax threadId:nil];
        NSArray *preserved = direction == MXTimelineDirectionForwards ? localEvents.reverseObjectEnumerator.allObjects : localEvents;
        for (MXEvent *event in preserved) {
            if (![proxy->store eventExistsWithEventId:event.eventId inRoom:room.roomId])
                [proxy->store storeEventForRoom:room.roomId event:event direction:direction == MXTimelineDirectionBackwards ? MXTimelineDirectionForwards : MXTimelineDirectionBackwards];
        }
        store = proxy->store; _state = proxy->_state; backState = proxy->backState;
        forwardsPaginationToken = proxy->forwardsPaginationToken;
        hasReachedHomeServerForwardsPaginationEnd = proxy->hasReachedHomeServerForwardsPaginationEnd;
        persistedContextRootId = next.componentId; storeMessagesEnumerator = nil;
        if (!deliveredContextRootIds) deliveredContextRootIds = [NSMutableSet set];
        [deliveredContextRootIds addObject:next.componentId];
        NSArray *events = direction == MXTimelineDirectionBackwards ? next.events.reverseObjectEnumerator.allObjects : next.events;
        for (MXEvent *event in events) {
            if ([delivered containsObject:event.eventId]) continue;
            [delivered addObject:event.eventId]; total++;
            for (MXEventListener *listener in [eventListeners copy]) {
                if ([eventListeners containsObject:listener]) [listener notify:event direction:direction andCustomObject:states[event.eventId]];
            }
        }
        [visited addObject:next.componentId]; current = next;
    }
    return total;
}

- (MXHTTPOperation *)paginate:(NSUInteger)numItems direction:(MXTimelineDirection)direction onlyFromStore:(BOOL)onlyFromStore complete:(void (^)(void))complete failure:(void (^)(NSError *))failure
{
    MXHTTPOperation *operation = [MXHTTPOperation new];
    [paginationOperations addObject:operation];

    // URLSession cancellation alone cannot stop a response which is already
    // being decrypted. Carry the outer operation across every async boundary.
    __block BOOL finished = NO;
    __block BOOL ordinaryHistoryRequest = NO;
    __weak MXSession *requestedContextSession = room.mxSession;
    id<MXStore> requestedContextStore = requestedContextSession.store;
    MXRoomHistoryContext *requestedComponent = self.historyContextComponent;
    NSString *requestedContextGeneration = persistedContextGeneration;
    __block NSUInteger contextRoomRevision = requestedComponent ? [requestedContextStore historyRevisionForRoom:room.roomId] : 0;
    __block NSUInteger contextComponentRevision = requestedComponent.revision;
    void (^finish)(NSError *) = ^(NSError *error) {
        if (finished) return;
        finished = YES;
        if (error)
        {
            if (failure) failure(error);
        }
        else
        {
            complete();
        }
    };
    BOOL (^shouldApply)(void) = ^BOOL {
        if (finished) return NO;
        if (requestedComponent && (!requestedContextSession || self->room.mxSession != requestedContextSession
            || requestedContextSession.store != requestedContextStore || ![requestedContextSession hasRoomWithRoomId:self->room.roomId]
            || ![requestedContextGeneration isEqualToString:[requestedContextStore historyContextGenerationForRoom:self->room.roomId]]
            || contextRoomRevision != [requestedContextStore historyRevisionForRoom:self->room.roomId]
            || contextComponentRevision != self.historyContextComponent.revision)) {
            finish([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); return NO;
        }
        if (operation.isCancelled || (ordinaryHistoryRequest && [self preservesHistoryGaps] && [self->store historyGapsForRoom:self.state.roomId].count))
        {
            finish([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
            return NO;
        }
        return YES;
    };

    NSAssert(nil != backState, @"[MXRoomEventTimeline] paginate: resetPagination or resetPaginationAroundInitialEventWithLimit must be called before starting the back pagination");

    NSAssert(!(_isLiveTimeline && direction == MXTimelineDirectionForwards), @"Cannot paginate forwards on a live timeline");
    if (requestedComponent && [self crossHistoryContextLocally:direction] > 0) {
        dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{ if (shouldApply()) finish(nil); }]);
        return operation;
    }
    
    MXWeakify(self);
    void (^consumeStored)(void (^)(NSArray<MXEvent *> *)) = ^(void (^callback)(NSArray<MXEvent *> *)) {
        if (!onlyFromStore && direction == MXTimelineDirectionBackwards && [self preservesHistoryGaps]) {
            NSMutableArray *events = [NSMutableArray array];
            for (MXEvent *event in [self->store continuousRecentMessagesForRoom:self.state.roomId].reverseObjectEnumerator) {
                if (![self->backwardDeliveredEventIds containsObject:event.eventId]) [events addObject:event];
                if (events.count >= numItems) break;
            }
            [self decryptEvents:events onComplete:^{ callback(events.reverseObjectEnumerator.allObjects); }];
        } else {
            [self paginateFromStore:numItems direction:direction onComplete:callback];
        }
    };
    MXHTTPProcessingLease *localLease = [operation beginProcessing];
    consumeStored(^(NSArray<MXEvent *> *eventsFromStore) {
        @try
        {
            MXStrongifyAndReturnIfNil(self);
            if (!shouldApply()) return;

            NSInteger remainingNumItems = numItems;
            NSUInteger eventsFromStoreCount = eventsFromStore.count;

            if (direction == MXTimelineDirectionBackwards)
            {
                // messagesFromStore are in chronological order
                // Handle events from the most recent
                for (MXEvent *event in eventsFromStore.reverseObjectEnumerator)
                {
                    if (!shouldApply()) return;
                    [self addEvent:event direction:MXTimelineDirectionBackwards fromStore:YES isRoomInitialSync:NO];
                }

                remainingNumItems -= eventsFromStoreCount;

                if (onlyFromStore)
                {
                    dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{
                        MXLogDebug(@"[MXRoomEventTimeline] paginate : is done from the store");
                        if (shouldApply()) finish(nil);
                    }]);

                    return;
                }

                MXRoomHistoryGap *gap = [self preservesHistoryGaps] ? [self->store historyGapsForRoom:self.state.roomId].lastObject : nil;
                if (remainingNumItems > 0 && gap) {
                    if (gap.recoveryBlocked) {
                        finish([NSError errorWithDomain:@"MXRoomHistoryGap" code:2 userInfo:nil]);
                        return;
                    }
                    MXHTTPOperation *gapOperation = [self paginateHistoryGap:gap.gapId success:^(NSArray<MXEvent *> *events) {
                        if (shouldApply()) finish(nil);
                    } failure:^(NSError *error) { finish(error); }];
                    [operation mutateTo:gapOperation];
                    return;
                }
                if (remainingNumItems <= 0 || [self backwardPaginationState] == MXRoomBackwardPaginationStateExhausted)
                {
                    dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{
                        // Nothing more to do
                        MXLogDebug(@"[MXRoomEventTimeline] paginate: is done");
                        if (shouldApply()) finish(nil);
                    }]);

                    return;
                }
            }

            // Do not try to paginate forward if end has been reached
            if (direction == MXTimelineDirectionForwards && YES == self->hasReachedHomeServerForwardsPaginationEnd)
            {
                dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{
                    // Nothing more to do
                    MXLogDebug(@"[MXRoomEventTimeline] paginate: is done");
                    if (shouldApply()) finish(nil);
                }]);

                return;
            }

            // Not enough messages: make a pagination request to the home server
            // from last known token
            if (!shouldApply()) return;
            NSString *paginationToken;

            if (direction == MXTimelineDirectionBackwards)
            {
                paginationToken = [self->store paginationTokenOfRoom:self.state.roomId];
            }
            else
            {
                paginationToken = self->forwardsPaginationToken;
            }

            MXLogDebug(@"[MXRoomEventTimeline] paginate : request %tu messages from the server", remainingNumItems);

            MXWeakify(self);
            ordinaryHistoryRequest = direction == MXTimelineDirectionBackwards;
            MXHTTPOperation *operation2 = [self->room.mxSession.matrixRestClient messagesForRoom:self.state.roomId from:paginationToken direction:direction limit:remainingNumItems filter:self.roomEventFilter success:^(MXPaginationResponse *paginatedResponse) {
                MXStrongifyAndReturnIfNil(self);
                if (!shouldApply()) return;

                MXLogDebug(@"[MXRoomEventTimeline] paginate : got %tu messages from the server", paginatedResponse.chunk.count);

                // Check if the room has not been left while waiting for the response
                if ([self->room.mxSession hasRoomWithRoomId:self->room.roomId]
                    || [self->room.mxSession isPeekingInRoomWithRoomId:self->room.roomId])
                {
                    [self handlePaginationResponse:paginatedResponse direction:direction operation:operation shouldApply:shouldApply didPersistContext:^{
                        if (requestedComponent) {
                            contextRoomRevision = [requestedContextStore historyRevisionForRoom:self->room.roomId];
                            contextComponentRevision = self.historyContextComponent.revision;
                        }
                    } failure:finish onComplete:^{
                        MXLogDebug(@"[MXRoomEventTimeline] paginate: is done");

                        // Inform the method caller
                        if (shouldApply()) finish(nil);
                    }];
                }
                else
                {
                    MXLogDebug(@"[MXRoomEventTimeline] paginate: is done");
                    // Inform the method caller
                    if (shouldApply()) finish(nil);
                }

            } failure:^(NSError *error) {
                MXStrongifyAndReturnIfNil(self);
                if (!shouldApply()) return;

                MXLogDebug(@"[MXRoomEventTimeline] paginate failed");
                finish(error);
            }];

            if (eventsFromStoreCount)
            {
                // Disable retry to let the caller handle messages from store without delay.
                // The caller will trigger a new pagination if need.
                operation2.maxNumberOfTries = 1;
            }
            if (self.paginationMaxNumberOfTries)
            {
                operation2.maxNumberOfTries = MIN(operation2.maxNumberOfTries, self.paginationMaxNumberOfTries.unsignedIntegerValue);
                operation2.maxTotalAttempts = self.paginationMaxNumberOfTries;
            }

            [operation mutateTo:operation2];
        }
        @finally { [localLease finish]; }
    });

    return operation;
}

- (NSUInteger)remainingMessagesForBackPaginationInStore
{
    return storeMessagesEnumerator.remaining;
}


#pragma mark - Homeserver responses handling
- (void)handleJoinedRoomSync:(MXRoomSync *)roomSync onComplete:(void (^)(void))onComplete
{
    // Is it an initial sync for this room?
    BOOL isRoomInitialSync = (room.summary.membership == MXMembershipUnknown || room.summary.membership == MXMembershipInvite);
    BOOL isSlidingSync = roomSync.slidingSyncInitial != nil;
    MXPrepareHistoryRegistries();
    NSMutableDictionary *modes = [MXHistoryModes objectForKey:store];
    if (!modes) { modes = [NSMutableDictionary dictionary]; [MXHistoryModes setObject:modes forKey:store]; }
    modes[room.roomId] = @(isSlidingSync);
    BOOL isSlidingSyncInitial = roomSync.slidingSyncInitial.boolValue;
    BOOL isPaginationInitialSync = isSlidingSync ? isSlidingSyncInitial : isRoomInitialSync;

    // Check whether the room was pending on an invitation.
    if (room.summary.membership == MXMembershipInvite)
    {
        // Reset the storage of this room. An initial sync of the room will be done with the provided 'roomSync'.
        MXLogDebug(@"[MXRoomEventTimeline] handleJoinedRoomSync: clean invited room from the store (%@).", self.state.roomId);
        [store deleteRoom:self.state.roomId];
    }

    // In case of lazy-loading, we may not have the membership event for our user.
    // If handleJoinedRoomSync is called, the user is a joined member.
    if (room.mxSession.syncWithLazyLoadOfRoomMembers && room.summary.membership != MXMembershipJoin)
    {
        room.summary.membership = MXMembershipJoin;
    }
    
    // Report the room id in the event as it is skipped in /sync response
    [self fixRoomIdInEvents:roomSync.state.events];
    [self fixRoomIdInEvents:roomSync.timeline.events];

    // Build/Update first the room state corresponding to the 'start' of the timeline.
    // Note: We consider it is not required to clone the existing room state here, because no notification is posted for these events.
    [self handleStateEvents:roomSync.state.events direction:MXTimelineDirectionForwards];
    
    // On an initial sync, this is useless to decrypt all events. It takes CPU time which delays the processing completion.
    // But we need to decrypt enough events to compute notifications correctly.
    // So decrypt only events that have not been read yet.
    uint64_t timestamp = 0;
    if (isRoomInitialSync && !_initialEventId)
    {
        NSDictionary<NSString *, MXReceiptData *> *lastUserReadReceiptList = [store getReceiptsInRoom:_state.roomId forUserId:room.mxSession.myUserId];
        for (MXReceiptData *lastUserReadReceipt in [lastUserReadReceiptList allValues])
        {
            if (lastUserReadReceipt)
            {
                timestamp = lastUserReadReceipt.ts;
                
                //  find the last encrypted event in the events
                __block MXEvent *lastEncryptedEvent = nil;
                [roomSync.timeline.events enumerateObjectsWithOptions:NSEnumerationReverse
                                                           usingBlock:^(MXEvent * _Nonnull event, NSUInteger idx, BOOL * _Nonnull stop) {
                    if ([event.type isEqualToString:kMXEventTypeStringRoomEncrypted])
                    {
                        *stop = YES;
                        lastEncryptedEvent = event;
                    }
                }];
                
                if (timestamp > lastEncryptedEvent.originServerTs)
                {
                    //  we should at least decrypt the last encrypted event for the rooms whose read markers passed the last encrypted event
                    timestamp = lastEncryptedEvent.originServerTs;
                }
            }
        }
    }
    
    MXWeakify(self);
    [self decryptEvents:roomSync.timeline.events ifNewerThanTimestamp:timestamp onComplete:^{
        MXStrongifyAndReturnIfNil(self);
        
        BOOL preserve = isSlidingSync && [self preservesHistoryGaps];
        MXEvent *olderAnchor = preserve ? [self->store messagesEnumeratorForRoom:self.state.roomId].nextEvent : nil;
        BOOL connects = NO;
        if (preserve && olderAnchor) {
            // Только перекрытие в самом новом сохранённом блоке может связать этот ответ с историей.
            NSSet *newestIds = [NSSet setWithArray:[[self->store continuousRecentMessagesForRoom:self.state.roomId] valueForKey:@"eventId"]];
            for (MXEvent *event in roomSync.timeline.events) if ([newestIds containsObject:event.eventId]) { connects = YES; break; }
        }
        MXRoomHistoryGap *createdGap = nil;
        if (preserve && olderAnchor && roomSync.timeline.hasLimited && roomSync.timeline.limited
            && roomSync.timeline.events.count && !connects) {
            MXEvent *newerAnchor = roomSync.timeline.events.firstObject;
            // Повторно воспроизводимые несвязанные снимки не должны добавлять дублирующиеся границы.
            if (![self->store eventExistsWithEventId:newerAnchor.eventId inRoom:self.state.roomId]) {
                createdGap = [MXRoomHistoryGap new];
                createdGap.olderAnchorEventId = olderAnchor.eventId;
                createdGap.newerAnchorEventId = newerAnchor.eventId;
                createdGap.backwardToken = roomSync.timeline.prevBatch;
                createdGap.recoveryBlocked = !createdGap.backwardToken.length;
            }
        }
        // Handle now timeline.events, the room state is updated during this step too (Note: timeline events are in chronological order)
        if (isRoomInitialSync)
        {
            for (MXEvent *event in roomSync.timeline.events)
            {
                // Add the event to the end of the timeline
                [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:isRoomInitialSync];
            }
            
        }
        else
        {
            // Check whether some events have not been received from server.
            if (!preserve && !isPaginationInitialSync && roomSync.timeline.limited)
            {
                // Flush the existing messages for this room by keeping state events.
                [self->store deleteAllMessagesInRoom:self.state.roomId];
            }
            
            for (MXEvent *event in roomSync.timeline.events)
            {
                // Add the event to the end of the timeline
                [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:isRoomInitialSync];
            }
        }
        
        if (createdGap) [self->store storeHistoryGap:createdGap forRoom:self.state.roomId];
        NSString *previousBatch = roomSync.timeline.prevBatch;
        BOOL hasExplicitGap = roomSync.timeline.hasLimited && roomSync.timeline.limited;

        if (preserve && olderAnchor) {
            // Самый старый сохранённый блок определяет токен комнаты и состояние конца истории, в том числе
            // для начальных снимков при переподключении. У новых разрывов независимые курсоры.
        }
        else if (isSlidingSync)
        {
            if (hasExplicitGap)
            {
                if (previousBatch)
                {
                    [self->store storePaginationTokenOfRoom:self.state.roomId andToken:previousBatch];
                }
                [self setBackwardPaginationState:(previousBatch
                                                  ? MXRoomBackwardPaginationStateAvailable
                                                  : MXRoomBackwardPaginationStateUnknown)
                                           reason:@"sync_gap"];
            }
            else if (isPaginationInitialSync)
            {
                MXRoomBackwardPaginationState previousState = [self backwardPaginationState];
                if (previousBatch && ![self->store paginationTokenOfRoom:self.state.roomId])
                {
                    [self->store storePaginationTokenOfRoom:self.state.roomId andToken:previousBatch];
                }

                // A Sliding Sync initial payload is a connection snapshot, not
                // proof that older history no longer exists. Preserve an end
                // established by /messages; otherwise keep one server probe.
                if (previousState != MXRoomBackwardPaginationStateExhausted)
                {
                    [self setBackwardPaginationState:(previousBatch
                                                      ? MXRoomBackwardPaginationStateAvailable
                                                      : MXRoomBackwardPaginationStateUnknown)
                                               reason:@"sliding_initial"];
                }
            }
            else if ([self backwardPaginationState] == MXRoomBackwardPaginationStateUnknown
                     && ![self->store paginationTokenOfRoom:self.state.roomId]
                     && previousBatch)
            {
                [self->store storePaginationTokenOfRoom:self.state.roomId andToken:previousBatch];
                [self setBackwardPaginationState:MXRoomBackwardPaginationStateAvailable
                                           reason:@"sync_gap"];
            }
        }
        else if (isPaginationInitialSync && roomSync.timeline.hasLimited)
        {
            if (roomSync.timeline.limited)
            {
                if (previousBatch)
                {
                    [self->store storePaginationTokenOfRoom:self.state.roomId andToken:previousBatch];
                }
                [self setBackwardPaginationState:(previousBatch
                                                  ? MXRoomBackwardPaginationStateAvailable
                                                  : MXRoomBackwardPaginationStateUnknown)
                                           reason:@"sync_gap"];
            }
            else
            {
                [self setBackwardPaginationState:MXRoomBackwardPaginationStateExhausted
                                           reason:@"legacy_initial_complete"];
            }
        }
        else if (hasExplicitGap)
        {
            if (previousBatch)
            {
                [self->store storePaginationTokenOfRoom:self.state.roomId andToken:previousBatch];
            }
            [self setBackwardPaginationState:MXRoomBackwardPaginationStateAvailable
                                       reason:@"sync_gap"];
        }
        
        // Finalize initial sync
        if (isRoomInitialSync)
        {
            // Notify that room has been sync'ed
            // Delay it so that MXRoom.summary is computed before sending it
            dispatch_async(dispatch_get_main_queue(), ^{
                
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXRoomInitialSyncNotification
                                                                    object:self->room
                                                                  userInfo:nil];
            });
        }
        else if (!isPaginationInitialSync && roomSync.timeline.limited)
        {
            // The room has been resync with a limited timeline - Post notification
            [[NSNotificationCenter defaultCenter] postNotificationName:kMXRoomDidFlushDataNotification
                                                                object:self->room
                                                              userInfo:createdGap ? @{@"historyGap": [createdGap copy]} : nil];
        }
        if (createdGap) [self notifyHistoryGapChange];
        
        onComplete();
    }];
}

- (void)handleInvitedRoomSync:(MXInvitedRoomSync *)invitedRoomSync onComplete:(void (^)(void))onComplete
{
    // In case of lazy-loading, we may not have the membership event for our user.
    // If handleInvitedRoomSync is called, the user is an invited member.
    if (room.mxSession.syncWithLazyLoadOfRoomMembers && room.summary.membership != MXMembershipInvite)
    {
        room.summary.membership = MXMembershipInvite;
    }
    
    NSArray<MXEvent*> *events = invitedRoomSync.inviteState.events;
    [self fixRoomIdInEvents:events];
    [self decryptEvents:events onComplete:^{
        // Handle the state events forwardly (the room state will be updated, and the listeners (if any) will be notified).
        for (MXEvent *event in events)
        {
            // Add a fake event id if none in order to be able to store the event
            if (!event.eventId)
            {
                event.eventId = [NSString stringWithFormat:@"%@%@", kMXRoomInviteStateEventIdPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
            }
            
            [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:YES];
        }
        
        onComplete();
    }];
}

- (void)handleLazyLoadedStateEvents:(NSArray<MXEvent *> *)stateEvents
{
    [self handleStateEvents:stateEvents direction:MXTimelineDirectionForwards];
}

- (void)handlePaginationResponse:(MXPaginationResponse*)paginatedResponse direction:(MXTimelineDirection)direction operation:(MXHTTPOperation *)operation shouldApply:(BOOL (^)(void))shouldApply didPersistContext:(void (^)(void))didPersistContext failure:(void (^)(NSError *))failure onComplete:(void (^)(void))onComplete
{
    if (!shouldApply()) return;
    MXWeakify(self);
    [self decryptEvents:paginatedResponse.chunk onComplete:[operation processingBlock:^{
        MXStrongifyAndReturnIfNil(self);
        if (!shouldApply()) return;

        if (![self persistContextPage:paginatedResponse direction:direction]) {
            failure([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); return;
        }
        didPersistContext();

        // Process additional state events (this happens in case of lazy loading)
        if (paginatedResponse.state.count)
        {
            if (direction == MXTimelineDirectionBackwards)
            {
                // Enrich the timeline root state with the additional state events observed during back pagination.
                // Check that it is a member state event (it should always be the case) and
                // that this memeber is not already known in our live room state
                NSMutableArray<MXEvent *> *selectedStateEvents = [NSMutableArray array];
                for (MXEvent *stateEvent in paginatedResponse.state)
                {
                    if ((stateEvent.eventType == MXEventTypeRoomMember)
                        && ![self->_state.members memberWithUserId: stateEvent.stateKey]) {
                        [selectedStateEvents addObject:stateEvent];
                    }
                }
            
                if (selectedStateEvents.count)
                {
                    [self handleStateEvents:selectedStateEvents direction:MXTimelineDirectionForwards];
                }
            }

            // Enrich intermediate room state while paginating
            [self handleStateEvents:paginatedResponse.state  direction:direction];
        }
    
        // Process received events
        for (MXEvent *event in paginatedResponse.chunk)
        {
            if (!shouldApply()) return;
            // Make sure we have not processed this event yet
            [self addEvent:event direction:direction fromStore:NO isRoomInitialSync:NO];
        }
        
        // Update pagination state and tokens only after every event has been
        // applied. A missing end token is authoritative even for non-empty
        // chunks; an empty filtered page with a new cursor is not an end.
        if (!shouldApply()) return;
        if (direction == MXTimelineDirectionBackwards)
        {
            if ((persistedContextId && !paginatedResponse.chunk.count) || !paginatedResponse.end)
            {
                [self setBackwardPaginationState:MXRoomBackwardPaginationStateExhausted
                                           reason:@"messages_end_absent"];
            }
            else if ([paginatedResponse.start isEqualToString:paginatedResponse.end])
            {
                [self setBackwardPaginationState:MXRoomBackwardPaginationStateExhausted
                                           reason:@"messages_no_progress"];
            }
            else
            {
                [self->store storePaginationTokenOfRoom:self.state.roomId andToken:paginatedResponse.end];
                [self setBackwardPaginationState:MXRoomBackwardPaginationStateAvailable
                                           reason:@"messages_end_present"];
            }
        }
        else
        {
            self->forwardsPaginationToken = paginatedResponse.end;
            if ((persistedContextId && !paginatedResponse.chunk.count)
                || ((persistedContextId || paginatedResponse.chunk.count == 0)
                && (!paginatedResponse.end || [paginatedResponse.start isEqualToString:paginatedResponse.end])))
            {
                self->hasReachedHomeServerForwardsPaginationEnd = YES;
            }
        }
        
        // Commit store changes
        if ([self->store respondsToSelector:@selector(commit)])
        {
            [self->store commit];
        }
        
        onComplete();
    }]];
}


#pragma mark - Timeline events
/**
 Add an event to the timeline.
 
 @param event the event to add.
 @param direction the direction indicates if the event must added to the start or to the end of the timeline.
 @param fromStore YES if the messages have been loaded from the store. In this case, there is no need to store
                  it again in the store.
 @param isRoomInitialSync YES we are managing the first sync of this room.
 */
- (void)addEvent:(MXEvent*)event direction:(MXTimelineDirection)direction fromStore:(BOOL)fromStore isRoomInitialSync:(BOOL)isRoomInitialSync
{
    // Make sure we have not processed this event yet
    if (fromStore == NO && [store eventExistsWithEventId:event.eventId inRoom:room.roomId])
    {
        if (event.redactedBecause && [self preservesContextHistory]) [store replaceEvent:event inRoom:room.roomId];
        return;
    }

    // Применяем сохранённое удаление до обработки состояния и уведомления подписчиков.
    BOOL storedForHistory = !fromStore && [self preservesContextHistory];
    if (storedForHistory) [store storeEventForRoom:_state.roomId event:event direction:direction];
    if ([self preservesContextHistory] && event.eventId.length) {
        event = [store eventWithEventId:event.eventId inRoom:_state.roomId] ?: event;
    }

    // State event updates the timeline room state
    if (event.isState)
    {
        [self cloneState:direction];

        [self handleStateEvents:@[event] direction:direction];
    }

    // Events going forwards on the live timeline come from /sync.
    // They are assimilated to live events.
    if (_isLiveTimeline && direction == MXTimelineDirectionForwards)
    {
        // Handle here live redaction
        // There is nothing to manage locally if we are getting the 1st sync for the room
        // as the homeserver provides sanitised data in this situation
        if (!isRoomInitialSync && event.eventType == MXEventTypeRoomRedaction)
        {
            [self handleRedaction:event];
        }

        // Consider that a message sent by a user has been read by him
        [room storeLocalReceipt:kMXEventTypeStringRead eventId:event.eventId threadId:event.threadId ?: kMXEventTimelineMain userId:event.sender ts:event.originServerTs];
    }

    // Store the event
    if (!fromStore && !storedForHistory)
    {
        [store storeEventForRoom:_state.roomId event:event direction:direction];
    }

    // Notify the aggregation manager for every events so that it can store
    // aggregated data sent by the server

    [room.mxSession.aggregations handleOriginalDataOfEvent:event];

    //  Pass event to threading service to build threads
    [room.mxSession.threadingService handleEvent:event direction:direction completion:nil];

    if (direction == MXTimelineDirectionBackwards && event.eventId) [backwardDeliveredEventIds addObject:event.eventId];
    // Notify listeners
    [self notifyListeners:event direction:direction];
}

#pragma mark - Specific events Handling
- (void)handleRedaction:(MXEvent*)redactionEvent
{
    [self handleRedaction:redactionEvent lookupUnknownTarget:YES];
}

- (void)handleRedaction:(MXEvent*)redactionEvent lookupUnknownTarget:(BOOL)lookupUnknownTarget
{
    MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: handle an event redaction");
    
    // Check whether the redacted event is stored in room messages
    MXEvent *redactedEvent = [store eventWithEventId:redactionEvent.redacts inRoom:_state.roomId];
    if (!redactedEvent && [self preservesContextHistory]) {
        for (MXRoomHistoryContext *context in [room.mxSession.store historyContextsForRoom:room.roomId]) {
            NSMutableArray *sources = [NSMutableArray arrayWithArray:context.events];
            [sources addObjectsFromArray:context.initialState];
            for (NSDictionary *update in context.pageUpdates) [sources addObjectsFromArray:update[@"state"]];
            for (MXRoomHistoryContext *root in context.replayRoots) {
                [sources addObjectsFromArray:root.initialState];
                for (NSDictionary *update in root.pageUpdates) [sources addObjectsFromArray:update[@"state"]];
            }
            for (MXEvent *candidate in sources) if ([candidate.eventId isEqualToString:redactionEvent.redacts]) { redactedEvent = candidate; break; }
            if (redactedEvent) break;
        }
    }
    if (redactedEvent)
    {
        // Redact the stored event
        redactedEvent = [redactedEvent prune];
        redactedEvent.redactedBecause = redactionEvent.JSONDictionary;

        // Store the updated event
        [store replaceEvent:redactedEvent inRoom:_state.roomId];
    }
    
    // Check whether the current room state depends on this redacted event.
    if (!redactedEvent || redactedEvent.isState)
    {
        NSMutableArray *stateEvents = [NSMutableArray arrayWithArray:_state.stateEvents];
        
        for (NSInteger index = 0; index < stateEvents.count; index++)
        {
            MXEvent *stateEvent = stateEvents[index];
            
            if ([stateEvent.eventId isEqualToString:redactionEvent.redacts])
            {
                MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: the current room state has been modified by the event redaction.");
                
                // Redact the stored event
                redactedEvent = [stateEvent prune];
                redactedEvent.redactedBecause = redactionEvent.JSONDictionary;
                
                [stateEvents replaceObjectAtIndex:index withObject:redactedEvent];
                
                // Reset the room state.
                _state = [[MXRoomState alloc] initWithRoomId:room.roomId andMatrixSession:room.mxSession andDirection:YES];
                [self initialiseState:stateEvents];
                
                // Reset the current pagination
                [self resetPagination];
                
                // Notify that room history has been flushed
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXRoomDidFlushDataNotification
                                                                    object:room
                                                                  userInfo:nil];
                return;
            }
        }
    }

    // We need to figure out if this redacted event is a room state in the past.
    // If yes, we must prune the `prev_content` of the state event that replaced it.
    // Indeed, redacted information shouldn't spontaneously appear when you backpaginate...
    // TODO: This is no more implemented (see https://github.com/vector-im/riot-ios/issues/443).
    // The previous implementation based on a room initial sync was too heavy server side
    // and has been removed.
    if (redactedEvent.isState)
    {
        // TODO
        MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: the redacted event is a former state event. TODO: prune prev_content of the current state event");
    }
    else if (!redactedEvent && lookupUnknownTarget)
    {
        MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: the redacted event is unknown. Fetch it from the homeserver");

        // Retrieve the event from the HS to check whether the redacted event is a state event or not
        MXWeakify(self);
        httpOperation = [room.mxSession eventWithEventId:redactionEvent.redacts inRoom:room.roomId success:^(MXEvent *event) {
            MXStrongifyAndReturnIfNil(self);

            if (event.isState)
            {
                // TODO
                MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: the redacted event is a state event in the past. TODO: prune prev_content of the current state event");
            }
            else
            {
                MXLogDebug(@"[MXRoomEventTimeline] handleRedaction: the redacted event is a not state event -> job is done");
            }

            if (!self->httpOperation)
            {
                return;
            }

            self->httpOperation = nil;

        } failure:^(NSError *error) {
            MXStrongifyAndReturnIfNil(self);

            if (!self->httpOperation)
            {
                return;
            }

            self->httpOperation = nil;

            MXLogErrorDetails(@"[MXRoomEventTimeline] handleRedaction: failed to retrieve the redacted event", @{
                @"error": error ?: @"unknown"
            });
        }];
    }
}

#pragma mark - State events handling
- (void)cloneState:(MXTimelineDirection)direction
{
    // create a new instance of the state
    if (MXTimelineDirectionBackwards == direction)
    {
        backState = [backState copy];
    }
    else
    {
        // Keep the previous state in cache for future usage in [self notifyListeners]
        previousState = _state;

        _state = [_state copy];
    }
}

- (void)handleStateEvents:(NSArray<MXEvent *> *)stateEvents direction:(MXTimelineDirection)direction
{
    // Update the room state
    if (MXTimelineDirectionBackwards == direction)
    {
        [backState handleStateEvents:stateEvents];
    }
    else
    {
        // Forwards events update the current state of the room
        [_state handleStateEvents:stateEvents];

        // Update summary with this state events update
        // Only the history feature keeps non-live (context) timelines from touching the summary.
        BOOL updatesRoom = !_initialEventId || !MXSDKOptions.sharedInstance.preserveHistoryOnSlidingSyncGaps;
        if (updatesRoom) [room.summary handleStateEvents:stateEvents];

        // Update room account data with this state events update
        if (updatesRoom) [room.mxSession.roomAccountDataUpdateDelegate updateAccountDataForRoom:room
                                                               withStateEvents:stateEvents];

        if (!room.mxSession.syncWithLazyLoadOfRoomMembers && ![store hasLoadedAllRoomMembersForRoom:room.roomId])
        {
            // If there is no lazy loading of room members, consider we have fetched
            // all of them
            MXLogDebug(@"[MXRoomEventTimeline] handleStateEvents: syncWithLazyLoadOfRoomMembers disabled. Mark all room members loaded for room %@",  room.roomId);
            
            // XXX: Optimisation removed because of https://github.com/vector-im/element-ios/issues/3807
            // There can be a race on mxSession.syncWithLazyLoadOfRoomMembers. Its value may be not set yet.
            // LL should be always enabled now. So, we should never come here.
            //[store storeHasLoadedAllRoomMembersForRoom:room.roomId andValue:YES];
        }
    }
}


#pragma mark - Events listeners
- (MXEventListener *)listenToEvents:(MXOnRoomEvent)onEvent
{
    return [self listenToEventsOfTypes:nil onEvent:onEvent];
}

- (MXEventListener *)listenToEventsOfTypes:(NSArray<MXEventTypeString> *)types onEvent:(MXOnRoomEvent)onEvent
{
    MXEventListener *listener = [[MXEventListener alloc] initWithSender:self andEventTypes:types andListenerBlock:onEvent];

    [eventListeners addObject:listener];

    return listener;
}

- (void)removeListener:(MXEventListener *)listener
{
    [eventListeners removeObject:listener];
}

- (void)removeAllListeners
{
    [eventListeners removeAllObjects];
}

- (void)notifyListeners:(MXEvent*)event direction:(MXTimelineDirection)direction
{
    MXRoomState * roomState;

    if (MXTimelineDirectionBackwards == direction)
    {
        roomState = backState;
    }
    else
    {
        if ([event isState])
        {
            // Provide the state of the room before this event
            roomState = previousState;
        }
        else
        {
            roomState = _state;
        }
    }

    // Notify all listeners
    // The SDK client may remove a listener while calling them by enumeration
    // So, use a copy of them
    NSArray<MXEventListener *> *listeners = [eventListeners copy];

    for (MXEventListener *listener in listeners)
    {
        // And check the listener still exists before calling it
        if (NSNotFound != [eventListeners indexOfObject:listener])
        {
            [listener notify:event direction:direction andCustomObject:roomState];
        }
    }
    
    if (_isLiveTimeline && (direction == MXTimelineDirectionForwards))
    {
        // Check for local echo suppression
        if (room.outgoingMessages.count && [event.sender isEqualToString:room.mxSession.myUserId])
        {
            MXEvent *localEcho = [room pendingLocalEchoRelatedToEvent:event];
            if (localEcho)
            {
                // Remove the event from the pending local echo list
                [room removePendingLocalEcho:localEcho.eventId];
            }
        }
    }
}

#pragma mark - Events processing

// Make sure that events have a room id. They are skipped in some server responses
- (void)fixRoomIdInEvents:(NSArray<MXEvent*>*)events
{
    for (MXEvent *event in events)
    {
        event.roomId = _state.roomId;
    }
}

- (void)decryptEvents:(NSArray<MXEvent*>*)events onComplete:(void (^)(void))onComplete
{
    [self decryptEvents:events ifNewerThanTimestamp:0 onComplete:onComplete];
}

- (void)decryptEvents:(NSArray<MXEvent*>*)events ifNewerThanTimestamp:(uint64_t)timestamp onComplete:(void (^)(void))onComplete
{
    NSMutableArray<MXEvent*> *eventsToDecrypt = [NSMutableArray arrayWithCapacity:(NSUInteger)events.count];
    
    // The state event providing the encrytion algorithm can be part of the timeline.
    // Extract if before starting decrypting.
    for (MXEvent *event in events)
    {
        if (event.eventType == MXEventTypeRoomEncryption)
        {
            [_state handleStateEvents:@[event]];
        }
        
        if (event.eventType == MXEventTypeRoomEncrypted
            && event.originServerTs >= timestamp)
        {
            [eventsToDecrypt addObject:event];
        }
    }
    
    if (eventsToDecrypt.count == 0)
    {
        onComplete();
        return;
    }
    
    [room.mxSession decryptEvents:eventsToDecrypt inTimeline:_timelineId onComplete:^(NSArray<MXEvent *> *failedEvents) {
        onComplete();
    }];
}


#pragma mark - Durable disconnected history
- (BOOL)preservesHistoryGaps
{
    MXPrepareHistoryRegistries();
    NSNumber *sliding = [MXHistoryModes objectForKey:store][room.roomId];
    return MXSDKOptions.sharedInstance.preserveHistoryOnSlidingSyncGaps
        && (!sliding || sliding.boolValue) && store == room.mxSession.store && !_initialEventId;
}

- (void)notifyHistoryGapChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:MXRoomHistoryGapsDidChangeNotification
                                                       object:room
                                                     userInfo:@{@"historyRevision": @([room.mxSession.store historyRevisionForRoom:room.roomId])}];
}

- (MXHTTPOperation *)paginateHistoryGap:(NSString *)gapId success:(void (^)(NSArray<MXEvent *> *))success failure:(void (^)(NSError *))failure
{
    MXHTTPOperation *operation = [MXHTTPOperation new];
    [paginationOperations addObject:operation];
    MXRoomHistoryGap *gap;
    for (MXRoomHistoryGap *candidate in [store historyGapsForRoom:room.roomId]) {
        if ([candidate.gapId isEqualToString:gapId]) { gap = candidate; break; }
    }
    if (![self preservesHistoryGaps] || !gap.backwardToken.length) {
        dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{
            failure([NSError errorWithDomain:@"MXRoomHistoryGap" code:1 userInfo:@{NSLocalizedDescriptionKey: @"History interval has no usable cursor"}]);
        }]);
        return operation;
    }
    MXPrepareHistoryRegistries();
    NSMapTable<NSString *, MXHTTPOperation *> *requests = [MXHistoryRequests objectForKey:store];
    if (!requests) { requests = [NSMapTable strongToWeakObjectsMapTable]; [MXHistoryRequests setObject:requests forKey:store]; }
    NSString *requestKey = room.roomId;
    if ([requests objectForKey:requestKey]) {
        dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{
            failure([NSError errorWithDomain:@"MXRoomHistoryGap" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Room history request is already running"}]);
        }]);
        return operation;
    }
    [requests setObject:operation forKey:requestKey];
    // Идентификатор комнаты и курсор интервала задают поколение запроса. Синхронизация live
    // может расширить другой интервал, не обесценивая полезную работу здесь.
    MXRoomHistoryGap *requestedGap = [gap copy];
    __weak MXSession *requestedSession = room.mxSession;
    __block BOOL finished = NO;
    void (^fail)(NSError *) = ^(NSError *error) {
        if (finished) return;
        finished = YES;
        if ([requests objectForKey:requestKey] == operation) [requests removeObjectForKey:requestKey];
        failure(error);
    };
    BOOL (^shouldApply)(void) = ^BOOL {
        BOOL valid = !operation.isCancelled && requestedSession && self->room.mxSession == requestedSession
            && self->store == requestedSession.store && [requestedSession hasRoomWithRoomId:self->room.roomId]
            && [self preservesHistoryGaps];
        MXRoomHistoryGap *current;
        for (MXRoomHistoryGap *candidate in [self->store historyGapsForRoom:self->room.roomId]) {
            if ([candidate.gapId isEqualToString:requestedGap.gapId]) current = candidate;
        }
        valid = valid && current && [current.backwardToken isEqualToString:requestedGap.backwardToken]
            && [current.newerAnchorEventId isEqualToString:requestedGap.newerAnchorEventId]
            && [current.olderAnchorEventId isEqualToString:requestedGap.olderAnchorEventId];
        if (!valid && !finished) fail([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
        return valid && !finished;
    };
    if (!backState) backState = [[MXRoomState alloc] initBackStateWith:_state];
    // Восстановление разрыва не наследует ограничения отображения: они могут скрывать удаления
    // целей вне страницы. Сохраняем настройки состояния и принятую политику исключения реакций.
    NSMutableDictionary *recoveryFilterData = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"lazy_load_members", @"include_redundant_members"]) {
        if (_roomEventFilter.dictionary[key]) recoveryFilterData[key] = _roomEventFilter.dictionary[key];
    }
    if ([_roomEventFilter.notTypes containsObject:kMXEventTypeStringReaction]) {
        recoveryFilterData[@"not_types"] = @[kMXEventTypeStringReaction];
    }
    MXRoomEventFilter *recoveryFilter = [[MXRoomEventFilter alloc] initWithDictionary:recoveryFilterData];
    MXHTTPOperation *request = [room.mxSession.matrixRestClient messagesForRoom:room.roomId
        from:gap.backwardToken direction:MXTimelineDirectionBackwards limit:50 filter:recoveryFilter
        success:^(MXPaginationResponse *response) {
            if (!shouldApply()) return;
            [self fixRoomIdInEvents:response.chunk];
            [self decryptEvents:response.chunk onComplete:[operation processingBlock:^{
                if (!shouldApply()) return;
                // Фиксируем набор доказательств до вставки; событие в другой части
                // хранилища (включая островок контекста другого разрыва) не служит доказательством.
                NSMutableSet *knownIds = [NSMutableSet set];
                for (MXEvent *event in response.chunk) {
                    if ([self->store eventExistsWithEventId:event.eventId inRoom:self->room.roomId]) [knownIds addObject:event.eventId];
                }
                [self->store applyHistoryGap:requestedGap inRoom:self->room.roomId events:response.chunk nextToken:response.end];
                NSMutableArray<MXEvent *> *delivered = [NSMutableArray array];
                for (MXEvent *event in response.chunk) {
                    if (![knownIds containsObject:event.eventId] && [self->store eventExistsWithEventId:event.eventId inRoom:self->room.roomId]) {
                        [delivered addObject:event]; [knownIds addObject:event.eventId];
                    }
                }
                // Применяем редактирование с удалением содержимого и обработку агрегации/веток через тот же
                // путь обработки событий, но никогда не добавляем страницу интервала к самому старому краю истории.
                for (MXEvent *event in delivered) {
                    if (event.eventType == MXEventTypeRoomRedaction) [self handleRedaction:event lookupUnknownTarget:NO];
                    [self addEvent:event direction:MXTimelineDirectionBackwards fromStore:YES isRoomInitialSync:NO];
                }
                // Возвращаем те же монотонные версии, которые получают подписчики timeline.
                for (NSUInteger index = 0; index < delivered.count; index++) {
                    MXEvent *current = [self->store eventWithEventId:delivered[index].eventId inRoom:self->room.roomId];
                    if (current) delivered[index] = current;
                }
                if ([self->store respondsToSelector:@selector(commit)]) [self->store commit];
                MXRoomHistoryGap *remaining;
                for (MXRoomHistoryGap *candidate in [self->store historyGapsForRoom:self->room.roomId]) {
                    if ([candidate.gapId isEqualToString:requestedGap.gapId]) remaining = candidate;
                }
                [self notifyHistoryGapChange];
                if (remaining.recoveryBlocked) {
                    fail([NSError errorWithDomain:@"MXRoomHistoryGap" code:2 userInfo:@{NSLocalizedDescriptionKey: @"History interval did not establish continuity"}]);
                } else if (!finished) {
                    finished = YES;
                    if ([requests objectForKey:requestKey] == operation) [requests removeObjectForKey:requestKey];
                    success(delivered);
                }
            }]];
        } failure:^(NSError *error) {
            BOOL offline = [error.domain isEqualToString:NSURLErrorDomain]
                && (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost);
            BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
            // Офлайн сохраняет курсор без постоянной блокировки; старые blocked-записи не мигрируем.
            if (!offline && !cancelled && shouldApply()) {
                MXRoomHistoryGap *blocked = [requestedGap copy]; blocked.recoveryBlocked = YES;
                [self->store storeHistoryGap:blocked forRoom:self->room.roomId];
                if ([self->store respondsToSelector:@selector(commit)]) [self->store commit];
                [self notifyHistoryGapChange];
            }
            fail(error);
        }];
    request.maxNumberOfTries = 1;
    request.maxTotalAttempts = @1;
    [operation mutateTo:request];
    return operation;
}

- (BOOL)preservesContextHistory
{
    MXPrepareHistoryRegistries();
    id<MXStore> liveStore = room.mxSession.store;
    NSNumber *sliding = [MXHistoryModes objectForKey:liveStore][room.roomId];
    return liveStore && MXSDKOptions.sharedInstance.preserveHistoryOnSlidingSyncGaps
        && (!sliding || sliding.boolValue);
}

- (MXRoomHistoryContext *)historyContextComponent
{
    if (![self preservesContextHistory] || !persistedContextId.length
        || ![persistedContextGeneration isEqualToString:[room.mxSession.store historyContextGenerationForRoom:room.roomId]]) return nil;
    for (MXRoomHistoryContext *context in [room.mxSession.store historyContextsForRoom:room.roomId]) {
        if ([context.componentId isEqualToString:persistedContextId]) return context;
    }
    return nil;
}
- (BOOL)historyContextAttachedToLive
{
    MXRoomHistoryContext *component = self.historyContextComponent;
    if (!component.attachedToLive || ![component.filter isEqualToDictionary:_roomEventFilter.dictionary ?: @{}]) return NO;
    NSArray *delivered = [[[store messagesEnumeratorForRoom:room.roomId] nextEventsBatch:NSUIntegerMax threadId:nil] valueForKey:@"eventId"];
    NSArray *coverage = [component.events valueForKey:@"eventId"];
    NSUInteger start = [coverage indexOfObject:_initialEventId];
    if (start == NSNotFound) {
        for (NSUInteger i = 0; i < coverage.count; i++) if ([delivered containsObject:coverage[i]]) { start = i; break; }
    }
    if (start == NSNotFound) return NO;
    NSUInteger previous = NSNotFound;
    for (NSUInteger i = start; i < coverage.count; i++) {
        NSUInteger index = [delivered indexOfObject:coverage[i]];
        if (index == NSNotFound || (previous != NSNotFound && index <= previous)) return NO;
        previous = index;
    }
    // Каноническое доказательство уже помещает эту конечную точку в текущий непрерывный
    // самый новый блок live. Последующие строки /sync без разрывов относятся к live-проекции
    // приложения; они не обязаны присутствовать в этом отфильтрованном приватном хранилище контекста.
    return YES;
}

- (void)applyContextPageState:(NSArray<MXEvent *> *)events direction:(MXTimelineDirection)direction
{
    if (direction == MXTimelineDirectionBackwards) {
        NSMutableArray *missingMembers = [NSMutableArray array];
        for (MXEvent *event in events) {
            if (event.eventType == MXEventTypeRoomMember && ![_state.members memberWithUserId:event.stateKey]) [missingMembers addObject:event];
        }
        if (missingMembers.count) [self handleStateEvents:missingMembers direction:MXTimelineDirectionForwards];
    }
    [self handleStateEvents:events direction:direction];
}

- (BOOL)restoreHistoryContextFromStore
{
    NSSet *previouslyDelivered = [deliveredContextRootIds copy];
    NSString *selectedRoot = persistedContextRootId;
    if (![self restoreHistoryContextRoot:selectedRoot]) return NO;
    if (previouslyDelivered.count > 1) {
        restoreAllowedContextRootIds = previouslyDelivered;
        [self crossHistoryContextLocally:MXTimelineDirectionBackwards];
        [self crossHistoryContextLocally:MXTimelineDirectionForwards];
        restoreAllowedContextRootIds = nil;
    }
    return YES;
}

- (BOOL)restoreHistoryContextRoot:(NSString *)rootId
{
    if (!_initialEventId || ![self preservesContextHistory]) return NO;
    id<MXStore> liveStore = room.mxSession.store;
    if (persistedContextGeneration && ![persistedContextGeneration isEqualToString:[liveStore historyContextGenerationForRoom:room.roomId]]) return NO;
    MXRoomHistoryContext *component = [liveStore historyContextForEventId:_initialEventId inRoom:room.roomId filter:_roomEventFilter.dictionary ?: @{}];
    if (!component && persistedContextId) component = self.historyContextComponent;
    if (!component || ![component.filter isEqualToDictionary:_roomEventFilter.dictionary ?: @{}]) return NO;
    MXRoomHistoryContext *canonical = component;
    NSString *selected = rootId ?: component.selectedRootId;
    component = canonical.replayRoots.firstObject ?: canonical;
    for (MXRoomHistoryContext *root in canonical.replayRoots) {
        if ([deliveredContextRootIds containsObject:root.componentId]) component = root;
        if ([root.componentId isEqualToString:selected]) { component = root; break; }
    }
    if (!component.events.count) return NO;
    NSString *anchorId = component.initialAnchorEventId ?: component.targetEventId;
    NSUInteger target = [[component.initialEvents valueForKey:@"eventId"] indexOfObject:anchorId];
    NSArray *backwardIds = component.initialBackwardEventIds;
    if (!component.initialAnchorEventId && target != NSNotFound) backwardIds = [[component.initialEvents subarrayWithRange:NSMakeRange(0, target)] valueForKey:@"eventId"];
    [self cancelPendingPaginations];
    if (!store.isPermanent) [store deleteAllData];
    _state = [[MXRoomState alloc] initWithRoomId:room.roomId andMatrixSession:room.mxSession andDirection:YES];
    persistedContextId = canonical.componentId;
    persistedContextRootId = component.componentId;
    if (!deliveredContextRootIds) deliveredContextRootIds = [NSMutableSet set];
    [deliveredContextRootIds addObject:component.componentId];
    persistedContextGeneration = [liveStore historyContextGenerationForRoom:room.roomId];
    restoringHistoryContext = YES;
    [self initialiseState:component.initialState];
    [self resetPagination];
    if (target != NSNotFound) [self addEvent:component.initialEvents[target] direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];
    for (MXEvent *event in component.initialEvents.reverseObjectEnumerator) {
        if ([backwardIds containsObject:event.eventId]) [self addEvent:event direction:MXTimelineDirectionBackwards fromStore:NO isRoomInitialSync:NO];
    }
    for (MXEvent *event in component.initialEvents) {
        if (![event.eventId isEqualToString:anchorId] && ![backwardIds containsObject:event.eventId]) [self addEvent:event direction:MXTimelineDirectionForwards fromStore:NO isRoomInitialSync:NO];
    }
    for (NSDictionary *update in component.pageUpdates) {
        MXTimelineDirection direction = [update[@"direction"] unsignedIntegerValue];
        [self applyContextPageState:update[@"state"] direction:direction];
        for (MXEvent *event in update[@"events"]) [self addEvent:event direction:direction fromStore:NO isRoomInitialSync:NO];
    }
    // Воспроизведённые страницы уже передали эти события; не перечисляем их повторно.
    storeMessagesEnumerator = nil;
    [store storePaginationTokenOfRoom:room.roomId andToken:component.backwardToken];
    [self setBackwardPaginationState:component.backwardBlocked ? MXRoomBackwardPaginationStateExhausted : MXRoomBackwardPaginationStateAvailable reason:@"context_restore_availability"];
    forwardsPaginationToken = component.forwardToken;
    hasReachedHomeServerForwardsPaginationEnd = component.forwardBlocked;
    MXEventContext *context = [MXEventContext new];
    NSUInteger currentTarget = [[component.events valueForKey:@"eventId"] indexOfObject:_initialEventId];
    if (currentTarget != NSNotFound) {
        context.event = component.events[currentTarget];
        context.eventsBefore = [[component.events subarrayWithRange:NSMakeRange(0, currentTarget)] reverseObjectEnumerator].allObjects;
        context.eventsAfter = [component.events subarrayWithRange:NSMakeRange(currentTarget + 1, component.events.count - currentTarget - 1)];
    }
    context.state = component.initialState; context.start = component.backwardToken; context.end = component.forwardToken;
    _historyContext = context;
    restoringHistoryContext = NO;
    return YES;
}

- (BOOL)persistContextPage:(MXPaginationResponse *)response direction:(MXTimelineDirection)direction
{
    if (!persistedContextId || restoringHistoryContext) return YES;
    MXRoomHistoryContext *canonical = self.historyContextComponent;
    if (!canonical || ![canonical.filter isEqualToDictionary:_roomEventFilter.dictionary ?: @{}]) return NO;
    MXRoomHistoryContext *component;
    for (MXRoomHistoryContext *root in canonical.replayRoots) if ([root.componentId isEqualToString:persistedContextRootId]) { component = root; break; }
    if (!component) return NO;
    NSString *owner = direction == MXTimelineDirectionBackwards ? canonical.backwardRootId : canonical.forwardRootId;
    if (![owner isEqualToString:persistedContextRootId]) return NO;
    NSString *cursor = direction == MXTimelineDirectionBackwards ? component.backwardToken : component.forwardToken;
    if (!cursor.length || (response.start && ![response.start isEqualToString:cursor])) return NO;
    id<MXStore> liveStore = room.mxSession.store;
    NSUInteger expectedRoomRevision = [liveStore historyRevisionForRoom:room.roomId];
    NSMutableArray *events = [component.events mutableCopy];
    NSArray *ordered = direction == MXTimelineDirectionBackwards ? response.chunk.reverseObjectEnumerator.allObjects : response.chunk;
    NSMutableArray *newEvents = [NSMutableArray array];
    NSArray *existingIds = [events valueForKey:@"eventId"];
    NSMutableSet *pageIds = [NSMutableSet set];
    NSUInteger previousOverlap = NSNotFound;
    BOOL encounteredOverlap = NO, encounteredNew = NO;
    for (MXEvent *event in ordered) {
        if (!event.eventId.length || [pageIds containsObject:event.eventId]) continue;
        [pageIds addObject:event.eventId];
        NSUInteger index = [existingIds indexOfObject:event.eventId];
        if (index != NSNotFound) {
            if ((previousOverlap != NSNotFound && index != previousOverlap + 1)
                || (direction == MXTimelineDirectionForwards && encounteredNew)) return NO;
            previousOverlap = index; encounteredOverlap = YES;
            // Перекрытие не добавляет строку, но несёт новое доказательство удаления.
            // Оно попадёт в CAS-коммит через покрытие корня и монотонное объединение хранилища.
            if (event.redactedBecause) events[index] = event;
        } else {
            if (direction == MXTimelineDirectionBackwards && encounteredOverlap) return NO;
            [newEvents addObject:event]; encounteredNew = YES;
        }
    }
    if (direction == MXTimelineDirectionBackwards) [events insertObjects:newEvents atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newEvents.count)]];
    else [events addObjectsFromArray:newEvents];
    component.events = events;
    NSMutableArray *updates = [component.pageUpdates mutableCopy];
    [updates addObject:@{@"direction": @(direction), @"events": (direction == MXTimelineDirectionBackwards ? newEvents.reverseObjectEnumerator.allObjects : newEvents), @"state": response.state ?: @[]}];
    component.pageUpdates = updates;
    BOOL blocked = !response.chunk.count || !response.end.length || [response.end isEqualToString:cursor];
    if (direction == MXTimelineDirectionBackwards) { component.backwardToken = response.end; component.backwardBlocked = blocked; }
    else { component.forwardToken = response.end; component.forwardBlocked = blocked; }
    component.revision++;
    NSMutableArray *coverage = [canonical.events mutableCopy];
    NSMutableArray *coverageNew = [NSMutableArray array];
    NSSet *coverageIds = [NSSet setWithArray:[coverage valueForKey:@"eventId"]];
    for (MXEvent *event in newEvents) if (![coverageIds containsObject:event.eventId]) [coverageNew addObject:event];
    if (direction == MXTimelineDirectionBackwards) [coverage insertObjects:coverageNew atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, coverageNew.count)]];
    else [coverage addObjectsFromArray:coverageNew];
    canonical.events = coverage;
    canonical.initialEvents = component.initialEvents; canonical.initialState = component.initialState;
    canonical.pageUpdates = component.pageUpdates; canonical.targetEventId = component.targetEventId;
    if (![liveStore storeHistoryContext:canonical inRoom:room.roomId expectedGeneration:persistedContextGeneration expectedRoomRevision:expectedRoomRevision expectedComponentRevision:canonical.revision]) return NO;
    MXRoomHistoryContext *committed = [liveStore historyContextForEventId:component.targetEventId inRoom:room.roomId filter:component.filter];
    MXRoomHistoryContext *committedRoot;
    for (MXRoomHistoryContext *root in committed.replayRoots) {
        if ([root.componentId isEqualToString:persistedContextRootId]) { committedRoot = root; break; }
    }
    if (!committedRoot || !committedRoot.pageUpdates.count) return NO;
    persistedContextId = committed.componentId;
    // Сохраняем порядок ответа, но доставляем только сохранённые очищенные версии.
    // Состояние берём из той же страницы того же корня, а не из другого объединённого контекста.
    NSMutableDictionary<NSString *, MXEvent *> *retained = [NSMutableDictionary dictionary];
    for (MXEvent *event in committed.events) retained[event.eventId] = event;
    NSMutableArray *retainedChunk = [NSMutableArray array];
    for (MXEvent *event in response.chunk) if (retained[event.eventId]) [retainedChunk addObject:retained[event.eventId]];
    response.chunk = retainedChunk;
    response.state = committedRoot.pageUpdates.lastObject[@"state"];
    if ([liveStore respondsToSelector:@selector(commit)]) [liveStore commit];
    [self notifyHistoryGapChange];
    return YES;
}

- (MXHTTPOperation *)paginateHistoryContext:(NSString *)componentId direction:(MXTimelineDirection)direction success:(void (^)(NSArray<MXEvent *> *))success failure:(void (^)(NSError *))failure
{
    MXHTTPOperation *operation = [MXHTTPOperation new];
    [paginationOperations addObject:operation];
    MXRoomHistoryContext *component;
    for (MXRoomHistoryContext *candidate in [room.mxSession.store historyContextsForRoom:room.roomId]) {
        if ([candidate.componentId isEqualToString:componentId]) { component = candidate; break; }
    }
    BOOL blocked = direction == MXTimelineDirectionBackwards ? component.backwardBlocked : component.forwardBlocked;
    NSString *cursor = direction == MXTimelineDirectionBackwards ? component.backwardToken : component.forwardToken;
    if (![self preservesContextHistory] || !component || blocked || !cursor.length) {
        dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{ failure([NSError errorWithDomain:@"MXRoomHistoryContext" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Context boundary has no usable cursor"}]); }]);
        return operation;
    }
    MXRoomEventTimeline *proxy = [[MXRoomEventTimeline alloc] initWithRoom:room andInitialEventId:component.targetEventId];
    proxy.roomEventFilter = [[MXRoomEventFilter alloc] initWithDictionary:component.filter];
    NSString *owner = direction == MXTimelineDirectionBackwards ? component.backwardRootId : component.forwardRootId;
    if (![proxy restoreHistoryContextRoot:owner]) {
        dispatch_async(dispatch_get_main_queue(), [operation processingBlock:^{ failure([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); }]);
        return operation;
    }
    NSMutableArray<MXEvent *> *delivered = [NSMutableArray array];
    MXEventListener *listener = [proxy listenToEvents:^(MXEvent *event, MXTimelineDirection eventDirection, MXRoomState *state) {
        [delivered addObject:event];
    }];
    MXHTTPOperation *request = [proxy paginate:50 direction:direction onlyFromStore:NO complete:^{
        [proxy removeListener:listener];
        if (!operation.isCancelled) success(delivered);
        else failure([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
    } failure:^(NSError *error) {
        [proxy removeListener:listener];
        failure(error);
    }];
    [operation mutateTo:request];
    return operation;
}

- (void)persistProvenContext:(MXEventContext *)context
{
    if (![self preservesContextHistory] || !context.event.eventId.length) return;
    id<MXStore> liveStore = room.mxSession.store;
    MXRoomHistoryContext *existing = [liveStore historyContextForEventId:context.event.eventId inRoom:room.roomId filter:_roomEventFilter.dictionary ?: @{}];
    if (existing) {
        NSString *generation = [liveStore historyContextGenerationForRoom:room.roomId];
        NSMutableArray<MXEvent *> *sources = [NSMutableArray arrayWithObject:context.event];
        [sources addObjectsFromArray:context.eventsBefore ?: @[]];
        [sources addObjectsFromArray:context.eventsAfter ?: @[]];
        [sources addObjectsFromArray:context.state ?: @[]];
        NSPredicate *redacted = [NSPredicate predicateWithBlock:^BOOL(MXEvent *event, NSDictionary *bindings) {
            return event.eventId.length && event.redactedBecause != nil;
        }];
        NSArray<MXEvent *> *redactions = [sources filteredArrayUsingPredicate:redacted];
        if (redactions.count) {
            // Повторный контекст не меняет покрытие и корни, но может впервые подтвердить удаление.
            // Сначала проверяем CAS; события, все проекции и индекс удалений фиксируются затем вместе.
            NSUInteger revision = [liveStore historyRevisionForRoom:room.roomId];
            if (![liveStore storeHistoryContext:existing inRoom:room.roomId expectedGeneration:generation
                          expectedRoomRevision:revision expectedComponentRevision:existing.revision]) return;
            for (MXEvent *event in redactions) [liveStore replaceEvent:event inRoom:room.roomId];
            if ([liveStore respondsToSelector:@selector(commit)]) [liveStore commit];
            [self notifyHistoryGapChange];
        }
        persistedContextId = existing.componentId;
        persistedContextRootId = existing.selectedRootId;
        persistedContextGeneration = generation;
        return;
    }
    MXRoomHistoryContext *component = [MXRoomHistoryContext new];
    component.targetEventId = context.event.eventId;
    NSMutableArray *events = [NSMutableArray arrayWithArray:context.eventsBefore.reverseObjectEnumerator.allObjects ?: @[]];
    [events addObject:context.event]; [events addObjectsFromArray:context.eventsAfter ?: @[]];
    NSMutableArray *unique = [NSMutableArray array]; NSMutableSet *ids = [NSMutableSet set];
    for (MXEvent *event in events) if (event.eventId.length && ![ids containsObject:event.eventId]) { [unique addObject:event]; [ids addObject:event.eventId]; }
    component.events = unique; component.initialEvents = unique; component.initialState = context.state ?: @[];
    component.filter = _roomEventFilter.dictionary ?: @{};
    component.backwardToken = context.start; component.forwardToken = context.end;
    component.backwardBlocked = !context.start.length; component.forwardBlocked = !context.end.length;
    NSString *generation = [liveStore historyContextGenerationForRoom:room.roomId];
    NSUInteger revision = [liveStore historyRevisionForRoom:room.roomId];
    if ([liveStore storeHistoryContext:component inRoom:room.roomId expectedGeneration:generation expectedRoomRevision:revision expectedComponentRevision:0]) {
        MXRoomHistoryContext *committed = [liveStore historyContextForEventId:context.event.eventId inRoom:room.roomId filter:component.filter];
        persistedContextId = committed.componentId; persistedContextRootId = committed.selectedRootId;
        if (!deliveredContextRootIds) deliveredContextRootIds = [NSMutableSet set];
        if (persistedContextRootId) [deliveredContextRootIds addObject:persistedContextRootId];
        persistedContextGeneration = generation;
        if ([liveStore respondsToSelector:@selector(commit)]) [liveStore commit];
        [self notifyHistoryGapChange];
    }
}

- (BOOL)persistHistoryContext:(MXEventContext *)context inGap:(NSString *)gapId
{
    if (![self preservesHistoryGaps] || !context.event.eventId.length) return NO;
    [self persistProvenContext:context];
    MXRoomHistoryContext *saved = [room.mxSession.store historyContextForEventId:context.event.eventId inRoom:room.roomId filter:_roomEventFilter.dictionary ?: @{}];
    // Хранилище определяет положение, не доверяя запрошенному ID разрыва.
    return saved.backwardConnected || saved.forwardConnected;
}

#pragma mark - NSCopying

- (nonnull id)copyWithZone:(nullable NSZone *)zone
{
    MXRoomEventTimeline *timeline = [[[self class] allocWithZone:zone] init];
    timeline->_initialEventId = _initialEventId;
    timeline->persistedContextId = persistedContextId;
    timeline->persistedContextRootId = persistedContextRootId;
    timeline->deliveredContextRootIds = [deliveredContextRootIds mutableCopy];
    timeline->persistedContextGeneration = persistedContextGeneration;
    timeline->_roomEventFilter = _roomEventFilter;
    timeline->_paginationMaxNumberOfTries = _paginationMaxNumberOfTries;
    timeline->_state = [_state copyWithZone:zone];
    timeline->room = room;
    timeline->store = store;
    [timeline observeRoomHistoryFlush];
    
    // There can be only a single live timeline
    timeline->_isLiveTimeline = NO;
    
    return timeline;
}

@end
