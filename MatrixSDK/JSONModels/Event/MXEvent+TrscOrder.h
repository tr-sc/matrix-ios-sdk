//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXEvent.h"

NS_ASSUME_NONNULL_BEGIN

/**
 TRSC: позиция события в ленте сервера — `unsigned["trsc.count"]` (ADR-0022).

 Строка сервера — это `PduCount` Tuwunel: у обычных событий положительная и растёт, у backfill отрицательная.
 На одном сервере это порядок ленты `/sync` и `/messages`; `/messages?from=<trsc.count>` исключающий.
 */
@interface MXEvent (TrscOrder)

/// YES, если сервер прислал корректный `trsc.count`.
@property (nonatomic, readonly) BOOL hasTrscOrder;

/// Позиция как int64. 0, если `hasTrscOrder == NO` — проверяйте флаг, 0 сам по себе ничего не значит.
@property (nonatomic, readonly) int64_t trscOrder;

/// Разбор строки `trsc.count`: только целое десятичное со знаком, без пробелов и в пределах int64.
+ (BOOL)trscOrderFromCount:(nullable NSString *)count order:(int64_t *)order;

@end

NS_ASSUME_NONNULL_END
