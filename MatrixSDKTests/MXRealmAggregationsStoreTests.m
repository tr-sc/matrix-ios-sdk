/* Copyright 2026 TRSC contributors. SPDX-License-Identifier: Apache-2.0 */
#import <XCTest/XCTest.h>
#import <Realm/Realm.h>
#import "../MatrixSDK/Aggregations/Data/Store/Realm/MXRealmAggregationsStore.h"

@interface MXRealmAggregationsStore (ConfigurationTests)
- (RLMRealmConfiguration *)realmConfiguration;
- (RLMRealmConfiguration *)prepareRealmConfigurationWithError:(NSError **)error;
- (RLMRealm *)realm;
@end

@interface MXTestPreparedAggregationsStore : MXRealmAggregationsStore
@property (nonatomic) NSUInteger preparations;
@property (nonatomic) BOOL failPreparation;
@property (nonatomic) BOOL failOpen;
@property (nonatomic, strong) NSURL *fixtureDirectory;
@end
@implementation MXTestPreparedAggregationsStore
- (RLMRealmConfiguration *)prepareRealmConfigurationWithError:(NSError **)error
{
    self.preparations++;
    RLMRealmConfiguration *configuration = [super prepareRealmConfigurationWithError:error];
    self.fixtureDirectory = configuration.fileURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    if (self.failPreparation && error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    // A read-only open of our new, nonexistent fixture database must fail.
    if (self.failOpen) {
        configuration.deleteRealmIfMigrationNeeded = NO;
        configuration.readOnly = YES;
    }
    return configuration;
}
@end

@interface MXRealmAggregationsStoreTests : XCTestCase
@property (nonatomic, strong) NSMutableArray<MXTestPreparedAggregationsStore *> *stores;
@end
@implementation MXRealmAggregationsStoreTests
- (void)setUp
{
    [super setUp];
    self.stores = [NSMutableArray new];
}
- (MXTestPreparedAggregationsStore *)newStore
{
    MXCredentials *credentials = [MXCredentials new];
    credentials.userId = [@"realm-config-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    MXTestPreparedAggregationsStore *store = [[MXTestPreparedAggregationsStore alloc] initWithCredentials:credentials];
    [self.stores addObject:store];
    return store;
}
- (void)tearDown
{
    NSMutableArray<NSURL *> *fixtureDirectories = [NSMutableArray new];
    for (MXTestPreparedAggregationsStore *store in self.stores) {
        if (store.fixtureDirectory) {
            [fixtureDirectories addObject:store.fixtureDirectory];
        }
    }
    // Release the stores' retained Realms before removing their database files.
    self.stores = nil;
    for (NSURL *directory in fixtureDirectories) {
        NSError *error;
        XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:directory error:&error], @"%@", error);
    }
    [super tearDown];
}
- (void)testEmptyLookupsPrepareConfigurationOnce
{
    MXTestPreparedAggregationsStore *store = [self newStore];
    for (NSUInteger page = 0; page < 2; page++) {
        @autoreleasepool {
            for (NSUInteger i = 0; i < 30; i++) {
                NSString *eventId = [NSString stringWithFormat:@"$%lu", (unsigned long)i];
                XCTAssertNil([store reactionCountsOnEvent:eventId]);
                XCTAssertNil([store reactionRelationsOnEvent:eventId]);
            }
        }
    }
    XCTAssertEqual(store.preparations, 1u);
}
- (void)testResetAndDifferentAccountsKeepTheirConfigurationScope
{
    MXTestPreparedAggregationsStore *first = [self newStore];
    MXTestPreparedAggregationsStore *second = [self newStore];
    @autoreleasepool {
        MXReactionCount *count = [MXReactionCount new];
        count.reaction = @"👍";
        count.count = 3;
        [first addOrUpdateReactionCount:count onEvent:@"$one" inRoom:@"!fixture:test"];
        XCTAssertEqual([first reactionCountsOnEvent:@"$one"].firstObject.count, 3u);
        XCTAssertNil([second reactionCountsOnEvent:@"$one"]);
        [first deleteAll];
        XCTAssertNil([first reactionCountsOnEvent:@"$one"]);
        [first addOrUpdateReactionCount:count onEvent:@"$one" inRoom:@"!fixture:test"];
        XCTAssertEqual([first reactionCountsOnEvent:@"$one"].firstObject.count, 3u);
        XCTAssertNotEqualObjects(first.realmConfiguration.fileURL, second.realmConfiguration.fileURL);
    }
    XCTAssertEqual(first.preparations, 1u);
    XCTAssertEqual(second.preparations, 1u);
}
- (void)testPreparationFailureIsNotCached
{
    MXTestPreparedAggregationsStore *store = [self newStore];
    store.failPreparation = YES;
    XCTAssertNotNil(store.realmConfiguration);
    XCTAssertNotNil(store.realmConfiguration);
    XCTAssertEqual(store.preparations, 2u);
    store.failPreparation = NO;
    RLMRealmConfiguration *configuration = store.realmConfiguration;
    XCTAssertEqual(configuration, store.realmConfiguration);
    XCTAssertEqual(store.preparations, 3u);
}
- (void)testOpenFailureRetriesPreparation
{
    MXTestPreparedAggregationsStore *store = [self newStore];
    @autoreleasepool {
        store.failOpen = YES;
        XCTAssertNil(store.realm);
        store.failOpen = NO;
        XCTAssertNotNil(store.realm);
    }
    XCTAssertEqual(store.preparations, 2u);
}
- (void)testConcurrentConfigurationAccessPreparesOnce
{
    MXTestPreparedAggregationsStore *store = [self newStore];
    XCTestExpectation *done = [self expectationWithDescription:@"configuration access"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        dispatch_apply(20, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool { (void)store.realmConfiguration; }
        });
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:5];
    XCTAssertEqual(store.preparations, 1u);
}
@end
