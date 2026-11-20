//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Квитанции (`receipt`, строка на комнату + тред + пользователя) и отметка «непрочитано» (`room.marked_unread`). Пакет iP4.
@interface MXSQLiteReceiptStore : NSObject <MXSQLiteReceiptStoring>
@end

NS_ASSUME_NONNULL_END
