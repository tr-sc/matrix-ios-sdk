// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import "MXSlidingSync.h"
#import "MXSyncResponse.h"
#import "MXRoomSync.h"
#import "MXRoomSyncSummary.h"
#import "MXCredentials.h"

NSString *MXSlidingSyncPersistenceKey(MXCredentials *credentials)
{
    NSString *identity = [NSString stringWithFormat:@"%@|%@|%@",
                          credentials.homeServer ?: @"",
                          credentials.userId ?: @"",
                          credentials.deviceId ?: @""];
    return [@"MXSlidingSync." stringByAppendingString:identity];
}

BOOL MXSlidingSyncHasPersistedPosition(MXCredentials *credentials)
{
    NSDictionary *state = [NSUserDefaults.standardUserDefaults dictionaryForKey:MXSlidingSyncPersistenceKey(credentials)];
    id position = state[@"position"];
    return [position isKindOfClass:NSString.class] && [position length] > 0;
}

NSNotificationName const MXSessionRoomListStateDidChangeNotification = @"MXSessionRoomListStateDidChangeNotification";
NSNotificationName const MXSessionSlidingSyncRoomOrderDidChangeNotification = @"MXSessionSlidingSyncRoomOrderDidChangeNotification";

@interface MXSlidingSyncRoomListState ()
@property (nonatomic, readwrite) MXSlidingSyncRoomListPhase phase;
@property (nonatomic, readwrite, getter=isPartial) BOOL partial;
@property (nonatomic, readwrite) NSUInteger loaded;
@property (nonatomic, readwrite) NSUInteger total;
@end

@implementation MXSlidingSyncRoomListState
+ (instancetype)stateWithPhase:(MXSlidingSyncRoomListPhase)phase loaded:(NSUInteger)loaded total:(NSUInteger)total
{
    MXSlidingSyncRoomListState *state = [MXSlidingSyncRoomListState new];
    state.phase = phase;
    state.loaded = loaded;
    state.total = total;
    state.partial = phase != MXSlidingSyncRoomListPhaseComplete;
    return state;
}
- (id)copyWithZone:(NSZone *)zone
{
    MXSlidingSyncRoomListState *copy = [[[self class] allocWithZone:zone] init];
    copy.phase = self.phase;
    copy.partial = self.partial;
    copy.loaded = self.loaded;
    copy.total = self.total;
    return copy;
}
@end

@implementation MXSlidingSyncConfiguration

+ (instancetype)defaultConfiguration
{
    MXSlidingSyncConfiguration *configuration = [MXSlidingSyncConfiguration new];
    configuration.initialWindowSize = 50;
    configuration.expandedWindowSize = 250;
    configuration.backgroundBatchSize = 250;
    configuration.timelineLimit = 1;
    configuration.openRoomTimelineLimit = 20;
    configuration.lazyLoadMembers = YES;
    configuration.backgroundHydrationEnabled = YES;
    configuration.listName = @"main";
    configuration.requiredState = @[
        @[@"m.room.member", @"$ME"],
        // Current member event of every timeline sender: a peer who changed the photo
        // and then wrote arrives with the new avatar even when timeline_limit=1 hides
        // the member event itself.
        @[@"m.room.member", @"$LAZY"],
        @[@"m.room.encryption", @""],
        @[@"m.room.create", @""],
        @[@"m.room.name", @""],
        @[@"m.room.avatar", @""],
        @[@"m.room.canonical_alias", @""],
        @[@"m.room.power_levels", @""],
        @[@"m.room.join_rules", @""],
        @[@"m.room.tombstone", @""]
    ];
    configuration.extensions = @{
        @"e2ee": @{@"enabled": @YES},
        @"to_device": @{@"enabled": @YES},
        @"account_data": @{@"enabled": @YES, @"lists": @[@"main"]},
        @"receipts": @{@"enabled": @YES, @"lists": @[@"main"]},
        @"typing": @{@"enabled": @YES, @"lists": @[@"main"]}
    };
    return configuration;
}

- (id)copyWithZone:(NSZone *)zone
{
    MXSlidingSyncConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.initialWindowSize = self.initialWindowSize;
    copy.expandedWindowSize = self.expandedWindowSize;
    copy.backgroundBatchSize = self.backgroundBatchSize;
    copy.timelineLimit = self.timelineLimit;
    copy.openRoomTimelineLimit = self.openRoomTimelineLimit;
    copy.lazyLoadMembers = self.lazyLoadMembers;
    copy.backgroundHydrationEnabled = self.backgroundHydrationEnabled;
    copy.listName = self.listName;
    copy.requiredState = self.requiredState;
    copy.extensions = self.extensions;
    copy.legacyFallbackSyncFilter = self.legacyFallbackSyncFilter;
    return copy;
}

- (NSDictionary<NSString *,id> *)requestDictionaryWithPosition:(NSString *)position
                                                   connectionId:(NSString *)connectionId
                                                         ranges:(NSArray<NSArray<NSNumber *> *> *)ranges
                                              roomSubscriptions:(NSArray<NSString *> *)roomIds
                                                        timeout:(NSUInteger)timeout
                                                    setPresence:(NSString *)setPresence
{
    return [self requestDictionaryWithPosition:position
                                  connectionId:connectionId
                                        ranges:ranges
                             roomSubscriptions:roomIds
                         openRoomSubscriptions:nil
                                       timeout:timeout
                                   setPresence:setPresence];
}

- (NSDictionary<NSString *,id> *)requestDictionaryWithPosition:(NSString *)position
                                                   connectionId:(NSString *)connectionId
                                                         ranges:(NSArray<NSArray<NSNumber *> *> *)ranges
                                              roomSubscriptions:(NSArray<NSString *> *)roomIds
                                          openRoomSubscriptions:(NSArray<NSString *> *)openRoomIds
                                                        timeout:(NSUInteger)timeout
                                                    setPresence:(NSString *)setPresence
{
    NSMutableDictionary *request = [NSMutableDictionary dictionary];
    if (position.length) request[@"pos"] = position;
    if (connectionId.length) request[@"conn_id"] = connectionId;
    request[@"timeout"] = @(timeout);
    if (setPresence.length) request[@"set_presence"] = setPresence;
    request[@"lists"] = @{
        self.listName: @{
            @"ranges": ranges,
            @"timeline_limit": @(self.timelineLimit),
            @"required_state": self.requiredState ?: @[]
        }
    };
    request[@"extensions"] = self.extensions ?: @{};
    if (roomIds.count || openRoomIds.count)
    {
        NSMutableDictionary *subscriptions = [NSMutableDictionary dictionaryWithCapacity:roomIds.count + openRoomIds.count];
        for (NSString *roomId in roomIds)
        {
            subscriptions[roomId] = @{
                @"timeline_limit": @(MAX(self.timelineLimit, 1)),
                @"required_state": self.requiredState ?: @[]
            };
        }
        // An open room may also be a plain subscription (opened outside the list window):
        // the larger limit wins, the server takes one config per subscribed room.
        for (NSString *roomId in openRoomIds)
        {
            subscriptions[roomId] = @{
                @"timeline_limit": @(MAX(MAX(self.openRoomTimelineLimit, self.timelineLimit), 1)),
                @"required_state": self.requiredState ?: @[]
            };
        }
        request[@"room_subscriptions"] = subscriptions;
    }
    return request;
}
@end

@implementation MXSlidingSyncListOperation
+ (id)modelFromJSON:(NSDictionary *)json
{
    MXSlidingSyncListOperation *model = [MXSlidingSyncListOperation new];
    MXJSONModelSetString(model.operation, json[@"op"]);
    MXJSONModelSetArray(model.range, json[@"range"]);
    MXJSONModelSetArray(model.roomIds, json[@"room_ids"]);
    MXJSONModelSetNumber(model.index, json[@"index"]);
    MXJSONModelSetNumber(model.fromIndex, json[@"from"] ?: json[@"from_index"]);
    MXJSONModelSetNumber(model.toIndex, json[@"to"] ?: json[@"to_index"]);
    MXJSONModelSetString(model.roomId, json[@"room_id"]);
    return model;
}
- (NSDictionary *)JSONDictionary
{
    NSMutableDictionary *json = [@{@"op": self.operation ?: @""} mutableCopy];
    if (self.range) json[@"range"] = self.range;
    if (self.roomIds) json[@"room_ids"] = self.roomIds;
    if (self.index) json[@"index"] = self.index;
    if (self.fromIndex) json[@"from"] = self.fromIndex;
    if (self.toIndex) json[@"to"] = self.toIndex;
    if (self.roomId) json[@"room_id"] = self.roomId;
    return json;
}
@end

@implementation MXSlidingSyncList
+ (id)modelFromJSON:(NSDictionary *)json
{
    MXSlidingSyncList *model = [MXSlidingSyncList new];
    NSNumber *count;
    MXJSONModelSetNumber(count, json[@"count"]);
    model.hasCount = [json[@"count"] isKindOfClass:NSNumber.class] && count.longLongValue >= 0;
    model.count = count.unsignedIntegerValue;
    NSArray *operationsJSON;
    MXJSONModelSetArray(operationsJSON, json[@"ops"]);
    NSMutableArray *operations = [NSMutableArray array];
    for (NSDictionary *operationJSON in operationsJSON)
    {
        if ([operationJSON isKindOfClass:NSDictionary.class])
            [operations addObject:[MXSlidingSyncListOperation modelFromJSON:operationJSON]];
    }
    model.operations = operations;
    return model;
}
- (NSDictionary *)JSONDictionary
{
    NSMutableArray *operations = [NSMutableArray arrayWithCapacity:self.operations.count];
    for (MXSlidingSyncListOperation *operation in self.operations) [operations addObject:operation.JSONDictionary];
    return @{@"count": @(self.count), @"ops": operations};
}
@end

@implementation MXSlidingSyncResponse
+ (id)modelFromJSON:(NSDictionary *)json
{
    MXSlidingSyncResponse *model = [MXSlidingSyncResponse new];
    MXJSONModelSetString(model.position, json[@"pos"]);
    MXJSONModelSetString(model.transactionId, json[@"txn_id"]);
    NSDictionary *listsJSON;
    MXJSONModelSetDictionary(listsJSON, json[@"lists"]);
    NSMutableDictionary *lists = [NSMutableDictionary dictionary];
    [listsJSON enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *value, BOOL *stop) {
        if ([value isKindOfClass:NSDictionary.class]) lists[key] = [MXSlidingSyncList modelFromJSON:value];
    }];
    model.lists = lists;
    MXJSONModelSetDictionary(model.rooms, json[@"rooms"]);
    MXJSONModelSetDictionary(model.extensions, json[@"extensions"]);
    model.rooms = model.rooms ?: @{};
    model.extensions = model.extensions ?: @{};
    return model;
}

- (NSDictionary *)JSONDictionary
{
    NSMutableDictionary *lists = [NSMutableDictionary dictionary];
    [self.lists enumerateKeysAndObjectsUsingBlock:^(NSString *key, MXSlidingSyncList *value, BOOL *stop) { lists[key] = value.JSONDictionary; }];
    return @{@"pos": self.position ?: @"", @"lists": lists, @"rooms": self.rooms ?: @{}, @"extensions": self.extensions ?: @{}};
}

NSString *MXSlidingSyncMembershipForRoom(NSDictionary *room, NSString *userId)
{
    if ([room[@"membership"] isKindOfClass:NSString.class]) return room[@"membership"];
    NSArray *state = room[@"required_state"];
    for (NSDictionary *event in state)
    {
        if ([event[@"type"] isEqual:@"m.room.member"] && [event[@"state_key"] isEqual:userId])
            return event[@"content"][@"membership"];
    }
    return room[@"invite_state"] ? @"invite" : @"join";
}

- (id)legacySyncResponseForUserId:(NSString *)userId
{
    NSMutableDictionary *join = [NSMutableDictionary dictionary];
    NSMutableDictionary *invite = [NSMutableDictionary dictionary];
    NSMutableDictionary *leave = [NSMutableDictionary dictionary];
    NSDictionary *accountData = self.extensions[@"account_data"];
    NSDictionary *roomAccountData = accountData[@"rooms"];
    NSDictionary *receipts = self.extensions[@"receipts"][@"rooms"];
    NSDictionary *typing = self.extensions[@"typing"][@"rooms"];

    [self.rooms enumerateKeysAndObjectsUsingBlock:^(NSString *roomId, NSDictionary *room, BOOL *stop) {
        NSString *membership = MXSlidingSyncMembershipForRoom(room, userId);
        if ([membership isEqual:@"invite"])
        {
            NSArray *events = room[@"invite_state"] ?: room[@"required_state"] ?: @[];
            invite[roomId] = @{@"invite_state": @{@"events": events}};
            return;
        }
        NSMutableDictionary *legacyRoom = [NSMutableDictionary dictionary];
        legacyRoom[@"state"] = @{@"events": room[@"required_state"] ?: @[]};
        NSMutableDictionary *timeline = [@{@"events": room[@"timeline"] ?: @[]} mutableCopy];
        id limited = room[@"limited"];
        if ([limited isKindOfClass:NSNumber.class])
        {
            timeline[@"limited"] = limited;
        }
        id previousBatch = room[@"prev_batch"];
        if ([previousBatch isKindOfClass:NSString.class])
        {
            timeline[@"prev_batch"] = previousBatch;
        }
        legacyRoom[@"timeline"] = timeline;
        legacyRoom[MXRoomSyncSlidingSyncInitialJSONKey] = @([room[@"initial"] boolValue]);
        NSDictionary *unread = room[@"unread_notifications"];
        if (!unread && (room[@"notification_count"] || room[@"highlight_count"]))
            unread = @{@"notification_count": room[@"notification_count"] ?: @0,
                       @"highlight_count": room[@"highlight_count"] ?: @0};
        if (unread) legacyRoom[@"unread_notifications"] = unread;
        NSDictionary *summary = room[@"summary"];
        if (!summary && (room[@"heroes"] || room[@"joined_count"] || room[@"invited_count"]))
        {
            NSMutableArray *heroIds = [NSMutableArray array];
            // The server computes hero avatars from the current member state on every
            // response. Keep them: a DM whose peer m.room.member fell into a limited
            // timeline gap would otherwise keep the old photo.
            NSMutableDictionary *heroAvatars = [NSMutableDictionary dictionary];
            for (id hero in room[@"heroes"] ?: @[])
            {
                if ([hero isKindOfClass:NSString.class]) [heroIds addObject:hero];
                else if ([hero isKindOfClass:NSDictionary.class] && [hero[@"user_id"] isKindOfClass:NSString.class])
                {
                    [heroIds addObject:hero[@"user_id"]];
                    id heroAvatar = hero[@"avatar_url"];
                    heroAvatars[hero[@"user_id"]] = [heroAvatar isKindOfClass:NSString.class] ? heroAvatar : NSNull.null;
                }
            }
            NSMutableDictionary *legacySummary = [@{@"m.heroes": heroIds,
                                                    @"m.joined_member_count": room[@"joined_count"] ?: @0,
                                                    @"m.invited_member_count": room[@"invited_count"] ?: @0} mutableCopy];
            if (heroAvatars.count) legacySummary[MXRoomSyncSummarySlidingSyncHeroAvatarsJSONKey] = heroAvatars;
            id roomAvatar = room[@"avatar"];
            if ([roomAvatar isKindOfClass:NSString.class]) legacySummary[MXRoomSyncSummarySlidingSyncAvatarJSONKey] = roomAvatar;
            summary = legacySummary;
        }
        if (summary) legacyRoom[@"summary"] = summary;
        NSArray *roomAccountEvents = roomAccountData[roomId];
        if ([roomAccountEvents isKindOfClass:NSDictionary.class]) roomAccountEvents = ((NSDictionary *)roomAccountEvents)[@"events"];
        legacyRoom[@"account_data"] = @{@"events": roomAccountEvents ?: @[]};
        NSMutableArray *ephemeral = [NSMutableArray array];
        id receipt = receipts[roomId];
        if ([receipt isKindOfClass:NSDictionary.class] && receipt[@"type"]) [ephemeral addObject:receipt];
        else if (receipt) [ephemeral addObject:@{@"type": @"m.receipt", @"content": receipt}];
        id typingRoom = typing[roomId];
        if ([typingRoom isKindOfClass:NSDictionary.class] && typingRoom[@"type"]) [ephemeral addObject:typingRoom];
        else if (typingRoom) [ephemeral addObject:@{@"type": @"m.typing", @"content": typingRoom}];
        legacyRoom[@"ephemeral"] = @{@"events": ephemeral};
        if ([membership isEqual:@"leave"] || [membership isEqual:@"ban"]) leave[roomId] = legacyRoom;
        else join[roomId] = legacyRoom;
    }];

    NSDictionary *e2ee = self.extensions[@"e2ee"] ?: @{};
    NSDictionary *toDevice = self.extensions[@"to_device"] ?: @{};
    NSArray *globalAccountData = accountData[@"global"];
    if ([globalAccountData isKindOfClass:NSDictionary.class]) globalAccountData = ((NSDictionary *)globalAccountData)[@"events"];
    NSDictionary *json = @{
        @"next_batch": self.position ?: @"",
        @"rooms": @{@"join": join, @"invite": invite, @"leave": leave},
        @"to_device": @{@"events": toDevice[@"events"] ?: @[]},
        @"device_lists": e2ee[@"device_lists"] ?: @{},
        @"device_one_time_keys_count": e2ee[@"device_one_time_keys_count"] ?: @{},
        @"org.matrix.msc2732.device_unused_fallback_key_types": e2ee[@"device_unused_fallback_key_types"] ?: @[],
        @"account_data": @{@"events": globalAccountData ?: @[]}
    };
    return [MXSyncResponse modelFromJSON:json];
}
@end
