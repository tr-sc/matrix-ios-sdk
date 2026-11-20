//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Состояние комнаты (`room_state`, пишется только разница с прошлым), room account data, флаги пагинации и
/// участников (колонки `room`). Пакет iP3.
@interface MXSQLiteStateStore : NSObject <MXSQLiteStateStoring>
@end

NS_ASSUME_NONNULL_END
