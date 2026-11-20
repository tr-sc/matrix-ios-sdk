//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//
// iP3/iP4 bench: how long MXSQLiteStore writes room state, receipts and the sync token while a real
// session syncs against the bench stand (scripts/ios-store-bench/up.sh).
//
//   xcodebuild test … -only-testing:RiotTests/TrscStateStoreSyncBenchTests
//
// Until the events component (iP2) lands, a commit of the SQLite store holds exactly these writes:
// state (diff), room account data, room flags, receipts, meta. The numbers are the writer's
// transaction time (MXStoreMetricsDelegate), not the time to the completion on main.

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>

#import "TrscStandSupport.h"

@interface TrscStateStoreSyncBenchTests : XCTestCase <MXStoreMetricsDelegate>
@end

@implementation TrscStateStoreSyncBenchTests
{
    TrscStandFixture *_fixture;
    TrscBenchJournal *_journal;
    BOOL _cryptoWasEnabled;
    NSMutableArray<NSDictionary *> *_commits;
}

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    _fixture = [TrscStandFixture load];
    _commits = [NSMutableArray array];
    if (!_fixture) return;
    _cryptoWasEnabled = MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession;
    MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = NO;
}

- (void)tearDown
{
    if (_fixture) MXSDKOptions.sharedInstance.enableCryptoWhenStartingMXSession = _cryptoWasEnabled;
    [super tearDown];
}

- (void)store:(id<MXTimelineStore>)store didCommitInMilliseconds:(double)milliseconds events:(NSUInteger)events rooms:(NSUInteger)rooms
{
    @synchronized (_commits)
    {
        [_commits addObject:@{@"ms": @(milliseconds), @"rooms": @(rooms)}];
    }
}

- (NSArray<NSDictionary *> *)takeCommits
{
    @synchronized (_commits)
    {
        NSArray *commits = [_commits copy];
        [_commits removeAllObjects];
        return commits;
    }
}

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

- (MXSession *)openSessionFor:(MXCredentials *)credentials store:(MXSQLiteStore *)store
{
    MXRestClient *client = [[MXRestClient alloc] initWithCredentials:credentials andOnUnrecognizedCertificateBlock:nil];
    MXSession *session = [[MXSession alloc] initWithMatrixRestClient:client];
    [self wait:@"store ready" timeout:120 block:^(dispatch_block_t done) {
        [session setStore:store success:done failure:^(NSError *error) {
            XCTFail(@"setStore: %@", error);
            done();
        }];
    }];
    return session;
}

- (void)commit:(MXSQLiteStore *)store
{
    [self wait:@"commit" timeout:120 block:^(dispatch_block_t done) {
        [store commitWithCompletion:done];
    }];
}

- (void)record:(NSString *)name commits:(NSArray<NSDictionary *> *)commits ctx:(NSDictionary *)ctx
{
    double total = 0, worst = 0;
    for (NSDictionary *commit in commits)
    {
        total += [commit[@"ms"] doubleValue];
        worst = MAX(worst, [commit[@"ms"] doubleValue]);
    }
    NSMutableDictionary *full = [ctx mutableCopy];
    full[@"commits"] = @(commits.count);
    full[@"max_ms"] = @(worst);
    [_journal record:name value:total unit:@"ms" ctx:full];
}

- (void)testStateAndReceiptWritesDuringSync
{
    if (!_fixture) { XCTSkip(@"no bench stand fixture: run scripts/ios-store-bench/up.sh"); }

    NSInteger incoming = [TrscStandSupport envInt:@"TRSC_BENCH_INCOMING" fallback:10];
    _journal = [[TrscBenchJournal alloc] initWithStoreKind:@"sqlite"];
    NSLog(@"[TRSC-BENCH] run %@ (state/receipts) results=%@", _journal.runId, _journal.filePath);

    MXCredentials *reader = [self login:_fixture.readerUser];
    MXCredentials *sender = [self login:_fixture.senderUser];
    MXRestClient *senderClient = [[MXRestClient alloc] initWithCredentials:sender andOnUnrecognizedCertificateBlock:nil];

    // Fresh database for the reader.
    MXSQLiteStore *wipeStore = [MXSQLiteStore new];
    MXSession *wipe = [self openSessionFor:reader store:wipeStore];
    [wipeStore deleteAllData];
    [wipe close];

    MXSQLiteStore *store = [MXSQLiteStore new];
    store.metricsDelegate = self;
    MXSession *session = [self openSessionFor:reader store:store];
    [self takeCommits];

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self wait:@"initial sync" timeout:300 block:^(dispatch_block_t done) {
        [session start:done failure:^(NSError *error) {
            XCTFail(@"initial sync: %@", error);
            done();
        }];
    }];
    [self commit:store];
    double syncMs = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    MXSQLiteDatabase *database = store.database;
    NSNumber *stateRows = [database read:^id(MXSQLiteConnection *c) { return @([c int64ForQuery:@"SELECT COUNT(*) FROM room_state" defaultValue:0 error:nil]); }];
    NSNumber *receiptRows = [database read:^id(MXSQLiteConnection *c) { return @([c int64ForQuery:@"SELECT COUNT(*) FROM receipt" defaultValue:0 error:nil]); }];
    [self record:@"state_commit_initial_sync" commits:[self takeCommits]
             ctx:@{@"phase": @"initial", @"state_rows": stateRows, @"receipt_rows": receiptRows, @"sync_ms": @(syncMs)}];
    XCTAssertGreaterThan(stateRows.integerValue, 0, @"room state is in the database");

    // Live syncs: a message and its read receipt from the sender, in every room.
    for (NSDictionary *room in _fixture.rooms)
    {
        NSString *roomId = room[@"room_id"];
        for (NSInteger i = 0; i < incoming; i++)
        {
            __block NSString *sentId;
            [self wait:@"send" timeout:30 block:^(dispatch_block_t done) {
                [senderClient sendTextMessageToRoom:roomId threadId:nil text:[NSString stringWithFormat:@"state bench %ld", (long)i]
                                            success:^(NSString *eventId) { sentId = eventId; done(); }
                                            failure:^(NSError *error) { XCTFail(@"send: %@", error); done(); }];
            }];
            [self wait:@"receipt" timeout:30 block:^(dispatch_block_t done) {
                [senderClient sendReadReceipt:roomId eventId:sentId threadId:nil
                                      success:^{ done(); }
                                      failure:^(NSError *error) { XCTFail(@"receipt: %@", error); done(); }];
            }];
            // Until the reader's store has the receipt of the sender for that event.
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while (deadline.timeIntervalSinceNow > 0
                   && ![[store getReceiptInRoom:roomId threadId:kMXEventTimelineMain forUserId:sender.userId].eventId isEqualToString:sentId])
            {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            XCTAssertEqualObjects([store getReceiptInRoom:roomId threadId:kMXEventTimelineMain forUserId:sender.userId].eventId, sentId);
            [self commit:store];
            [self record:@"state_commit_live_sync" commits:[self takeCommits]
                     ctx:@{@"phase": @"incoming", @"room": room[@"local"], @"i": @(i)}];
        }
    }

    [session close];
    [senderClient close];
}

@end
