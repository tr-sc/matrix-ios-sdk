//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteOverlay.h"

#import <os/lock.h>

@interface MXSQLiteOverlay ()
{
    os_unfair_lock _lock;
    NSMutableDictionary *_pending;
    /// Партии в полёте, от старой к новой.
    NSMutableArray<NSMutableDictionary *> *_inflight;
    NSMutableDictionary *_cache;
}
@end

@implementation MXSQLiteOverlay

- (instancetype)init
{
    return [self initWithCommittedCache:NO];
}

- (instancetype)initWithCommittedCache:(BOOL)cachesCommitted
{
    self = [super init];
    if (self)
    {
        _lock = OS_UNFAIR_LOCK_INIT;
        _pending = [NSMutableDictionary dictionary];
        _inflight = [NSMutableArray array];
        _cache = cachesCommitted ? [NSMutableDictionary dictionary] : nil;
    }
    return self;
}

- (void)setObject:(id)object forKey:(id<NSCopying>)key
{
    os_unfair_lock_lock(&_lock);
    _pending[key] = object;
    os_unfair_lock_unlock(&_lock);
}

/// Под замком.
- (id)unlockedObjectForKey:(id<NSCopying>)key
{
    id value = _pending[key];
    if (value)
    {
        return value;
    }
    for (NSDictionary *batch in _inflight.reverseObjectEnumerator)
    {
        value = batch[key];
        if (value)
        {
            return value;
        }
    }
    return nil;
}

- (id)objectForKey:(id<NSCopying>)key
{
    os_unfair_lock_lock(&_lock);
    id value = [self unlockedObjectForKey:key];
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (id)pendingObjectForKey:(id<NSCopying>)key
{
    os_unfair_lock_lock(&_lock);
    id value = _pending[key];
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (id)cachedObjectForKey:(id<NSCopying>)key
{
    os_unfair_lock_lock(&_lock);
    id value = [self unlockedObjectForKey:key] ?: _cache[key];
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)cacheObject:(id)object forKey:(id<NSCopying>)key
{
    os_unfair_lock_lock(&_lock);
    if (_cache && !_cache[key])
    {
        _cache[key] = object;
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSDictionary *)snapshot
{
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary *batch in _inflight)
    {
        [result addEntriesFromDictionary:batch];
    }
    [result addEntriesFromDictionary:_pending];
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (BOOL)hasPending
{
    os_unfair_lock_lock(&_lock);
    BOOL result = _pending.count > 0;
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (NSDictionary *)take
{
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *batch = _pending;
    _pending = [NSMutableDictionary dictionary];
    [_inflight addObject:batch];
    NSDictionary *result = [batch copy];
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (void)finishOldestCommitted:(BOOL)committed
{
    os_unfair_lock_lock(&_lock);
    if (!_inflight.count)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    NSMutableDictionary *batch = _inflight.firstObject;
    [_inflight removeObjectAtIndex:0];
    if (committed)
    {
        [_cache addEntriesFromDictionary:batch];
    }
    else
    {
        [batch enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if (self->_pending[key])
            {
                return;
            }
            for (NSDictionary *newer in self->_inflight)
            {
                if (newer[key])
                {
                    return;
                }
            }
            self->_pending[key] = value;
        }];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)removeKeysPassingTest:(BOOL (NS_NOESCAPE ^)(id))test
{
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSMutableDictionary *> *layers = [NSMutableArray arrayWithObject:_pending];
    [layers addObjectsFromArray:_inflight];
    if (_cache)
    {
        [layers addObject:_cache];
    }
    for (NSMutableDictionary *layer in layers)
    {
        for (id key in layer.allKeys)
        {
            if (test(key))
            {
                [layer removeObjectForKey:key];
            }
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)removeAll
{
    os_unfair_lock_lock(&_lock);
    [_pending removeAllObjects];
    // Партии в полёте остаются пустыми: подтверждения от писателя ещё придут и снимут их по одной.
    for (NSMutableDictionary *batch in _inflight)
    {
        [batch removeAllObjects];
    }
    [_cache removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

@end
