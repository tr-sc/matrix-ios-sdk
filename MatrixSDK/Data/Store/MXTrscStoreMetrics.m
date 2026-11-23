//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXTrscStoreMetrics.h"

#import <QuartzCore/QuartzCore.h>

#import "MXFileStore.h"
#import "MXMemoryStore.h"
#import "MXSQLiteStore.h"
#import "MXSQLiteDatabase.h"

static NSUInteger const MXTrscStoreMetricsLiveProbeMax = 256;

/// Запись ответа синка, ждущая своего коммита.
@interface MXTrscPendingSyncPersist : NSObject
@property (nonatomic, weak) id<MXStore> store;
@property (nonatomic) NSUInteger events;
@property (nonatomic) NSUInteger rooms;
@property (nonatomic) BOOL initial;
@property (nonatomic) NSTimeInterval startedAt;
@end

@implementation MXTrscPendingSyncPersist
@end

@implementation MXTrscStoreMetrics

static id<MXTrscStoreMetricsSink> sSink;
static NSLock *sLock;
static BOOL sStoreOpenReported;
static MXTrscPendingSyncPersist *sPendingPersist;
static NSMutableDictionary<NSString *, NSNumber *> *sLiveProbe;
static NSMutableArray<NSString *> *sLiveProbeOrder;

+ (void)initialize
{
    if (self == MXTrscStoreMetrics.class)
    {
        sLock = [NSLock new];
        sLiveProbe = [NSMutableDictionary dictionary];
        sLiveProbeOrder = [NSMutableArray array];
    }
}

+ (id<MXTrscStoreMetricsSink>)sink
{
    [sLock lock];
    id<MXTrscStoreMetricsSink> sink = sSink;
    [sLock unlock];
    return sink;
}

+ (void)setSink:(id<MXTrscStoreMetricsSink>)sink
{
    [sLock lock];
    sSink = sink;
    if (!sink)
    {
        [sLiveProbe removeAllObjects];
        [sLiveProbeOrder removeAllObjects];
        sPendingPersist = nil;
    }
    [sLock unlock];
}

+ (MXTrscStoreMetrics *)shared
{
    static MXTrscStoreMetrics *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [MXTrscStoreMetrics new]; });
    return shared;
}

+ (void)resetForTests
{
    [sLock lock];
    sStoreOpenReported = NO;
    sPendingPersist = nil;
    [sLiveProbe removeAllObjects];
    [sLiveProbeOrder removeAllObjects];
    [sLock unlock];
}

+ (NSString *)kindOfStore:(id<MXStore>)store
{
    if (!store) return @"none";
    if ([store isKindOfClass:MXSQLiteStore.class]) return @"sqlite";
    if ([store isKindOfClass:MXFileStore.class]) return @"file";
    if ([store isKindOfClass:MXMemoryStore.class]) return @"memory";
    return NSStringFromClass([(NSObject *)store class]);
}

+ (void)event:(NSString *)name milliseconds:(double)milliseconds detail:(NSString *)detail
{
    [self.sink storeMetricsEvent:name milliseconds:milliseconds detail:detail];
}

#pragma mark - Open

+ (void)reportStoreOpen:(id<MXStore>)store milliseconds:(double)milliseconds
{
    id<MXTrscStoreMetricsSink> sink = self.sink;
    if (!sink) return;
    [sLock lock];
    BOOL first = !sStoreOpenReported;
    sStoreOpenReported = YES;
    [sLock unlock];
    if (!first) return;
    // db_open_ms у SQLite — открытие самой базы (ключ, PRAGMA, схема), как у Android; ожидание main на
    // холодном старте видно отдельно в store_open_ms. У MXFileStore базы нет — оба числа одно и то же.
    double databaseOpen = milliseconds;
    MXSQLiteDatabase *database = nil;
    if ([store isKindOfClass:MXSQLiteStore.class])
    {
        database = [(MXSQLiteStore *)store database];
        if (database) databaseOpen = database.openMilliseconds;
    }
    [sink storeMetricsContext:@"db_open_ms" value:@((NSInteger)llround(databaseOpen))];
    [sink storeMetricsContext:@"store_open_ms" value:@((NSInteger)llround(milliseconds))];
    [sink storeMetricsContext:@"store" value:[self kindOfStore:store]];
    if (database)
    {
        [sink storeMetricsContext:@"db_mb" value:@((NSInteger)llround(database.fileSize / (1024.0 * 1024.0)))];
    }
}

#pragma mark - Sync persist

+ (BOOL)isWorthAJournalLine:(NSUInteger)rooms initial:(BOOL)initial
{
    // Пустой long-poll пишет только токен.
    return rooms > 0 || initial;
}

+ (void)beginSyncPersistOfStore:(id<MXStore>)store events:(NSUInteger)events rooms:(NSUInteger)rooms initial:(BOOL)initial
{
    if (!self.sink) return;
    MXTrscPendingSyncPersist *pending = nil;
    if ([self isWorthAJournalLine:rooms initial:initial])
    {
        pending = [MXTrscPendingSyncPersist new];
        pending.store = store;
        pending.events = events;
        pending.rooms = rooms;
        pending.initial = initial;
        pending.startedAt = CACurrentMediaTime();
    }
    [sLock lock];
    sPendingPersist = pending;
    [sLock unlock];
}

+ (void)endSyncPersistOfStore:(id<MXStore>)store
{
    [sLock lock];
    MXTrscPendingSyncPersist *pending = sPendingPersist;
    BOOL mine = pending && pending.store == store;
    if (mine) sPendingPersist = nil;
    [sLock unlock];
    if (!mine) return;
    // SQLite пишет свою транзакцию сам (store:didCommitInMilliseconds:); дошло сюда — коммит был пустым.
    if ([store isKindOfClass:MXSQLiteStore.class]) return;
    [self reportSyncPersist:store milliseconds:(CACurrentMediaTime() - pending.startedAt) * 1000
                     events:pending.events rooms:pending.rooms initial:pending.initial];
}

+ (void)reportSyncPersist:(id<MXStore>)store milliseconds:(double)milliseconds events:(NSUInteger)events
                    rooms:(NSUInteger)rooms initial:(BOOL)initial
{
    if (![self isWorthAJournalLine:rooms initial:initial]) return;
    NSString *detail = [NSString stringWithFormat:@"events=%tu rooms=%tu initial=%@ store=%@",
                        events, rooms, initial ? @"true" : @"false", [self kindOfStore:store]];
    [self event:@"sync_persist_ms" milliseconds:milliseconds detail:detail];
}

#pragma mark - Timeline

+ (void)reportChatWindow:(id<MXStore>)store milliseconds:(double)milliseconds rows:(NSUInteger)rows anchor:(NSString *)anchor
{
    if (!rows) return;
    NSString *detail = [NSString stringWithFormat:@"rows=%tu anchor=%@ store=%@", rows, anchor, [self kindOfStore:store]];
    [self event:@"chat_window_ms" milliseconds:milliseconds detail:detail];
}

+ (void)reportPageFetch:(id<MXStore>)store milliseconds:(double)milliseconds direction:(NSString *)direction
                  count:(NSUInteger)count rows:(NSUInteger)rows
{
    NSString *detail = [NSString stringWithFormat:@"dir=%@ count=%tu rows=%tu store=%@", direction, count, rows,
                        [self kindOfStore:store]];
    [self event:@"page_fetch_ms" milliseconds:milliseconds detail:detail];
}

#pragma mark - Live insert

+ (void)noteSyncEventIds:(NSArray<NSString *> *)eventIds
{
    [self noteSyncEventIds:eventIds at:CACurrentMediaTime()];
}

+ (void)noteSyncEventIds:(NSArray<NSString *> *)eventIds at:(NSTimeInterval)time
{
    if (!eventIds.count || !self.sink) return;
    [sLock lock];
    for (NSString *eventId in eventIds)
    {
        if (!sLiveProbe[eventId]) [sLiveProbeOrder addObject:eventId];
        sLiveProbe[eventId] = @(time);
    }
    while (sLiveProbeOrder.count > MXTrscStoreMetricsLiveProbeMax)
    {
        [sLiveProbe removeObjectForKey:sLiveProbeOrder.firstObject];
        [sLiveProbeOrder removeObjectAtIndex:0];
    }
    [sLock unlock];
}

+ (void)reportLiveEventDelivered:(NSString *)eventId roomId:(NSString *)roomId store:(id<MXStore>)store
{
    [self reportLiveEventDelivered:eventId roomId:roomId store:store at:CACurrentMediaTime()];
}

+ (void)reportLiveEventDelivered:(NSString *)eventId roomId:(NSString *)roomId store:(id<MXStore>)store
                              at:(NSTimeInterval)time
{
    if (!eventId) return;
    id<MXTrscStoreMetricsSink> sink = self.sink;
    if (!sink) return;
    [sLock lock];
    BOOL probing = sLiveProbe.count > 0;
    [sLock unlock];
    if (!probing) return;
    // Догоняющий синк на старте отдаёт события и в ленты закрытых комнат — это не вставка в чат.
    if ([sink respondsToSelector:@selector(storeMetricsShowsRoom:)] && !(roomId && [sink storeMetricsShowsRoom:roomId])) return;
    [sLock lock];
    if (!sLiveProbe.count)
    {
        [sLock unlock];
        return;
    }
    NSNumber *noted = sLiveProbe[eventId];
    if (noted)
    {
        [sLiveProbe removeObjectForKey:eventId];
        [sLiveProbeOrder removeObject:eventId];
    }
    [sLock unlock];
    if (!noted) return;
    [self event:@"live_insert_ms" milliseconds:(time - noted.doubleValue) * 1000
         detail:[NSString stringWithFormat:@"store=%@", [self kindOfStore:store]]];
}

#pragma mark - MXStoreMetricsDelegate

- (void)store:(id<MXStore>)store didCommitInMilliseconds:(double)milliseconds events:(NSUInteger)events rooms:(NSUInteger)rooms
{
    [sLock lock];
    MXTrscPendingSyncPersist *pending = sPendingPersist;
    BOOL mine = pending && pending.store == store;
    if (mine) sPendingPersist = nil;
    [sLock unlock];
    if (!mine) return;
    [MXTrscStoreMetrics reportSyncPersist:store milliseconds:milliseconds events:pending.events rooms:pending.rooms
                                  initial:pending.initial];
}

@end
