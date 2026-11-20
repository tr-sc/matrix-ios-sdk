//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponents.h"

NS_ASSUME_NONNULL_BEGIN

/// Ключ `meta` токена синка (тесты атомарности читают его из базы).
FOUNDATION_EXPORT NSString *const MXSQLiteMetaKeyEventStreamToken;
/// Ключ `meta` отметки «перенос из MXFileStore сделан».
FOUNDATION_EXPORT NSString *const MXSQLiteMetaKeyLegacyImportDone;

/// Мета сессии в таблице `meta` (токен синка — в общей транзакции коммита с событиями, well-known, versions…),
/// пользователи (`user`), фильтры (`filter`). Группы — только в памяти (из Matrix удалены). Пакет iP3.
@interface MXSQLiteMetaStore : NSObject <MXSQLiteMetaStoring>
@end

NS_ASSUME_NONNULL_END
