//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Мета сессии (токен синка, well-known, versions…), пользователи, группы, фильтры. Заглушка iP1: чтение пустое, запись принимается и забывается. Реализация — пакет iP3.
@interface MXSQLiteMetaStore : NSObject <MXSQLiteMetaStoring>
@end

NS_ASSUME_NONNULL_END
