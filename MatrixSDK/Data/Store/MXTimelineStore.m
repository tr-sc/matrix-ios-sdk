//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXTimelineStore.h"

NSString *const MXStoreDidCommitNotification = @"MXStoreDidCommitNotification";
int64_t const MXRoomHoleOpenStart = INT64_MIN;
int64_t const MXRoomHoleOpenEnd = INT64_MAX;

@implementation MXRoomHole

- (instancetype)initWithRoomId:(NSString *)roomId
                      threadId:(NSString *)threadId
                    lowerOrder:(int64_t)lowerOrder
                    upperOrder:(int64_t)upperOrder
                 backwardToken:(NSString *)backwardToken
                  forwardToken:(NSString *)forwardToken
                  retryBlocked:(BOOL)retryBlocked
{
    self = [super init];
    if (self)
    {
        _roomId = [roomId copy];
        _threadId = [threadId copy];
        _lowerOrder = lowerOrder;
        _upperOrder = upperOrder;
        _backwardToken = [backwardToken copy];
        _forwardToken = [forwardToken copy];
        _retryBlocked = retryBlocked;
        _holeId = [NSString stringWithFormat:@"%@|%@|%lld", roomId, threadId ?: @"", upperOrder];
    }
    return self;
}

- (BOOL)isOpenEnded
{
    return _upperOrder == MXRoomHoleOpenEnd;
}

- (BOOL)isOpenStarted
{
    return _lowerOrder == MXRoomHoleOpenStart;
}

- (id)copyWithZone:(NSZone *)zone
{
    // Неизменяемый снимок.
    return self;
}

- (BOOL)isEqual:(id)object
{
    if (self == object)
    {
        return YES;
    }
    if (![object isKindOfClass:MXRoomHole.class])
    {
        return NO;
    }
    MXRoomHole *other = object;
    return [_holeId isEqualToString:other.holeId]
        && _lowerOrder == other.lowerOrder
        && _retryBlocked == other.retryBlocked
        && (_backwardToken == other.backwardToken || [_backwardToken isEqualToString:other.backwardToken])
        && (_forwardToken == other.forwardToken || [_forwardToken isEqualToString:other.forwardToken]);
}

- (NSUInteger)hash
{
    return _holeId.hash;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MXRoomHole %@ (%lld, %lld)%@>", _holeId, _lowerOrder, _upperOrder,
            _retryBlocked ? @" blocked" : @""];
}

@end

@implementation MXStorePage

- (instancetype)initWithEvents:(NSArray<MXEvent *> *)events
                    holeBefore:(MXRoomHole *)holeBefore
                     holeAfter:(MXRoomHole *)holeAfter
               reachedRoomStart:(BOOL)reachedRoomStart
                reachedLiveEdge:(BOOL)reachedLiveEdge
                       revision:(NSUInteger)revision
{
    self = [super init];
    if (self)
    {
        _events = [events copy];
        _holeBefore = holeBefore;
        _holeAfter = holeAfter;
        _reachedRoomStart = reachedRoomStart;
        _reachedLiveEdge = reachedLiveEdge;
        _revision = revision;
    }
    return self;
}

+ (instancetype)emptyPage
{
    return [[self alloc] initWithEvents:@[] holeBefore:nil holeAfter:nil
                       reachedRoomStart:NO reachedLiveEdge:NO revision:0];
}

@end
