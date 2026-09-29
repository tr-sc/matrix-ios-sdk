// 
// Copyright 2021 The Matrix.org Foundation C.I.C
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <MatrixSDK/MatrixSDK.h>

NS_ASSUME_NONNULL_BEGIN

/**
 SDK-internal JSON keys that carry the Sliding Sync server's hero and room avatars
 while the response travels through the legacy sync pipeline.
 */
FOUNDATION_EXPORT NSString * const MXRoomSyncSummarySlidingSyncHeroAvatarsJSONKey;
FOUNDATION_EXPORT NSString * const MXRoomSyncSummarySlidingSyncAvatarJSONKey;

/**
 `MXRoomSyncSummary` represents the summary of a room.
 */
@interface MXRoomSyncSummary : MXJSONModel

/**
 Present only if the room has no m.room.name or m.room.canonical_alias.
 Lists the mxids of the first 5 members in the room who are currently joined or
 invited (ordered by stream ordering as seen on the server).
 */
@property (nonatomic) NSArray<NSString*> *heroes;

/**
 The number of m.room.members in state ‘joined’ (including the syncing user).
 -1 means the information was not sent by the server.
 */
@property (nonatomic) NSUInteger joinedMemberCount;

/**
 The number of m.room.members in state ‘invited’.
 -1 means the information was not sent by the server.
 */
@property (nonatomic) NSUInteger invitedMemberCount;

/**
 Avatars of the heroes as computed by a Sliding Sync server from the current room state:
 user id -> mxc string, or NSNull when the hero has no avatar.
 nil when the server did not send hero objects (legacy /sync).
 */
@property (nonatomic, nullable) NSDictionary<NSString*, id> *heroAvatars;

/**
 The room avatar computed by a Sliding Sync server (m.room.avatar, else the first hero's avatar).
 nil when the server did not send it.
 */
@property (nonatomic, nullable) NSString *avatar;

@end

NS_ASSUME_NONNULL_END
