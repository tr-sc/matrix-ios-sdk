//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Квитанции и отметка «непрочитано». Заглушка iP1: чтение пустое, запись принимается и забывается. Реализация — пакет iP4.
@interface MXSQLiteReceiptStore : NSObject <MXSQLiteReceiptStoring>
@end

NS_ASSUME_NONNULL_END
