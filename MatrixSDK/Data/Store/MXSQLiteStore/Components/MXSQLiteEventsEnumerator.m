//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteEventsEnumerator.h"

#import "MXEvent.h"
#import "MXSQLitePendingBatch.h"

@implementation MXSQLiteEventsEnumerator
{
    id<MXSQLiteEventsEnumeratorSource> _source;
    NSString *_roomId;
    NSSet<NSString *> *_types;
    /// Ещё не отданные строки, от новых к старым.
    NSMutableArray<MXSQLiteEventRow *> *_buffer;
    /// Нижний ord уже выбранного: следующая выборка — строго ниже.
    int64_t _cursor;
    BOOL _reachedEnd;
}

+ (NSUInteger)pageSize
{
    return 50;
}

- (instancetype)initWithSource:(id<MXSQLiteEventsEnumeratorSource>)source roomId:(NSString *)roomId types:(NSSet<NSString *> *)types
{
    self = [super init];
    if (self)
    {
        _source = source;
        _roomId = [roomId copy];
        _types = [types copy];
        _buffer = [NSMutableArray array];
        _cursor = INT64_MAX;
    }
    return self;
}

- (BOOL)fill
{
    if (_buffer.count) return YES;
    if (_reachedEnd) return NO;
    BOOL reachedEnd = NO;
    NSArray<MXSQLiteEventRow *> *rows = [_source enumeratorRowsInRoom:_roomId belowOrder:_cursor
                                                                limit:MXSQLiteEventsEnumerator.pageSize
                                                                types:_types reachedEnd:&reachedEnd];
    [_buffer addObjectsFromArray:rows];
    if (rows.count) _cursor = rows.lastObject.ord;
    _reachedEnd = reachedEnd || rows.count == 0;
    return _buffer.count > 0;
}

- (MXEvent *)nextEvent
{
    while ([self fill])
    {
        MXSQLiteEventRow *row = _buffer.firstObject;
        [_buffer removeObjectAtIndex:0];
        MXEvent *event = row.event;
        if (event) return event;
    }
    return nil;
}

- (NSArray<MXEvent *> *)nextEventsBatch:(NSUInteger)eventsCount threadId:(NSString *)threadId
{
    if (![self fill]) return nil;
    NSMutableArray<MXEvent *> *result = [NSMutableArray arrayWithCapacity:MIN(eventsCount, 100)];
    NSUInteger counted = 0;
    MXEvent *event;
    while (counted < eventsCount && (event = self.nextEvent))
    {
        if (threadId)
        {
            if ([event.threadId isEqualToString:threadId] || [event.eventId isEqualToString:threadId])
            {
                [result addObject:event];
                counted++;
            }
        }
        else
        {
            // Как MXEventsEnumeratorOnArray: события тредов идут в результат, но не в счёт.
            if (!event.isInThread) counted++;
            [result addObject:event];
        }
    }
    return [[result reverseObjectEnumerator] allObjects];
}

- (NSUInteger)remaining
{
    if (_reachedEnd) return _buffer.count;
    return _buffer.count + [_source enumeratorCountInRoom:_roomId belowOrder:_cursor types:_types];
}

@end
