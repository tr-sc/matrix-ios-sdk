// Bench of the store wiring (iP9) against the local bench stand, flag off vs on:
//   scripts/ios-store-bench/run-bench.sh --wiring                 flag off: MXFileStore, as the app runs today
//   scripts/ios-store-bench/run-bench.sh --wiring --store sqlite  flag on: MXSQLiteSessionStore + NSE store
//
// Phases (one test, fixed order):
//   prepare  — wipe both stores, login, initial sync, back-paginate every room so the store holds the whole history.
//   list     — cold: new MXSession + new store → setStore success = summaries and rooms mounted, the chat list can be
//              drawn (cold_list_ready).
//   push     — app closed; bench_b sends a message; "NSE" fetches it with /event and (flag on) puts it into the
//              database with the extension store (nse_store_event); then the app opens from the push: new session +
//              store, room timeline, first page from the store. push_chat_open = until the pushed message is on
//              screen; flag on — without network (push_offline = 1), flag off — after the catch-up sync brings it.
//   sync     — live sync; bench_b sends; store_commit = the commit after the sync with the message (data on disk).
// Crypto is off (unencrypted rooms): the bench is about the store. Same process for every "cold" open.

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>

#import "TrscStandSupport.h"

@interface TrscStoreWiringBenchTests : XCTestCase
@end

@implementation TrscStoreWiringBenchTests
{
    TrscStandFixture *_fixture;
    TrscBenchJournal *_journal;
    MXCredentials *_reader;
    MXRestClient *_senderClient;
    BOOL _cryptoWasEnabled;
    BOOL _sqlite;
}

static const NSUInteger kPage = 50;

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    _fixture = [TrscStandFixture load];
    if (!_fixture) return;
    _sqlite = [[TrscStandSupport storeKind] isEqualToString:@"sqlite"];
    _cryptoWasEnabled = MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession;
    MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = NO;
}

- (void)tearDown
{
    if (_fixture) MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = _cryptoWasEnabled;
    [_senderClient close];
    [super tearDown];
}

#pragma mark - Helpers

- (void)wait:(NSString *)what timeout:(NSTimeInterval)timeout block:(void (^)(dispatch_block_t done))block
{
    XCTestExpectation *expectation = [self expectationWithDescription:what];
    block(^{ [expectation fulfill]; });
    [self waitForExpectations:@[expectation] timeout:timeout];
}

- (MXCredentials *)login:(NSString *)user
{
    __block MXCredentials *credentials;
    MXRestClient *client = [[MXRestClient alloc] initWithHomeServer:_fixture.homeserver andOnUnrecognizedCertificateBlock:nil];
    [self wait:[@"login " stringByAppendingString:user] timeout:30 block:^(dispatch_block_t done) {
        [client loginWithLoginType:kMXLoginFlowTypePassword username:user password:self->_fixture.password success:^(MXCredentials *c) {
            credentials = c;
            done();
        } failure:^(NSError *error) {
            XCTFail(@"login %@: %@", user, error);
            done();
        }];
    }];
    credentials.homeServer = credentials.homeServer ?: _fixture.homeserver;
    [client close];
    return credentials;
}

/// The store the app would pick: flag on → MXSQLiteSessionStore, off → MXFileStore.
- (id<MXStore>)makeStore
{
    return _sqlite ? [MXSQLiteSessionStore new] : [MXFileStore new];
}

- (MXSession *)openSession
{
    id<MXStore> store = [TrscTimedStore wrap:[self makeStore]];
    MXRestClient *client = [[MXRestClient alloc] initWithCredentials:_reader andOnUnrecognizedCertificateBlock:nil];
    MXSession *session = [[MXSession alloc] initWithMatrixRestClient:client];
    [self wait:@"store ready" timeout:300 block:^(dispatch_block_t done) {
        [session setStore:store success:done failure:^(NSError *error) {
            XCTFail(@"setStore: %@", error);
            done();
        }];
    }];
    return session;
}

- (void)startSession:(MXSession *)session
{
    [self wait:@"sync" timeout:600 block:^(dispatch_block_t done) {
        [session start:done failure:^(NSError *error) {
            XCTFail(@"sync: %@", error);
            done();
        }];
    }];
}

- (void)commitAndClose:(MXSession *)session
{
    TrscTimedStore *timed = [TrscTimedStore unwrap:session.store];
    [self wait:@"commit" timeout:600 block:^(dispatch_block_t done) {
        [timed commitWithCompletion:done];
    }];
    [session close];
}

- (id<MXEventTimeline>)liveTimelineOf:(MXRoom *)room
{
    __block id<MXEventTimeline> timeline;
    [self wait:@"live timeline" timeout:120 block:^(dispatch_block_t done) {
        [room liveTimeline:^(id<MXEventTimeline> live) {
            timeline = live;
            done();
        }];
    }];
    return timeline;
}

- (NSArray<MXEvent *> *)paginate:(id<MXEventTimeline>)timeline count:(NSUInteger)count onlyFromStore:(BOOL)onlyFromStore reset:(BOOL)reset
{
    NSMutableArray<MXEvent *> *delivered = [NSMutableArray array];
    MXEventListener *listener = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        if (direction == MXTimelineDirectionBackwards) [delivered addObject:event];
    }];
    if (reset) [timeline resetPagination];
    [self wait:@"paginate" timeout:600 block:^(dispatch_block_t done) {
        [timeline paginate:count direction:MXTimelineDirectionBackwards onlyFromStore:onlyFromStore complete:done failure:^(NSError *error) {
            XCTFail(@"paginate: %@", error);
            done();
        }];
    }];
    [timeline removeListener:listener];
    return delivered;
}

- (NSString *)send:(NSString *)body toRoom:(NSString *)roomId
{
    __block NSString *eventId;
    [self wait:@"send" timeout:60 block:^(dispatch_block_t done) {
        [self->_senderClient sendTextMessageToRoom:roomId threadId:nil text:body success:^(NSString *sent) {
            eventId = sent;
            done();
        } failure:^(NSError *error) {
            XCTFail(@"send: %@", error);
            done();
        }];
    }];
    return eventId;
}

- (NSDictionary *)ctxForRoom:(NSDictionary *)room extra:(NSDictionary *)extra
{
    NSMutableDictionary *ctx = [@{@"room_events": room[@"messages"], @"room": room[@"local"],
                                  @"flag": _sqlite ? @"on" : @"off"} mutableCopy];
    [ctx addEntriesFromDictionary:extra ?: @{}];
    return ctx;
}

#pragma mark - Bench

- (void)testWiringBench
{
    if (!_fixture) { XCTSkip(@"no bench stand fixture: run scripts/ios-store-bench/up.sh"); }
    NSInteger iterations = [TrscStandSupport envInt:@"TRSC_BENCH_ITER" fallback:5];
    NSInteger incoming = [TrscStandSupport envInt:@"TRSC_BENCH_INCOMING" fallback:10];
    _journal = [[TrscBenchJournal alloc] initWithStoreKind:_sqlite ? @"sqlite-wired" : @"file-wired"];
    NSLog(@"[TRSC-BENCH] run %@ wiring flag=%@ results=%@", _journal.runId, _sqlite ? @"on" : @"off", _journal.filePath);

    _reader = [self login:_fixture.readerUser];
    MXCredentials *sender = [self login:_fixture.senderUser];
    _senderClient = [[MXRestClient alloc] initWithCredentials:sender andOnUnrecognizedCertificateBlock:nil];

    [self preparePhase];
    [self listPhase:iterations];
    [self pushPhase:iterations];
    [self syncPhase:incoming];
}

- (void)preparePhase
{
    // Both stores of the reader: a run of the other kind must not leave a database or a MXFileStore folder behind.
    MXFileStore *fileStore = [[MXFileStore alloc] initWithCredentials:_reader];
    [fileStore deleteAllData];
    [MXSQLiteSessionStore deactivateForCredentials:_reader rootDirectory:nil
                                       keyProvider:[[MXSQLiteKeychainKeyProvider alloc] initWithAccessGroup:MXSQLiteStore.keychainAccessGroup]];

    MXSession *session = [self openSession];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self startSession:session];
    [_journal record:@"initial_sync" value:(CFAbsoluteTimeGetCurrent() - start) * 1000 unit:@"ms" ctx:@{@"phase": @"prepare"}];
    for (NSDictionary *room in _fixture.rooms)
    {
        id<MXEventTimeline> timeline = [self liveTimelineOf:[session roomWithRoomId:room[@"room_id"]]];
        [self paginate:timeline count:kPage onlyFromStore:NO reset:YES];
        while ([timeline canPaginate:MXTimelineDirectionBackwards])
        {
            if (![self paginate:timeline count:500 onlyFromStore:NO reset:NO].count) break;
        }
    }
    [session pause];
    [self commitAndClose:session];
}

- (void)listPhase:(NSInteger)iterations
{
    for (NSInteger iteration = 0; iteration < iterations; iteration++)
    {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        MXSession *session = [self openSession];
        double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        NSUInteger rooms = MIN(session.rooms.count, session.store.roomSummaryStore.countOfRooms);
        XCTAssertGreaterThanOrEqual(rooms, _fixture.rooms.count, @"the chat list is mounted from the store");
        [_journal record:@"cold_list_ready" value:ms unit:@"ms"
                     ctx:@{@"phase": @"list", @"iteration": @(iteration), @"rooms": @(rooms), @"flag": _sqlite ? @"on" : @"off"}];
        [session close];
    }
}

/// What NSE does with the push: /event, then (flag on) one row in the shared database.
- (double)nseHandlePushOfEvent:(NSString *)eventId inRoom:(NSString *)roomId stored:(BOOL *)stored
{
    MXRestClient *client = [[MXRestClient alloc] initWithCredentials:_reader andOnUnrecognizedCertificateBlock:nil];
    __block MXEvent *event;
    [self wait:@"/event" timeout:30 block:^(dispatch_block_t done) {
        [client eventWithEventId:eventId inRoom:roomId success:^(MXEvent *e) {
            event = e;
            done();
        } failure:^(NSError *error) {
            XCTFail(@"/event: %@", error);
            done();
        }];
    }];
    [client close];
    *stored = NO;
    if (!_sqlite) return 0;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    MXSQLiteStore *nse = [[MXSQLiteStore alloc] initForExtensionWithKeyProvider:[[MXSQLiteKeychainKeyProvider alloc] initWithAccessGroup:MXSQLiteStore.keychainAccessGroup]
                                                                  rootDirectory:nil];
    NSError *error;
    if ([nse openSynchronouslyWithCredentials:_reader error:&error])
    {
        *stored = [nse insertPushEvent:event inRoom:roomId error:&error];
    }
    XCTAssertTrue(*stored, @"NSE did not store the push event: %@", error);
    [nse close];
    return (CFAbsoluteTimeGetCurrent() - start) * 1000;
}

- (void)pushPhase:(NSInteger)iterations
{
    for (NSDictionary *room in _fixture.rooms)
    {
        for (NSInteger iteration = 0; iteration < iterations; iteration++)
        {
            NSString *body = [NSString stringWithFormat:@"bench push %@ %ld %@", room[@"local"], (long)iteration, NSUUID.UUID.UUIDString];
            NSString *eventId = [self send:body toRoom:room[@"room_id"]];
            BOOL stored = NO;
            double nseMs = [self nseHandlePushOfEvent:eventId inRoom:room[@"room_id"] stored:&stored];
            NSDictionary *ctx = [self ctxForRoom:room extra:@{@"phase": @"push", @"iteration": @(iteration)}];
            if (_sqlite) [_journal record:@"nse_store_event" value:nseMs unit:@"ms" ctx:ctx];

            // The app opens from the push tap.
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            MXSession *session = [self openSession];
            id<MXEventTimeline> timeline = [self liveTimelineOf:[session roomWithRoomId:room[@"room_id"]]];
            __block BOOL visible = NO;
            MXEventListener *live = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
                if ([event.eventId isEqualToString:eventId]) visible = YES;
            }];
            NSArray<MXEvent *> *page = [self paginate:timeline count:kPage onlyFromStore:YES reset:YES];
            BOOL offline = [[page valueForKey:@"eventId"] containsObject:eventId];
            if (!offline)
            {
                // Not in the store: the catch-up sync has to bring it.
                [session start:^{} failure:^(NSError *error) { XCTFail(@"sync: %@", error); }];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
                while (!visible && deadline.timeIntervalSinceNow > 0)
                {
                    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
                }
            }
            double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
            [timeline removeListener:live];
            XCTAssertTrue(offline || visible, @"%@: pushed message never shown", room[@"local"]);
            NSMutableDictionary *openCtx = [ctx mutableCopy];
            openCtx[@"offline"] = @(offline);
            [_journal record:@"push_chat_open" value:ms unit:@"ms" ctx:openCtx];
            [_journal record:@"push_offline" value:offline ? 1 : 0 unit:@"bool" ctx:openCtx];
            if (_sqlite) XCTAssertTrue(offline, @"flag on: the pushed message is in the first page without network");

            // Catch up before the next push so every iteration starts from a synced store.
            if (offline) [self startSession:session];
            [session pause];
            [self commitAndClose:session];
        }
    }
}

- (void)syncPhase:(NSInteger)count
{
    MXSession *session = [self openSession];
    [self startSession:session];
    TrscTimedStore *timed = [TrscTimedStore unwrap:session.store];
    __block NSMutableArray<NSNumber *> *commits = [NSMutableArray array];
    timed.onCommitDone = ^(double ms) { [commits addObject:@(ms)]; };
    for (NSDictionary *room in _fixture.rooms)
    {
        id<MXEventTimeline> timeline = [self liveTimelineOf:[session roomWithRoomId:room[@"room_id"]]];
        for (NSInteger i = 0; i < count; i++)
        {
            NSString *body = [NSString stringWithFormat:@"bench sync %@ %ld %@", room[@"local"], (long)i, NSUUID.UUID.UUIDString];
            __block BOOL seen = NO;
            XCTestExpectation *arrived = [self expectationWithDescription:@"incoming"];
            MXEventListener *listener = [timeline listenToEventsOfTypes:@[kMXEventTypeStringRoomMessage] onEvent:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
                if (direction == MXTimelineDirectionForwards && !seen && [event.content[@"body"] isEqual:body])
                {
                    seen = YES;
                    [commits removeAllObjects];
                    [arrived fulfill];
                }
            }];
            [_senderClient sendTextMessageToRoom:room[@"room_id"] threadId:nil text:body success:nil failure:^(NSError *error) {
                XCTFail(@"send: %@", error);
            }];
            [self waitForExpectations:@[arrived] timeout:60];
            [timeline removeListener:listener];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while (!commits.count && deadline.timeIntervalSinceNow > 0)
            {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            XCTAssertTrue(commits.count, @"%@: no commit after the incoming message", room[@"local"]);
            if (commits.count)
            {
                [_journal record:@"store_commit" value:commits.firstObject.doubleValue unit:@"ms"
                             ctx:[self ctxForRoom:room extra:@{@"phase": @"sync", @"i": @(i)}]];
            }
        }
    }
    timed.onCommitDone = nil;
    [session pause];
    [self commitAndClose:session];
}

@end
