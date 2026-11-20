//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Накладка компонента `MXSQLiteStore` по ключу (ADR-0022 §1.10): незакоммиченные записи, видимые чтению сразу.

 Три слоя, чтение идёт сверху вниз:
 1. `pending` — записи после последнего `take`;
 2. партии в полёте — отданы телу коммита, ещё не подтверждены (их может быть несколько: `commit` зовут чаще,
    чем пишет писатель; писатель последовательный, поэтому подтверждения приходят в порядке `take`);
 3. кеш закоммиченного (если включён) — чтобы точечные чтения с main не ходили в базу каждый раз.

 `NSNull` в значении — удаление (надгробие). Потокобезопасна.
 */
@interface MXSQLiteOverlay<KeyType, ObjectType> : NSObject

/// YES — после успешного коммита значения партии остаются в кеше, `cachedObjectForKey:` их отдаёт.
- (instancetype)initWithCommittedCache:(BOOL)cachesCommitted NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

/// Записать (или `NSNull` — удалить).
- (void)setObject:(id)object forKey:(KeyType<NSCopying>)key;

/// Незакоммиченное значение: `pending`, затем партии в полёте от новой к старой. nil — ключа в накладке нет;
/// `NSNull` — удалено.
- (nullable id)objectForKey:(KeyType<NSCopying>)key;

/// Только `pending` (для слияния нескольких записей в одну до коммита).
- (nullable id)pendingObjectForKey:(KeyType<NSCopying>)key;

/// Накладка, затем кеш закоммиченного. nil — не знаем, надо читать базу.
- (nullable id)cachedObjectForKey:(KeyType<NSCopying>)key;

/// Положить прочитанное из базы в кеш, если ключа там ещё нет (чтение не перетирает свежий коммит).
- (void)cacheObject:(id)object forKey:(KeyType<NSCopying>)key;

/// Все незакоммиченные ключи и значения (новые поверх старых).
- (NSDictionary<KeyType, id> *)snapshot;

@property (nonatomic, readonly) BOOL hasPending;

/// Забрать `pending` в новую партию в полёте. Всегда кладёт партию (возможно пустую): `finishOldestCommitted:`
/// снимает их по одной.
- (NSDictionary<KeyType, id> *)take;

/// Самая старая партия в полёте закончилась. YES — в кеш; NO — вернуть в `pending` те ключи, которые с тех пор не
/// переписаны (ни в `pending`, ни в более новой партии).
- (void)finishOldestCommitted:(BOOL)committed;

/// Забыть ключи (во всех слоях), для которых `test` вернул YES.
- (void)removeKeysPassingTest:(BOOL (NS_NOESCAPE ^)(KeyType key))test;

- (void)removeAll;

@end

NS_ASSUME_NONNULL_END
