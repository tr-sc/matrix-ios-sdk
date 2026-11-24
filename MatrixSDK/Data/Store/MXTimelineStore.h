//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXStore.h"
#import "MXEnumConstants.h"
#import "MXRoomSummaryProtocol.h"

@class MXEvent, MXPaginationResponse, MXEventContext;

NS_ASSUME_NONNULL_BEGIN

/**
 Контракт хранилища «события + дыры».

 Позиция события в ленте — `ord`, это `unsigned["trsc.count"]` как знаковый int64 (см. `MXEvent+TrscOrder.h`).
 На одном сервере `ord` и есть порядок ленты: у обычных событий растёт, у backfill отрицательный.

 Пропуск истории — дыра `(lowerOrder, upperOrder)`, обе границы исключающие. Инварианты одной ленты (комната или тред):
 - дыры не пересекаются;
 - ни одного события ленты нет строго внутри дыры;
 - комната без загруженного начала имеет нижнюю дыру `(MXRoomHoleOpenStart, min ord)`;
 - событие из пуша, вставленное раньше синка, лежит между двумя дырами: `(live edge, ord)` и `(ord, MXRoomHoleOpenEnd)`.

 Чтение — страницами, запись — через накладку: записанное видно для чтения сразу, на диск уходит на `commit`.
 На main можно звать только точечные методы и страницы до 100 событий.
 */

/// Постится на main после каждой транзакции записи. userInfo: `@{roomId: @(revision)}` для затронутых комнат.
FOUNDATION_EXPORT NSString *const MXStoreDidCommitNotification;

/// Нижняя граница дыры, когда начало истории неизвестно (`INT64_MIN`).
FOUNDATION_EXPORT int64_t const MXRoomHoleOpenStart;

/// Верхняя граница дыры над событием из пуша, пока синк не дошёл до него (`INT64_MAX`).
FOUNDATION_EXPORT int64_t const MXRoomHoleOpenEnd;

/**
 Дыра одной ленты. Снимок: стор возвращает копии, менять их бессмысленно.
 */
@interface MXRoomHole : NSObject <NSCopying>

- (instancetype)initWithRoomId:(NSString *)roomId
                      threadId:(nullable NSString *)threadId
                    lowerOrder:(int64_t)lowerOrder
                    upperOrder:(int64_t)upperOrder
                 backwardToken:(nullable NSString *)backwardToken
                  forwardToken:(nullable NSString *)forwardToken
                  retryBlocked:(BOOL)retryBlocked NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// `"<roomId>|<threadId или пусто>|<upperOrder>"`: верхняя граница уникальна в ленте, потому что дыры не пересекаются.
@property (nonatomic, readonly) NSString *holeId;
@property (nonatomic, readonly) NSString *roomId;
/// nil — основная лента; id корня — лента треда.
@property (nonatomic, readonly, nullable) NSString *threadId;
/// Исключающие границы. `MXRoomHoleOpenStart` / `MXRoomHoleOpenEnd` — граница неизвестна.
@property (nonatomic, readonly) int64_t lowerOrder;
@property (nonatomic, readonly) int64_t upperOrder;
/// `/messages?from=backwardToken&dir=b` — обычно `trsc.count` события на верхней границе.
@property (nonatomic, readonly, nullable) NSString *backwardToken;
/// `/messages?from=forwardToken&dir=f` — обычно `trsc.count` события на нижней границе.
@property (nonatomic, readonly, nullable) NSString *forwardToken;
/// Догрузка недавно упала и повторять её пока рано. Это не «история кончилась».
@property (nonatomic, readonly) BOOL retryBlocked;

/// Верхней границы нет: над дырой только будущие события синка.
@property (nonatomic, readonly) BOOL isOpenEnded;
/// Нижней границы нет: под дырой начало истории или порог автоудаления.
@property (nonatomic, readonly) BOOL isOpenStarted;

@end

/**
 Непрерывный кусок ленты между дырами. Страница никогда не склеивает события через дыру:
 если между событиями есть дыра, страница обрезается по ней и дыра отдаётся в `holeBefore` / `holeAfter`.
 */
@interface MXStorePage : NSObject

- (instancetype)initWithEvents:(NSArray<MXEvent *> *)events
                    holeBefore:(nullable MXRoomHole *)holeBefore
                     holeAfter:(nullable MXRoomHole *)holeAfter
               reachedRoomStart:(BOOL)reachedRoomStart
                reachedLiveEdge:(BOOL)reachedLiveEdge
                       revision:(NSUInteger)revision NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Пустая страница: нет событий, нет дыр, края не достигнуты, ревизия 0.
+ (instancetype)emptyPage;

/// От старых к новым.
@property (nonatomic, readonly) NSArray<MXEvent *> *events;
/// Дыра сразу под самым старым событием страницы, если она там есть.
@property (nonatomic, readonly, nullable) MXRoomHole *holeBefore;
/// Дыра сразу над самым новым событием страницы, если она там есть.
@property (nonatomic, readonly, nullable) MXRoomHole *holeAfter;
/// Ниже страницы событий нет и не будет: загружено начало истории (`m.room.create`) или порог удаления.
@property (nonatomic, readonly) BOOL reachedRoomStart;
/// Выше страницы ничего нет: самое новое событие страницы — живой край ленты.
@property (nonatomic, readonly) BOOL reachedLiveEdge;
/// Ревизия комнаты на момент чтения; та же, что в `MXStoreDidCommitNotification`.
@property (nonatomic, readonly) NSUInteger revision;

@end

/// Тайминги стора для журнала запуска. Вызывается на любом потоке.
@protocol MXStoreMetricsDelegate <NSObject>
@optional
/// Открытие базы: ключ, PRAGMA, проверка схемы.
- (void)store:(id<MXStore>)store didOpenInMilliseconds:(double)milliseconds databaseBytes:(uint64_t)bytes;
/// Одна транзакция записи: `events` — событий в ней, `rooms` — затронутых комнат.
- (void)store:(id<MXStore>)store didCommitInMilliseconds:(double)milliseconds events:(NSUInteger)events rooms:(NSUInteger)rooms;
/// Чтение одной страницы.
- (void)store:(id<MXStore>)store didReadPageInMilliseconds:(double)milliseconds events:(NSUInteger)events roomId:(NSString *)roomId;
/// Запись ответа догрузки в дыру.
- (void)store:(id<MXStore>)store didFillHoleInMilliseconds:(double)milliseconds events:(NSUInteger)events roomId:(NSString *)roomId;
/// База пересоздана (`reason`: `key_rejected`, `schema_mismatch`, `corrupt`, …).
- (void)store:(id<MXStore>)store didResetWithReason:(NSString *)reason;
/// База не открылась и не пересоздана, файл и ключ целы (`reason`: `transient` — следующий запуск пробует снова;
/// `cipher_unavailable`, `key_unavailable`, … — `+[MXSQLiteStore openFailureReasonForError:]`).
- (void)store:(id<MXStore>)store didFailToOpenWithReason:(NSString *)reason;
@end

/**
 Хранилище ленты страницами и дырами. Реализация: `MXSQLiteStore`.
 Потребители проверяют `[store conformsToProtocol:@protocol(MXTimelineStore)]`, иначе работают по-старому.
 */
@protocol MXTimelineStore <MXStore>

#pragma mark - Чтение

/// Самые новые `limit` событий ленты (до первой дыры сверху вниз).
/// @param threadId nil — основная лента, иначе лента треда с этим корнем.
/// @param types nil — все типы. Фильтр по типу не обрезает страницу по дыре между пропущенными событиями.
- (MXStorePage *)latestPageInRoom:(NSString *)roomId
                           thread:(nullable NSString *)threadId
                            limit:(NSUInteger)limit
                            types:(nullable NSSet<NSString *> *)types;

/// Страница строго старше `order` (исключающе).
- (MXStorePage *)pageInRoom:(NSString *)roomId
                     thread:(nullable NSString *)threadId
                beforeOrder:(int64_t)order
                      limit:(NSUInteger)limit
                      types:(nullable NSSet<NSString *> *)types;

/// Страница строго новее `order` (исключающе).
- (MXStorePage *)pageInRoom:(NSString *)roomId
                     thread:(nullable NSString *)threadId
                 afterOrder:(int64_t)order
                      limit:(NSUInteger)limit
                      types:(nullable NSSet<NSString *> *)types;

/// Окно вокруг события: около `limit / 2` с каждой стороны, само событие внутри. nil — события нет в базе.
- (nullable MXStorePage *)pageAroundEvent:(NSString *)eventId
                                   inRoom:(NSString *)roomId
                                    limit:(NSUInteger)limit;

/// Позиция события. NO — события нет в базе (`order` не трогается).
- (BOOL)orderOfEvent:(NSString *)eventId inRoom:(NSString *)roomId order:(int64_t *)order;

/// Все дыры ленты по возрастанию `upperOrder`.
- (NSArray<MXRoomHole *> *)holesInRoom:(NSString *)roomId thread:(nullable NSString *)threadId;

/// Ревизия комнаты: растёт с каждым коммитом, который её затронул. 0 — комнаты нет.
- (NSUInteger)revisionOfRoom:(NSString *)roomId;

/// Самое новое событие из `types` строго старше `order` (`MXRoomHoleOpenEnd` — без ограничения).
/// Для квитанции и маркера «прочитано»: сравнение по `ord`, а не по времени.
- (nullable MXEvent *)latestEventInRoom:(NSString *)roomId
                                  types:(nullable NSSet<NSString *> *)types
                               threadId:(nullable NSString *)threadId
                            beforeOrder:(int64_t)order;

/// Сколько событий новее `eventId` (nil — с начала имеющейся истории), не больше `limit`.
/// Если события `eventId` нет в базе, возвращает `NSNotFound` — вызывающий берёт серверный счётчик.
- (NSUInteger)countEventsInRoom:(NSString *)roomId
                   afterEventId:(nullable NSString *)eventId
                          types:(nullable NSSet<NSString *> *)types
                excludingSender:(nullable NSString *)userId
                       threadId:(nullable NSString *)threadId
                          limit:(NSUInteger)limit;

/**
 TRSC: непрочитанные сообщения строки списка чатов одним запросом — события `types` основной ленты после
 своей квитанции, без своих, удалённых, событий состояния, правок (`m.replace`) и реакций (`m.annotation`), не больше
 `limit`. -1 — своей квитанции или её события в базе нет (считать не от чего: вызывающий берёт серверный счётчик).
 Зовётся из `MXRoomSummary` при обновлении сводки; результат лежит в `MXRoomSummary.trscUnreadCount`.
 */
- (NSInteger)trscUnreadMessageCountInRoom:(NSString *)roomId types:(nullable NSArray<NSString *> *)types limit:(NSUInteger)limit;

/// Первые `limit` сводок по убыванию последней активности — для первого кадра главной.
- (NSArray<id<MXRoomSummaryProtocol>> *)summariesOrderedByActivity:(NSUInteger)limit;

#pragma mark - Запись (через накладку: видна сразу, на диск — на commit)

/**
 Начало пачки ленты из ответа синка. Зовётся один раз на комнату и ответ, **до** `storeEventForRoom:…Forwards` событий пачки.

 - Пачка непрерывна от своего первого события до «сейчас», поэтому все дыры выше `firstEvent.ord` (в том числе
   открытая сверху дыра над событием из пуша) убираются.
 - `limited == NO`: пачка продолжает живой край, дыры между прежним краем и `firstEvent` убираются.
 - `limited == YES` и `firstEvent` ещё не в базе: появляется дыра `(прежний живой край, firstEvent.ord)`
   с `backwardToken = firstEvent.trsc.count` (если номера нет — `prevBatch`). Для новой комнаты нижняя граница
   `MXRoomHoleOpenStart`.

 @param firstEvent первое событие ленты пачки; nil — лента пустая (тогда при `limited == NO` ничего не меняется).
 */
- (void)noteSyncTimelineInRoom:(NSString *)roomId
                    firstEvent:(nullable MXEvent *)firstEvent
                       limited:(BOOL)limited
                     prevBatch:(nullable NSString *)prevBatch;

/**
 Ответ `/messages` в дыру. Атомарно и идемпотентно: повтор того же ответа ничего не меняет.

 Назад (`dir=b`, от `hole.backwardToken`): события вставляются; если в ответе есть событие с `ord <= lowerOrder`
 или нет `end` — дыра закрывается (при `MXRoomHoleOpenStart` и пустом `end` достигнуто начало комнаты);
 иначе дыра сужается: `upperOrder = min(ord ответа)`, `backwardToken = end`.
 Вперёд (`dir=f`, от `hole.forwardToken`) — зеркально.

 Дыры, которой уже нет (её закрыл синк или другой ответ), — не ошибка: события вставляются, дыры не меняются.
 */
- (void)applyPage:(MXPaginationResponse *)response
           toHole:(MXRoomHole *)hole
        direction:(MXTimelineDirection)direction;

/**
 Окно `/context` (прыжок к сообщению). События вставляются со своими `ord`; дыра, в которую попало окно, делится
 на две: `(lo, min окна)` и `(max окна, hi)`. Окно — обычный диапазон между дырами, отдельной модели «контекстов» нет.
 */
- (void)insertContext:(MXEventContext *)context inRoom:(NSString *)roomId;

/**
 Одиночное событие из пуша (NSE → приложение) раньше синка.

 Событие ставится на свой `ord` и окружается дырами: если оно выше живого края — дыры `(живой край, ord)` и
 `(ord, MXRoomHoleOpenEnd)`; если внутри существующей дыры — дыра делится. Следующий синк закрывает их по правилам
 `noteSyncTimelineInRoom:…`, без дублей (событие с тем же id не вставляется второй раз).

 @return NO — у события нет `trsc.count` (позицию не определить) или оно уже в базе; база не меняется.
 */
- (BOOL)insertDetachedEvent:(MXEvent *)event inRoom:(NSString *)roomId;

#pragma mark - Метрики

@property (nonatomic, weak, nullable) id<MXStoreMetricsDelegate> metricsDelegate;

@end

NS_ASSUME_NONNULL_END
