//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Исходящие (`outgoing`, строка на local_id) и черновики (`room.draft`). Пакет iP4.
@interface MXSQLiteOutgoingStore : NSObject <MXSQLiteOutgoingStoring>
@end

NS_ASSUME_NONNULL_END
