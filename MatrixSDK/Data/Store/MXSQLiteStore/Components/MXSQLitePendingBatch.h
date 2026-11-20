//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXSQLiteHoleSet.h"

@class MXEvent, MXSQLiteConnection, MXSQLiteStatement, MXSQLiteRoomRegistry, MXSQLiteCommitContext;

NS_ASSUME_NONNULL_BEGIN

/// Биты колонки `event.flags`.
typedef NS_OPTIONS(int64_t, MXSQLiteEventFlags)
{
    MXSQLiteEventFlagExactOrder    = 1 << 0,   // ord — настоящий trsc.count, а не временный
    MXSQLiteEventFlagRedacted      = 1 << 1,
    MXSQLiteEventFlagEncrypted     = 1 << 2,
    MXSQLiteEventFlagDecryptFailed = 1 << 3,
    MXSQLiteEventFlagThreadRoot    = 1 << 4,
};

/**
 Строка таблицы `event`: из базы (тогда `event` разбирается из JSON лениво) или из накладки (тогда JSON
 собирается при коммите, на очереди писателя).
 */
@interface MXSQLiteEventRow : NSObject

/// Из события SDK. `ord`/`sub`/`exact` решает вызывающий.
- (instancetype)initWithEvent:(MXEvent *)event roomId:(NSString *)roomId ord:(int64_t)ord sub:(int64_t)sub exact:(BOOL)exact;
/// Из строки запроса `+selectColumns`.
- (instancetype)initWithStatement:(MXSQLiteStatement *)statement roomId:(NSString *)roomId;
- (instancetype)init NS_UNAVAILABLE;

/// Колонки в порядке, который понимает `initWithStatement:`.
@property (class, nonatomic, readonly) NSString *selectColumns;

@property (nonatomic, readonly) NSString *eventId;
@property (nonatomic, readonly) NSString *roomId;
@property (nonatomic, readonly) int64_t ord;
@property (nonatomic, readonly) int64_t sub;
@property (nonatomic, readonly) MXSQLiteEventFlags flags;
@property (nonatomic, readonly) NSString *type;
@property (nonatomic, readonly, nullable) NSString *sender;
@property (nonatomic, readonly, nullable) NSString *stateKey;
@property (nonatomic, readonly) int64_t ts;
@property (nonatomic, readonly, nullable) NSString *threadId;
@property (nonatomic, readonly, nullable) NSString *relType;
@property (nonatomic, readonly, nullable) NSString *relatesTo;
@property (nonatomic, readonly, nullable) NSString *txnId;
/// Строка с этим event_id переименовывается в эту (эхо и серверное событие — одна строка).
@property (nonatomic, copy, nullable) NSString *replacesEventId;
@property (nonatomic, readonly) BOOL exactOrder;

/// Событие SDK. Из базы — разбирается при первом обращении (с расшифрованным, если оно сохранено).
@property (nonatomic, readonly, nullable) MXEvent *event;

/// JSON для записи (`json`, `clear`). nil у `json` — событие не сериализуется (строка не пишется).
- (nullable NSData *)jsonData;
- (nullable NSData *)clearData;

/// Порядок ленты: (ord, sub).
- (NSComparisonResult)compareOrder:(MXSQLiteEventRow *)other;

@end

/// Какие события ленты брать.
typedef NS_ENUM(NSInteger, MXSQLiteThreadScope)
{
    /// Все события комнаты (основная лента старого стора: треды внутри).
    MXSQLiteThreadScopeAll,
    /// Только вне тредов (`thread_id IS NULL`): непрочитанные основной ленты.
    MXSQLiteThreadScopeMain,
    /// Только тред `threadId` (`thread_id = ?`), корень — по `includeThreadRoot`.
    MXSQLiteThreadScopeThread,
};

/**
 Условие выборки событий одной комнаты: одно и то же для SQL и для строк накладки.
 Границы `minOrder`/`maxOrder` включительные.
 */
@interface MXSQLiteEventFilter : NSObject <NSCopying>
@property (nonatomic) int64_t minOrder;
@property (nonatomic) int64_t maxOrder;
@property (nonatomic, copy, nullable) NSSet<NSString *> *types;
@property (nonatomic) MXSQLiteThreadScope threadScope;
@property (nonatomic, copy, nullable) NSString *threadId;
@property (nonatomic) BOOL includeThreadRoot;
@property (nonatomic, copy, nullable) NSString *excludedSender;
@property (nonatomic) BOOL excludeRedacted;
@property (nonatomic, copy, nullable) NSString *relatesTo;
@property (nonatomic, copy, nullable) NSString *relType;
/// Только эта строка (точечное чтение).
@property (nonatomic, copy, nullable) NSString *eventId;

+ (instancetype)filterFromOrder:(int64_t)minOrder toOrder:(int64_t)maxOrder;

- (BOOL)matchesRow:(MXSQLiteEventRow *)row;

/// `WHERE …` без слова WHERE: `rid = ?1` и условия; параметры с `?2` привязывает `bindTo:from:`.
/// `minTs` — нижняя граница `ts` для не-состояний (удаление по сроку из накладки), INT64_MIN — нет.
- (NSString *)sqlConditionWithMinTimestamp:(int64_t)minTs;
- (void)bindTo:(MXSQLiteStatement *)statement rid:(int64_t)rid minTimestamp:(int64_t)minTs;
/// Номер следующего свободного параметра после условия (для LIMIT).
- (int)nextParameterIndexWithMinTimestamp:(int64_t)minTs;

@end

/// Незакоммиченные изменения одной комнаты.
@interface MXSQLitePendingRoom : NSObject

/// Upsert по event_id.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLiteEventRow *> *events;
/// Удалить по event_id.
@property (nonatomic, readonly) NSMutableSet<NSString *> *deletedEventIds;
/// Удалить все события, дыры и края комнаты (до `events` этой же накладки).
@property (nonatomic) BOOL clearAll;
/// Комната удалена фасадом (`deleteRoom`): строки снесёт фасад, пустую комнату не создавать заново.
@property (nonatomic) BOOL deletedByFacade;
/// Удалить не-состояния с `ts` строго меньше (удаление по сроку). INT64_MIN — нет.
@property (nonatomic) int64_t deleteBeforeTs;
/// Полные наборы дыр по пространствам ('' — основная лента).
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLiteHoleSet *> *holes;
/// Живой край: NSNumber или NSNull (нет края); nil — не менялся.
@property (nonatomic, nullable) id liveOrder;
/// NSNumber(BOOL); nil — не менялся.
@property (nonatomic, nullable) NSNumber *reachedStart;
/// NSNumber(int64); nil — не менялся.
@property (nonatomic, nullable) NSNumber *retentionFloorTs;
/// Отложенные редакции: id цели → JSON редакции.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSDictionary *> *pendingRedactions;
/// Отложенные редакции, применённые к цели (удалить строку).
@property (nonatomic, readonly) NSMutableSet<NSString *> *resolvedRedactions;

/// Сколько строк накладки может заслонить строки базы (запас лимита запроса).
@property (nonatomic, readonly) NSUInteger shadowCount;
/// Есть, что писать.
@property (nonatomic, readonly) BOOL hasWrites;

@end

/**
 Накладка незакоммиченных записей компонента событий (ADR-0022 §«Запись: накладка и коммит»).

 Слои: `MXSQLiteEventStore` держит список пачек от старой к новой; новая принимает записи, старые уже отданы
 писателю и видимы для чтения, пока транзакция не закончится. Чтение = строки базы, поверх которых по порядку
 накладываются слои (`applyLayers:…`).
 */
@interface MXSQLitePendingBatch : NSObject

/// Комнаты пачки.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, MXSQLitePendingRoom *> *rooms;
@property (nonatomic, readonly) BOOL hasWrites;
/// Пачка отдана писателю (её тело выполняется или выполнено).
@property (nonatomic) BOOL taken;

- (MXSQLitePendingRoom *)roomForWrite:(NSString *)roomId;

/// Записать пачку в базу. Писатель, внутри транзакции коммита.
- (BOOL)writeWithConnection:(MXSQLiteConnection *)connection
                      rooms:(MXSQLiteRoomRegistry *)rooms
                     commit:(MXSQLiteCommitContext *)commit
                      error:(NSError **)error;

/**
 Наложить слои на строки базы одной комнаты: удаления, очистки, upsert. Результат — по порядку ленты (ord, sub)
 по возрастанию; строки накладки берутся, только если подходят под `filter`.
 */
+ (NSArray<MXSQLiteEventRow *> *)applyLayers:(NSArray<MXSQLitePendingBatch *> *)layers
                                      roomId:(NSString *)roomId
                                      toRows:(NSArray<MXSQLiteEventRow *> *)rows
                                      filter:(MXSQLiteEventFilter *)filter;

/// Читать ли базу вообще (никакой слой не очистил комнату) и нижняя граница `ts` от удаления по сроку.
+ (BOOL)layers:(NSArray<MXSQLitePendingBatch *> *)layers
 allowDatabaseRowsOfRoom:(NSString *)roomId
  minTimestamp:(int64_t *)minTs
   shadowCount:(nullable NSUInteger *)shadowCount;

@end

NS_ASSUME_NONNULL_END
