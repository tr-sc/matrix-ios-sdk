//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteHoleSet.h"

@interface MXSQLiteHoleSet ()
@property (nonatomic, readonly) NSMutableArray<MXRoomHole *> *storage;
@end

@implementation MXSQLiteHoleSet

- (instancetype)initWithRoomId:(NSString *)roomId threadId:(NSString *)threadId
{
    return [self initWithRoomId:roomId threadId:threadId holes:@[]];
}

- (instancetype)initWithRoomId:(NSString *)roomId threadId:(NSString *)threadId holes:(NSArray<MXRoomHole *> *)holes
{
    self = [super init];
    if (self)
    {
        _roomId = [roomId copy];
        _threadId = threadId.length ? [threadId copy] : nil;
        _storage = [NSMutableArray arrayWithCapacity:holes.count];
        // Через add: чужие данные (база, тест) тоже приводятся к инварианту.
        for (MXRoomHole *hole in holes)
        {
            [self addHoleWithLowerOrder:hole.lowerOrder upperOrder:hole.upperOrder
                          backwardToken:hole.backwardToken forwardToken:hole.forwardToken];
        }
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    MXSQLiteHoleSet *copy = [[MXSQLiteHoleSet alloc] initWithRoomId:_roomId threadId:_threadId];
    [copy.storage addObjectsFromArray:_storage];
    return copy;
}

- (NSArray<MXRoomHole *> *)holes
{
    return [_storage copy];
}

- (BOOL)isEmpty
{
    return _storage.count == 0;
}

- (NSString *)description
{
    NSMutableArray *parts = [NSMutableArray array];
    for (MXRoomHole *hole in _storage)
    {
        [parts addObject:[NSString stringWithFormat:@"(%lld,%lld)", hole.lowerOrder, hole.upperOrder]];
    }
    return [NSString stringWithFormat:@"<holes %@|%@ %@>", _roomId, _threadId ?: @"", [parts componentsJoinedByString:@" "]];
}

+ (BOOL)isEmptyRangeLower:(int64_t)lower upper:(int64_t)upper
{
    // Позиций нет, если upper <= lower + 1; без переполнения на краях int64.
    return upper <= lower || upper - 1 <= lower;
}

- (MXRoomHole *)holeWithLower:(int64_t)lower upper:(int64_t)upper backward:(NSString *)backward forward:(NSString *)forward
{
    return [[MXRoomHole alloc] initWithRoomId:_roomId threadId:_threadId lowerOrder:lower upperOrder:upper
                                backwardToken:backward forwardToken:forward retryBlocked:NO];
}

/// Индекс вставки по upperOrder.
- (NSUInteger)insertionIndexForUpper:(int64_t)upper
{
    NSUInteger low = 0, high = _storage.count;
    while (low < high)
    {
        NSUInteger mid = (low + high) / 2;
        if (_storage[mid].upperOrder < upper) low = mid + 1; else high = mid;
    }
    return low;
}

#pragma mark - Поиск

- (MXRoomHole *)holeContainingOrder:(int64_t)order
{
    // Первая дыра с hi > order; дыры не пересекаются, поэтому только она может содержать order.
    NSUInteger index = [self insertionIndexForUpper:order];
    while (index < _storage.count && _storage[index].upperOrder <= order) index++;
    if (index < _storage.count && _storage[index].lowerOrder < order)
    {
        return _storage[index];
    }
    return nil;
}

- (MXRoomHole *)highestHoleAtOrBelowOrder:(int64_t)order
{
    NSUInteger index = [self insertionIndexForUpper:order];
    while (index < _storage.count && _storage[index].upperOrder <= order) index++;
    return index > 0 ? _storage[index - 1] : nil;
}

- (MXRoomHole *)lowestHoleAtOrAboveOrder:(int64_t)order
{
    for (MXRoomHole *hole in _storage)
    {
        if (hole.lowerOrder >= order) return hole;
    }
    return nil;
}

- (MXRoomHole *)holeWithUpperOrder:(int64_t)upperOrder
{
    NSUInteger index = [self insertionIndexForUpper:upperOrder];
    if (index < _storage.count && _storage[index].upperOrder == upperOrder) return _storage[index];
    return nil;
}

- (MXRoomHole *)holeWithLowerOrder:(int64_t)lowerOrder
{
    for (MXRoomHole *hole in _storage)
    {
        if (hole.lowerOrder == lowerOrder) return hole;
    }
    return nil;
}

- (MXRoomHole *)openEndedHole
{
    MXRoomHole *last = _storage.lastObject;
    return last.upperOrder == MXRoomHoleOpenEnd ? last : nil;
}

#pragma mark - Изменение

- (void)addHoleWithLowerOrder:(int64_t)lower
                   upperOrder:(int64_t)upper
                backwardToken:(NSString *)backwardToken
                 forwardToken:(NSString *)forwardToken
{
    if ([MXSQLiteHoleSet isEmptyRangeLower:lower upper:upper]) return;

    int64_t newLower = lower, newUpper = upper;
    NSString *backward = backwardToken, *forward = forwardToken;
    NSMutableIndexSet *merged = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < _storage.count; index++)
    {
        MXRoomHole *hole = _storage[index];
        // Сливаются, если между ними нет известной позиции: max(lo) < min(hi). Общая граница
        // (10,20)+(20,30) — известное событие 20, дыры раздельные; (10,21)+(20,30) — одна серия.
        int64_t maxLower = MAX(hole.lowerOrder, lower);
        int64_t minUpper = MIN(hole.upperOrder, upper);
        if (maxLower >= minUpper) continue;
        [merged addIndex:index];
        if (hole.upperOrder > newUpper || (hole.upperOrder == newUpper && !backward))
        {
            newUpper = hole.upperOrder;
            backward = hole.backwardToken;
        }
        if (hole.lowerOrder < newLower || (hole.lowerOrder == newLower && !forward))
        {
            newLower = hole.lowerOrder;
            forward = hole.forwardToken;
        }
    }
    [_storage removeObjectsAtIndexes:merged];
    MXRoomHole *hole = [self holeWithLower:newLower upper:newUpper backward:backward forward:forward];
    [_storage insertObject:hole atIndex:[self insertionIndexForUpper:newUpper]];
}

- (void)fillFromOrder:(int64_t)low toOrder:(int64_t)high lowToken:(NSString *)lowToken highToken:(NSString *)highToken
{
    if (high < low) return;
    NSMutableArray<MXRoomHole *> *result = [NSMutableArray arrayWithCapacity:_storage.count + 1];
    for (MXRoomHole *hole in _storage)
    {
        // Позиции дыры: lo+1 … hi-1. Пересечения с [low, high] нет — дыра остаётся.
        BOOL disjoint = (hole.upperOrder <= low) || (hole.lowerOrder >= high);
        if (disjoint)
        {
            [result addObject:hole];
            continue;
        }
        if (hole.lowerOrder < low && ![MXSQLiteHoleSet isEmptyRangeLower:hole.lowerOrder upper:low])
        {
            [result addObject:[self holeWithLower:hole.lowerOrder upper:low
                                         backward:lowToken ?: hole.backwardToken forward:hole.forwardToken]];
        }
        if (hole.upperOrder > high && ![MXSQLiteHoleSet isEmptyRangeLower:high upper:hole.upperOrder])
        {
            [result addObject:[self holeWithLower:high upper:hole.upperOrder
                                         backward:hole.backwardToken forward:highToken ?: hole.forwardToken]];
        }
    }
    [_storage setArray:result];
}

- (BOOL)removeHoleWithUpperOrder:(int64_t)upperOrder
{
    MXRoomHole *hole = [self holeWithUpperOrder:upperOrder];
    if (!hole) return NO;
    [_storage removeObjectIdenticalTo:hole];
    return YES;
}

- (BOOL)replaceHoleWithUpperOrder:(int64_t)upperOrder
                       lowerOrder:(int64_t)newLower
                       upperOrder:(int64_t)newUpper
                    backwardToken:(NSString *)backwardToken
                     forwardToken:(NSString *)forwardToken
{
    if (![self removeHoleWithUpperOrder:upperOrder]) return NO;
    [self addHoleWithLowerOrder:newLower upperOrder:newUpper backwardToken:backwardToken forwardToken:forwardToken];
    return YES;
}

- (void)removeAllHoles
{
    [_storage removeAllObjects];
}

#pragma mark - Проверка

- (BOOL)isValid
{
    MXRoomHole *previous = nil;
    for (MXRoomHole *hole in _storage)
    {
        if ([MXSQLiteHoleSet isEmptyRangeLower:hole.lowerOrder upper:hole.upperOrder]) return NO;
        if (previous && (previous.upperOrder >= hole.upperOrder || hole.lowerOrder < previous.upperOrder)) return NO;
        previous = hole;
    }
    return YES;
}

@end
