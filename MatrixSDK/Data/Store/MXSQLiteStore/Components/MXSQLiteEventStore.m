//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteEventStore.h"

#import "MXEvent+TrscOrder.h"
#import "MXEventUnsignedData.h"
#import "MXJSONModels.h"
#import "MXLog.h"
#import "MXSQLiteDatabase.h"
#import "MXSQLiteEventsEnumerator.h"
#import "MXSQLitePendingBatch.h"
#import "MXSQLiteRoomRegistry.h"

/// Пространство основной ленты в таблице `hole`.
static NSString *const kMainSpace = @"";
/// Предел для старых методов, которые отдавали «всё в памяти» (непрерывный хвост, блок перед дырой, новые входящие).
static const NSUInteger kLegacyListLimit = 500;

static NSString *MXSQLiteTokenForOrder(int64_t order)
{
    return [NSString stringWithFormat:@"%lld", order];
}

/// Непрерывный кусок ленты: строки и то, что вокруг них.
@interface MXSQLiteSegment : NSObject
@property (nonatomic) NSArray<MXSQLiteEventRow *> *rows;     // по возрастанию
@property (nonatomic, nullable) MXRoomHole *holeBelow;        // дыра сразу под куском
@property (nonatomic, nullable) MXRoomHole *holeAbove;        // дыра сразу над куском
@property (nonatomic) BOOL more;                              // в сторону чтения есть ещё строки того же куска
@property (nonatomic) BOOL reachedStart;
@property (nonatomic) BOOL reachedLive;
@end

@implementation MXSQLiteSegment
@end

@interface MXSQLiteEventStore () <MXSQLiteEventsEnumeratorSource>
@property (nonatomic, readonly) MXSQLiteStoreContext *context;
@end

@implementation MXSQLiteEventStore
{
    /// Накладка: пачки от старой к новой. Последняя (если не `taken`) принимает записи.
    NSMutableArray<MXSQLitePendingBatch *> *_layers;
    /// Отданные писателю группы пачек по порядку `takePendingWrites`.
    NSMutableArray<NSArray<MXSQLitePendingBatch *> *> *_takenGroups;
    /// Замок накладки. Рекурсивный: методы записи читают через те же помощники, что и чтение.
    /// Правило: под замком можно брать читателя базы, но не наоборот (замок не берётся внутри блока `read:`).
    NSRecursiveLock *_lock;
    /// В `redaction_pending` базы могут быть строки (иначе точечную проверку при вставке можно пропустить).
    NSNumber *_databaseHasPendingRedactions;
}

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        _context = context;
        _layers = [NSMutableArray array];
        _takenGroups = [NSMutableArray array];
        _lock = [NSRecursiveLock new];
        _lock.name = @"MXSQLiteEventStore";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onDidDecryptEvent:)
                                                   name:kMXEventDidDecryptNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Overlay plumbing

/// Пачка для записи. Под замком.
- (MXSQLitePendingBatch *)currentBatch
{
    MXSQLitePendingBatch *last = _layers.lastObject;
    if (!last || last.taken)
    {
        last = [MXSQLitePendingBatch new];
        [_layers addObject:last];
    }
    return last;
}

- (NSArray<MXSQLitePendingBatch *> *)snapshotLayers
{
    [_lock lock];
    NSArray *layers = [_layers copy];
    [_lock unlock];
    return layers;
}

/// Чтение базы по rid комнаты. nil — базы нет (до открытия) или комнаты нет.
- (id)read:(id (^NS_NOESCAPE)(MXSQLiteConnection *connection, int64_t rid))body roomId:(NSString *)roomId
{
    MXSQLiteDatabase *database = self.context.database;
    if (!database) return nil;
    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    return [database read:^id(MXSQLiteConnection *connection) {
        int64_t rid = [rooms ridForRoomId:roomId connection:connection];
        if (rid == MXSQLiteNoRoom) return nil;
        return body(connection, rid);
    }];
}

+ (NSString *)spaceForThread:(NSString *)threadId
{
    return (threadId.length && ![threadId isEqualToString:kMXEventTimelineMain]) ? threadId : kMainSpace;
}

#pragma mark - Merged reads (overlay over the database)

- (NSArray<MXSQLiteEventRow *> *)databaseRowsInRoom:(NSString *)roomId
                                             filter:(MXSQLiteEventFilter *)filter
                                         descending:(BOOL)descending
                                              limit:(NSUInteger)limit
                                       minTimestamp:(int64_t)minTs
{
    NSString *columns = MXSQLiteEventRow.selectColumns;
    NSArray *rows = [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        NSString *condition = [filter sqlConditionWithMinTimestamp:minTs];
        int limitIndex = [filter nextParameterIndexWithMinTimestamp:minTs];
        NSString *order = descending ? @"ord DESC, sub DESC" : @"ord ASC, sub ASC";
        NSString *sql = limit == NSUIntegerMax
            ? [NSString stringWithFormat:@"SELECT %@ FROM event WHERE %@ ORDER BY %@", columns, condition, order]
            : [NSString stringWithFormat:@"SELECT %@ FROM event WHERE %@ ORDER BY %@ LIMIT ?%d", columns, condition, order, limitIndex];
        NSError *error;
        NSMutableArray *result = [[connection query:sql bind:^(MXSQLiteStatement *statement) {
            [filter bindTo:statement rid:rid minTimestamp:minTs];
            if (limit != NSUIntegerMax) [statement bindInt64:(int64_t)MIN(limit, (NSUInteger)INT64_MAX) at:limitIndex];
        } row:^id(MXSQLiteStatement *statement) {
            return [[MXSQLiteEventRow alloc] initWithStatement:statement roomId:roomId];
        } error:&error] mutableCopy];
        if (!result)
        {
            MXLogErrorDetails(@"[MXSQLiteEventStore] query failed", @{@"error": error ?: @"?"});
            return @[];
        }
        if (filter.threadScope == MXSQLiteThreadScopeThread && filter.includeThreadRoot && filter.threadId)
        {
            // Корень треда — точечной выборкой (OR по event_id в основном запросе ломает индекс event_thread).
            MXSQLiteEventFilter *rootFilter = [filter copy];
            rootFilter.threadScope = MXSQLiteThreadScopeAll;
            rootFilter.eventId = filter.threadId;
            NSString *rootSql = [NSString stringWithFormat:@"SELECT %@ FROM event WHERE %@", columns,
                                 [rootFilter sqlConditionWithMinTimestamp:minTs]];
            NSArray *root = [connection query:rootSql bind:^(MXSQLiteStatement *statement) {
                [rootFilter bindTo:statement rid:rid minTimestamp:minTs];
            } row:^id(MXSQLiteStatement *statement) {
                return [[MXSQLiteEventRow alloc] initWithStatement:statement roomId:roomId];
            } error:nil];
            [result addObjectsFromArray:root ?: @[]];
        }
        return result;
    } roomId:roomId];
    return rows ?: @[];
}

/// Строки комнаты под фильтром с учётом накладки: первые `limit` от новых (`descending`) или от старых.
/// Результат всегда по возрастанию порядка ленты.
- (NSArray<MXSQLiteEventRow *> *)rowsInRoom:(NSString *)roomId
                                     filter:(MXSQLiteEventFilter *)filter
                                 descending:(BOOL)descending
                                      limit:(NSUInteger)limit
                                     layers:(NSArray<MXSQLitePendingBatch *> *)layers
{
    if (limit == 0) return @[];
    int64_t minTs = INT64_MIN;
    NSUInteger shadow = 0;
    BOOL allowDatabase = [MXSQLitePendingBatch layers:layers allowDatabaseRowsOfRoom:roomId minTimestamp:&minTs shadowCount:&shadow];
    // Запас на строки базы, которые заслонит накладка (удалены или переехали).
    NSUInteger databaseLimit = (limit == NSUIntegerMax || shadow > NSUIntegerMax - limit - 1) ? NSUIntegerMax : limit + shadow;
    NSArray *databaseRows = allowDatabase
        ? [self databaseRowsInRoom:roomId filter:filter descending:descending limit:databaseLimit minTimestamp:minTs]
        : @[];
    [_lock lock];
    NSArray<MXSQLiteEventRow *> *merged = [MXSQLitePendingBatch applyLayers:layers roomId:roomId toRows:databaseRows filter:filter];
    [_lock unlock];
    if (merged.count <= limit) return merged;
    NSRange range = descending ? NSMakeRange(merged.count - limit, limit) : NSMakeRange(0, limit);
    return [merged subarrayWithRange:range];
}

- (NSArray<MXSQLiteEventRow *> *)rowsInRoom:(NSString *)roomId filter:(MXSQLiteEventFilter *)filter descending:(BOOL)descending limit:(NSUInteger)limit
{
    return [self rowsInRoom:roomId filter:filter descending:descending limit:limit layers:[self snapshotLayers]];
}

- (MXSQLiteEventRow *)rowWithEventId:(NSString *)eventId inRoom:(NSString *)roomId
{
    if (!eventId.length || !roomId.length) return nil;
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter new];
    filter.eventId = eventId;
    return [self rowsInRoom:roomId filter:filter descending:NO limit:1].firstObject;
}

/// Точное число строк под фильтром с учётом накладки.
- (NSUInteger)countRowsInRoom:(NSString *)roomId filter:(MXSQLiteEventFilter *)filter
{
    NSArray<MXSQLitePendingBatch *> *layers = [self snapshotLayers];
    int64_t minTs = INT64_MIN;
    BOOL allowDatabase = [MXSQLitePendingBatch layers:layers allowDatabaseRowsOfRoom:roomId minTimestamp:&minTs shadowCount:NULL];
    if (!allowDatabase)
    {
        [_lock lock];
        NSUInteger count = [MXSQLitePendingBatch applyLayers:layers roomId:roomId toRows:@[] filter:filter].count;
        [_lock unlock];
        return count;
    }

    NSNumber *databaseCount = [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        NSString *sql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM event WHERE %@", [filter sqlConditionWithMinTimestamp:minTs]];
        return [connection query:sql bind:^(MXSQLiteStatement *statement) {
            [filter bindTo:statement rid:rid minTimestamp:minTs];
        } row:^id(MXSQLiteStatement *statement) {
            return @([statement int64At:0]);
        } error:nil].firstObject;
    } roomId:roomId];
    NSInteger count = databaseCount.integerValue;
    if (filter.threadScope == MXSQLiteThreadScopeThread && filter.includeThreadRoot && filter.threadId)
    {
        MXSQLiteEventFilter *rootFilter = [filter copy];
        rootFilter.threadScope = MXSQLiteThreadScopeAll;
        rootFilter.eventId = filter.threadId;
        count += (NSInteger)[self databaseRowsInRoom:roomId filter:rootFilter descending:NO limit:1 minTimestamp:minTs].count;
    }

    // Строки, которые трогала накладка: поправка «как в итоге» минус «как в базе».
    NSMutableSet<NSString *> *touched = [NSMutableSet set];
    [_lock lock];
    for (MXSQLitePendingBatch *layer in layers)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        if (!room) continue;
        [touched addObjectsFromArray:room.events.allKeys];
        [touched unionSet:room.deletedEventIds];
    }
    [_lock unlock];
    for (NSString *eventId in touched)
    {
        MXSQLiteEventFilter *one = [filter copy];
        one.eventId = eventId;
        NSArray *inDatabase = [self databaseRowsInRoom:roomId filter:one descending:NO limit:1 minTimestamp:minTs];
        [_lock lock];
        NSArray *merged = [MXSQLitePendingBatch applyLayers:layers roomId:roomId toRows:inDatabase filter:one];
        [_lock unlock];
        count += (NSInteger)merged.count - (NSInteger)inDatabase.count;
    }
    return (NSUInteger)MAX(0, count);
}

- (MXSQLiteHoleSet *)holeSetForRoom:(NSString *)roomId space:(NSString *)space layers:(NSArray<MXSQLitePendingBatch *> *)layers
{
    NSString *threadId = space.length ? space : nil;
    [_lock lock];
    for (MXSQLitePendingBatch *layer in layers.reverseObjectEnumerator)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        MXSQLiteHoleSet *set = room.holes[space];
        if (set || room.clearAll)
        {
            MXSQLiteHoleSet *copy = set ? [set copy] : [[MXSQLiteHoleSet alloc] initWithRoomId:roomId threadId:threadId];
            [_lock unlock];
            return copy;
        }
    }
    [_lock unlock];
    int64_t now = (int64_t)(NSDate.date.timeIntervalSince1970 * 1000);
    NSArray<MXRoomHole *> *holes = [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        return [connection query:@"SELECT lo, hi, hi_token, lo_token, retry_after FROM hole WHERE rid = ?1 AND space = ?2 ORDER BY hi"
                            bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
            [s bindText:space at:2];
        } row:^id(MXSQLiteStatement *s) {
            BOOL blocked = ![s isNullAt:4] && [s int64At:4] > now;
            return [[MXRoomHole alloc] initWithRoomId:roomId threadId:threadId lowerOrder:[s int64At:0] upperOrder:[s int64At:1]
                                        backwardToken:[s textAt:2] forwardToken:[s textAt:3] retryBlocked:blocked];
        } error:nil];
    } roomId:roomId];
    return [[MXSQLiteHoleSet alloc] initWithRoomId:roomId threadId:threadId holes:holes ?: @[]];
}

/// Живой край: NSNumber или nil.
- (NSNumber *)liveOrderOfRoom:(NSString *)roomId layers:(NSArray<MXSQLitePendingBatch *> *)layers
{
    [_lock lock];
    for (MXSQLitePendingBatch *layer in layers.reverseObjectEnumerator)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        if (room.liveOrder)
        {
            id live = room.liveOrder;
            [_lock unlock];
            return [live isKindOfClass:NSNumber.class] ? live : nil;
        }
        if (room.clearAll)
        {
            [_lock unlock];
            return nil;
        }
    }
    [_lock unlock];
    return [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        return [connection query:@"SELECT live_ord FROM room WHERE rid = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindInt64:rid at:1];
        } row:^id(MXSQLiteStatement *s) {
            return [s isNullAt:0] ? nil : @([s int64At:0]);
        } error:nil].firstObject;
    } roomId:roomId];
}

- (MXSQLiteEventFilter *)filterForSpace:(NSString *)space types:(NSSet<NSString *> *)types
{
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter new];
    filter.types = types;
    if (space.length)
    {
        filter.threadScope = MXSQLiteThreadScopeThread;
        filter.threadId = space;
        filter.includeThreadRoot = YES;
    }
    return filter;
}

/// Самое новое событие ленты строго ниже `order` (INT64_MAX — без ограничения), без фильтра типов.
- (MXSQLiteEventRow *)topRowInRoom:(NSString *)roomId space:(NSString *)space belowOrder:(int64_t)order layers:(NSArray *)layers
{
    if (order == INT64_MIN) return nil;
    MXSQLiteEventFilter *filter = [self filterForSpace:space types:nil];
    if (order != INT64_MAX) filter.maxOrder = order - 1;
    return [self rowsInRoom:roomId filter:filter descending:YES limit:1 layers:layers].lastObject;
}

#pragma mark - Segments (pages)

/// Непрерывный кусок вниз от позиции `top` включительно.
- (MXSQLiteSegment *)segmentInRoom:(NSString *)roomId space:(NSString *)space downFrom:(int64_t)top
                             limit:(NSUInteger)limit types:(NSSet<NSString *> *)types
{
    NSArray *layers = [self snapshotLayers];
    MXSQLiteHoleSet *holes = [self holeSetForRoom:roomId space:space layers:layers];
    MXSQLiteSegment *segment = [MXSQLiteSegment new];
    segment.rows = @[];
    MXRoomHole *touching = [holes holeContainingOrder:top];
    if (touching)
    {
        segment.holeBelow = touching;
        return segment;
    }
    MXRoomHole *below = [holes highestHoleAtOrBelowOrder:top];
    MXSQLiteEventFilter *filter = [self filterForSpace:space types:types];
    filter.minOrder = below ? below.upperOrder : INT64_MIN;
    filter.maxOrder = top;
    NSArray<MXSQLiteEventRow *> *rows = [self rowsInRoom:roomId filter:filter descending:YES
                                                   limit:limit == NSUIntegerMax ? limit : limit + 1 layers:layers];
    segment.more = rows.count > limit;
    if (segment.more) rows = [rows subarrayWithRange:NSMakeRange(rows.count - limit, limit)];
    segment.rows = rows;
    segment.holeBelow = segment.more ? nil : below;
    segment.reachedStart = !segment.more && !below;

    int64_t newest = rows.count ? rows.lastObject.ord : top;
    MXRoomHole *above = newest == INT64_MAX ? nil : [holes lowestHoleAtOrAboveOrder:newest];
    segment.holeAbove = (above && above.lowerOrder == newest && rows.count) ? above : nil;
    MXSQLiteEventRow *topRow = [self topRowInRoom:roomId space:space belowOrder:INT64_MAX layers:layers];
    segment.reachedLive = !above && (!topRow || topRow.ord <= newest);
    return segment;
}

/// Непрерывный кусок вверх от позиции `bottom` включительно.
- (MXSQLiteSegment *)segmentInRoom:(NSString *)roomId space:(NSString *)space upFrom:(int64_t)bottom
                             limit:(NSUInteger)limit types:(NSSet<NSString *> *)types
{
    NSArray *layers = [self snapshotLayers];
    MXSQLiteHoleSet *holes = [self holeSetForRoom:roomId space:space layers:layers];
    MXSQLiteSegment *segment = [MXSQLiteSegment new];
    segment.rows = @[];
    MXRoomHole *touching = [holes holeContainingOrder:bottom];
    if (touching)
    {
        segment.holeAbove = touching;
        return segment;
    }
    MXRoomHole *above = [holes lowestHoleAtOrAboveOrder:bottom];
    MXSQLiteEventFilter *filter = [self filterForSpace:space types:types];
    filter.minOrder = bottom;
    filter.maxOrder = above ? above.lowerOrder : INT64_MAX;
    NSArray<MXSQLiteEventRow *> *rows = [self rowsInRoom:roomId filter:filter descending:NO
                                                   limit:limit == NSUIntegerMax ? limit : limit + 1 layers:layers];
    segment.more = rows.count > limit;
    if (segment.more) rows = [rows subarrayWithRange:NSMakeRange(0, limit)];
    segment.rows = rows;
    segment.holeAbove = segment.more ? nil : above;
    segment.reachedLive = !segment.more && !above;

    int64_t oldest = rows.count ? rows.firstObject.ord : bottom;
    MXRoomHole *below = [holes highestHoleAtOrBelowOrder:oldest];
    segment.holeBelow = (below && below.upperOrder == oldest && rows.count) ? below : nil;
    MXSQLiteEventFilter *lower = [self filterForSpace:space types:nil];
    lower.maxOrder = oldest == INT64_MIN ? INT64_MIN : oldest - 1;
    segment.reachedStart = !below && (oldest == INT64_MIN || ![self rowsInRoom:roomId filter:lower descending:YES limit:1 layers:layers].count);
    return segment;
}

- (MXStorePage *)pageFromSegments:(NSArray<MXSQLiteSegment *> *)segments
                       holeBefore:(MXRoomHole *)holeBefore
                        holeAfter:(MXRoomHole *)holeAfter
                     reachedStart:(BOOL)reachedStart
                      reachedLive:(BOOL)reachedLive
                           roomId:(NSString *)roomId
                          started:(CFAbsoluteTime)started
{
    NSMutableArray<MXEvent *> *events = [NSMutableArray array];
    for (MXSQLiteSegment *segment in segments)
    {
        [events addObjectsFromArray:[self eventsOfRows:segment.rows]];
    }
    MXStorePage *page = [[MXStorePage alloc] initWithEvents:events holeBefore:holeBefore holeAfter:holeAfter
                                           reachedRoomStart:reachedStart reachedLiveEdge:reachedLive
                                                   revision:[self revisionOfRoom:roomId]];
    id<MXStoreMetricsDelegate> metrics = self.context.store.metricsDelegate;
    if ([metrics respondsToSelector:@selector(store:didReadPageInMilliseconds:events:roomId:)])
    {
        [metrics store:(id<MXStore>)self.context.store didReadPageInMilliseconds:(CFAbsoluteTimeGetCurrent() - started) * 1000
                events:events.count roomId:roomId];
    }
    return page;
}

- (NSArray<MXEvent *> *)eventsOfRows:(NSArray<MXSQLiteEventRow *> *)rows
{
    NSMutableArray *events = [NSMutableArray arrayWithCapacity:rows.count];
    for (MXSQLiteEventRow *row in rows)
    {
        MXEvent *event = row.event;
        if (event) [events addObject:event];
    }
    return events;
}

#pragma mark - Rooms

- (NSArray<NSString *> *)roomIds
{
    MXSQLiteStoreContext *context = self.context;
    NSMutableOrderedSet<NSString *> *roomIds = [NSMutableOrderedSet orderedSet];
    NSArray *stored = [context.database read:^id(MXSQLiteConnection *connection) {
        return [context.rooms allRoomIdsWithConnection:connection];
    }];
    [roomIds addObjectsFromArray:stored ?: @[]];
    [_lock lock];
    for (MXSQLitePendingBatch *layer in _layers)
    {
        for (NSString *roomId in layer.rooms)
        {
            MXSQLitePendingRoom *room = layer.rooms[roomId];
            if (room.deletedByFacade && !room.events.count) [roomIds removeObject:roomId];
            else if (room.hasWrites) [roomIds addObject:roomId];
        }
    }
    [_lock unlock];
    return roomIds.array;
}

#pragma mark - Writes

/// Под замком. Строка для события: позиция из trsc.count; у уже известного события — его позиция; иначе временная
/// рядом с краем, куда событие пришло (sub отличает её от настоящего ord).
- (MXSQLiteEventRow *)rowForEvent:(MXEvent *)event roomId:(NSString *)roomId direction:(MXTimelineDirection)direction
{
    if (event.hasTrscOrder)
    {
        return [[MXSQLiteEventRow alloc] initWithEvent:event roomId:roomId ord:event.trscOrder sub:0 exact:YES];
    }
    MXSQLiteEventRow *existing = [self rowWithEventId:event.eventId inRoom:roomId];
    if (existing)
    {
        return [[MXSQLiteEventRow alloc] initWithEvent:event roomId:roomId ord:existing.ord sub:existing.sub exact:existing.exactOrder];
    }
    BOOL forwards = direction == MXTimelineDirectionForwards;
    NSArray *edgeRows = [self rowsInRoom:roomId filter:[MXSQLiteEventFilter new] descending:forwards limit:1];
    MXSQLiteEventRow *edge = forwards ? edgeRows.lastObject : edgeRows.firstObject;
    int64_t ord = edge ? edge.ord : 0;
    int64_t sub = edge ? (forwards ? edge.sub + 1 : edge.sub - 1) : 1;
    return [[MXSQLiteEventRow alloc] initWithEvent:event roomId:roomId ord:ord sub:sub exact:NO];
}

/// Под замком.
- (void)putRow:(MXSQLiteEventRow *)row roomId:(NSString *)roomId
{
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];
    [room.deletedEventIds removeObject:row.eventId];
    room.events[row.eventId] = row;
}

/// Под замком: отложенная редакция цели (накладка, затем база).
- (NSDictionary *)pendingRedactionForEventId:(NSString *)eventId roomId:(NSString *)roomId
{
    for (MXSQLitePendingBatch *layer in _layers.reverseObjectEnumerator)
    {
        MXSQLitePendingRoom *room = layer.rooms[roomId];
        if ([room.resolvedRedactions containsObject:eventId]) return nil;
        if (room.pendingRedactions[eventId]) return room.pendingRedactions[eventId];
        if (room.clearAll) return nil;
    }
    if (_databaseHasPendingRedactions && !_databaseHasPendingRedactions.boolValue) return nil;
    MXSQLiteDatabase *database = self.context.database;
    if (!database) return nil;
    if (!_databaseHasPendingRedactions)
    {
        NSNumber *any = [database read:^id(MXSQLiteConnection *connection) {
            return @([connection int64ForQuery:@"SELECT EXISTS (SELECT 1 FROM redaction_pending)" defaultValue:0 error:nil]);
        }];
        _databaseHasPendingRedactions = @(any.boolValue);
        if (!any.boolValue) return nil;
    }
    NSData *json = [database read:^id(MXSQLiteConnection *connection) {
        return [connection query:@"SELECT json FROM redaction_pending WHERE target_event_id = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindText:eventId at:1];
        } row:^id(MXSQLiteStatement *s) {
            return [s blobAt:0];
        } error:nil].firstObject;
    }];
    id object = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

/// Под замком: строка эха с этим txn_id под другим event_id.
- (MXSQLiteEventRow *)rowWithTransactionId:(NSString *)txnId inRoom:(NSString *)roomId exceptEventId:(NSString *)eventId
{
    for (MXSQLitePendingBatch *layer in _layers.reverseObjectEnumerator)
    {
        for (MXSQLiteEventRow *row in layer.rooms[roomId].events.objectEnumerator)
        {
            if ([row.txnId isEqualToString:txnId] && ![row.eventId isEqualToString:eventId]) return row;
        }
    }
    NSString *candidate = [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        return [connection query:@"SELECT event_id FROM event WHERE txn_id = ?1 AND rid = ?2 AND event_id <> ?3 LIMIT 1"
                            bind:^(MXSQLiteStatement *s) {
            [s bindText:txnId at:1];
            [s bindInt64:rid at:2];
            [s bindText:eventId at:3];
        } row:^id(MXSQLiteStatement *s) {
            return [s textAt:0];
        } error:nil].firstObject;
    } roomId:roomId];
    return candidate ? [self rowWithEventId:candidate inRoom:roomId] : nil;
}

/// Под замком. Вставка события без правки дыр: позиция, отложенная редакция, эхо, редакция чужой цели.
/// Возвращает txn_id для снятия исходящего (или nil).
- (NSString *)insertEvent:(MXEvent *)event roomId:(NSString *)roomId direction:(MXTimelineDirection)direction row:(MXSQLiteEventRow **)rowOut
{
    MXSQLiteEventRow *row = [self rowForEvent:event roomId:roomId direction:direction];
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];

    // Редакция пришла раньше цели (история назад): применяется при вставке цели.
    NSDictionary *redaction = event.isRedactedEvent ? nil : [self pendingRedactionForEventId:event.eventId roomId:roomId];
    if (redaction)
    {
        MXEvent *pruned = [event prune];
        pruned.redactedBecause = redaction;
        row = [[MXSQLiteEventRow alloc] initWithEvent:pruned roomId:roomId ord:row.ord sub:row.sub exact:row.exactOrder];
        [room.pendingRedactions removeObjectForKey:event.eventId];
        [room.resolvedRedactions addObject:event.eventId];
    }

    // Эхо и серверное событие — одна строка: строка с тем же txn_id под другим id переименовывается.
    if (row.txnId.length)
    {
        MXSQLiteEventRow *echo = [self rowWithTransactionId:row.txnId inRoom:roomId exceptEventId:row.eventId];
        if (echo)
        {
            row.replacesEventId = echo.eventId;
            [room.events removeObjectForKey:echo.eventId];
            [room.deletedEventIds addObject:echo.eventId];
        }
    }
    [self putRow:row roomId:roomId];

    if (event.eventType == MXEventTypeRoomRedaction && event.redacts.length)
    {
        MXSQLiteEventRow *target = [self rowWithEventId:event.redacts inRoom:roomId];
        if (!target)
        {
            NSDictionary *json = event.JSONDictionary;
            if (json)
            {
                room.pendingRedactions[event.redacts] = json;
                [room.resolvedRedactions removeObject:event.redacts];
                _databaseHasPendingRedactions = @YES;
            }
        }
        else if (!(target.flags & MXSQLiteEventFlagRedacted) && target.event)
        {
            MXEvent *pruned = [target.event prune];
            pruned.redactedBecause = event.JSONDictionary;
            [self putRow:[[MXSQLiteEventRow alloc] initWithEvent:pruned roomId:roomId ord:target.ord sub:target.sub exact:target.exactOrder]
                  roomId:roomId];
        }
    }
    if (rowOut) *rowOut = row;
    return row.txnId;
}

/// Под замком: набор дыр для изменения. Изменённый поставить `installHoleSet:…`.
- (MXSQLiteHoleSet *)holeSetForWriteInRoom:(NSString *)roomId space:(NSString *)space
{
    MXSQLiteHoleSet *own = self.currentBatch.rooms[roomId].holes[space];
    return own ?: [self holeSetForRoom:roomId space:space layers:_layers];
}

/// Под замком: в текущую пачку, только если набор изменился (иначе коммит не переписывает дыры).
- (void)installHoleSet:(MXSQLiteHoleSet *)set before:(NSArray<MXRoomHole *> *)before space:(NSString *)space roomId:(NSString *)roomId
{
    NSAssert(set.isValid, @"hole set broke the invariant: %@", set);
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];
    if (room.holes[space] != set && ![before isEqualToArray:set.holes])
    {
        room.holes[space] = set;
    }
}

/// Под замком: событие на позиции `order` пришло в направлении `direction` — дыра вокруг него сужается
/// со стороны, откуда пришло событие (вперёд — снизу, назад — сверху).
- (void)trimHoleAtOrder:(int64_t)order direction:(MXTimelineDirection)direction space:(NSString *)space roomId:(NSString *)roomId
{
    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:space];
    MXRoomHole *hole = [set holeContainingOrder:order];
    if (!hole) return;
    NSArray *before = set.holes;
    NSString *token = MXSQLiteTokenForOrder(order);
    if (direction == MXTimelineDirectionForwards)
    {
        [set fillFromOrder:hole.lowerOrder + 1 toOrder:order lowToken:nil highToken:token];
    }
    else
    {
        [set fillFromOrder:order toOrder:hole.upperOrder - 1 lowToken:token highToken:nil];
    }
    [self installHoleSet:set before:before space:space roomId:roomId];
}

/// Вне замка: снять строки `outgoing` (компонент исходящих сам кладёт удаление в тот же коммит).
- (void)consumeOutgoingForTransactionIds:(NSArray<NSString *> *)txnIds roomId:(NSString *)roomId
{
    id<MXSQLiteOutgoingStoring> outgoing = self.context.outgoing;
    for (NSString *txnId in txnIds)
    {
        [outgoing consumeOutgoingForTransactionId:txnId inRoom:roomId];
    }
}

- (void)storeEventForRoom:(NSString *)roomId event:(MXEvent *)event direction:(MXTimelineDirection)direction
{
    if (!event.eventId.length || !roomId.length) return;
    [_lock lock];
    MXSQLiteEventRow *row;
    NSString *txnId = [self insertEvent:event roomId:roomId direction:direction row:&row];
    if (row.exactOrder)
    {
        [self trimHoleAtOrder:row.ord direction:direction space:kMainSpace roomId:roomId];
        if (row.threadId) [self trimHoleAtOrder:row.ord direction:direction space:row.threadId roomId:roomId];
    }
    if (direction == MXTimelineDirectionForwards)
    {
        NSNumber *live = [self liveOrderOfRoom:roomId layers:_layers];
        if (!live || live.longLongValue < row.ord)
        {
            [self.currentBatch roomForWrite:roomId].liveOrder = @(row.ord);
        }
    }
    [_lock unlock];
    if (txnId) [self consumeOutgoingForTransactionIds:@[txnId] roomId:roomId];
}

- (void)replaceEvent:(MXEvent *)event inRoom:(NSString *)roomId
{
    if (!event.eventId.length || !roomId.length) return;
    [_lock lock];
    MXSQLiteEventRow *existing = [self rowWithEventId:event.eventId inRoom:roomId];
    if (existing)
    {
        [self putRow:[[MXSQLiteEventRow alloc] initWithEvent:event roomId:roomId ord:existing.ord sub:existing.sub exact:existing.exactOrder]
              roomId:roomId];
    }
    [_lock unlock];
}

- (void)onDidDecryptEvent:(NSNotification *)notification
{
    MXEvent *event = notification.object;
    if (![event isKindOfClass:MXEvent.class] || !event.roomId.length || !event.eventId.length) return;
    // Поздняя расшифровка (после ошибки): обновить `clear` и тип строки, если событие у нас есть.
    [self replaceEvent:event inRoom:event.roomId];
}

- (BOOL)eventExistsWithEventId:(NSString *)eventId inRoom:(NSString *)roomId
{
    return [self rowWithEventId:eventId inRoom:roomId] != nil;
}

- (MXEvent *)eventWithEventId:(NSString *)eventId inRoom:(NSString *)roomId
{
    return [self rowWithEventId:eventId inRoom:roomId].event;
}

- (void)deleteAllMessagesInRoom:(NSString *)roomId
{
    [_lock lock];
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];
    room.clearAll = YES;
    [room.events removeAllObjects];
    [room.deletedEventIds removeAllObjects];
    [room.holes removeAllObjects];
    [room.pendingRedactions removeAllObjects];
    [room.resolvedRedactions removeAllObjects];
    room.liveOrder = nil;
    room.reachedStart = nil;
    room.deleteBeforeTs = INT64_MIN;
    [_lock unlock];
}

- (void)loadRoomMessagesForRoom:(NSString *)roomId completion:(void (^)(void))completion
{
    // Чат не читается целиком: загружать нечего (ADR-0022).
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

#pragma mark - Enumerators

- (id<MXEventsEnumerator>)messagesEnumeratorForRoom:(NSString *)roomId
{
    return [[MXSQLiteEventsEnumerator alloc] initWithSource:self roomId:roomId types:nil];
}

- (id<MXEventsEnumerator>)messagesEnumeratorForRoom:(NSString *)roomId withTypeIn:(NSArray *)types
{
    return [[MXSQLiteEventsEnumerator alloc] initWithSource:self roomId:roomId types:types ? [NSSet setWithArray:types] : nil];
}

/// Верх ленты для чтения сверху: под открытой сверху дырой (событие из пуша) — её нижняя граница.
- (int64_t)topPositionInRoom:(NSString *)roomId space:(NSString *)space hole:(MXRoomHole **)openHole
{
    MXRoomHole *open = [self holeSetForRoom:roomId space:space layers:[self snapshotLayers]].openEndedHole;
    if (openHole) *openHole = open;
    return open ? open.lowerOrder : INT64_MAX;
}

- (NSArray<MXSQLiteEventRow *> *)enumeratorRowsInRoom:(NSString *)roomId
                                           belowOrder:(int64_t)order
                                                limit:(NSUInteger)limit
                                                types:(NSSet<NSString *> *)types
                                           reachedEnd:(BOOL *)reachedEnd
{
    int64_t top = order == INT64_MAX ? [self topPositionInRoom:roomId space:kMainSpace hole:NULL] : order - 1;
    if (top == MXRoomHoleOpenStart)
    {
        *reachedEnd = YES;
        return @[];
    }
    MXSQLiteSegment *segment = [self segmentInRoom:roomId space:kMainSpace downFrom:top limit:limit types:types];
    *reachedEnd = !segment.more;
    return segment.rows.reverseObjectEnumerator.allObjects;
}

- (NSUInteger)enumeratorCountInRoom:(NSString *)roomId belowOrder:(int64_t)order types:(NSSet<NSString *> *)types
{
    int64_t top = order == INT64_MAX ? [self topPositionInRoom:roomId space:kMainSpace hole:NULL] : order - 1;
    if (top == MXRoomHoleOpenStart) return 0;
    MXSQLiteHoleSet *holes = [self holeSetForRoom:roomId space:kMainSpace layers:[self snapshotLayers]];
    if ([holes holeContainingOrder:top]) return 0;
    MXRoomHole *below = [holes highestHoleAtOrBelowOrder:top];
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter filterFromOrder:below ? below.upperOrder : INT64_MIN toOrder:top];
    filter.types = types;
    return [self countRowsInRoom:roomId filter:filter];
}

#pragma mark - Relations, unread

- (NSArray<MXEvent *> *)relationsForEvent:(NSString *)eventId inRoom:(NSString *)roomId relationType:(NSString *)relationType
{
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter new];
    filter.relatesTo = eventId;
    filter.relType = relationType;
    return [self eventsOfRows:[self rowsInRoom:roomId filter:filter descending:NO limit:NSUIntegerMax]];
}

/// Фильтр «после квитанции пользователя» для старых методов непрочитанного. nil — квитанции или её события нет:
/// считать не от чего, вызывающий берёт серверные счётчики (частый случай после переключения стора).
- (MXSQLiteEventFilter *)unreadFilterInRoom:(NSString *)roomId threadId:(NSString *)threadId types:(NSArray *)types
{
    NSString *userId = self.context.credentials.userId;
    id<MXStore> store = (id<MXStore>)self.context.store;
    if (!userId || !store) return nil;
    BOOL main = !threadId.length || [threadId isEqualToString:kMXEventTimelineMain];
    MXReceiptData *receipt = [store getReceiptInRoom:roomId threadId:main ? kMXEventTimelineMain : threadId forUserId:userId];
    if (!receipt.eventId) return nil;
    MXSQLiteEventRow *anchor = [self rowWithEventId:receipt.eventId inRoom:roomId];
    if (!anchor || anchor.ord == INT64_MAX) return nil;
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter filterFromOrder:anchor.ord + 1 toOrder:INT64_MAX];
    filter.types = types ? [NSSet setWithArray:types] : nil;
    filter.excludedSender = userId;
    filter.threadScope = main ? MXSQLiteThreadScopeMain : MXSQLiteThreadScopeThread;
    filter.threadId = main ? nil : threadId;
    return filter;
}

- (NSUInteger)localUnreadEventCount:(NSString *)roomId threadId:(NSString *)threadId withTypeIn:(NSArray *)types
{
    MXSQLiteEventFilter *filter = [self unreadFilterInRoom:roomId threadId:threadId types:types];
    if (!filter) return 0;
    filter.excludeRedacted = YES;
    return [self countRowsInRoom:roomId filter:filter];
}

- (NSInteger)trscUnreadMessageCountInRoom:(NSString *)roomId types:(NSArray<NSString *> *)types limit:(NSUInteger)limit
{
    MXSQLiteEventFilter *filter = [self unreadFilterInRoom:roomId threadId:nil types:types];
    if (!filter) return -1;
    // Правило бейджа списка (`TrscUnreadPolicy` приложения): правка — не новое сообщение, реакция и ответ в
    // треде строку не поднимают, служебные события состояния тоже. `unreadFilterInRoom` уже убрал своё и треды.
    filter.excludeRedacted = YES;
    filter.excludeState = YES;
    filter.excludedRelTypes = [NSSet setWithObjects:@"m.replace", @"m.annotation", nil];
    return (NSInteger)MIN(limit, [self countRowsInRoom:roomId filter:filter]);
}

- (NSDictionary<NSString *, NSNumber *> *)localUnreadEventCountPerThread:(NSString *)roomId withTypeIn:(NSArray *)types
{
    NSMutableSet<NSString *> *threads = [NSMutableSet set];
    NSArray *stored = [self read:^id(MXSQLiteConnection *connection, int64_t rid) {
        return [connection query:@"SELECT DISTINCT thread_id FROM event WHERE rid = ?1 AND thread_id IS NOT NULL"
                            bind:^(MXSQLiteStatement *s) { [s bindInt64:rid at:1]; }
                             row:^id(MXSQLiteStatement *s) { return [s textAt:0]; } error:nil];
    } roomId:roomId];
    [threads addObjectsFromArray:stored ?: @[]];
    [_lock lock];
    for (MXSQLitePendingBatch *layer in _layers)
    {
        for (MXSQLiteEventRow *row in layer.rooms[roomId].events.objectEnumerator)
        {
            if (row.threadId) [threads addObject:row.threadId];
        }
    }
    [_lock unlock];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *threadId in threads)
    {
        MXSQLiteEventFilter *filter = [self unreadFilterInRoom:roomId threadId:threadId types:types];
        if (!filter) continue;
        filter.excludeRedacted = YES;
        result[threadId] = @([self countRowsInRoom:roomId filter:filter]);
    }
    return result;
}

- (NSArray<MXEvent *> *)newIncomingEventsInRoom:(NSString *)roomId threadId:(NSString *)threadId withTypeIn:(NSArray<MXEventTypeString> *)types
{
    MXSQLiteEventFilter *filter = [self unreadFilterInRoom:roomId threadId:threadId types:types];
    if (!filter) return @[];
    return [self eventsOfRows:[self rowsInRoom:roomId filter:filter descending:YES limit:kLegacyListLimit]];
}

#pragma mark - Retention

- (BOOL)removeAllMessagesSentBefore:(uint64_t)limitTs inRoom:(NSString *)roomId
{
    int64_t limit = limitTs > (uint64_t)INT64_MAX ? INT64_MAX : (int64_t)limitTs;
    [_lock lock];
    // Есть ли что удалять: не-состояние раньше порога в накладке или в базе (EXISTS по индексу event_ts).
    BOOL expired = NO;
    for (MXSQLitePendingBatch *layer in _layers)
    {
        for (MXSQLiteEventRow *row in layer.rooms[roomId].events.objectEnumerator)
        {
            if (!row.stateKey && row.ts < limit) { expired = YES; break; }
        }
    }
    if (!expired)
    {
        expired = [[self read:^id(MXSQLiteConnection *connection, int64_t rid) {
            return [connection query:@"SELECT EXISTS (SELECT 1 FROM event WHERE rid = ?1 AND ts < ?2 AND state_key IS NULL)"
                                bind:^(MXSQLiteStatement *s) {
                [s bindInt64:rid at:1];
                [s bindInt64:limit at:2];
            } row:^id(MXSQLiteStatement *s) {
                return @([s int64At:0]);
            } error:nil].firstObject;
        } roomId:roomId] boolValue];
    }
    if (!expired)
    {
        [_lock unlock];
        return NO;
    }
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];
    for (MXSQLiteEventRow *row in room.events.allValues)
    {
        if (!row.stateKey && row.ts < limit) [room.events removeObjectForKey:row.eventId];
    }
    room.deleteBeforeTs = MAX(room.deleteBeforeTs, limit);
    room.retentionFloorTs = @(MAX(room.retentionFloorTs.longLongValue, limit));

    // Ниже нового самого старого события — нижняя дыра «до порога», её не догружают (сервер удалил то же).
    MXSQLiteEventRow *first = [self rowsInRoom:roomId filter:[MXSQLiteEventFilter new] descending:NO limit:1].firstObject;
    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:kMainSpace];
    NSArray *before = set.holes;
    if (first)
    {
        [set fillFromOrder:INT64_MIN toOrder:first.ord lowToken:nil highToken:nil];
        [set addHoleWithLowerOrder:MXRoomHoleOpenStart upperOrder:first.ord backwardToken:nil forwardToken:nil];
    }
    else
    {
        [set removeAllHoles];
    }
    [self installHoleSet:set before:before space:kMainSpace roomId:roomId];
    [_lock unlock];
    return YES;
}

- (void)removeExpiredMessagesWithRoomMinimumTimestamps:(NSDictionary<NSString *, NSNumber *> *)roomMinimumTimestamps
                                            completion:(void (^)(NSUInteger, NSUInteger, BOOL))completion
{
    NSUInteger cleaned = 0;
    for (NSString *roomId in roomMinimumTimestamps)
    {
        if ([self removeAllMessagesSentBefore:roomMinimumTimestamps[roomId].unsignedLongLongValue inRoom:roomId]) cleaned++;
    }
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cleaned, 0, NO); });
    }
}

#pragma mark - History gaps shim (old model over `hole`)

- (NSString *)eventIdAtOrder:(int64_t)order inRoom:(NSString *)roomId
{
    return [self rowsInRoom:roomId filter:[MXSQLiteEventFilter filterFromOrder:order toOrder:order] descending:NO limit:1].firstObject.eventId;
}

- (NSArray<MXRoomHistoryGap *> *)historyGapsForRoom:(NSString *)roomId
{
    NSMutableArray *gaps = [NSMutableArray array];
    for (MXRoomHole *hole in [self holesInRoom:roomId thread:nil])
    {
        if (hole.isOpenStarted || hole.isOpenEnded) continue;   // у старой модели нет дыры без якорей
        NSString *older = [self eventIdAtOrder:hole.lowerOrder inRoom:roomId];
        NSString *newer = [self eventIdAtOrder:hole.upperOrder inRoom:roomId];
        if (!older || !newer) continue;
        MXRoomHistoryGap *gap = [MXRoomHistoryGap new];
        gap.gapId = hole.holeId;
        gap.olderAnchorEventId = older;
        gap.newerAnchorEventId = newer;
        gap.backwardToken = hole.backwardToken;
        gap.recoveryBlocked = hole.retryBlocked;
        [gaps addObject:gap];
    }
    return gaps;
}

- (NSUInteger)historyRevisionForRoom:(NSString *)roomId
{
    // Меняется и до коммита: + число пачек накладки, трогавших комнату.
    NSUInteger pending = 0;
    [_lock lock];
    for (MXSQLitePendingBatch *layer in _layers)
    {
        if (layer.rooms[roomId].hasWrites) pending++;
    }
    [_lock unlock];
    return [self revisionOfRoom:roomId] + pending;
}

- (NSArray<MXEvent *> *)continuousRecentMessagesForRoom:(NSString *)roomId
{
    return [self latestPageInRoom:roomId thread:nil limit:kLegacyListLimit types:nil].events;
}

- (void)storeHistoryGap:(MXRoomHistoryGap *)gap forRoom:(NSString *)roomId
{
    [_lock lock];
    MXSQLiteEventRow *older = [self rowWithEventId:gap.olderAnchorEventId inRoom:roomId];
    MXSQLiteEventRow *newer = [self rowWithEventId:gap.newerAnchorEventId inRoom:roomId];
    if (older && newer && older.ord < newer.ord)
    {
        MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:kMainSpace];
        NSArray *before = set.holes;
        [set addHoleWithLowerOrder:older.ord upperOrder:newer.ord backwardToken:gap.backwardToken
                      forwardToken:MXSQLiteTokenForOrder(older.ord)];
        [self installHoleSet:set before:before space:kMainSpace roomId:roomId];
    }
    [_lock unlock];
}

- (void)removeHistoryGapWithId:(NSString *)gapId inRoom:(NSString *)roomId
{
    // holeId = "<roomId>|<thread>|<upperOrder>"
    NSArray<NSString *> *parts = [gapId componentsSeparatedByString:@"|"];
    if (parts.count < 3) return;
    NSString *space = parts[parts.count - 2];
    int64_t upper = parts.lastObject.longLongValue;
    [_lock lock];
    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:space];
    NSArray *before = set.holes;
    [set removeHoleWithUpperOrder:upper];
    [self installHoleSet:set before:before space:space roomId:roomId];
    [_lock unlock];
}

- (void)insertHistoryEvents:(NSArray<MXEvent *> *)events inRoom:(NSString *)roomId beforeEventId:(NSString *)eventId
{
    for (MXEvent *event in events)
    {
        [self storeEventForRoom:roomId event:event direction:MXTimelineDirectionBackwards];
    }
}

- (NSArray<MXEvent *> *)historyBlockBeforeGap:(MXRoomHistoryGap *)gap inRoom:(NSString *)roomId
{
    MXSQLiteEventRow *older = [self rowWithEventId:gap.olderAnchorEventId inRoom:roomId];
    if (!older) return @[];
    MXSQLiteSegment *segment = [self segmentInRoom:roomId space:kMainSpace downFrom:older.ord limit:kLegacyListLimit types:nil];
    return [self eventsOfRows:segment.rows];
}

- (void)applyHistoryGap:(MXRoomHistoryGap *)gap inRoom:(NSString *)roomId events:(NSArray<MXEvent *> *)events nextToken:(NSString *)token
{
    MXSQLiteEventRow *older = [self rowWithEventId:gap.olderAnchorEventId inRoom:roomId];
    MXSQLiteEventRow *newer = [self rowWithEventId:gap.newerAnchorEventId inRoom:roomId];
    if (!older || !newer) return;
    MXRoomHole *hole = [[MXRoomHole alloc] initWithRoomId:roomId threadId:nil lowerOrder:older.ord upperOrder:newer.ord
                                            backwardToken:gap.backwardToken forwardToken:nil retryBlocked:NO];
    [self applyEvents:events toHole:hole direction:MXTimelineDirectionBackwards endToken:token];
}

#pragma mark - History contexts: not stored (final behaviour, not a stub)

- (NSArray<MXRoomHistoryContext *> *)historyContextsForRoom:(NSString *)roomId { return @[]; }
- (MXRoomHistoryContext *)historyContextForEventId:(NSString *)eventId inRoom:(NSString *)roomId filter:(NSDictionary *)filter { return nil; }
- (NSString *)historyContextGenerationForRoom:(NSString *)roomId { return nil; }

- (BOOL)storeHistoryContext:(MXRoomHistoryContext *)context
                     inRoom:(NSString *)roomId
         expectedGeneration:(NSString *)generation
       expectedRoomRevision:(NSUInteger)roomRevision
  expectedComponentRevision:(NSUInteger)componentRevision
{
    return NO;
}

#pragma mark - MXTimelineStore: reads

- (MXStorePage *)latestPageInRoom:(NSString *)roomId thread:(NSString *)threadId limit:(NSUInteger)limit types:(NSSet<NSString *> *)types
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSString *space = [MXSQLiteEventStore spaceForThread:threadId];
    MXRoomHole *open = nil;
    int64_t top = [self topPositionInRoom:roomId space:space hole:&open];
    if (top == MXRoomHoleOpenStart || limit == 0)
    {
        return [self pageFromSegments:@[] holeBefore:nil holeAfter:open reachedStart:NO reachedLive:!open roomId:roomId started:started];
    }
    MXSQLiteSegment *segment = [self segmentInRoom:roomId space:space downFrom:top limit:limit types:types];
    return [self pageFromSegments:@[segment] holeBefore:segment.holeBelow holeAfter:open
                     reachedStart:segment.reachedStart reachedLive:!open && segment.reachedLive roomId:roomId started:started];
}

- (MXStorePage *)pageInRoom:(NSString *)roomId thread:(NSString *)threadId beforeOrder:(int64_t)order limit:(NSUInteger)limit types:(NSSet<NSString *> *)types
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (order == INT64_MIN || limit == 0) return MXStorePage.emptyPage;
    NSString *space = [MXSQLiteEventStore spaceForThread:threadId];
    MXSQLiteSegment *segment = [self segmentInRoom:roomId space:space downFrom:order - 1 limit:limit types:types];
    return [self pageFromSegments:@[segment] holeBefore:segment.holeBelow holeAfter:segment.holeAbove
                     reachedStart:segment.reachedStart reachedLive:segment.rows.count && segment.reachedLive roomId:roomId started:started];
}

- (MXStorePage *)pageInRoom:(NSString *)roomId thread:(NSString *)threadId afterOrder:(int64_t)order limit:(NSUInteger)limit types:(NSSet<NSString *> *)types
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (order == INT64_MAX || limit == 0) return MXStorePage.emptyPage;
    NSString *space = [MXSQLiteEventStore spaceForThread:threadId];
    MXSQLiteSegment *segment = [self segmentInRoom:roomId space:space upFrom:order + 1 limit:limit types:types];
    return [self pageFromSegments:@[segment] holeBefore:segment.holeBelow holeAfter:segment.holeAbove
                     reachedStart:segment.rows.count && segment.reachedStart reachedLive:segment.reachedLive roomId:roomId started:started];
}

- (MXStorePage *)pageAroundEvent:(NSString *)eventId inRoom:(NSString *)roomId limit:(NSUInteger)limit
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    MXSQLiteEventRow *row = [self rowWithEventId:eventId inRoom:roomId];
    if (!row) return nil;
    NSUInteger down = MAX((NSUInteger)1, limit / 2 + 1);
    MXSQLiteSegment *older = [self segmentInRoom:roomId space:kMainSpace downFrom:row.ord limit:down types:nil];
    NSUInteger up = limit > older.rows.count ? limit - older.rows.count : 0;
    MXSQLiteSegment *newer = (row.ord == INT64_MAX || up == 0) ? nil
        : [self segmentInRoom:roomId space:kMainSpace upFrom:row.ord + 1 limit:up types:nil];
    NSArray *segments = newer ? @[older, newer] : @[older];
    return [self pageFromSegments:segments holeBefore:older.holeBelow holeAfter:newer ? newer.holeAbove : older.holeAbove
                     reachedStart:older.reachedStart reachedLive:newer ? newer.reachedLive : older.reachedLive
                           roomId:roomId started:started];
}

- (BOOL)orderOfEvent:(NSString *)eventId inRoom:(NSString *)roomId order:(int64_t *)order
{
    MXSQLiteEventRow *row = [self rowWithEventId:eventId inRoom:roomId];
    if (!row) return NO;
    if (order) *order = row.ord;
    return YES;
}

- (NSArray<MXRoomHole *> *)holesInRoom:(NSString *)roomId thread:(NSString *)threadId
{
    return [self holeSetForRoom:roomId space:[MXSQLiteEventStore spaceForThread:threadId] layers:[self snapshotLayers]].holes;
}

- (NSUInteger)revisionOfRoom:(NSString *)roomId
{
    MXSQLiteStoreContext *context = self.context;
    NSNumber *revision = [context.database read:^id(MXSQLiteConnection *connection) {
        return [connection query:@"SELECT revision FROM room WHERE room_id = ?1" bind:^(MXSQLiteStatement *s) {
            [s bindText:roomId at:1];
        } row:^id(MXSQLiteStatement *s) {
            return @([s int64At:0]);
        } error:nil].firstObject;
    }];
    return revision.unsignedIntegerValue;
}

- (void)applyThread:(NSString *)threadId toFilter:(MXSQLiteEventFilter *)filter
{
    if ([threadId isEqualToString:kMXEventTimelineMain])
    {
        filter.threadScope = MXSQLiteThreadScopeMain;
    }
    else if (threadId.length)
    {
        filter.threadScope = MXSQLiteThreadScopeThread;
        filter.threadId = threadId;
    }
}

- (MXEvent *)latestEventInRoom:(NSString *)roomId types:(NSSet<NSString *> *)types threadId:(NSString *)threadId beforeOrder:(int64_t)order
{
    if (order == INT64_MIN) return nil;
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter new];
    filter.types = types;
    if (order != MXRoomHoleOpenEnd) filter.maxOrder = order - 1;
    [self applyThread:threadId toFilter:filter];
    return [self rowsInRoom:roomId filter:filter descending:YES limit:1].lastObject.event;
}

- (NSUInteger)countEventsInRoom:(NSString *)roomId
                   afterEventId:(NSString *)eventId
                          types:(NSSet<NSString *> *)types
                excludingSender:(NSString *)userId
                       threadId:(NSString *)threadId
                          limit:(NSUInteger)limit
{
    // До открытия базы стор ничего не знает — вызывающий берёт серверный счётчик.
    if (!self.context.database) return NSNotFound;
    MXSQLiteEventFilter *filter = [MXSQLiteEventFilter new];
    if (eventId)
    {
        MXSQLiteEventRow *anchor = [self rowWithEventId:eventId inRoom:roomId];
        if (!anchor) return NSNotFound;
        if (anchor.ord == INT64_MAX) return 0;
        filter.minOrder = anchor.ord + 1;
    }
    filter.types = types;
    filter.excludedSender = userId;
    [self applyThread:threadId toFilter:filter];
    if (limit <= 1000) return [self rowsInRoom:roomId filter:filter descending:NO limit:limit].count;
    return MIN(limit, [self countRowsInRoom:roomId filter:filter]);
}

#pragma mark - MXTimelineStore: writes

- (void)noteSyncTimelineInRoom:(NSString *)roomId firstEvent:(MXEvent *)firstEvent limited:(BOOL)limited prevBatch:(NSString *)prevBatch
{
    if (!firstEvent || !roomId.length) return;
    [_lock lock];
    BOOL firstKnown = [self rowWithEventId:firstEvent.eventId inRoom:roomId] != nil;
    int64_t first;
    if (firstEvent.hasTrscOrder)
    {
        first = firstEvent.trscOrder;
    }
    else
    {
        MXSQLiteEventRow *top = [self topRowInRoom:roomId space:kMainSpace belowOrder:INT64_MAX layers:_layers];
        first = top ? top.ord : 0;
    }
    NSString *firstToken = firstEvent.unsignedData.trscCount ?: prevBatch;

    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:kMainSpace];
    NSArray *before = set.holes;

    // Пачка непрерывна от первого события до «сейчас»: всё, что выше него, известно.
    [set fillFromOrder:first toOrder:INT64_MAX lowToken:firstToken highToken:nil];

    NSNumber *live = [self liveOrderOfRoom:roomId layers:_layers];
    if (!live)
    {
        MXSQLiteEventRow *below = [self topRowInRoom:roomId space:kMainSpace belowOrder:first layers:_layers];
        live = below ? @(below.ord) : nil;
    }
    if (!limited)
    {
        // Продолжение живого края: между ним и пачкой дыр нет (у новой комнаты — вся история в пачке).
        [set fillFromOrder:live ? live.longLongValue : INT64_MIN toOrder:first lowToken:nil highToken:nil];
    }
    else if (!firstKnown)
    {
        int64_t lower = live ? live.longLongValue : MXRoomHoleOpenStart;
        // События между краем и пачкой (из пуша) делят новую дыру.
        NSMutableArray<NSNumber *> *bounds = [NSMutableArray arrayWithObject:@(lower)];
        if (lower < first && ![MXSQLiteHoleSet isEmptyRangeLower:lower upper:first])
        {
            MXSQLiteEventFilter *between = [MXSQLiteEventFilter filterFromOrder:lower == INT64_MIN ? INT64_MIN : lower + 1 toOrder:first - 1];
            for (MXSQLiteEventRow *row in [self rowsInRoom:roomId filter:between descending:NO limit:NSUIntegerMax layers:_layers])
            {
                if (row.ord != bounds.lastObject.longLongValue) [bounds addObject:@(row.ord)];
            }
        }
        [bounds addObject:@(first)];
        for (NSUInteger index = 0; index + 1 < bounds.count; index++)
        {
            int64_t lo = bounds[index].longLongValue, hi = bounds[index + 1].longLongValue;
            NSString *backward = hi == first ? firstToken : MXSQLiteTokenForOrder(hi);
            NSString *forward = lo == MXRoomHoleOpenStart ? nil : MXSQLiteTokenForOrder(lo);
            [set addHoleWithLowerOrder:lo upperOrder:hi backwardToken:backward forwardToken:forward];
        }
    }
    [self installHoleSet:set before:before space:kMainSpace roomId:roomId];
    [_lock unlock];
}

/// Вставить события ответа и поправить дыру. Общая часть `applyPage:` и прокладки `applyHistoryGap:`.
- (void)applyEvents:(NSArray<MXEvent *> *)events toHole:(MXRoomHole *)hole direction:(MXTimelineDirection)direction endToken:(NSString *)end
{
    NSString *roomId = hole.roomId;
    NSString *space = [MXSQLiteEventStore spaceForThread:hole.threadId];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSString *> *txnIds = [NSMutableArray array];
    [_lock lock];
    NSMutableArray<NSNumber *> *orders = [NSMutableArray arrayWithCapacity:events.count];
    for (MXEvent *event in events)
    {
        if (!event.eventId.length) continue;
        MXSQLiteEventRow *row;
        NSString *txnId = [self insertEvent:event roomId:roomId direction:direction row:&row];
        if (txnId) [txnIds addObject:txnId];
        if (row.exactOrder) [orders addObject:@(row.ord)];
    }

    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:space];
    NSArray *before = set.holes;
    BOOL backwards = direction == MXTimelineDirectionBackwards;
    // Ответ непрерывен от границы дыры: `/messages?from=<trsc.count границы>` отдаёт подряд всё строго за ней.
    // Значит, известен весь диапазон от границы до последнего события ответа — в том числе куски соседних дыр,
    // если ответ «перелетел» нижнюю границу (сервер не знает дыр клиента). Пустой `end` — дальше событий нет.
    int64_t edge = backwards ? INT64_MAX : INT64_MIN;
    for (NSNumber *number in orders)
    {
        int64_t order = number.longLongValue;
        if (backwards ? order < edge : order > edge) edge = order;
    }
    MXRoomHole *current = backwards ? [set holeWithUpperOrder:hole.upperOrder] : [set holeWithLowerOrder:hole.lowerOrder];
    if (backwards)
    {
        int64_t top = hole.upperOrder == INT64_MIN ? INT64_MIN : hole.upperOrder - 1;
        if (!end.length)
        {
            [set fillFromOrder:INT64_MIN toOrder:top lowToken:nil highToken:nil];
            if (!space.length) [self.currentBatch roomForWrite:roomId].reachedStart = @YES;
        }
        else if (edge != INT64_MAX)
        {
            [set fillFromOrder:edge toOrder:top lowToken:end highToken:nil];
        }
        else if (current)
        {
            // Пустая страница с продолжением: только новый токен.
            [set replaceHoleWithUpperOrder:current.upperOrder lowerOrder:current.lowerOrder upperOrder:current.upperOrder
                             backwardToken:end forwardToken:current.forwardToken];
        }
    }
    else
    {
        int64_t bottom = hole.lowerOrder == INT64_MAX ? INT64_MAX : hole.lowerOrder + 1;
        if (!end.length)
        {
            [set fillFromOrder:bottom toOrder:INT64_MAX lowToken:nil highToken:nil];
        }
        else if (edge != INT64_MIN)
        {
            [set fillFromOrder:bottom toOrder:edge lowToken:nil highToken:end];
        }
        else if (current)
        {
            [set replaceHoleWithUpperOrder:current.upperOrder lowerOrder:current.lowerOrder upperOrder:current.upperOrder
                             backwardToken:current.backwardToken forwardToken:end];
        }
    }
    [self installHoleSet:set before:before space:space roomId:roomId];
    [_lock unlock];
    if (txnIds.count) [self consumeOutgoingForTransactionIds:txnIds roomId:roomId];

    id<MXStoreMetricsDelegate> metrics = self.context.store.metricsDelegate;
    if ([metrics respondsToSelector:@selector(store:didFillHoleInMilliseconds:events:roomId:)])
    {
        [metrics store:(id<MXStore>)self.context.store didFillHoleInMilliseconds:(CFAbsoluteTimeGetCurrent() - started) * 1000
                events:events.count roomId:roomId];
    }
}

- (void)applyPage:(MXPaginationResponse *)response toHole:(MXRoomHole *)hole direction:(MXTimelineDirection)direction
{
    [self applyEvents:response.chunk ?: @[] toHole:hole direction:direction endToken:response.end];
}

/// Под замком: позиции `low … high` (окно или одно событие) стали известны вне непрерывной ленты.
/// Пересекает дыры — режет их; лежит выше всего известного — окружается дырами от края и до открытого верха.
- (void)coverRangeInRoom:(NSString *)roomId low:(int64_t)low high:(int64_t)high topBefore:(MXSQLiteEventRow *)topBefore
{
    MXSQLiteHoleSet *set = [self holeSetForWriteInRoom:roomId space:kMainSpace];
    NSArray *before = set.holes;
    NSString *lowToken = MXSQLiteTokenForOrder(low), *highToken = MXSQLiteTokenForOrder(high);
    BOOL overlaps = NO;
    for (MXRoomHole *hole in set.holes)
    {
        // Позиции дыры lo+1 … hi-1 пересекают [low, high].
        if (hole.lowerOrder < high && low < hole.upperOrder) { overlaps = YES; break; }
    }
    if (overlaps)
    {
        [set fillFromOrder:low toOrder:high lowToken:lowToken highToken:highToken];
    }
    else if (!topBefore || topBefore.ord < low)
    {
        int64_t edge = topBefore ? topBefore.ord : MXRoomHoleOpenStart;
        [set addHoleWithLowerOrder:edge upperOrder:low backwardToken:lowToken
                      forwardToken:topBefore ? MXSQLiteTokenForOrder(edge) : nil];
        [set addHoleWithLowerOrder:high upperOrder:MXRoomHoleOpenEnd backwardToken:nil forwardToken:highToken];
    }
    [self installHoleSet:set before:before space:kMainSpace roomId:roomId];
}

- (void)insertContext:(MXEventContext *)context inRoom:(NSString *)roomId
{
    NSMutableArray<MXEvent *> *events = [NSMutableArray array];
    [events addObjectsFromArray:context.eventsBefore ?: @[]];
    if (context.event) [events addObject:context.event];
    [events addObjectsFromArray:context.eventsAfter ?: @[]];
    NSMutableArray<NSString *> *txnIds = [NSMutableArray array];
    [_lock lock];
    MXSQLiteEventRow *topBefore = [self topRowInRoom:roomId space:kMainSpace belowOrder:INT64_MAX layers:_layers];
    int64_t low = INT64_MAX, high = INT64_MIN;
    for (MXEvent *event in events)
    {
        if (!event.eventId.length) continue;
        MXSQLiteEventRow *row;
        NSString *txnId = [self insertEvent:event roomId:roomId direction:MXTimelineDirectionBackwards row:&row];
        if (txnId) [txnIds addObject:txnId];
        if (!row.exactOrder) continue;
        low = MIN(low, row.ord);
        high = MAX(high, row.ord);
    }
    if (low <= high)
    {
        [self coverRangeInRoom:roomId low:low high:high topBefore:topBefore];
    }
    [_lock unlock];
    if (txnIds.count) [self consumeOutgoingForTransactionIds:txnIds roomId:roomId];
}

- (BOOL)insertDetachedEvent:(MXEvent *)event inRoom:(NSString *)roomId
{
    if (!event.eventId.length || !roomId.length || !event.hasTrscOrder) return NO;
    [_lock lock];
    if ([self rowWithEventId:event.eventId inRoom:roomId])
    {
        [_lock unlock];
        return NO;
    }
    MXSQLiteEventRow *topBefore = [self topRowInRoom:roomId space:kMainSpace belowOrder:INT64_MAX layers:_layers];
    MXSQLiteEventRow *row;
    NSString *txnId = [self insertEvent:event roomId:roomId direction:MXTimelineDirectionForwards row:&row];
    [self coverRangeInRoom:roomId low:row.ord high:row.ord topBefore:topBefore];
    [_lock unlock];
    if (txnId) [self consumeOutgoingForTransactionIds:@[txnId] roomId:roomId];
    return YES;
}

#pragma mark - MXSQLiteStoreComponent

- (MXSQLiteCommitBody)takePendingWrites
{
    [_lock lock];
    NSMutableArray<MXSQLitePendingBatch *> *group = [NSMutableArray array];
    for (MXSQLitePendingBatch *batch in _layers)
    {
        if (!batch.taken && batch.rooms.count) [group addObject:batch];
    }
    for (MXSQLitePendingBatch *batch in group) batch.taken = YES;
    if (group.count) [_takenGroups addObject:[group copy]];
    [_lock unlock];
    if (!group.count) return nil;

    MXSQLiteRoomRegistry *rooms = self.context.rooms;
    NSArray *batches = [group copy];
    return ^BOOL(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error) {
        for (MXSQLitePendingBatch *batch in batches)
        {
            if (![batch writeWithConnection:connection rooms:rooms commit:commit error:error]) return NO;
        }
        return YES;
    };
}

- (void)didFinishPendingWrites:(BOOL)committed
{
    [_lock lock];
    NSArray<MXSQLitePendingBatch *> *group = _takenGroups.firstObject;
    if (group)
    {
        [_takenGroups removeObjectAtIndex:0];
        for (MXSQLitePendingBatch *batch in group)
        {
            if (committed) [_layers removeObjectIdenticalTo:batch];
            else batch.taken = NO;   // остаётся видимой и уйдёт со следующим коммитом
        }
    }
    [_lock unlock];
}

- (void)willDeleteRoom:(NSString *)roomId
{
    [_lock lock];
    for (MXSQLitePendingBatch *batch in _layers)
    {
        if (!batch.taken) [batch.rooms removeObjectForKey:roomId];
    }
    MXSQLitePendingRoom *room = [self.currentBatch roomForWrite:roomId];
    room.clearAll = YES;
    room.deletedByFacade = YES;
    [_lock unlock];
}

- (void)didDeleteAllData
{
    [_lock lock];
    [_layers removeAllObjects];
    [_takenGroups removeAllObjects];
    _databaseHasPendingRedactions = nil;
    [_lock unlock];
}

@end
