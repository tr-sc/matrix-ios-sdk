//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXTimelineStore.h"

NS_ASSUME_NONNULL_BEGIN

/**
 Дыры одной ленты (комната или тред) — алгебра без базы (ADR-0022 §«Дыры»).

 Дыра `(lo, hi)` — неизвестные позиции `lo+1 … hi-1`; границы исключающие и обычно совпадают с `ord` событий.
 Набор держит инвариант: дыры отсортированы по `upperOrder`, не пересекаются и не пустые (между границами
 есть хотя бы одна позиция). Значит, набор однозначно равен максимальным сериям неизвестных позиций.

 Изменяемый, не потокобезопасный: им владеет накладка `MXSQLitePendingBatch` под своим замком.
 */
@interface MXSQLiteHoleSet : NSObject <NSCopying>

- (instancetype)initWithRoomId:(NSString *)roomId threadId:(nullable NSString *)threadId;
- (instancetype)initWithRoomId:(NSString *)roomId threadId:(nullable NSString *)threadId holes:(NSArray<MXRoomHole *> *)holes;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSString *roomId;
@property (nonatomic, readonly, nullable) NSString *threadId;

/// По возрастанию `upperOrder`.
@property (nonatomic, readonly) NSArray<MXRoomHole *> *holes;
@property (nonatomic, readonly) BOOL isEmpty;

#pragma mark - Поиск

/// Дыра, внутри которой лежит позиция: `lo < order < hi`.
- (nullable MXRoomHole *)holeContainingOrder:(int64_t)order;
/// Самая высокая дыра, целиком не выше позиции: `hi <= order`.
- (nullable MXRoomHole *)highestHoleAtOrBelowOrder:(int64_t)order;
/// Самая низкая дыра, целиком не ниже позиции: `lo >= order`.
- (nullable MXRoomHole *)lowestHoleAtOrAboveOrder:(int64_t)order;
/// Дыра с этой верхней границей.
- (nullable MXRoomHole *)holeWithUpperOrder:(int64_t)upperOrder;
/// Дыра с этой нижней границей.
- (nullable MXRoomHole *)holeWithLowerOrder:(int64_t)lowerOrder;
/// Дыра без верхней границы (`MXRoomHoleOpenEnd`), если есть.
@property (nonatomic, readonly, nullable) MXRoomHole *openEndedHole;

#pragma mark - Изменение

/**
 Добавить неизвестный диапазон `(lower, upper)`. Пересекающиеся дыры сливаются: токен назад берётся у куска
 с самой высокой верхней границей, токен вперёд — у куска с самой низкой нижней. Пустой диапазон игнорируется.
 Вызывающий отвечает за то, что внутри диапазона нет событий (иначе делите диапазон по событиям сами).
 */
- (void)addHoleWithLowerOrder:(int64_t)lower
                   upperOrder:(int64_t)upper
                backwardToken:(nullable NSString *)backwardToken
                 forwardToken:(nullable NSString *)forwardToken;

/**
 Позиции `low … high` (включительно) стали известны: всё, что от дыр попадает в них, вырезается.
 Кусок ниже `low` получает `backwardToken = lowToken` (если передан), кусок выше `high` — `forwardToken = highToken`.
 */
- (void)fillFromOrder:(int64_t)low
              toOrder:(int64_t)high
             lowToken:(nullable NSString *)lowToken
            highToken:(nullable NSString *)highToken;

/// Убрать дыру с этой верхней границей. NO — такой нет.
- (BOOL)removeHoleWithUpperOrder:(int64_t)upperOrder;

/// Заменить дыру с верхней границей `upperOrder` на новый диапазон и токены (пустой диапазон — удалить). NO — такой нет.
- (BOOL)replaceHoleWithUpperOrder:(int64_t)upperOrder
                       lowerOrder:(int64_t)newLower
                       upperOrder:(int64_t)newUpper
                    backwardToken:(nullable NSString *)backwardToken
                     forwardToken:(nullable NSString *)forwardToken;

- (void)removeAllHoles;

#pragma mark - Проверка

/// Инвариант набора (для тестов и assert): отсортировано, без пересечений, без пустых.
- (BOOL)isValid;

/// Пустой диапазон: между исключающими границами нет ни одной позиции.
+ (BOOL)isEmptyRangeLower:(int64_t)lower upper:(int64_t)upper;

@end

NS_ASSUME_NONNULL_END
