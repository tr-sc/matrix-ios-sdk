//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Лента комнаты и треда на MXSQLiteStore (iP7, iP8): страницы из стора до дыры, дыра — запрос к серверу
// от trsc.count её границы, прыжок к событию — окно между дырами в общем сторе, эхо — одна строка.
// Сервер — TrscFakeHomeserver: история с trsc.count, /messages, /context и /relations от trsc.count.

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>
#import <MatrixSDK/MatrixSDK-Swift.h>

@interface MXRoom (TrscTimelineTests)
- (MXEvent *)addLocalEchoForMessageContent:(NSDictionary *)msgContent
                                 eventType:(MXEventTypeString)eventType
                                 withState:(MXEventSentState)eventState
                                  threadId:(NSString *)threadId;
@end

static NSString *const kRoomId = @"!timeline:example.org";
static NSString *const kMe = @"@me:example.org";
static NSString *const kPeer = @"@peer:example.org";

#pragma mark - Fake homeserver

static int64_t TrscFakeNowMs(void)
{
    static int64_t now;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ now = (int64_t)(NSDate.date.timeIntervalSince1970 * 1000); });
    return now;
}

/// История одной комнаты на «сервере»: события по возрастанию trsc.count (1, 2, 3 …).
@interface TrscFakeHomeserver : MXRestClient
@property (nonatomic) NSMutableArray<NSDictionary *> *history;
@property (nonatomic) NSMutableArray<NSString *> *requests;   // "messages b 281", "context $e100", "relations b 290"
@end

@implementation TrscFakeHomeserver

- (instancetype)init
{
    MXCredentials *credentials = [[MXCredentials alloc] initWithHomeServer:@"https://example.org" userId:kMe accessToken:@"token"];
    self = [super initWithCredentials:credentials andOnUnrecognizedCertificateBlock:nil];
    if (self)
    {
        _history = [NSMutableArray array];
        _requests = [NSMutableArray array];
    }
    return self;
}

+ (NSString *)idOfCount:(NSInteger)count
{
    return [NSString stringWithFormat:@"$e%ld", (long)count];
}

/// Добавить сообщения с номерами `from … to` (включительно). `thread` — id корня для ответов в треде.
- (void)appendMessagesFrom:(NSInteger)from to:(NSInteger)to
{
    for (NSInteger count = from; count <= to; count++) [self appendMessage:count thread:nil sender:kPeer txnId:nil];
}

- (NSDictionary *)appendMessage:(NSInteger)count thread:(NSString *)threadRoot sender:(NSString *)sender txnId:(NSString *)txnId
{
    NSMutableDictionary *content = [@{@"msgtype": kMXMessageTypeText, @"body": [NSString stringWithFormat:@"message %ld", (long)count]} mutableCopy];
    if (threadRoot)
    {
        content[@"m.relates_to"] = @{@"rel_type": MXEventRelationTypeThread, @"event_id": threadRoot};
    }
    NSMutableDictionary *unsignedData = [@{@"trsc.count": [NSString stringWithFormat:@"%ld", (long)count]} mutableCopy];
    if (txnId) unsignedData[@"transaction_id"] = txnId;
    NSDictionary *json = @{
        @"event_id": [TrscFakeHomeserver idOfCount:count],
        @"room_id": kRoomId,
        @"type": kMXEventTypeStringRoomMessage,
        @"sender": sender,
        // Свежие метки: старые съест фоновая очистка по сроку хранения (TRSC retention).
        @"origin_server_ts": @(TrscFakeNowMs() - (100000 - count) * 1000),
        @"content": content,
        @"unsigned": unsignedData,
    };
    [_history addObject:json];
    return json;
}

- (NSInteger)countOf:(NSDictionary *)json
{
    return [json[@"unsigned"][@"trsc.count"] integerValue];
}

- (NSArray<MXEvent *> *)eventsOf:(NSArray<NSDictionary *> *)jsons
{
    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *json in jsons) [events addObject:[MXEvent modelFromJSON:json]];
    return events;
}

/// Ответ синка с событиями `from … to`.
- (MXRoomSync *)syncFrom:(NSInteger)from to:(NSInteger)to limited:(BOOL)limited
{
    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *json in _history)
    {
        NSInteger count = [self countOf:json];
        if (count >= from && count <= to) [events addObject:json];
    }
    return [MXRoomSync modelFromJSON:@{
        @"timeline": @{@"events": events, @"limited": @(limited), @"prev_batch": @"sync_prev_batch"},
        @"state": @{@"events": @[]},
        @"ephemeral": @{@"events": @[]},
        @"account_data": @{@"events": @[]},
    }];
}

- (MXHTTPOperation *)messagesForRoom:(NSString *)roomId from:(NSString *)from direction:(MXTimelineDirection)direction
                               limit:(NSInteger)limit filter:(MXRoomEventFilter *)roomEventFilter
                             success:(void (^)(MXPaginationResponse *))success failure:(void (^)(NSError *))failure
{
    BOOL backwards = direction == MXTimelineDirectionBackwards;
    [_requests addObject:[NSString stringWithFormat:@"messages %@ %@", backwards ? @"b" : @"f", from ?: @"-"]];
    NSInteger anchor = from.length ? from.integerValue : (backwards ? NSIntegerMax : NSIntegerMin);
    NSMutableArray *matching = [NSMutableArray array];
    NSEnumerator *enumerator = backwards ? _history.reverseObjectEnumerator : _history.objectEnumerator;
    for (NSDictionary *json in enumerator)
    {
        NSInteger count = [self countOf:json];
        if (backwards ? count < anchor : count > anchor) [matching addObject:json];
    }
    NSArray *chunk = [matching subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)limit, matching.count))];
    MXPaginationResponse *response = [MXPaginationResponse new];
    response.chunk = [self eventsOf:chunk];
    response.state = @[];
    response.start = from;
    response.end = matching.count > chunk.count ? [NSString stringWithFormat:@"%ld", (long)[self countOf:chunk.lastObject]] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{ success(response); });
    return [MXHTTPOperation new];
}

- (MXHTTPOperation *)contextOfEvent:(NSString *)eventId inRoom:(NSString *)roomId limit:(NSUInteger)limit
                             filter:(MXRoomEventFilter *)filter
                            success:(void (^)(MXEventContext *))success failure:(void (^)(NSError *))failure
{
    [_requests addObject:[@"context " stringByAppendingString:eventId]];
    NSUInteger index = [_history indexOfObjectPassingTest:^BOOL(NSDictionary *json, NSUInteger idx, BOOL *stop) {
        return [json[@"event_id"] isEqualToString:eventId];
    }];
    NSUInteger half = limit / 2;
    NSUInteger beforeStart = index >= half ? index - half : 0;
    NSArray *before = [_history subarrayWithRange:NSMakeRange(beforeStart, index - beforeStart)];
    NSUInteger afterCount = MIN(half, _history.count - index - 1);
    NSArray *after = [_history subarrayWithRange:NSMakeRange(index + 1, afterCount)];
    MXEventContext *context = [MXEventContext new];
    context.event = [MXEvent modelFromJSON:_history[index]];
    context.eventsBefore = [self eventsOf:before.reverseObjectEnumerator.allObjects];
    context.eventsAfter = [self eventsOf:after];
    context.start = beforeStart > 0 ? [NSString stringWithFormat:@"%ld", (long)[self countOf:before.firstObject]] : nil;
    context.end = index + afterCount + 1 < _history.count ? [NSString stringWithFormat:@"%ld", (long)[self countOf:(after.lastObject ?: _history[index])]] : nil;
    context.state = @[];
    dispatch_async(dispatch_get_main_queue(), ^{ success(context); });
    return [MXHTTPOperation new];
}

- (MXHTTPOperation *)relationsForEvent:(NSString *)eventId inRoom:(NSString *)roomId relationType:(NSString *)relationType
                             eventType:(NSString *)eventType from:(NSString *)from direction:(MXTimelineDirection)direction
                                 limit:(NSInteger)limit
                               success:(void (^)(MXAggregationPaginatedResponse *))success failure:(void (^)(NSError *))failure
{
    [_requests addObject:[NSString stringWithFormat:@"relations %@ %@", direction == MXTimelineDirectionBackwards ? @"b" : @"f", from ?: @"-"]];
    NSInteger anchor = from.length ? from.integerValue : NSIntegerMax;
    NSDictionary *root;
    NSMutableArray *replies = [NSMutableArray array];
    for (NSDictionary *json in _history.reverseObjectEnumerator)
    {
        if ([json[@"event_id"] isEqualToString:eventId]) root = json;
        NSDictionary *relation = json[@"content"][@"m.relates_to"];
        if ([relation[@"event_id"] isEqualToString:eventId] && [self countOf:json] < anchor) [replies addObject:json];
    }
    NSArray *chunk = [replies subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)limit, replies.count))];
    NSString *next = replies.count > chunk.count ? [NSString stringWithFormat:@"%ld", (long)[self countOf:chunk.lastObject]] : nil;
    MXAggregationPaginatedResponse *response = [[MXAggregationPaginatedResponse alloc]
                                                initWithOriginalEvent:[MXEvent modelFromJSON:root] chunk:[self eventsOf:chunk] nextBatch:next];
    dispatch_async(dispatch_get_main_queue(), ^{ success(response); });
    return [MXHTTPOperation new];
}

- (MXHTTPOperation *)sendReadReceipt:(NSString *)roomId eventId:(NSString *)eventId threadId:(NSString *)threadId
                             success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    if (success) dispatch_async(dispatch_get_main_queue(), success);
    return [MXHTTPOperation new];
}

- (MXHTTPOperation *)setReadMarker:(NSString *)roomId readMarkerEventId:(NSString *)readMarkerEventId readReceiptEventId:(NSString *)readReceiptEventId
                          threadId:(NSString *)threadId success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    if (success) dispatch_async(dispatch_get_main_queue(), success);
    return [MXHTTPOperation new];
}

@end

#pragma mark - Tests

@interface MXSQLiteTimelineTests : XCTestCase
@end

@implementation MXSQLiteTimelineTests
{
    NSURL *_directory;
    TrscFakeHomeserver *_server;
    MXSession *_session;
    MXSQLiteStore *_store;
    MXRoom *_room;
    BOOL _cryptoWasEnabled;
}

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    _cryptoWasEnabled = MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession;
    MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = NO;
    _directory = [[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"MXSQLiteTimelineTests"]
                  URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _server = [TrscFakeHomeserver new];
    _store = [[MXSQLiteStore alloc] initWithKeyProvider:[MXSQLiteMemoryKeyProvider new] rootDirectory:_directory readOnly:NO];
    _session = [[MXSession alloc] initWithMatrixRestClient:_server];
    [self wait:@"store" block:^(dispatch_block_t done) {
        [self->_session setStore:self->_store success:done failure:^(NSError *error) {
            XCTFail(@"setStore: %@", error);
            done();
        }];
    }];
    _room = [_session getOrCreateRoom:kRoomId];
    _room.summary.membership = MXMembershipJoin;
}

- (void)tearDown
{
    [_session close];
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = _cryptoWasEnabled;
    [super tearDown];
}

#pragma mark Helpers

- (void)wait:(NSString *)what block:(void (^)(dispatch_block_t done))block
{
    XCTestExpectation *expectation = [self expectationWithDescription:what];
    block(^{ [expectation fulfill]; });
    [self waitForExpectations:@[expectation] timeout:20];
}

- (void)sync:(MXRoomSync *)roomSync
{
    [self wait:@"sync" block:^(dispatch_block_t done) {
        [self->_room handleJoinedRoomSync:roomSync onComplete:done];
    }];
    [self commit];
}

- (void)commit
{
    [self wait:@"commit" block:^(dispatch_block_t done) {
        [self->_store commitWithCompletion:done];
    }];
}

- (id<MXEventTimeline>)liveTimeline
{
    __block id<MXEventTimeline> timeline;
    [self wait:@"live timeline" block:^(dispatch_block_t done) {
        [self->_room liveTimeline:^(id<MXEventTimeline> live) {
            timeline = live;
            done();
        }];
    }];
    return timeline;
}

/// Ids событий, которые лента отдала слушателю за одну пагинацию, в порядке выдачи.
- (NSArray<NSString *> *)paginate:(id<MXEventTimeline>)timeline count:(NSUInteger)count direction:(MXTimelineDirection)direction
{
    NSMutableArray<NSString *> *delivered = [NSMutableArray array];
    MXEventListener *listener = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection eventDirection, MXRoomState *state) {
        if (eventDirection == direction) [delivered addObject:event.eventId];
    }];
    [self wait:@"paginate" block:^(dispatch_block_t done) {
        [timeline paginate:count direction:direction onlyFromStore:NO complete:done failure:^(NSError *error) {
            XCTFail(@"paginate: %@", error);
            done();
        }];
    }];
    [timeline removeListener:listener];
    return delivered;
}

- (NSArray<NSString *> *)paginateToEnd:(id<MXEventTimeline>)timeline direction:(MXTimelineDirection)direction page:(NSUInteger)page
{
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSUInteger guard = 0; [timeline canPaginate:direction] && guard < 100; guard++)
    {
        NSArray *got = [self paginate:timeline count:page direction:direction];
        [all addObjectsFromArray:got];
    }
    XCTAssertFalse([timeline canPaginate:direction]);
    return all;
}

- (NSArray<NSString *> *)idsFrom:(NSInteger)from to:(NSInteger)to
{
    NSMutableArray *ids = [NSMutableArray array];
    NSInteger step = from <= to ? 1 : -1;
    for (NSInteger count = from; ; count += step)
    {
        [ids addObject:[TrscFakeHomeserver idOfCount:count]];
        if (count == to) break;
    }
    return ids;
}

- (NSArray<NSString *> *)messageRequests
{
    return [_server.requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'messages'"]];
}

#pragma mark Back pagination through holes

/// Первый синк ограничен: в базе 20 последних, ниже дыра до начала. Пагинация назад — сначала стор,
/// затем сервер от trsc.count нижнего события; каждое событие ровно один раз и по порядку.
- (void)testBackPaginationReadsStoreThenFillsHoleFromServer
{
    [_server appendMessagesFrom:1 to:300];
    [self sync:[_server syncFrom:281 to:300 limited:YES]];

    id<MXEventTimeline> timeline = [self liveTimeline];
    [timeline resetPagination];
    NSArray *first = [self paginate:timeline count:50 direction:MXTimelineDirectionBackwards];
    XCTAssertEqualObjects(first, [self idsFrom:300 to:251]);
    XCTAssertEqualObjects(self.messageRequests, @[@"messages b 281"], @"the hole is asked from trsc.count of its upper event");

    NSArray *rest = [self paginateToEnd:timeline direction:MXTimelineDirectionBackwards page:50];
    XCTAssertEqualObjects(rest, [self idsFrom:250 to:1]);
    [self commit];

    // Дыра закрыта: новая лента читает всю историю из стора, без сети.
    [_server.requests removeAllObjects];
    [timeline resetPagination];
    NSArray *again = [self paginateToEnd:timeline direction:MXTimelineDirectionBackwards page:100];
    XCTAssertEqualObjects(again, [self idsFrom:300 to:1]);
    XCTAssertEqual(self.messageRequests.count, 0u);
}

/// Пропуск синка (limited) оставляет дыру между старым живым краем и новой пачкой.
/// Пагинация назад проходит пачку, догружает дыру с сервера и продолжает старую историю из стора.
- (void)testGappySyncLeavesHoleAndBackPaginationCrossesItWithoutDuplicates
{
    [_server appendMessagesFrom:1 to:100];
    [self sync:[_server syncFrom:1 to:100 limited:NO]];
    [_server appendMessagesFrom:101 to:250];
    [self sync:[_server syncFrom:231 to:250 limited:YES]];

    NSArray<MXRoomHole *> *holes = [_store holesInRoom:kRoomId thread:nil];
    XCTAssertEqual(holes.count, 1u);
    XCTAssertEqual(holes.firstObject.lowerOrder, 100);
    XCTAssertEqual(holes.firstObject.upperOrder, 231);

    id<MXEventTimeline> timeline = [self liveTimeline];
    [timeline resetPagination];
    NSArray *all = [self paginateToEnd:timeline direction:MXTimelineDirectionBackwards page:40];
    XCTAssertEqualObjects(all, [self idsFrom:250 to:1]);
    for (NSString *request in self.messageRequests)
    {
        NSInteger from = [[request componentsSeparatedByString:@" "].lastObject integerValue];
        XCTAssertGreaterThan(from, 100, @"%@: the stored history below the hole is not asked again", request);
    }
    XCTAssertEqual([_store holesInRoom:kRoomId thread:nil].count, 0u);
}

/// Лента только из стора: onlyFromStore не ходит в сеть даже при дыре.
- (void)testOnlyFromStoreStopsAtHole
{
    [_server appendMessagesFrom:1 to:100];
    [self sync:[_server syncFrom:71 to:100 limited:YES]];
    id<MXEventTimeline> timeline = [self liveTimeline];
    [timeline resetPagination];
    NSMutableArray *delivered = [NSMutableArray array];
    MXEventListener *listener = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        [delivered addObject:event.eventId];
    }];
    [self wait:@"paginate" block:^(dispatch_block_t done) {
        [timeline paginate:50 direction:MXTimelineDirectionBackwards onlyFromStore:YES complete:done failure:^(NSError *error) {
            XCTFail(@"%@", error);
            done();
        }];
    }];
    [timeline removeListener:listener];
    XCTAssertEqualObjects(delivered, [self idsFrom:100 to:71]);
    XCTAssertEqual(_server.requests.count, 0u);
    XCTAssertTrue([timeline canPaginate:MXTimelineDirectionBackwards], @"the hole below is still there");
}

#pragma mark Jump to an event

/// Прыжок к событию, которого нет в базе: /context кладёт окно в общий стор между двумя дырами.
/// Вперёд лента догружает дыру до живого края и срастается с ним; назад — до начала истории.
- (void)testJumpToUnknownEventStoresWindowAndForwardPaginationMeetsLiveEdge
{
    [_server appendMessagesFrom:1 to:300];
    [self sync:[_server syncFrom:281 to:300 limited:YES]];

    id<MXEventTimeline> past = [_room timelineOnEvent:[TrscFakeHomeserver idOfCount:100]];
    NSMutableArray<NSString *> *window = [NSMutableArray array];
    MXEventListener *listener = [past listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        [window addObject:event.eventId];
    }];
    [self wait:@"jump" block:^(dispatch_block_t done) {
        [past resetPaginationAroundInitialEventWithLimit:20 success:done failure:^(NSError *error) {
            XCTFail(@"%@", error);
            done();
        }];
    }];
    [past removeListener:listener];
    XCTAssertEqualObjects(_server.requests, @[@"context $e100"]);
    XCTAssertEqual(window.count, 21u);
    XCTAssertEqualObjects([NSSet setWithArray:window], [NSSet setWithArray:[self idsFrom:90 to:110]]);
    XCTAssertTrue([_store eventExistsWithEventId:[TrscFakeHomeserver idOfCount:100] inRoom:kRoomId], @"the window lives in the shared store");
    XCTAssertEqual([_store holesInRoom:kRoomId thread:nil].count, 2u, @"below the window and between it and the live part");

    NSArray *forwards = [self paginateToEnd:past direction:MXTimelineDirectionForwards page:50];
    XCTAssertEqualObjects(forwards, [self idsFrom:111 to:300], @"forward pagination grows into the live timeline without duplicates");
    NSArray *backwards = [self paginateToEnd:past direction:MXTimelineDirectionBackwards page:50];
    XCTAssertEqualObjects(backwards, [self idsFrom:89 to:1]);
    [self commit];
    XCTAssertEqual([_store holesInRoom:kRoomId thread:nil].count, 0u);
    [past destroy];
    XCTAssertTrue([_store eventExistsWithEventId:[TrscFakeHomeserver idOfCount:100] inRoom:kRoomId], @"destroy keeps the shared store");
}

/// Прыжок к событию, которое уже в базе: окно читается из стора, сети нет.
- (void)testJumpToStoredEventReadsWindowFromStore
{
    [_server appendMessagesFrom:1 to:200];
    [self sync:[_server syncFrom:1 to:200 limited:NO]];
    [_server.requests removeAllObjects];

    id<MXEventTimeline> past = [_room timelineOnEvent:[TrscFakeHomeserver idOfCount:150]];
    NSMutableArray<NSString *> *window = [NSMutableArray array];
    MXEventListener *listener = [past listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        [window addObject:event.eventId];
    }];
    [self wait:@"jump" block:^(dispatch_block_t done) {
        [past resetPaginationAroundInitialEventWithLimit:20 success:done failure:^(NSError *error) {
            XCTFail(@"%@", error);
            done();
        }];
    }];
    [past removeListener:listener];
    XCTAssertEqual(_server.requests.count, 0u);
    XCTAssertTrue([window containsObject:[TrscFakeHomeserver idOfCount:150]]);
    NSArray *forwards = [self paginateToEnd:past direction:MXTimelineDirectionForwards page:30];
    NSArray *backwards = [self paginateToEnd:past direction:MXTimelineDirectionBackwards page:30];
    NSMutableSet *seen = [NSMutableSet setWithArray:window];
    [seen addObjectsFromArray:forwards];
    [seen addObjectsFromArray:backwards];
    XCTAssertEqual(window.count + forwards.count + backwards.count, 200u, @"no duplicates");
    XCTAssertEqual(seen.count, 200u);
    XCTAssertEqualObjects(forwards.lastObject, [TrscFakeHomeserver idOfCount:200]);
    XCTAssertEqualObjects(backwards.lastObject, [TrscFakeHomeserver idOfCount:1]);
    XCTAssertEqual(_server.requests.count, 0u);
}

#pragma mark Echo

/// Своё сообщение: эхо в исходящих, серверное событие с тем же transaction_id — одна строка в базе,
/// исходящее снято, слушатель ленты получает событие один раз.
- (void)testEchoAndServerEventAreOneRow
{
    [_server appendMessagesFrom:1 to:10];
    [self sync:[_server syncFrom:1 to:10 limited:NO]];
    id<MXEventTimeline> timeline = [self liveTimeline];

    MXEvent *echo = [_room addLocalEchoForMessageContent:@{@"msgtype": kMXMessageTypeText, @"body": @"mine"}
                                               eventType:kMXEventTypeStringRoomMessage
                                               withState:MXEventSentStateSending
                                                threadId:nil];
    [self commit];
    XCTAssertEqual(_room.outgoingMessages.count, 1u);

    NSDictionary *json = [_server appendMessage:11 thread:nil sender:kMe txnId:echo.eventId];
    NSMutableDictionary *mine = [json mutableCopy];
    NSMutableDictionary *content = [json[@"content"] mutableCopy];
    content[@"body"] = @"mine";
    mine[@"content"] = content;
    _server.history[_server.history.count - 1] = mine;

    NSMutableArray *live = [NSMutableArray array];
    MXEventListener *listener = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        if (direction == MXTimelineDirectionForwards && event.eventId) [live addObject:event.eventId];
    }];
    [self sync:[_server syncFrom:11 to:11 limited:NO]];
    [timeline removeListener:listener];

    XCTAssertEqualObjects(live, @[[TrscFakeHomeserver idOfCount:11]]);
    XCTAssertEqual(_room.outgoingMessages.count, 0u, @"the echo is consumed by the server event");
    MXStorePage *page = [_store latestPageInRoom:kRoomId thread:nil limit:50 types:nil];
    NSArray *bodies = [page.events valueForKeyPath:@"content.body"];
    XCTAssertEqual([bodies indexesOfObjectsPassingTest:^BOOL(id body, NSUInteger idx, BOOL *stop) { return [body isEqual:@"mine"]; }].count, 1u);
    XCTAssertFalse([_store eventExistsWithEventId:echo.eventId inRoom:kRoomId]);

    [timeline resetPagination];
    NSArray *back = [self paginate:timeline count:50 direction:MXTimelineDirectionBackwards];
    XCTAssertEqualObjects(back, [self idsFrom:11 to:1]);
}

#pragma mark Threads

/// Тред с дырой: в базе только хвост (последний ответ — из ограниченного синка), остальное — /relations
/// от trsc.count нижнего ответа. Корень завершает тред. Вторая лента того же треда читает стор без сети.
- (void)testThreadTimelineFillsHoleFromRelations
{
    NSString *root = [TrscFakeHomeserver idOfCount:50];
    for (NSInteger count = 1; count <= 300; count++)
    {
        BOOL reply = count == 60 || count == 120 || count == 200 || count == 290;
        [_server appendMessage:count thread:reply ? root : nil sender:kPeer txnId:nil];
    }
    [self sync:[_server syncFrom:281 to:300 limited:YES]];

    MXThread *thread = [_session.threadingService createTempThreadWithId:root roomId:kRoomId];
    MXThreadEventTimeline *timeline = [[MXThreadEventTimeline alloc] initWithThread:thread andInitialEventId:nil];
    [timeline resetPagination];
    NSArray *all = [self paginateToEnd:timeline direction:MXTimelineDirectionBackwards page:10];
    NSArray *expected = @[[TrscFakeHomeserver idOfCount:290], [TrscFakeHomeserver idOfCount:200],
                          [TrscFakeHomeserver idOfCount:120], [TrscFakeHomeserver idOfCount:60], root];
    XCTAssertEqualObjects(all, expected);
    XCTAssertEqualObjects(_server.requests, @[@"relations b 290"]);
    [self commit];

    [_server.requests removeAllObjects];
    MXThreadEventTimeline *again = [[MXThreadEventTimeline alloc] initWithThread:thread andInitialEventId:nil];
    [again resetPagination];
    XCTAssertEqualObjects([self paginateToEnd:again direction:MXTimelineDirectionBackwards page:10], expected);
    XCTAssertEqual(_server.requests.count, 0u, @"the thread is complete in the store");
}

/// Непрочитанные треда и квитанция в треде — по позициям в базе.
- (void)testThreadReceiptAndUnreadCountFromStore
{
    NSString *root = [TrscFakeHomeserver idOfCount:1];
    [_server appendMessage:1 thread:nil sender:kPeer txnId:nil];
    for (NSInteger count = 2; count <= 6; count++) [_server appendMessage:count thread:root sender:kPeer txnId:nil];
    [self sync:[_server syncFrom:1 to:6 limited:NO]];

    MXEvent *third = [_store eventWithEventId:[TrscFakeHomeserver idOfCount:3] inRoom:kRoomId];
    [_room acknowledgeEvent:third andUpdateReadMarker:NO];
    [self commit];
    MXReceiptData *receipt = [_store getReceiptInRoom:kRoomId threadId:root forUserId:kMe];
    XCTAssertEqualObjects(receipt.eventId, third.eventId);
    XCTAssertEqual([_store localUnreadEventCount:kRoomId threadId:root withTypeIn:_session.unreadEventTypes], 3u);

    // Более старое событие квитанцию назад не двигает.
    [_room acknowledgeEvent:[_store eventWithEventId:[TrscFakeHomeserver idOfCount:2] inRoom:kRoomId] andUpdateReadMarker:NO];
    XCTAssertEqualObjects([_store getReceiptInRoom:kRoomId threadId:root forUserId:kMe].eventId, third.eventId);
}

#pragma mark Room receipts and read marker

/// Неподтверждаемое событие (свой тип вне acknowledgableEventTypes): квитанция встаёт на последнее
/// подтверждаемое событие не новее него (по ord).
- (void)testReceiptMovesToLatestAcknowledgeableEventByOrder
{
    [_server appendMessagesFrom:1 to:5];
    NSMutableDictionary *reaction = [@{
        @"event_id": @"$custom",
        @"room_id": kRoomId,
        @"type": @"org.example.custom",
        @"sender": kPeer,
        @"origin_server_ts": @(TrscFakeNowMs() - (100000 - 6) * 1000),
        @"content": @{@"value": @1},
        @"unsigned": @{@"trsc.count": @"6"},
    } mutableCopy];
    [_server.history addObject:reaction];
    [self sync:[_server syncFrom:1 to:6 limited:NO]];

    [_room acknowledgeEvent:[_store eventWithEventId:@"$custom" inRoom:kRoomId] andUpdateReadMarker:NO];
    [self commit];
    XCTAssertEqualObjects([_store getReceiptInRoom:kRoomId threadId:kMXEventTimelineMain forUserId:kMe].eventId, @"$e5");
}

/// «Прочитать всё»: маркер и квитанция — на самом новом событии комнаты.
- (void)testMarkAllAsReadUsesLatestEvent
{
    [_server appendMessagesFrom:1 to:30];
    [self sync:[_server syncFrom:1 to:30 limited:NO]];
    [_room acknowledgeEvent:[_store eventWithEventId:@"$e10" inRoom:kRoomId] andUpdateReadMarker:NO];
    [self commit];
    [_room markAllAsRead];
    [self commit];
    XCTAssertEqualObjects([_store getReceiptInRoom:kRoomId threadId:kMXEventTimelineMain forUserId:kMe].eventId, @"$e30");
}

/// Прокладка для экрана чата на MXRoomHistoryGap (до iP10): разрыв = дыра стора, догрузка — та же applyPage.
- (void)testHistoryGapShimFillsHoleThroughTimelineStore
{
    [_server appendMessagesFrom:1 to:100];
    [self sync:[_server syncFrom:1 to:100 limited:NO]];
    [_server appendMessagesFrom:101 to:250];
    [self sync:[_server syncFrom:231 to:250 limited:YES]];
    MXRoomHistoryGap *gap = [_store historyGapsForRoom:kRoomId].firstObject;
    XCTAssertNotNil(gap);

    MXRoomEventTimeline *timeline = (MXRoomEventTimeline *)[self liveTimeline];
    __block NSArray<MXEvent *> *delivered;
    [self wait:@"gap" block:^(dispatch_block_t done) {
        [timeline paginateHistoryGap:gap.gapId success:^(NSArray<MXEvent *> *events) {
            delivered = events;
            done();
        } failure:^(NSError *error) {
            XCTFail(@"%@", error);
            done();
        }];
    }];
    XCTAssertEqualObjects([delivered valueForKey:@"eventId"], [self idsFrom:230 to:181]);
    XCTAssertEqualObjects(self.messageRequests, @[@"messages b 231"]);
    MXRoomHole *left = [_store holesInRoom:kRoomId thread:nil].firstObject;
    XCTAssertEqual(left.lowerOrder, 100);
    XCTAssertEqual(left.upperOrder, 181);
}

#pragma mark Legacy store

/// Стор без MXTimelineStore (флаг TrscFeatures.sqliteStore выключен → MXFileStore): прежний путь.
/// Прыжок всегда идёт в /context и держит окно в своём MXMemoryStore, общий стор не трогает.
- (void)testStoreWithoutTimelineContractKeepsLegacyPath
{
    [_session close];
    _session = [[MXSession alloc] initWithMatrixRestClient:_server];
    MXMemoryStore *memory = [MXMemoryStore new];
    [self wait:@"store" block:^(dispatch_block_t done) {
        [self->_session setStore:memory success:done failure:^(NSError *error) {
            XCTFail(@"setStore: %@", error);
            done();
        }];
    }];
    _room = [_session getOrCreateRoom:kRoomId];
    _room.summary.membership = MXMembershipJoin;
    [_server appendMessagesFrom:1 to:20];
    [self wait:@"sync" block:^(dispatch_block_t done) {
        [self->_room handleJoinedRoomSync:[self->_server syncFrom:1 to:20 limited:NO] onComplete:done];
    }];

    id<MXEventTimeline> timeline = [self liveTimeline];
    [timeline resetPagination];
    XCTAssertEqual(timeline.remainingMessagesForBackPaginationInStore, 20u, @"the legacy enumerator over the whole room");

    id<MXEventTimeline> past = [_room timelineOnEvent:[TrscFakeHomeserver idOfCount:10]];
    [self wait:@"jump" block:^(dispatch_block_t done) {
        [past resetPaginationAroundInitialEventWithLimit:6 success:done failure:^(NSError *error) {
            XCTFail(@"%@", error);
            done();
        }];
    }];
    XCTAssertEqualObjects(_server.requests, @[@"context $e10"], @"the legacy path asks /context even for a stored event");
    XCTAssertEqual([memory messagesEnumeratorForRoom:kRoomId].remaining, 20u, @"the window does not go into the session store");
    [past destroy];
}

@end
