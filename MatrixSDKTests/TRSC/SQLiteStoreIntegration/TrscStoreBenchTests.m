// Store benchmark against the local bench stand (iP13). Same test for every store behind MXStore:
//   TEST_RUNNER_TRSC_BENCH_STORE=file|sqlite  scripts/ios-store-bench/run-bench.sh
//
// Rooms: 10 / 1k / 10k / 50k messages (scripts/ios-store-bench/up.sh). Results: JSON lines
// ([TRSC-BENCH] in the test log, ~/trsc-wt/i2-bench-stand/results/<run>.jsonl, the app's perf-events.jsonl),
// summed up by scripts/ios-store-bench/report.py.
//
// Phases, all in one test so the order is fixed:
//   prepare  — fresh store, login, initial /sync, back-paginate every room to its start so the store holds
//              the whole history (as a long-lived account does), wait for the commit; store size.
//   cold     — per room and iteration: new MXSession + new store instance → storeDataReady
//              (cold_store_ready), then 50 rows of that room from the store (chat_open_first, and
//              cold_rows = both together); then the same room again (chat_open_warm).
//   incoming — live /sync running; bench_b sends a message, until it reaches the reader's live timeline
//              listener (msg_live_listener: send start → listener; msg_after_ack: server ack → listener),
//              and the commit that follows (store_commit, call → data on disk).
// Crypto is off: the rooms are unencrypted and the bench is about the store, not about the OLM machine.
// "Cold" is a new session in the same process: the file cache of the OS is warm. A true cold start of the
// app is measured by TrscLaunchMetrics on a device.

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>

#import "TrscStandSupport.h"

@interface TrscStoreBenchTests : XCTestCase
@end

@implementation TrscStoreBenchTests
{
    TrscStandFixture *_fixture;
    TrscBenchJournal *_journal;
    MXCredentials *_reader;
    MXRestClient *_senderClient;
    BOOL _cryptoWasEnabled;
}

static const NSUInteger kPage = 50;

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    _fixture = [TrscStandFixture load];
    if (!_fixture) return;
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

/// Runs `block` with a fulfil callback and waits for it on the main run loop.
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

/// A session over a new store instance, opened up to storeDataReady. Returns the elapsed ms.
- (MXSession *)openSession:(double *)storeReadyMs
{
    id<MXStore> store = [TrscStandSupport makeStore];
    XCTAssertNotNil(store, @"store %@ is not linked", [TrscStandSupport storeKind]);
    store = [TrscTimedStore wrap:store];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    MXRestClient *client = [[MXRestClient alloc] initWithCredentials:_reader andOnUnrecognizedCertificateBlock:nil];
    MXSession *session = [[MXSession alloc] initWithMatrixRestClient:client];
    [self wait:@"store ready" timeout:300 block:^(dispatch_block_t done) {
        [session setStore:store success:done failure:^(NSError *error) {
            XCTFail(@"setStore: %@", error);
            done();
        }];
    }];
    if (storeReadyMs) *storeReadyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    return session;
}

- (void)closeSession:(MXSession *)session
{
    [self commit:session];
    [session close];
}

/// Commits and waits until the data is on disk. Returns the ms of that commit.
- (double)commit:(MXSession *)session
{
    __block double took = 0;
    TrscTimedStore *timed = [TrscTimedStore unwrap:session.store];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self wait:@"commit" timeout:600 block:^(dispatch_block_t done) {
        [timed commitWithCompletion:^{
            took = (CFAbsoluteTimeGetCurrent() - start) * 1000;
            done();
        }];
    }];
    return took;
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

/// Back pagination of `count` events (store only or store + server). Returns the number delivered.
- (NSUInteger)paginate:(id<MXEventTimeline>)timeline count:(NSUInteger)count onlyFromStore:(BOOL)onlyFromStore reset:(BOOL)reset
{
    __block NSUInteger delivered = 0;
    MXEventListener *listener = [timeline listenToEvents:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
        if (direction == MXTimelineDirectionBackwards) delivered++;
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

- (NSDictionary *)ctxForRoom:(NSDictionary *)room extra:(NSDictionary *)extra
{
    NSMutableDictionary *ctx = [@{@"room_events": room[@"messages"], @"room": room[@"local"]} mutableCopy];
    [ctx addEntriesFromDictionary:extra ?: @{}];
    return ctx;
}

#pragma mark - Smoke

/// The stand is up, the fixture matches it, and the server serves trsc.count.
- (void)testStandSmoke
{
    if (!_fixture) { XCTSkip(@"no bench stand fixture: run scripts/ios-store-bench/up.sh"); }
    MXCredentials *reader = [self login:_fixture.readerUser];
    XCTAssertNotNil(reader.accessToken);
    for (NSDictionary *room in _fixture.rooms)
    {
        XCTAssertGreaterThan([room[@"newest_trsc_count"] length], 0, @"%@ has no trsc.count", room[@"local"]);
    }
}

#pragma mark - Bench

- (void)testStoreBench
{
    if (!_fixture) { XCTSkip(@"no bench stand fixture: run scripts/ios-store-bench/up.sh"); }
    if (![TrscStandSupport makeStore]) { XCTSkip(@"store %@ is not linked in this build", [TrscStandSupport storeKind]); }

    NSInteger iterations = [TrscStandSupport envInt:@"TRSC_BENCH_ITER" fallback:5];
    NSInteger incoming = [TrscStandSupport envInt:@"TRSC_BENCH_INCOMING" fallback:10];
    _journal = [[TrscBenchJournal alloc] initWithStoreKind:[TrscStandSupport storeKind]];
    NSLog(@"[TRSC-BENCH] run %@ store=%@ fixture=%@ results=%@", _journal.runId, [TrscStandSupport storeKind],
          _fixture.path, _journal.filePath);

    _reader = [self login:_fixture.readerUser];
    MXCredentials *sender = [self login:_fixture.senderUser];
    _senderClient = [[MXRestClient alloc] initWithCredentials:sender andOnUnrecognizedCertificateBlock:nil];

    [self preparePhase];
    [self coldPhase:iterations];
    [self incomingPhase:incoming];
}

- (void)preparePhase
{
    // Wipe whatever an earlier run left for this user.
    MXSession *wipe = [self openSession:nil];
    [wipe.store deleteAllData];
    [wipe close];

    MXSession *session = [self openSession:nil];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self wait:@"initial sync" timeout:600 block:^(dispatch_block_t done) {
        [session start:done failure:^(NSError *error) {
            XCTFail(@"initial sync: %@", error);
            done();
        }];
    }];
    [_journal record:@"initial_sync" value:(CFAbsoluteTimeGetCurrent() - start) * 1000 unit:@"ms" ctx:@{@"phase": @"prepare"}];

    for (NSDictionary *room in _fixture.rooms)
    {
        MXRoom *mxRoom = [session roomWithRoomId:room[@"room_id"]];
        XCTAssertNotNil(mxRoom, @"reader is not in %@", room[@"local"]);
        id<MXEventTimeline> timeline = [self liveTimelineOf:mxRoom];
        CFAbsoluteTime fillStart = CFAbsoluteTimeGetCurrent();
        NSUInteger total = [self paginate:timeline count:kPage onlyFromStore:NO reset:YES];
        while ([timeline canPaginate:MXTimelineDirectionBackwards])
        {
            NSUInteger got = [self paginate:timeline count:500 onlyFromStore:NO reset:NO];
            total += got;
            if (got == 0) break;
        }
        NSUInteger stored = [session.store messagesEnumeratorForRoom:room[@"room_id"]].remaining;
        [_journal record:@"backfill" value:(CFAbsoluteTimeGetCurrent() - fillStart) * 1000 unit:@"ms"
                     ctx:[self ctxForRoom:room extra:@{@"phase": @"prepare", @"delivered": @(total), @"stored_events": @(stored)}]];
        double commitMs = [self commit:session];
        [_journal record:@"store_commit_backfill" value:commitMs unit:@"ms"
                     ctx:[self ctxForRoom:room extra:@{@"phase": @"prepare", @"stored_events": @(stored)}]];
        unsigned long long roomBytes = [TrscStandSupport bytesOfDirectoriesNamed:room[@"room_id"]];
        if (roomBytes)
        {
            [_journal record:@"store_room_size" value:roomBytes / 1024.0 unit:@"KiB"
                         ctx:[self ctxForRoom:room extra:@{@"phase": @"prepare", @"stored_events": @(stored)}]];
        }
    }

    __block unsigned long long bytes = 0;
    [self wait:@"disk usage" timeout:120 block:^(dispatch_block_t done) {
        [TrscStandSupport diskUsageOfStore:session.store userId:self->_reader.userId completion:^(unsigned long long b) {
            bytes = b;
            done();
        }];
    }];
    [_journal record:@"store_size" value:bytes / 1024.0 unit:@"KiB" ctx:@{@"phase": @"prepare"}];
    [session pause];
    [self closeSession:session];
}

- (void)coldPhase:(NSInteger)iterations
{
    for (NSInteger iteration = 0; iteration < iterations; iteration++)
    {
        for (NSDictionary *room in _fixture.rooms)
        {
            double storeReadyMs = 0;
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            MXSession *session = [self openSession:&storeReadyMs];
            NSDictionary *ctx = [self ctxForRoom:room extra:@{@"phase": @"cold", @"iteration": @(iteration)}];
            [_journal record:@"cold_store_ready" value:storeReadyMs unit:@"ms" ctx:ctx];

            MXRoom *mxRoom = [session roomWithRoomId:room[@"room_id"]];
            CFAbsoluteTime openStart = CFAbsoluteTimeGetCurrent();
            id<MXEventTimeline> timeline = [self liveTimelineOf:mxRoom];
            NSUInteger rows = [self paginate:timeline count:kPage onlyFromStore:YES reset:YES];
            CFAbsoluteTime openEnd = CFAbsoluteTimeGetCurrent();
            NSMutableDictionary *openCtx = [ctx mutableCopy];
            openCtx[@"rows"] = @(rows);
            [_journal record:@"chat_open_first" value:(openEnd - openStart) * 1000 unit:@"ms" ctx:openCtx];
            [_journal record:@"cold_rows" value:(openEnd - start) * 1000 unit:@"ms" ctx:openCtx];
            XCTAssertGreaterThanOrEqual(rows, MIN(kPage, [room[@"messages"] unsignedIntegerValue]),
                                        @"%@: store gave %tu rows", room[@"local"], rows);

            CFAbsoluteTime warmStart = CFAbsoluteTimeGetCurrent();
            NSUInteger warmRows = [self paginate:timeline count:kPage onlyFromStore:YES reset:YES];
            openCtx[@"rows"] = @(warmRows);
            [_journal record:@"chat_open_warm" value:(CFAbsoluteTimeGetCurrent() - warmStart) * 1000 unit:@"ms" ctx:openCtx];
            [session close];
        }
    }
}

- (void)incomingPhase:(NSInteger)count
{
    MXSession *session = [self openSession:nil];
    [self wait:@"catch-up sync" timeout:300 block:^(dispatch_block_t done) {
        [session start:done failure:^(NSError *error) {
            XCTFail(@"catch-up sync: %@", error);
            done();
        }];
    }];
    TrscTimedStore *timed = [TrscTimedStore unwrap:session.store];
    __block NSMutableArray<NSNumber *> *commits = [NSMutableArray array];
    timed.onCommitDone = ^(double ms) { [commits addObject:@(ms)]; };

    for (NSDictionary *room in _fixture.rooms)
    {
        MXRoom *mxRoom = [session roomWithRoomId:room[@"room_id"]];
        id<MXEventTimeline> timeline = [self liveTimelineOf:mxRoom];
        // The chat is open: its first page is loaded, as on screen.
        [self paginate:timeline count:kPage onlyFromStore:YES reset:YES];

        for (NSInteger i = 0; i < count; i++)
        {
            NSString *body = [NSString stringWithFormat:@"bench incoming %@ %ld %@", room[@"local"], (long)i, NSUUID.UUID.UUIDString];
            __block CFAbsoluteTime acked = 0, seen = 0;
            [commits removeAllObjects];
            XCTestExpectation *arrived = [self expectationWithDescription:@"incoming"];
            MXEventListener *listener = [timeline listenToEventsOfTypes:@[kMXEventTypeStringRoomMessage] onEvent:^(MXEvent *event, MXTimelineDirection direction, MXRoomState *state) {
                if (direction == MXTimelineDirectionForwards && !seen && [event.content[@"body"] isEqual:body])
                {
                    seen = CFAbsoluteTimeGetCurrent();
                    // MXSession commits after the listeners of a /sync: the next commit to finish is this one.
                    [commits removeAllObjects];
                    [arrived fulfill];
                }
            }];
            CFAbsoluteTime sent = CFAbsoluteTimeGetCurrent();
            [_senderClient sendTextMessageToRoom:room[@"room_id"] threadId:nil text:body success:^(NSString *eventId) {
                acked = CFAbsoluteTimeGetCurrent();
            } failure:^(NSError *error) {
                XCTFail(@"send: %@", error);
            }];
            [self waitForExpectations:@[arrived] timeout:60];
            [timeline removeListener:listener];

            // The commit of that sync: wait until one finishes (MXSession commits after every /sync).
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while (!commits.count && deadline.timeIntervalSinceNow > 0)
            {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            NSDictionary *ctx = [self ctxForRoom:room extra:@{@"phase": @"incoming", @"i": @(i)}];
            [_journal record:@"msg_live_listener" value:(seen - sent) * 1000 unit:@"ms" ctx:ctx];
            if (acked > 0)
            {
                [_journal record:@"msg_after_ack" value:MAX(0, seen - acked) * 1000 unit:@"ms" ctx:ctx];
            }
            if (commits.count)
            {
                [_journal record:@"store_commit" value:commits.firstObject.doubleValue unit:@"ms" ctx:ctx];
            }
            else
            {
                XCTFail(@"%@: no commit within 30 s after the incoming message", room[@"local"]);
            }
        }
    }
    timed.onCommitDone = nil;
    [session pause];
    [self closeSession:session];
}

@end
