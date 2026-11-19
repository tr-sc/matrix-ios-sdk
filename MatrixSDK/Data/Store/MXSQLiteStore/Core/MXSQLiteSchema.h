//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

@class MXSQLiteConnection;

NS_ASSUME_NONNULL_BEGIN

/// Что сделала подготовка схемы.
typedef NS_ENUM(NSInteger, MXSQLiteSchemaOutcome)
{
    /// Пустой файл: схема создана.
    MXSQLiteSchemaOutcomeCreated,
    /// Версия совпала.
    MXSQLiteSchemaOutcomeUpToDate,
    /// Применены миграции по шагам.
    MXSQLiteSchemaOutcomeMigrated,
    /// Пути миграции нет (или версия из будущего): кеш снесён и создан заново, `outgoing` и черновики перенесены.
    MXSQLiteSchemaOutcomeRebuilt,
};

/// Шаг миграции `from → from + 1` внутри транзакции подготовки.
typedef BOOL (^MXSQLiteMigrationStep)(MXSQLiteConnection *connection, NSError **error);

/**
 Схема `MXSQLiteStore` (ADR-0022 §iOS «Схема»), версия в `PRAGMA user_version`.

 База — кеш, его наполняет синк. Поэтому при несовпадении версии без пути миграции всё сносится и создаётся заново.
 Исключение — то, чего нет на сервере: неотправленные сообщения (`outgoing`) и черновики (`room.draft`). Они
 переносятся в новую схему по `room_id`.
 */
@interface MXSQLiteSchema : NSObject

/// Текущая версия схемы кода.
@property (class, nonatomic, readonly) int32_t currentVersion;

/// DDL текущей версии: таблицы и индексы, по одному запросу на элемент.
@property (class, nonatomic, readonly) NSArray<NSString *> *statements;

/// Таблицы с колонкой `rid` — их строки удаляются вместе с комнатой.
@property (class, nonatomic, readonly) NSArray<NSString *> *roomScopedTables;

/**
 Привести файл к версии `targetVersion` одной транзакцией на писателе.

 @param migrations шаги по исходной версии: `migrations[@(n)]` (блок `MXSQLiteMigrationStep`) переводит n → n+1.
                   Если для какого-то шага от текущей версии до целевой его нет — пересоздание. Значения типизированы
                   как `id`: Swift не мостит блоки внутри коллекций и падает на приведении словаря.
 @param statements DDL целевой версии (для тестов; в коде — `MXSQLiteSchema.statements`).
 */
+ (BOOL)prepareConnection:(MXSQLiteConnection *)connection
            targetVersion:(int32_t)targetVersion
               statements:(NSArray<NSString *> *)statements
               migrations:(NSDictionary<NSNumber *, id> *)migrations
                  outcome:(nullable MXSQLiteSchemaOutcome *)outcome
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
