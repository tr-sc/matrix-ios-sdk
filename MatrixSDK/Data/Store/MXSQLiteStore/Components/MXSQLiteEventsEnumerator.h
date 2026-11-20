//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXEventsEnumerator.h"

@class MXSQLiteEventRow;

NS_ASSUME_NONNULL_BEGIN

/// Откуда перечислитель берёт строки: компонент событий (накладка + база).
@protocol MXSQLiteEventsEnumeratorSource <NSObject>

/**
 Строки непрерывного куска ленты строго ниже `order`, от новых к старым, не больше `limit`.
 @param reachedEnd YES — ниже больше ничего нет в этом куске: дыра или начало истории.
 */
- (NSArray<MXSQLiteEventRow *> *)enumeratorRowsInRoom:(NSString *)roomId
                                           belowOrder:(int64_t)order
                                                limit:(NSUInteger)limit
                                                types:(nullable NSSet<NSString *> *)types
                                           reachedEnd:(BOOL *)reachedEnd;

/// Сколько строк непрерывного куска строго ниже `order` (до дыры).
- (NSUInteger)enumeratorCountInRoom:(NSString *)roomId belowOrder:(int64_t)order types:(nullable NSSet<NSString *> *)types;

@end

/**
 Постраничный перечислитель ленты комнаты (ADR-0022): батчи по 50 строк с курсора `ord`, от новых к старым.
 Дыры не пересекает — останавливается на первой (оговорка «плоский перечислитель пересекает интервалы»
 из `MXStore.h` к нему не относится). Семантика `nextEventsBatch:threadId:` — как у `MXEventsEnumeratorOnArray`.
 */
@interface MXSQLiteEventsEnumerator : NSObject <MXEventsEnumerator>

- (instancetype)initWithSource:(id<MXSQLiteEventsEnumeratorSource>)source
                        roomId:(NSString *)roomId
                         types:(nullable NSSet<NSString *> *)types NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Размер одной выборки из базы.
@property (class, nonatomic, readonly) NSUInteger pageSize;

@end

NS_ASSUME_NONNULL_END
