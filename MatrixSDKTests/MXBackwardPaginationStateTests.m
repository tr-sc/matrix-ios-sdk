// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import <XCTest/XCTest.h>

#import <MatrixSDK/MatrixSDK.h>
#import "MXRoomEventTimeline.h"

@interface MXRoomEventTimeline (MXBackwardPaginationStateTests)
- (void)handleJoinedRoomSync:(MXRoomSync *)roomSync onComplete:(void (^)(void))onComplete;
@end

@interface MXRoomSummary (MXBackwardPaginationStateTests)
- (MXHTTPOperation *)fetchLastMessageWithMaxServerPaginationCount:(NSUInteger)maxServerPaginationCount
                                                       onComplete:(void (^)(void))onComplete
                                                          failure:(void (^)(NSError *))failure
                                                         timeline:(id<MXEventTimeline>)timeline
                                                        operation:(MXHTTPOperation *)operation
                                                           commit:(BOOL)commit;
@end

@interface MXBackwardPaginationTestRestClient : MXRestClient
@property (nonatomic, copy) void (^pageSuccess)(MXPaginationResponse *);
@property (nonatomic, copy) void (^pageFailure)(NSError *);
@property (nonatomic) NSUInteger requestCount;
@property (nonatomic, copy) NSString *requestedFrom;
@property (nonatomic) NSInteger requestedLimit;
@property (nonatomic, strong) MXHTTPOperation *lastOperation;
@end

@implementation MXBackwardPaginationTestRestClient

- (MXHTTPOperation *)messagesForRoom:(NSString *)roomId
                                from:(NSString *)from
                           direction:(MXTimelineDirection)direction
                               limit:(NSInteger)limit
                              filter:(MXRoomEventFilter *)filter
                             success:(void (^)(MXPaginationResponse *))success
                             failure:(void (^)(NSError *))failure
{
    self.requestCount += 1;
    self.requestedFrom = from;
    self.requestedLimit = limit;
    self.pageSuccess = success;
    self.pageFailure = failure;
    self.lastOperation = [MXHTTPOperation new];
    return self.lastOperation;
}

@end

@interface MXLegacyOnlyMemoryStore : MXMemoryStore
@end

@implementation MXLegacyOnlyMemoryStore

- (BOOL)respondsToSelector:(SEL)aSelector
{
    if (aSelector == @selector(storeBackwardPaginationStateForRoom:state:)
        || aSelector == @selector(backwardPaginationStateForRoom:))
    {
        return NO;
    }
    return [super respondsToSelector:aSelector];
}

@end

@interface MXBackwardPaginationTestSession : MXSession
@property (nonatomic, strong) MXMemoryStore *testStore;
@property (nonatomic, strong) MXRoomSummary *testSummary;
@property (nonatomic, weak) MXRoom *testRoom;
@end

@implementation MXBackwardPaginationTestSession

- (id<MXStore>)store
{
    return self.testStore;
}

- (MXRoomSummary *)roomSummaryWithRoomId:(NSString *)roomId
{
    return self.testSummary;
}

- (BOOL)hasRoomWithRoomId:(NSString *)roomId
{
    return YES;
}

- (MXRoom *)roomWithRoomId:(NSString *)roomId
{
    return self.testRoom;
}

@end

@interface MXSynchronousDecryptionRoomEventTimeline : MXRoomEventTimeline
@end

@implementation MXSynchronousDecryptionRoomEventTimeline

- (void)decryptEvents:(NSArray<MXEvent *> *)events onComplete:(dispatch_block_t)completion
{
    completion();
}

- (void)decryptEvents:(NSArray<MXEvent *> *)events
ifNewerThanTimestamp:(uint64_t)timestamp
            onComplete:(dispatch_block_t)completion
{
    completion();
}

@end

@interface MXBackwardPaginationFixture : NSObject
@property (nonatomic, readonly) NSString *roomId;
@property (nonatomic, strong, readonly) MXBackwardPaginationTestRestClient *restClient;
@property (nonatomic, strong, readonly) MXBackwardPaginationTestSession *session;
@property (nonatomic, strong, readonly) MXMemoryStore *store;
@property (nonatomic, strong, readonly) MXRoom *room;
@property (nonatomic, strong, readonly) MXSynchronousDecryptionRoomEventTimeline *timeline;
- (instancetype)initWithStore:(MXMemoryStore *)store;
- (void)respondWithEvents:(NSArray<MXEvent *> *)events end:(NSString *)end;
- (void)failWithError:(NSError *)error;
@end

@implementation MXBackwardPaginationFixture

- (instancetype)init
{
    return [self initWithStore:[MXMemoryStore new]];
}

- (instancetype)initWithStore:(MXMemoryStore *)store
{
    self = [super init];
    if (self)
    {
        _roomId = @"!backward-pagination:example.org";
        MXCredentials *credentials = [[MXCredentials alloc] initWithHomeServer:@"https://example.org"
                                                                        userId:@"@me:example.org"
                                                                   accessToken:@"token"];
        _restClient = [[MXBackwardPaginationTestRestClient alloc]
                       initWithCredentials:credentials
                       andOnUnrecognizedCertificateBlock:nil];
        _session = [[MXBackwardPaginationTestSession alloc] initWithMatrixRestClient:_restClient];
        _store = store;
        _session.testStore = _store;
        _session.testSummary = [[MXRoomSummary alloc] initWithRoomId:_roomId andMatrixSession:_session];
        _session.testSummary.membership = MXMembershipJoin;
        _room = [[MXRoom alloc] initWithRoomId:_roomId matrixSession:_session andStore:_store];
        _session.testRoom = _room;
        _timeline = [[MXSynchronousDecryptionRoomEventTimeline alloc] initWithRoom:_room
                                                                    initialEventId:nil
                                                                          andStore:_store];
        [_store storePaginationTokenOfRoom:_roomId andToken:@"cursor-0"];
        [_store storeBackwardPaginationStateForRoom:_roomId state:MXRoomBackwardPaginationStateUnknown];
        [_timeline resetPagination];
    }
    return self;
}

- (void)respondWithEvents:(NSArray<MXEvent *> *)events end:(NSString *)end
{
    NSMutableArray *chunk = [NSMutableArray arrayWithCapacity:events.count];
    for (MXEvent *event in events)
    {
        [chunk addObject:event.JSONDictionary];
    }

    NSMutableDictionary *json = [@{
        @"start": @"cursor-0",
        @"chunk": chunk,
        @"state": @[]
    } mutableCopy];
    if (end)
    {
        json[@"end"] = end;
    }

    MXPaginationResponse *response = [MXPaginationResponse modelFromJSON:json];
    void (^success)(MXPaginationResponse *) = self.restClient.pageSuccess;
    self.restClient.pageSuccess = nil;
    self.restClient.pageFailure = nil;
    if (success)
    {
        success(response);
    }
}

- (void)failWithError:(NSError *)error
{
    void (^failure)(NSError *) = self.restClient.pageFailure;
    self.restClient.pageSuccess = nil;
    self.restClient.pageFailure = nil;
    if (failure)
    {
        failure(error);
    }
}

@end

@interface MXBackwardPaginationStateTests : XCTestCase
@end

@implementation MXBackwardPaginationStateTests

- (MXBackwardPaginationFixture *)newFixture
{
    return [self newFixtureWithStore:[MXMemoryStore new]];
}

- (MXBackwardPaginationFixture *)newFixtureWithStore:(MXMemoryStore *)store
{
    MXBackwardPaginationFixture *fixture = [[MXBackwardPaginationFixture alloc] initWithStore:store];
    [self addTeardownBlock:^{
        [fixture.session close];
    }];
    return fixture;
}

- (MXEvent *)eventWithIndex:(NSUInteger)index
{
    return [MXEvent modelFromJSON:@{
        @"event_id": [NSString stringWithFormat:@"$event-%tu", index],
        @"room_id": @"!backward-pagination:example.org",
        @"sender": @"@alice:example.org",
        @"origin_server_ts": @(index + 1),
        @"type": @"m.room.message",
        @"content": @{
            @"msgtype": @"m.text",
            @"body": [NSString stringWithFormat:@"Message %tu", index]
        }
    }];
}

- (MXRoomSync *)slidingSyncInitialRoomWithEventCount:(NSUInteger)eventCount
{
    return [self slidingSyncRoomWithInitial:YES eventCount:eventCount limited:nil prevBatch:nil];
}

- (MXRoomSync *)slidingSyncRoomWithInitial:(BOOL)initial
                                eventCount:(NSUInteger)eventCount
                                   limited:(NSNumber *)limited
                                  prevBatch:(NSString *)prevBatch
{
    NSMutableArray *timeline = [NSMutableArray arrayWithCapacity:eventCount];
    for (NSUInteger index = 0; index < eventCount; index++)
    {
        [timeline addObject:[self eventWithIndex:index].JSONDictionary];
    }

    NSMutableDictionary *roomJSON = [@{
        @"membership": @"join",
        @"initial": @(initial),
        @"timeline": timeline
    } mutableCopy];
    if (limited)
    {
        roomJSON[@"limited"] = limited;
    }
    if (prevBatch)
    {
        roomJSON[@"prev_batch"] = prevBatch;
    }

    MXSlidingSyncResponse *response = [MXSlidingSyncResponse modelFromJSON:@{
        @"pos": @"sliding-pos-1",
        @"lists": @{},
        @"rooms": @{
            @"!backward-pagination:example.org": roomJSON
        },
        @"extensions": @{}
    }];
    MXSyncResponse *legacy = [response legacySyncResponseForUserId:@"@me:example.org"];
    return legacy.rooms.join[@"!backward-pagination:example.org"];
}

- (MXRoomSync *)legacyRoomSyncWithLimited:(BOOL)limited prevBatch:(NSString *)prevBatch
{
    NSMutableDictionary *timeline = [@{
        @"events": @[],
        @"limited": @(limited)
    } mutableCopy];
    if (prevBatch)
    {
        timeline[@"prev_batch"] = prevBatch;
    }

    return [MXRoomSync modelFromJSON:@{
        @"state": @{ @"events": @[] },
        @"timeline": timeline
    }];
}

- (void)testSlidingSyncInitialWithoutLimitedAndKnownMembershipAllowsOneServerRequest
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    MXRoomSync *roomSync = [self slidingSyncInitialRoomWithEventCount:3];

    __block BOOL syncCompleted = NO;
    [fixture.timeline handleJoinedRoomSync:roomSync onComplete:^{
        syncCompleted = YES;
    }];

    XCTAssertTrue(syncCompleted);
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateUnknown);
    XCTAssertTrue([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);

    [fixture.timeline resetPagination];
    __block BOOL paginationCompleted = NO;
    [fixture.timeline paginate:4
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ paginationCompleted = YES; }
                       failure:^(NSError *error) { XCTFail(@"Unexpected pagination error: %@", error); }];

    XCTAssertEqual(fixture.restClient.requestCount, 1u);
    XCTAssertEqualObjects(fixture.restClient.requestedFrom, @"cursor-0");
    [fixture respondWithEvents:@[] end:@"cursor-1"];
    XCTAssertTrue(paginationCompleted);
}

- (void)testLegacyOnlyStoreUsesBooleanFallbackForBackwardPaginationState
{
    MXLegacyOnlyMemoryStore *store = [MXLegacyOnlyMemoryStore new];
    MXBackwardPaginationFixture *fixture = [self newFixtureWithStore:store];

    [store storeHasReachedHomeServerPaginationEndForRoom:fixture.roomId andValue:NO];
    XCTAssertTrue([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);

    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{}
                       failure:^(NSError *error) { XCTFail(@"Unexpected pagination error: %@", error); }];
    [fixture respondWithEvents:@[] end:nil];

    XCTAssertTrue([store hasReachedHomeServerPaginationEndForRoom:fixture.roomId]);
    XCTAssertFalse([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);

    [store storeHasReachedHomeServerPaginationEndForRoom:fixture.roomId andValue:NO];
    XCTAssertTrue([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);
}

- (void)testSlidingSyncInitialWithCursorFillsMissingTokenAndBecomesAvailable
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    [fixture.store deleteAllMessagesInRoom:fixture.roomId];
    MXRoomSync *roomSync = [self slidingSyncRoomWithInitial:YES
                                                eventCount:2
                                                   limited:nil
                                                  prevBatch:@"sliding-cursor"];

    [fixture.timeline handleJoinedRoomSync:roomSync onComplete:^{}];

    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"sliding-cursor");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
}

- (void)testSlidingSyncInitialPreservesAuthoritativeExhaustedState
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    [fixture.store storeBackwardPaginationStateForRoom:fixture.roomId
                                                 state:MXRoomBackwardPaginationStateExhausted];
    MXRoomSync *roomSync = [self slidingSyncRoomWithInitial:YES
                                                eventCount:2
                                                   limited:nil
                                                  prevBatch:@"shallow-cursor"];

    [fixture.timeline handleJoinedRoomSync:roomSync onComplete:^{}];

    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-0");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateExhausted);
}

- (void)testSlidingSyncIncrementalWithoutLimitedPreservesMessagesAndDeepCursor
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    MXEvent *storedEvent = [self eventWithIndex:99];
    [fixture.store storeEventForRoom:fixture.roomId
                               event:storedEvent
                           direction:MXTimelineDirectionForwards];
    [fixture.store storePaginationTokenOfRoom:fixture.roomId andToken:@"deep-cursor"];
    [fixture.store storeBackwardPaginationStateForRoom:fixture.roomId
                                                 state:MXRoomBackwardPaginationStateAvailable];
    MXRoomSync *roomSync = [self slidingSyncRoomWithInitial:NO
                                                eventCount:1
                                                   limited:nil
                                                  prevBatch:@"shallow-cursor"];

    [fixture.timeline handleJoinedRoomSync:roomSync onComplete:^{}];

    XCTAssertTrue([fixture.store eventExistsWithEventId:storedEvent.eventId inRoom:fixture.roomId]);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"deep-cursor");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
}

- (void)testSlidingSyncExplicitGapFlushesMessagesAndInstallsCursor
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    MXEvent *storedEvent = [self eventWithIndex:99];
    [fixture.store storeEventForRoom:fixture.roomId
                               event:storedEvent
                           direction:MXTimelineDirectionForwards];
    __block BOOL didFlush = NO;
    id observer = [[NSNotificationCenter defaultCenter]
                   addObserverForName:kMXRoomDidFlushDataNotification
                   object:fixture.room
                   queue:nil
                   usingBlock:^(NSNotification *note) { didFlush = YES; }];
    MXRoomSync *roomSync = [self slidingSyncRoomWithInitial:NO
                                                eventCount:1
                                                   limited:@YES
                                                  prevBatch:@"gap-cursor"];

    [fixture.timeline handleJoinedRoomSync:roomSync onComplete:^{}];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];

    XCTAssertFalse([fixture.store eventExistsWithEventId:storedEvent.eventId inRoom:fixture.roomId]);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"gap-cursor");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
    XCTAssertTrue(didFlush);
}

- (void)testLegacyInitialExplicitlyNotLimitedBecomesExhausted
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    fixture.session.testSummary.membership = MXMembershipUnknown;

    [fixture.timeline handleJoinedRoomSync:[self legacyRoomSyncWithLimited:NO prevBatch:nil]
                                onComplete:^{}];

    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateExhausted);
    XCTAssertFalse([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);
}

- (void)testRoomSummaryPreservesAuthoritativeExhaustedState
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    [fixture.store storeBackwardPaginationStateForRoom:fixture.roomId
                                                 state:MXRoomBackwardPaginationStateExhausted];
    [fixture.timeline resetPagination];
    XCTestExpectation *completed = [self expectationWithDescription:@"summary pagination completed"];

    [fixture.session.testSummary fetchLastMessageWithMaxServerPaginationCount:1
                                                                   onComplete:^{ [completed fulfill]; }
                                                                      failure:^(NSError *error) {
        XCTFail(@"Unexpected summary pagination error: %@", error);
        [completed fulfill];
    }
                                                                     timeline:fixture.timeline
                                                                    operation:nil
                                                                       commit:NO];

    [self waitForExpectations:@[completed] timeout:1];
    XCTAssertEqual(fixture.restClient.requestCount, 0u);
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateExhausted);
}

- (void)testEmptyFilteredPageWithAdvancedCursorRemainsAvailable
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    __block BOOL completed = NO;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ completed = YES; }
                       failure:^(NSError *error) { XCTFail(@"Unexpected pagination error: %@", error); }];

    XCTAssertEqual(fixture.restClient.requestCount, 1u);
    [fixture respondWithEvents:@[] end:@"cursor-1"];

    XCTAssertTrue(completed);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-1");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
    XCTAssertTrue([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);
}

- (void)testNonEmptyPageWithoutEndStoresEventsBeforeBecomingExhausted
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    NSArray<MXEvent *> *events = @[[self eventWithIndex:1], [self eventWithIndex:0]];
    __block BOOL completed = NO;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ completed = YES; }
                       failure:^(NSError *error) { XCTFail(@"Unexpected pagination error: %@", error); }];

    [fixture respondWithEvents:events end:nil];

    XCTAssertTrue(completed);
    XCTAssertTrue([fixture.store eventExistsWithEventId:@"$event-0" inRoom:fixture.roomId]);
    XCTAssertTrue([fixture.store eventExistsWithEventId:@"$event-1" inRoom:fixture.roomId]);
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateExhausted);
    XCTAssertFalse([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);
}

- (void)testUnchangedCursorBecomesExhausted
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    __block BOOL completed = NO;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ completed = YES; }
                       failure:^(NSError *error) { XCTFail(@"Unexpected pagination error: %@", error); }];

    [fixture respondWithEvents:@[] end:@"cursor-0"];

    XCTAssertTrue(completed);
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateExhausted);
    XCTAssertFalse([fixture.timeline canPaginate:MXTimelineDirectionBackwards]);
}

- (void)testTransportFailurePreservesStateAndCursor
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    [fixture.store storeBackwardPaginationStateForRoom:fixture.roomId
                                                 state:MXRoomBackwardPaginationStateAvailable];
    __block NSError *receivedError;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ XCTFail(@"Transport failure must not become success"); }
                       failure:^(NSError *error) { receivedError = error; }];

    NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    [fixture failWithError:timeout];

    XCTAssertEqual(receivedError.code, NSURLErrorTimedOut);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-0");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
}

- (void)testAuthenticationFailurePreservesStateAndCursor
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    [fixture.store storeBackwardPaginationStateForRoom:fixture.roomId
                                                 state:MXRoomBackwardPaginationStateAvailable];
    __block NSError *receivedError;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ XCTFail(@"Authentication failure must not become success"); }
                       failure:^(NSError *error) { receivedError = error; }];

    NSError *authenticationError = [[[MXError alloc] initWithErrorCode:kMXErrCodeStringUnknownToken
                                                                  error:@"Expired access token"] createNSError];
    [fixture failWithError:authenticationError];

    XCTAssertEqualObjects(receivedError, authenticationError);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-0");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateAvailable);
}

- (void)testInvalidTokenMessageIsFailureAndDoesNotInventPaginationEnd
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    __block NSError *receivedError;
    [fixture.timeline paginate:30
                     direction:MXTimelineDirectionBackwards
                 onlyFromStore:NO
                      complete:^{ XCTFail(@"Invalid token failure must not become success"); }
                       failure:^(NSError *error) { receivedError = error; }];

    NSError *invalidToken = [[[MXError alloc] initWithErrorCode:kMXErrCodeStringBadPagination
                                                         error:kMXErrorStringInvalidToken] createNSError];
    [fixture failWithError:invalidToken];

    XCTAssertEqualObjects(receivedError, invalidToken);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-0");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateUnknown);
}

- (void)testLateSuccessAfterCancellationDoesNotMutateStore
{
    MXBackwardPaginationFixture *fixture = [self newFixture];
    __block NSError *receivedError;
    MXHTTPOperation *operation = [fixture.timeline paginate:30
                                                     direction:MXTimelineDirectionBackwards
                                                 onlyFromStore:NO
                                                      complete:^{ XCTFail(@"Cancelled pagination must not complete successfully"); }
                                                       failure:^(NSError *error) { receivedError = error; }];

    [operation cancel];
    [fixture respondWithEvents:@[[self eventWithIndex:7]] end:@"cursor-1"];

    XCTAssertEqual(receivedError.code, NSURLErrorCancelled);
    XCTAssertFalse([fixture.store eventExistsWithEventId:@"$event-7" inRoom:fixture.roomId]);
    XCTAssertEqualObjects([fixture.store paginationTokenOfRoom:fixture.roomId], @"cursor-0");
    XCTAssertEqual([fixture.store backwardPaginationStateForRoom:fixture.roomId],
                   MXRoomBackwardPaginationStateUnknown);
}

@end
