//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Store-level bench (iP2): the event part of the store alone, without MXSession.
//
// For every fixture room of the bench stand (scripts/ios-store-bench/up.sh) the history is read once
// over REST /messages (read-only, nothing is sent), then for each store — MXFileStore and MXSQLiteStore —
// the room is written into a fresh store and measured:
//   store_write_one  — one incoming event: storeEvent forwards + commit until the data is on disk;
//   store_page50_cold — reopen the store, first page of 50 rows through messagesEnumeratorForRoom;
//   store_page50_warm — the same page again on the open store.
// Results go to the stand's results/<run>.jsonl via TrscBenchJournal (ctx.store = file | sqlite).
// TRSC_BENCH_WRITES (default 20) incoming events per room, TRSC_BENCH_ROOMS limits the rooms (e.g. r10,r1k).

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>
#import "TrscStandSupport.h"

@interface TrscStoreLevelBenchTests : XCTestCase
@end

@implementation TrscStoreLevelBenchTests
{
    TrscStandFixture *_fixture;
}

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    _fixture = [TrscStandFixture load];
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
    [self wait:@"login" timeout:30 block:^(dispatch_block_t done) {
        [client loginWithLoginType:kMXLoginFlowTypePassword username:user password:self->_fixture.password success:^(MXCredentials *c) {
            credentials = c;
            done();
        } failure:^(NSError *error) {
            XCTFail(@"login %@: %@", user, error);
            done();
        }];
    }];
    credentials.homeServer = credentials.homeServer ?: _fixture.homeserver;
    return credentials;
}

/// Whole history of the room, oldest first, read backwards in pages of 1000.
- (NSArray<MXEvent *> *)historyOfRoom:(NSString *)roomId client:(MXRestClient *)client
{
    NSMutableArray<MXEvent *> *newestFirst = [NSMutableArray array];
    __block NSString *from = nil;
    __block BOOL more = YES;
    while (more)
    {
        [self wait:@"messages" timeout:120 block:^(dispatch_block_t done) {
            [client messagesForRoom:roomId from:from direction:MXTimelineDirectionBackwards limit:1000 filter:nil success:^(MXPaginationResponse *response) {
                [newestFirst addObjectsFromArray:response.chunk];
                more = response.chunk.count > 0 && response.end.length && ![response.end isEqualToString:from];
                from = response.end;
                done();
            } failure:^(NSError *error) {
                XCTFail(@"messages %@: %@", roomId, error);
                more = NO;
                done();
            }];
        }];
    }
    return newestFirst.reverseObjectEnumerator.allObjects;
}

- (id<MXStore>)newStoreOfKind:(NSString *)kind
{
    Class storeClass = NSClassFromString([kind isEqualToString:@"sqlite"] ? @"MXSQLiteStore" : @"MXFileStore");
    return storeClass ? [[storeClass alloc] init] : nil;
}

- (void)open:(id<MXStore>)store credentials:(MXCredentials *)credentials
{
    [self wait:@"open" timeout:120 block:^(dispatch_block_t done) {
        [store openWithCredentials:credentials onComplete:done failure:^(NSError *error) {
            XCTFail(@"open: %@", error);
            done();
        }];
    }];
}

- (double)commit:(id<MXStore>)store
{
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    __block double ms = 0;
    [self wait:@"commit" timeout:300 block:^(dispatch_block_t done) {
        [store commitWithCompletion:^{
            ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
            done();
        }];
    }];
    return ms;
}

/// A copy of `template` as a new incoming event with the given order.
static MXEvent *IncomingEvent(MXEvent *template, int64_t order, NSUInteger i)
{
    NSMutableDictionary *json = [template.JSONDictionary mutableCopy];
    json[@"event_id"] = [NSString stringWithFormat:@"$storebench-%lld-%lu", order, (unsigned long)i];
    json[@"origin_server_ts"] = @((uint64_t)(NSDate.date.timeIntervalSince1970 * 1000));
    NSMutableDictionary *unsignedData = [json[@"unsigned"] mutableCopy] ?: [NSMutableDictionary dictionary];
    unsignedData[@"trsc.count"] = @(order);
    [unsignedData removeObjectForKey:@"transaction_id"];
    json[@"unsigned"] = unsignedData;
    return [MXEvent modelFromJSON:json];
}

static double Median(NSArray<NSNumber *> *values)
{
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    return sorted.count ? [sorted[sorted.count / 2] doubleValue] : 0;
}

static double P90(NSArray<NSNumber *> *values)
{
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    return sorted.count ? [sorted[MIN(sorted.count - 1, (NSUInteger)(sorted.count * 0.9))] doubleValue] : 0;
}

- (void)testStoreLevelBench
{
    if (!_fixture) { XCTSkip(@"no bench stand fixture: run scripts/ios-store-bench/up.sh"); }
    MXCredentials *reader = [self login:_fixture.readerUser];
    MXRestClient *client = [[MXRestClient alloc] initWithCredentials:reader andOnUnrecognizedCertificateBlock:nil];
    NSInteger writes = [TrscStandSupport envInt:@"TRSC_BENCH_WRITES" fallback:20];
    NSString *onlyRooms = [TrscStandSupport env:@"TRSC_BENCH_ROOMS"];
    NSDictionary<NSString *, TrscBenchJournal *> *journals = @{
        @"file": [[TrscBenchJournal alloc] initWithStoreKind:@"file"],
        @"sqlite": [[TrscBenchJournal alloc] initWithStoreKind:@"sqlite"],
    };

    for (NSDictionary *room in _fixture.rooms)
    {
        NSString *local = room[@"local"], *roomId = room[@"room_id"];
        if (onlyRooms.length && ![[onlyRooms componentsSeparatedByString:@","] containsObject:local]) continue;
        NSArray<MXEvent *> *history = [self historyOfRoom:roomId client:client];
        MXEvent *newestMessage = nil;
        int64_t newestOrder = 0;
        for (MXEvent *event in history)
        {
            if (event.hasTrscOrder) newestOrder = MAX(newestOrder, event.trscOrder);
            if ([event.type isEqualToString:kMXEventTypeStringRoomMessage]) newestMessage = event;
        }
        XCTAssertNotNil(newestMessage, @"%@ has no messages", local);
        NSLog(@"[TRSC-BENCH] room %@: %lu events, newest order %lld", local, (unsigned long)history.count, newestOrder);

        NSArray *firstPageIds = nil;
        for (NSString *kind in @[@"file", @"sqlite"])
        {
            id<MXStore> store = [self newStoreOfKind:kind];
            if (!store) { NSLog(@"[TRSC-BENCH] %@ is not linked", kind); continue; }
            MXCredentials *credentials = [[MXCredentials alloc] initWithHomeServer:_fixture.homeserver
                                                                            userId:[NSString stringWithFormat:@"@storebench-%@-%@:bench.local", kind, local]
                                                                       accessToken:@"storebench"];
            [self open:store credentials:credentials];
            [store deleteAllData];
            [self open:store credentials:credentials];
            // Без токена синка MXFileStore считает метаданные неполными и при следующем открытии стирает данные.
            store.eventStreamToken = @"storebench";

            // Populate: the whole history as it would come from forward syncs.
            CFAbsoluteTime fillStart = CFAbsoluteTimeGetCurrent();
            for (MXEvent *event in history)
            {
                [store storeEventForRoom:roomId event:event direction:MXTimelineDirectionForwards];
            }
            double fillCommitMs = [self commit:store];
            double fillMs = (CFAbsoluteTimeGetCurrent() - fillStart) * 1000;
            NSDictionary *ctx = @{@"store": kind, @"room": local, @"events": @(history.count)};
            TrscBenchJournal *journal = journals[kind];
            [journal record:@"store_fill" value:fillMs unit:@"ms" ctx:ctx];
            [journal record:@"store_fill_commit" value:fillCommitMs unit:@"ms" ctx:ctx];

            // One incoming event at a time, each committed to disk.
            NSMutableArray<NSNumber *> *writeMs = [NSMutableArray array];
            for (NSInteger i = 0; i < writes; i++)
            {
                MXEvent *incoming = IncomingEvent(newestMessage, newestOrder + 1 + i, i);
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                [store storeEventForRoom:roomId event:incoming direction:MXTimelineDirectionForwards];
                [self commit:store];
                [writeMs addObject:@((CFAbsoluteTimeGetCurrent() - start) * 1000)];
            }
            for (NSNumber *ms in writeMs) [journal record:@"store_write_one" value:ms.doubleValue unit:@"ms" ctx:ctx];
            [store close];

            // Cold page: new instance, open, first 50 rows.
            id<MXStore> reopened = [self newStoreOfKind:kind];
            CFAbsoluteTime openStart = CFAbsoluteTimeGetCurrent();
            [self open:reopened credentials:credentials];
            double openMs = (CFAbsoluteTimeGetCurrent() - openStart) * 1000;
            CFAbsoluteTime pageStart = CFAbsoluteTimeGetCurrent();
            NSArray<MXEvent *> *page = [[reopened messagesEnumeratorForRoom:roomId] nextEventsBatch:50 threadId:nil];
            double coldMs = (CFAbsoluteTimeGetCurrent() - pageStart) * 1000;
            XCTAssertEqual(page.count, MIN((NSUInteger)50, history.count + writes), @"%@ %@ cold page", kind, local);
            XCTAssertEqualObjects(page.lastObject.eventId, IncomingEvent(newestMessage, newestOrder + writes, writes - 1).eventId,
                                  @"%@ %@: the page ends at the newest event", kind, local);

            NSArray *pageIds = [page valueForKey:@"eventId"];
            if (firstPageIds) XCTAssertEqualObjects(pageIds, firstPageIds, @"%@: file and sqlite give the same page", local);
            firstPageIds = pageIds;

            NSMutableArray<NSNumber *> *warmMs = [NSMutableArray array];
            for (NSInteger i = 0; i < 10; i++)
            {
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                NSArray *again = [[reopened messagesEnumeratorForRoom:roomId] nextEventsBatch:50 threadId:nil];
                [warmMs addObject:@((CFAbsoluteTimeGetCurrent() - start) * 1000)];
                XCTAssertEqual(again.count, page.count);
            }
            [journal record:@"store_open" value:openMs unit:@"ms" ctx:ctx];
            [journal record:@"store_page50_cold" value:coldMs unit:@"ms" ctx:ctx];
            for (NSNumber *ms in warmMs) [journal record:@"store_page50_warm" value:ms.doubleValue unit:@"ms" ctx:ctx];

            NSLog(@"[TRSC-BENCH] SUMMARY store=%@ room=%@ events=%lu fill=%.0fms write_one_p50=%.2fms write_one_p90=%.2fms open=%.1fms page50_cold=%.2fms page50_warm_p50=%.2fms",
                  kind, local, (unsigned long)history.count, fillMs, Median(writeMs), P90(writeMs), openMs, coldMs, Median(warmMs));
            [reopened deleteAllData];
            [reopened close];
        }
    }
}

@end
