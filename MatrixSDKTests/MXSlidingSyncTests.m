// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import <XCTest/XCTest.h>
#import <MatrixSDK/MatrixSDK.h>

@interface MXSession (SlidingSyncPersistenceTests)
- (NSString *)slidingSyncPersistenceKey;
- (void)persistSlidingSyncState;
- (void)restoreSlidingSyncStateWithConfiguration:(MXSlidingSyncConfiguration *)configuration;
- (void)resetSlidingSyncStateForUnknownPosition;
@end

@interface MXSlidingSyncTests : XCTestCase
@end

@implementation MXSlidingSyncTests

- (MXRoomSync *)legacyRoomFromSlidingRoom:(NSDictionary *)slidingRoom
{
    NSDictionary *json = @{
        @"pos": @"99",
        @"lists": @{},
        @"rooms": @{@"!room:example.org": slidingRoom},
        @"extensions": @{}
    };
    MXSlidingSyncResponse *response = [MXSlidingSyncResponse modelFromJSON:json];
    MXSyncResponse *legacy = [response legacySyncResponseForUserId:@"@me:example.org"];
    return legacy.rooms.join[@"!room:example.org"];
}

- (void)testDefaultRequestUsesFastInitialWindowAndRequiredState
{
    MXSlidingSyncConfiguration *configuration = MXSlidingSyncConfiguration.defaultConfiguration;
    NSDictionary *request = [configuration requestDictionaryWithPosition:@"42"
                                                              connectionId:@"connection"
                                                                    ranges:@[@[@0, @49]]
                                                         roomSubscriptions:@[@"!deep:example.org"]
                                                                   timeout:30000
                                                               setPresence:@"online"];

    XCTAssertEqualObjects(request[@"pos"], @"42");
    XCTAssertEqualObjects(request[@"lists"][@"main"][@"ranges"], (@[@[@0, @49]]));
    XCTAssertEqualObjects(request[@"lists"][@"main"][@"timeline_limit"], @1);
    XCTAssertTrue(([request[@"lists"][@"main"][@"required_state"] containsObject:@[@"m.room.member", @"$ME"]]));
    XCTAssertTrue(([request[@"lists"][@"main"][@"required_state"] containsObject:@[@"m.room.member", @"$LAZY"]]));
    XCTAssertNotNil(request[@"room_subscriptions"][@"!deep:example.org"]);
    XCTAssertTrue([request[@"extensions"][@"e2ee"][@"enabled"] boolValue]);
    XCTAssertTrue([request[@"extensions"][@"to_device"][@"enabled"] boolValue]);
}

- (void)testSimplifiedResponseAdaptsToLegacySyncPipeline
{
    NSDictionary *json = @{
        @"pos": @"99",
        @"lists": @{@"main": @{@"count": @1}},
        @"rooms": @{
            @"!room:example.org": @{
                @"membership": @"join",
                @"initial": @1,
                @"notification_count": @4,
                @"highlight_count": @2,
                @"bump_stamp": @123,
                @"required_state": @[@{@"type": @"m.room.name", @"state_key": @"", @"content": @{@"name": @"Room"}}],
                @"timeline": @[@{@"type": @"m.room.message", @"event_id": @"$event", @"sender": @"@alice:example.org", @"origin_server_ts": @1, @"content": @{@"msgtype": @"m.text", @"body": @"Hi"}}]
            }
        },
        @"extensions": @{
            @"to_device": @{@"next_batch": @"device-2", @"events": @[]},
            @"e2ee": @{@"device_lists": @{@"changed": @[@"@alice:example.org"], @"left": @[]}, @"device_one_time_keys_count": @{@"signed_curve25519": @3}},
            @"account_data": @{@"global": @[], @"rooms": @{}},
            @"receipts": @{@"rooms": @{}},
            @"typing": @{@"rooms": @{}}
        }
    };

    MXSlidingSyncResponse *response = [MXSlidingSyncResponse modelFromJSON:json];
    MXSyncResponse *legacy = [response legacySyncResponseForUserId:@"@me:example.org"];
    MXRoomSync *room = legacy.rooms.join[@"!room:example.org"];

    XCTAssertEqualObjects(response.position, @"99");
    XCTAssertEqual(response.lists[@"main"].count, 1u);
    XCTAssertEqual(room.timeline.events.count, 1u);
    XCTAssertFalse(room.timeline.hasLimited);
    XCTAssertFalse(room.timeline.limited);
    XCTAssertNil(room.timeline.prevBatch);
    XCTAssertEqualObjects(room.slidingSyncInitial, @YES);
    XCTAssertNil(room.JSONDictionary[@"timeline"][@"limited"]);
    XCTAssertNil(room.JSONDictionary[@"timeline"][@"prev_batch"]);
    MXRoomSync *roundTrippedRoom = [MXRoomSync modelFromJSON:room.JSONDictionary];
    XCTAssertFalse(roundTrippedRoom.timeline.hasLimited);
    XCTAssertEqualObjects(roundTrippedRoom.slidingSyncInitial, @YES);
    XCTAssertEqual(room.unreadNotifications.notificationCount, 4u);
    XCTAssertEqual(room.unreadNotifications.highlightCount, 2u);
    XCTAssertEqualObjects(legacy.deviceOneTimeKeysCount[@"signed_curve25519"], @3);
}

- (void)testHeroAvatarsAndRoomAvatarReachLegacySummary
{
    MXRoomSync *room = [self legacyRoomFromSlidingRoom:@{
        @"membership": @"join",
        @"timeline": @[],
        @"joined_count": @2,
        @"avatar": @"mxc://example.org/new",
        @"heroes": @[
            @{@"user_id": @"@peer:example.org", @"displayname": @"Peer", @"avatar_url": @"mxc://example.org/new"},
            @{@"user_id": @"@bare:example.org"}
        ]
    }];

    XCTAssertEqualObjects(room.summary.heroes, (@[@"@peer:example.org", @"@bare:example.org"]));
    XCTAssertEqualObjects(room.summary.heroAvatars[@"@peer:example.org"], @"mxc://example.org/new");
    XCTAssertEqualObjects(room.summary.heroAvatars[@"@bare:example.org"], NSNull.null,
                          @"A hero without avatar_url has no photo on the server");
    XCTAssertEqualObjects(room.summary.avatar, @"mxc://example.org/new");

    MXRoomSync *roundTripped = [MXRoomSync modelFromJSON:room.JSONDictionary];
    XCTAssertEqualObjects(roundTripped.summary.heroAvatars, room.summary.heroAvatars);
    XCTAssertEqualObjects(roundTripped.summary.avatar, @"mxc://example.org/new");
}

- (void)testDirectRoomAvatarPrefersServerHeroAvatarOverStaleMember
{
    MXRoomState *state = [[MXRoomState alloc] initWithRoomId:@"!dm:example.org" andMatrixSession:nil andDirection:NO];
    [state handleStateEvents:@[[MXEvent modelFromJSON:@{
        @"type": @"m.room.member",
        @"state_key": @"@peer:example.org",
        @"sender": @"@peer:example.org",
        @"event_id": @"$old",
        @"origin_server_ts": @1,
        @"content": @{@"membership": @"join", @"displayname": @"Peer", @"avatar_url": @"mxc://example.org/old"}
    }]]];
    MXRoomSummary *summary = [[MXRoomSummary alloc] initWithRoomId:@"!dm:example.org" andMatrixSession:nil];
    summary.directUserId = @"@peer:example.org";
    summary.avatar = @"mxc://example.org/old";
    MXRoomSummaryUpdater *updater = [MXRoomSummaryUpdater new];

    MXRoomSyncSummary *fresh = [MXRoomSyncSummary modelFromJSON:@{
        @"m.heroes": @[@"@peer:example.org"],
        @"m.joined_member_count": @2,
        MXRoomSyncSummarySlidingSyncHeroAvatarsJSONKey: @{@"@peer:example.org": @"mxc://example.org/new"}
    }];
    XCTAssertTrue([updater updateSummaryAvatar:summary session:nil withServerRoomSummary:fresh roomState:state excludingUserIDs:@[]]);
    XCTAssertEqualObjects(summary.avatar, @"mxc://example.org/new");

    MXRoomSyncSummary *removed = [MXRoomSyncSummary modelFromJSON:@{
        @"m.heroes": @[@"@peer:example.org"],
        @"m.joined_member_count": @2,
        MXRoomSyncSummarySlidingSyncHeroAvatarsJSONKey: @{@"@peer:example.org": NSNull.null}
    }];
    XCTAssertTrue([updater updateSummaryAvatar:summary session:nil withServerRoomSummary:removed roomState:state excludingUserIDs:@[]]);
    XCTAssertNil(summary.avatar);

    MXRoomSyncSummary *legacy = [MXRoomSyncSummary modelFromJSON:@{
        @"m.heroes": @[@"@peer:example.org"],
        @"m.joined_member_count": @2
    }];
    [updater updateSummaryAvatar:summary session:nil withServerRoomSummary:legacy roomState:state excludingUserIDs:@[]];
    XCTAssertEqualObjects(summary.avatar, @"mxc://example.org/old", @"Without server avatars the member state still applies");
}

- (void)testMemberEventWithDisplaynameAlsoUpdatesUserAvatar
{
    BOOL disableIdenticon = MXSDKOptions.sharedInstance.disableIdenticonUseForUserAvatar;
    MXSDKOptions.sharedInstance.disableIdenticonUseForUserAvatar = YES;
    MXUser *user = [[MXUser alloc] initWithUserId:@"@peer:example.org"];
    void (^apply)(NSString *, uint64_t) = ^(NSString *avatarUrl, uint64_t ts) {
        NSMutableDictionary *content = [@{@"membership": @"join", @"displayname": @"Peer"} mutableCopy];
        content[@"avatar_url"] = avatarUrl;
        MXEvent *event = [MXEvent modelFromJSON:@{
            @"type": @"m.room.member",
            @"state_key": @"@peer:example.org",
            @"sender": @"@peer:example.org",
            @"event_id": [NSString stringWithFormat:@"$%llu", ts],
            @"origin_server_ts": @(ts),
            @"content": content
        }];
        [user updateWithRoomMemberEvent:event roomMember:[[MXRoomMember alloc] initWithMXEvent:event] inMatrixSession:nil];
    };

    apply(@"mxc://example.org/old", 1000);
    XCTAssertEqualObjects(user.displayname, @"Peer");
    XCTAssertEqualObjects(user.avatarUrl, @"mxc://example.org/old");

    apply(@"mxc://example.org/new", 2000);
    XCTAssertEqualObjects(user.avatarUrl, @"mxc://example.org/new", @"Same displayname, new photo");

    apply(@"mxc://example.org/stale", 1500);
    XCTAssertEqualObjects(user.avatarUrl, @"mxc://example.org/new", @"An older event must not win");

    apply(nil, 3000);
    XCTAssertNil(user.avatarUrl, @"A newer event without avatar_url removes the photo");

    MXSDKOptions.sharedInstance.disableIdenticonUseForUserAvatar = disableIdenticon;
}

- (void)testSlidingSyncPreservesExplicitLimitedFalse
{
    MXRoomSync *room = [self legacyRoomFromSlidingRoom:@{
        @"membership": @"join",
        @"initial": @YES,
        @"limited": @NO,
        @"timeline": @[]
    }];

    XCTAssertTrue(room.timeline.hasLimited);
    XCTAssertFalse(room.timeline.limited);
    XCTAssertEqualObjects(room.timeline.JSONDictionary[@"limited"], @NO);
    XCTAssertEqualObjects(room.slidingSyncInitial, @YES);
}

- (void)testSlidingSyncPreservesLimitedTrueAndPreviousBatch
{
    MXRoomSync *room = [self legacyRoomFromSlidingRoom:@{
        @"membership": @"join",
        @"initial": @YES,
        @"limited": @YES,
        @"prev_batch": @"deep-token",
        @"timeline": @[]
    }];

    XCTAssertTrue(room.timeline.hasLimited);
    XCTAssertTrue(room.timeline.limited);
    XCTAssertEqualObjects(room.timeline.prevBatch, @"deep-token");
    XCTAssertEqualObjects(room.timeline.JSONDictionary[@"limited"], @YES);
    XCTAssertEqualObjects(room.timeline.JSONDictionary[@"prev_batch"], @"deep-token");
}

- (void)testSlidingSyncIncrementalRoomHasExplicitProvenance
{
    MXRoomSync *room = [self legacyRoomFromSlidingRoom:@{
        @"membership": @"join",
        @"timeline": @[]
    }];

    XCTAssertEqualObjects(room.slidingSyncInitial, @NO);
    XCTAssertFalse(room.timeline.hasLimited);
}

- (void)testLegacySyncLimitedFalseDoesNotHaveSlidingSyncProvenance
{
    MXRoomSync *room = [MXRoomSync modelFromJSON:@{
        @"timeline": @{
            @"events": @[],
            @"limited": @NO
        }
    }];

    XCTAssertNil(room.slidingSyncInitial);
    XCTAssertTrue(room.timeline.hasLimited);
    XCTAssertFalse(room.timeline.limited);
    XCTAssertEqualObjects(room.timeline.JSONDictionary[@"limited"], @NO);
}

- (void)testParsesEveryClassicListOperationForCompatibleServers
{
    NSDictionary *json = @{@"count": @4, @"ops": @[
        @{@"op": @"SYNC", @"range": @[@0, @1], @"room_ids": @[@"!a:x", @"!b:x"]},
        @{@"op": @"INSERT", @"index": @1, @"room_id": @"!c:x"},
        @{@"op": @"DELETE", @"index": @2},
        @{@"op": @"MOVE", @"from": @3, @"to": @0},
        @{@"op": @"INVALIDATE", @"range": @[@2, @3]}
    ]};
    MXSlidingSyncList *list = [MXSlidingSyncList modelFromJSON:json];
    XCTAssertEqual(list.operations.count, 5u);
    XCTAssertEqualObjects(list.operations[0].roomIds, (@[@"!a:x", @"!b:x"]));
    XCTAssertEqualObjects(list.operations[3].fromIndex, @3);
    XCTAssertEqualObjects(list.operations[3].toIndex, @0);
    XCTAssertEqualObjects(list.operations[4].range, (@[@2, @3]));
}

- (void)testNewSessionRestoresCommittedSlidingSyncStateAndExpandedRange
{
    MXCredentials *credentials = [[MXCredentials alloc] initWithHomeServer:@"https://example.org"
                                                                    userId:@"@restore:example.org"
                                                               accessToken:@"token"];
    MXRestClient *firstRestClient = [[MXRestClient alloc] initWithCredentials:credentials
                                          andOnUnrecognizedCertificateBlock:nil];
    MXSession *first = [[MXSession alloc] initWithMatrixRestClient:firstRestClient];
    NSString *persistenceKey = first.slidingSyncPersistenceKey;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:persistenceKey];
    [first setValue:@"pos-7" forKey:@"slidingSyncPosition"];
    [first setValue:@"conn-7" forKey:@"slidingSyncConnectionId"];
    [first setValue:@"device-7" forKey:@"slidingSyncToDevicePosition"];
    [first setValue:@[@"!a:example.org", @"!b:example.org", @"!c:example.org"] forKey:@"slidingSyncRoomOrder"];
    [first setValue:[@{@"!a:example.org": @30, @"!b:example.org": @20} mutableCopy] forKey:@"slidingSyncBumpStamps"];
    [first setValue:@120 forKey:@"slidingSyncTotalRoomCount"];
    [first persistSlidingSyncState];
    [first close];

    MXRestClient *restoredRestClient = [[MXRestClient alloc] initWithCredentials:credentials
                                             andOnUnrecognizedCertificateBlock:nil];
    MXSession *restored = [[MXSession alloc] initWithMatrixRestClient:restoredRestClient];
    MXMemoryStore *store = [MXMemoryStore new];
    MXRoomSummary *summary = [[MXRoomSummary alloc] initWithRoomId:@"!a:example.org" andMatrixSession:nil];
    [store.roomSummaryStore storeSummary:summary];
    XCTestExpectation *ready = [self expectationWithDescription:@"memory store ready"];
    [restored setStore:store success:^{
        MXSlidingSyncConfiguration *configuration = MXSlidingSyncConfiguration.defaultConfiguration;
        configuration.initialWindowSize = 2;
        [restored setValue:configuration forKey:@"slidingSyncConfiguration"];
        [restored restoreSlidingSyncStateWithConfiguration:configuration];

        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncPosition"], @"pos-7");
        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncConnectionId"], @"conn-7");
        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncToDevicePosition"], @"device-7");
        XCTAssertEqualObjects(restored.slidingSyncRoomOrder, (@[@"!a:example.org", @"!b:example.org", @"!c:example.org"]));
        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncBumpStamps"], (@{@"!a:example.org": @30, @"!b:example.org": @20}));
        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncTotalRoomCount"], @120);
        XCTAssertEqualObjects([restored valueForKey:@"slidingSyncRangeEnd"], @2,
                              @"The next request must cover at least the previously loaded order");
        XCTAssertEqualObjects(configuration.extensions[@"to_device"][@"since"], @"device-7");
        XCTAssertEqual(restored.roomListState.loaded, 3u);
        XCTAssertEqual(restored.roomListState.total, 120u);
        [ready fulfill];
    } failure:^(NSError *error) {
        XCTFail(@"Cannot open memory store: %@", error);
        [ready fulfill];
    }];

    [self waitForExpectationsWithTimeout:2 handler:nil];
    [restored close];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:persistenceKey];
}

- (void)testCacheClearAndUnknownPositionDiscardIncompatibleMetadata
{
    MXCredentials *credentials = [[MXCredentials alloc] initWithHomeServer:@"https://example.org"
                                                                    userId:@"@unknown:example.org"
                                                               accessToken:@"token"];
    MXRestClient *restClient = [[MXRestClient alloc] initWithCredentials:credentials
                                      andOnUnrecognizedCertificateBlock:nil];
    MXSession *session = [[MXSession alloc] initWithMatrixRestClient:restClient];
    NSString *persistenceKey = session.slidingSyncPersistenceKey;
    NSDictionary *persisted = @{
        @"position": @"stale-pos",
        @"connectionId": @"stale-conn",
        @"toDevicePosition": @"stale-device",
        @"roomOrder": @[@"!stale:example.org"],
        @"bumpStamps": @{@"!stale:example.org": @1},
        @"total": @1
    };
    [NSUserDefaults.standardUserDefaults setObject:persisted forKey:persistenceKey];

    XCTestExpectation *ready = [self expectationWithDescription:@"empty store ready"];
    [session setStore:[MXMemoryStore new] success:^{
        MXSlidingSyncConfiguration *configuration = MXSlidingSyncConfiguration.defaultConfiguration;
        [session setValue:configuration forKey:@"slidingSyncConfiguration"];
        [session restoreSlidingSyncStateWithConfiguration:configuration];
        XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:persistenceKey]);
        XCTAssertNil([session valueForKey:@"slidingSyncPosition"]);
        XCTAssertTrue(session.slidingSyncRoomOrder.count == 0);

        [session setValue:@"accepted-pos" forKey:@"slidingSyncPosition"];
        [session setValue:@"accepted-conn" forKey:@"slidingSyncConnectionId"];
        [session setValue:@"accepted-device" forKey:@"slidingSyncToDevicePosition"];
        NSMutableDictionary *extensions = configuration.extensions.mutableCopy;
        NSMutableDictionary *toDevice = [extensions[@"to_device"] mutableCopy];
        toDevice[@"since"] = @"accepted-device";
        extensions[@"to_device"] = toDevice;
        configuration.extensions = extensions;
        [session persistSlidingSyncState];
        XCTAssertNotNil([NSUserDefaults.standardUserDefaults objectForKey:persistenceKey]);

        NSString *oldConnectionId = [session valueForKey:@"slidingSyncConnectionId"];
        [session resetSlidingSyncStateForUnknownPosition];
        XCTAssertNil([session valueForKey:@"slidingSyncPosition"]);
        XCTAssertNil([session valueForKey:@"slidingSyncToDevicePosition"]);
        XCTAssertNotEqualObjects([session valueForKey:@"slidingSyncConnectionId"], oldConnectionId);
        XCTAssertNil(configuration.extensions[@"to_device"][@"since"]);
        XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:persistenceKey]);
        [ready fulfill];
    } failure:^(NSError *error) {
        XCTFail(@"Cannot open memory store: %@", error);
        [ready fulfill];
    }];

    [self waitForExpectationsWithTimeout:2 handler:nil];
    [session close];
}

@end
