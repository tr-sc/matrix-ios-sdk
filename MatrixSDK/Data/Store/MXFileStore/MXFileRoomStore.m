/*
 Copyright 2014 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXFileRoomStore.h"

static NSString *const kMXFileRoomStoreBackwardPaginationStateV1Key = @"backwardPaginationStateV1";
static NSString *const kMXFileRoomStoreLegacyPaginationEndKey = @"hasReachedHomeServerPaginationEnd";

@implementation MXFileRoomStore

#pragma mark - NSCoding
- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [self init];
    if (self)
    {
        messages = [aDecoder decodeObjectForKey:@"messages"];

        self.paginationToken = [aDecoder decodeObjectForKey:@"paginationToken"];

        if ([aDecoder containsValueForKey:kMXFileRoomStoreBackwardPaginationStateV1Key])
        {
            NSInteger rawState = [aDecoder decodeIntegerForKey:kMXFileRoomStoreBackwardPaginationStateV1Key];
            if (rawState >= (NSInteger)MXRoomBackwardPaginationStateUnknown
                && rawState <= (NSInteger)MXRoomBackwardPaginationStateExhausted)
            {
                self.backwardPaginationState = (MXRoomBackwardPaginationState)rawState;
            }
            else
            {
                MXLogWarning(@"[MXFileRoomStore] Invalid backward pagination state: %@", @(rawState));
                self.backwardPaginationState = MXRoomBackwardPaginationStateUnknown;
            }
        }
        else
        {
            BOOL legacyPaginationEnd = [aDecoder decodeBoolForKey:kMXFileRoomStoreLegacyPaginationEndKey];
            if (!legacyPaginationEnd && self.paginationToken.length > 0)
            {
                self.backwardPaginationState = MXRoomBackwardPaginationStateAvailable;
            }
            else
            {
                // Legacy YES may have been written for a Sliding Sync response whose
                // pagination status was actually unknown, so it cannot be trusted.
                self.backwardPaginationState = MXRoomBackwardPaginationStateUnknown;
            }
        }
        self.hasLoadedAllRoomMembersForRoom = [aDecoder decodeBoolForKey:@"hasLoadedAllRoomMembersForRoom"];

        self.partialAttributedTextMessage = [aDecoder decodeObjectForKey:@"partialAttributedTextMessage"];

        // Rebuild the messagesByEventIds cache
        for (MXEvent *event in messages)
        {
            if (event.eventId)
            {
                messagesByEventIds[event.eventId] = event;
            }
        }
    }
    return self;
}

- (MXFileRoomStore *)archivingSnapshot
{
    MXFileRoomStore *snapshot = [[MXFileRoomStore alloc] init];
    snapshot->messages = [messages mutableCopy];
    snapshot.paginationToken = self.paginationToken;
    snapshot.backwardPaginationState = self.backwardPaginationState;
    snapshot.hasLoadedAllRoomMembersForRoom = self.hasLoadedAllRoomMembersForRoom;
    snapshot.partialAttributedTextMessage = self.partialAttributedTextMessage;
    return snapshot;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    // The goal of the NSCoding implementation here is to store room data to the file system during a [MXFileStore commit].

    // This runs on the file store queue. [MXFileStore commit] archives an `archivingSnapshot` taken on
    // the main thread, not the live store: copying `messages` here raced with the main thread mutating
    // it (a limited sync clearing a room's timeline) and archived events that were already released.
    [aCoder encodeObject:[messages mutableCopy] forKey:@"messages"];

    if (self.paginationToken)
    {
        [aCoder encodeObject:self.paginationToken forKey:@"paginationToken"];
    }
    
    [aCoder encodeInteger:self.backwardPaginationState forKey:kMXFileRoomStoreBackwardPaginationStateV1Key];
    [aCoder encodeBool:self.backwardPaginationState == MXRoomBackwardPaginationStateExhausted
                forKey:kMXFileRoomStoreLegacyPaginationEndKey];
    [aCoder encodeBool:self.hasLoadedAllRoomMembersForRoom forKey:@"hasLoadedAllRoomMembersForRoom"];

    if (self.partialAttributedTextMessage)
    {
        [aCoder encodeObject:self.partialAttributedTextMessage forKey:@"partialAttributedTextMessage"];
    }
}

@end
