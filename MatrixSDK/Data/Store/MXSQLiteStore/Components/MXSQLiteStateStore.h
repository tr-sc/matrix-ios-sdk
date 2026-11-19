//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Состояние комнаты, room account data, флаги пагинации и участников. Заглушка iP1: чтение пустое, запись принимается и забывается. Реализация — пакет iP3.
@interface MXSQLiteStateStore : NSObject <MXSQLiteStateStoring>
@end

NS_ASSUME_NONNULL_END
