//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Исходящие и черновики. Заглушка iP1: чтение пустое, запись принимается и забывается. Реализация — пакет iP4.
@interface MXSQLiteOutgoingStore : NSObject <MXSQLiteOutgoingStoring>
@end

NS_ASSUME_NONNULL_END
