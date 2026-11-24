//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteDatabase.h"

NS_ASSUME_NONNULL_BEGIN

/**
 Подменники для тестов SDK. Заголовок приватный (`private_header_files` в MatrixSDK.podspec): его нет в зонтичном
 заголовке и модуле MatrixSDK, поэтому из кода приложения (`import MatrixSDK`) эти методы не видны. Тесты берут его
 через bridging header своей цели.

 Здесь, а не в `MXSQLiteDatabase.h`: подмена версии шифра снимает fail-closed проверку SQLCipher, и вызов из приложения
 писал бы историю открытым текстом.
 */
@interface MXSQLiteDatabase (Testing)

/// Запрос вместо `PRAGMA cipher_version;` (nil — вернуть обычный). `SELECT ''` изображает SQLite без SQLCipher.
+ (void)setCipherVersionQueryForTesting:(nullable NSString *)query;

/// Коды результата проверочного чтения ключа (`SELECT count(*) FROM sqlite_master`), по одному на попытку: код,
/// отличный от `SQLITE_OK`, отдаётся вместо настоящего чтения, `SQLITE_OK` (0) — читать по-настоящему. Когда очередь
/// кончилась — обычное чтение. nil — сбросить. `@[@7, @7]` (`SQLITE_NOMEM` дважды) изображает нехватку памяти
/// при открытии с верным ключом.
+ (void)setKeyCheckResultCodesForTesting:(nullable NSArray<NSNumber *> *)codes;

/// Пауза перед повтором проверочного чтения после `SQLITE_NOMEM`, мс (nil — обычная).
+ (void)setNoMemoryRetryDelayForTesting:(nullable NSNumber *)milliseconds;

@end

NS_ASSUME_NONNULL_END
