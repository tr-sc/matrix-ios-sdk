//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteSchema.h"

#import "MXSQLiteDatabase.h"
#import "MXLog.h"

@implementation MXSQLiteSchema

+ (int32_t)currentVersion
{
    return 1;
}

+ (NSArray<NSString *> *)statements
{
    static NSArray<NSString *> *statements;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Длинные CREATE TABLE склеены из строк по колонкам, чтобы рядом стоял комментарий.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-string-concatenation"
        statements = @[
            // event_stream_token, sync_filter_id, user_account_data, well_known, capabilities, versions,
            // auth_metadata, max_upload_size, is_terms_agreed, server_event_count
            @"CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",

            @"CREATE TABLE room ("
             "rid INTEGER PRIMARY KEY, "                // короткий суррогат: ключи событий и дыр в 5–8 раз короче room_id
             "room_id TEXT NOT NULL UNIQUE, "
             "revision INTEGER NOT NULL DEFAULT 0, "    // растёт с каждым коммитом, затронувшим комнату
             "live_ord INTEGER, "                       // живой край: ord последнего события непрерывного синка
             "members_loaded INTEGER NOT NULL DEFAULT 0, "
             "marked_unread INTEGER NOT NULL DEFAULT 0, "
             "reached_start INTEGER NOT NULL DEFAULT 0, "   // история до m.room.create загружена
             "retention_floor_ts INTEGER, "             // ниже не храним и не догружаем (TrscRetentionCenter)
             "draft BLOB, "                             // NSAttributedString (NSKeyedArchiver)
             "legacy_token TEXT, "                      // paginationTokenOfRoom для старых вызовов
             "backward_state INTEGER NOT NULL DEFAULT 0, "
             "reached_end INTEGER NOT NULL DEFAULT 0)",  // hasReachedHomeServerPaginationEnd

            @"CREATE TABLE event ("
             "id INTEGER PRIMARY KEY, "                 // rowid: строки большие, WITHOUT ROWID здесь хуже
             "rid INTEGER NOT NULL, "
             "ord INTEGER NOT NULL, "                   // trsc.count (signed int64); backfill < 0
             "sub INTEGER NOT NULL DEFAULT 0, "         // > 0 только у событий без trsc.count (временный порядок)
             "event_id TEXT NOT NULL, "
             "type TEXT NOT NULL, "                     // у зашифрованных — тип расшифрованного, если есть
             "sender TEXT, "
             "state_key TEXT, "
             "ts INTEGER NOT NULL, "                    // origin_server_ts
             "thread_id TEXT, "                         // корень треда (m.thread) или NULL
             "rel_type TEXT, "
             "relates_to TEXT, "
             "txn_id TEXT, "                            // unsigned.transaction_id своих: связь с локальным эхо
             "flags INTEGER NOT NULL DEFAULT 0, "       // 1 exact_ord, 2 redacted, 4 encrypted, 8 decrypt_failed, 16 thread_root
             "json BLOB NOT NULL, "                     // событие с провода (после редакции — урезанное)
             "clear BLOB)",                             // расшифрованное (E2EE), NULL если нет
            @"CREATE UNIQUE INDEX event_pos ON event(rid, ord, sub)",
            @"CREATE UNIQUE INDEX event_eid ON event(event_id)",
            @"CREATE INDEX event_type ON event(rid, type, ord)",
            @"CREATE INDEX event_thread ON event(rid, thread_id, ord) WHERE thread_id IS NOT NULL",
            @"CREATE INDEX event_rel ON event(relates_to, rel_type) WHERE relates_to IS NOT NULL",
            @"CREATE INDEX event_ts ON event(rid, ts)",
            @"CREATE INDEX event_txn ON event(txn_id) WHERE txn_id IS NOT NULL",

            @"CREATE TABLE hole ("
             "rid INTEGER NOT NULL, "
             "space TEXT NOT NULL DEFAULT '', "         // '' основная лента; event_id корня — лента треда
             "lo INTEGER NOT NULL, "                    // исключающая нижняя граница; INT64_MIN — начало неизвестно
             "hi INTEGER NOT NULL, "                    // исключающая верхняя граница; INT64_MAX — над событием из пуша
             "hi_token TEXT, "                          // /messages from=hi_token dir=b
             "lo_token TEXT, "                          // /messages from=lo_token dir=f
             "retry_after INTEGER, "                    // не догружать до этого времени (мс)
             "PRIMARY KEY (rid, space, hi)) WITHOUT ROWID",

            // Редакция пришла раньше цели: применяется при вставке цели.
            @"CREATE TABLE redaction_pending ("
             "target_event_id TEXT PRIMARY KEY, rid INTEGER NOT NULL, json BLOB NOT NULL) WITHOUT ROWID",

            @"CREATE TABLE room_state ("
             "rid INTEGER NOT NULL, type TEXT NOT NULL, state_key TEXT NOT NULL, "
             "event_id TEXT, json BLOB NOT NULL, PRIMARY KEY (rid, type, state_key))",

            @"CREATE TABLE room_account_data (rid INTEGER PRIMARY KEY, data BLOB NOT NULL)",

            @"CREATE TABLE receipt ("
             "rid INTEGER NOT NULL, thread TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL, "
             "event_id TEXT NOT NULL, ts INTEGER NOT NULL, data BLOB, "
             "PRIMARY KEY (rid, thread, user_id)) WITHOUT ROWID",
            @"CREATE INDEX receipt_event ON receipt(rid, event_id)",

            @"CREATE TABLE outgoing ("
             "local_id TEXT PRIMARY KEY, "              // kMXEventLocalEventIdPrefix… — id строки на весь её век
             "rid INTEGER NOT NULL, txn_id TEXT, created_ts INTEGER NOT NULL, "
             "sent_state INTEGER NOT NULL, json BLOB NOT NULL, clear BLOB)",
            @"CREATE INDEX outgoing_room ON outgoing(rid, created_ts)",
            @"CREATE INDEX outgoing_txn ON outgoing(txn_id) WHERE txn_id IS NOT NULL",

            @"CREATE TABLE summary (rid INTEGER PRIMARY KEY, last_ts INTEGER NOT NULL, data BLOB NOT NULL)",
            @"CREATE INDEX summary_activity ON summary(last_ts DESC)",

            @"CREATE TABLE user (user_id TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID",
            @"CREATE TABLE filter (filter_id TEXT PRIMARY KEY, json BLOB NOT NULL) WITHOUT ROWID",

            @"CREATE TABLE reaction_count ("
             "event_id TEXT NOT NULL, reaction TEXT NOT NULL, count INTEGER NOT NULL, "
             "origin_ts INTEGER, mine INTEGER NOT NULL, rid INTEGER NOT NULL, "
             "PRIMARY KEY (event_id, reaction)) WITHOUT ROWID",
            @"CREATE INDEX reaction_count_room ON reaction_count(rid)",
            @"CREATE TABLE reaction_relation ("
             "reaction_event_id TEXT PRIMARY KEY, event_id TEXT NOT NULL, reaction TEXT NOT NULL, "
             "sender TEXT, ts INTEGER, rid INTEGER NOT NULL) WITHOUT ROWID",
            @"CREATE INDEX reaction_relation_target ON reaction_relation(event_id)",
            @"CREATE INDEX reaction_relation_room ON reaction_relation(rid)",
        ];
#pragma clang diagnostic pop
    });
    return statements;
}

+ (NSArray<NSString *> *)roomScopedTables
{
    return @[@"event", @"hole", @"redaction_pending", @"room_state", @"room_account_data", @"receipt",
             @"outgoing", @"summary", @"reaction_count", @"reaction_relation"];
}

+ (BOOL)prepareConnection:(MXSQLiteConnection *)connection
            targetVersion:(int32_t)targetVersion
               statements:(NSArray<NSString *> *)statements
               migrations:(NSDictionary<NSNumber *, id> *)migrations
                  outcome:(MXSQLiteSchemaOutcome *)outcome
                    error:(NSError **)error
{
    if (![connection execute:@"BEGIN IMMEDIATE;" error:error])
    {
        return NO;
    }

    MXSQLiteSchemaOutcome result;
    BOOL ok = [self prepareInTransaction:connection targetVersion:targetVersion statements:statements
                              migrations:migrations outcome:&result error:error];
    if (ok)
    {
        ok = [connection execute:@"COMMIT;" error:error];
    }
    if (!ok)
    {
        [connection execute:@"ROLLBACK;" error:nil];
        return NO;
    }
    if (outcome)
    {
        *outcome = result;
    }
    return YES;
}

+ (BOOL)prepareInTransaction:(MXSQLiteConnection *)connection
               targetVersion:(int32_t)targetVersion
                  statements:(NSArray<NSString *> *)statements
                  migrations:(NSDictionary<NSNumber *, id> *)migrations
                     outcome:(MXSQLiteSchemaOutcome *)outcome
                       error:(NSError **)error
{
    int64_t version = [connection int64ForQuery:@"PRAGMA user_version;" defaultValue:0 error:error];
    if (version == targetVersion)
    {
        *outcome = MXSQLiteSchemaOutcomeUpToDate;
        return YES;
    }

    NSArray<NSString *> *tables = [self userTablesInConnection:connection error:error];
    if (!tables)
    {
        return NO;
    }

    if (version == 0 && tables.count == 0)
    {
        *outcome = MXSQLiteSchemaOutcomeCreated;
        return [self createWithStatements:statements connection:connection error:error]
            && [self setVersion:targetVersion connection:connection error:error];
    }

    if (version > 0 && version < targetVersion && [self hasPathFrom:version to:targetVersion migrations:migrations])
    {
        for (int64_t step = version; step < targetVersion; step++)
        {
            MXSQLiteMigrationStep migrate = migrations[@(step)];
            if (!migrate(connection, error))
            {
                return NO;
            }
        }
        *outcome = MXSQLiteSchemaOutcomeMigrated;
        return [self setVersion:targetVersion connection:connection error:error];
    }

    MXLogWarning(@"[MXSQLiteSchema] Rebuilding the store: version %lld, expected %d", version, targetVersion);
    *outcome = MXSQLiteSchemaOutcomeRebuilt;
    return [self rebuildWithStatements:statements tables:tables connection:connection error:error]
        && [self setVersion:targetVersion connection:connection error:error];
}

+ (BOOL)hasPathFrom:(int64_t)version to:(int32_t)target migrations:(NSDictionary<NSNumber *, id> *)migrations
{
    for (int64_t step = version; step < target; step++)
    {
        if (!migrations[@(step)])
        {
            return NO;
        }
    }
    return YES;
}

+ (NSArray<NSString *> *)userTablesInConnection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    return [connection query:@"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
                        bind:nil
                         row:^id(MXSQLiteStatement *statement) { return [statement textAt:0]; }
                       error:error];
}

+ (BOOL)createWithStatements:(NSArray<NSString *> *)statements connection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    for (NSString *statement in statements)
    {
        if (![connection execute:statement error:error])
        {
            return NO;
        }
    }
    return YES;
}

+ (BOOL)setVersion:(int32_t)version connection:(MXSQLiteConnection *)connection error:(NSError **)error
{
    return [connection execute:[NSString stringWithFormat:@"PRAGMA user_version = %d;", version] error:error];
}

#pragma mark - Rebuild

/// Строки, которых нет на сервере. Читаются из старой схемы по именам колонок v1; если старая схема другая
/// и чтение падает, теряются они, а не весь запуск (в лог).
+ (BOOL)rebuildWithStatements:(NSArray<NSString *> *)statements
                       tables:(NSArray<NSString *> *)tables
                   connection:(MXSQLiteConnection *)connection
                        error:(NSError **)error
{
    NSArray<NSArray *> *outgoing = @[];
    NSArray<NSArray *> *drafts = @[];
    if ([tables containsObject:@"outgoing"] && [tables containsObject:@"room"])
    {
        NSError *readError;
        outgoing = [connection query:@"SELECT r.room_id, o.local_id, o.txn_id, o.created_ts, o.sent_state, o.json, o.clear "
                                      "FROM outgoing o JOIN room r ON r.rid = o.rid"
                                bind:nil
                                 row:^id(MXSQLiteStatement *statement) {
            return @[[statement textAt:0] ?: @"", [statement textAt:1] ?: @"", [statement textAt:2] ?: NSNull.null,
                     @([statement int64At:3]), @([statement int64At:4]), [statement blobAt:5] ?: NSData.data,
                     [statement blobAt:6] ?: NSNull.null];
        } error:&readError] ?: @[];
        if (readError)
        {
            MXLogWarning(@"[MXSQLiteSchema] Outgoing messages are lost in the rebuild: %@", readError);
        }
    }
    if ([tables containsObject:@"room"])
    {
        NSError *readError;
        drafts = [connection query:@"SELECT room_id, draft FROM room WHERE draft IS NOT NULL"
                              bind:nil
                               row:^id(MXSQLiteStatement *statement) {
            return @[[statement textAt:0] ?: @"", [statement blobAt:1] ?: NSData.data];
        } error:&readError] ?: @[];
        if (readError)
        {
            MXLogWarning(@"[MXSQLiteSchema] Drafts are lost in the rebuild: %@", readError);
        }
    }

    // Индексы и триггеры уходят вместе с таблицами.
    for (NSString *table in tables)
    {
        NSString *quoted = [table stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        if (![connection execute:[NSString stringWithFormat:@"DROP TABLE IF EXISTS \"%@\";", quoted] error:error])
        {
            return NO;
        }
    }
    if (![self createWithStatements:statements connection:connection error:error])
    {
        return NO;
    }

    NSString *insertRoom = @"INSERT INTO room (room_id) VALUES (?1) ON CONFLICT(room_id) DO NOTHING";
    NSString *ridOfRoom = @"SELECT rid FROM room WHERE room_id = ?1";
    int64_t (^ridFor)(NSString *) = ^int64_t(NSString *roomId) {
        [connection run:insertRoom bind:^(MXSQLiteStatement *statement) { [statement bindText:roomId at:1]; } error:nil];
        NSNumber *rid = [connection query:ridOfRoom bind:^(MXSQLiteStatement *statement) {
            [statement bindText:roomId at:1];
        } row:^id(MXSQLiteStatement *statement) { return @([statement int64At:0]); } error:nil].firstObject;
        return rid.longLongValue;
    };

    for (NSArray *draft in drafts)
    {
        int64_t rid = ridFor(draft[0]);
        if (![connection run:@"UPDATE room SET draft = ?2 WHERE rid = ?1" bind:^(MXSQLiteStatement *statement) {
            [statement bindInt64:rid at:1];
            [statement bindBlob:draft[1] at:2];
        } error:error])
        {
            return NO;
        }
    }
    for (NSArray *row in outgoing)
    {
        int64_t rid = ridFor(row[0]);
        if (![connection run:@"INSERT INTO outgoing (local_id, rid, txn_id, created_ts, sent_state, json, clear) "
                              "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"
                        bind:^(MXSQLiteStatement *statement) {
            [statement bindText:row[1] at:1];
            [statement bindInt64:rid at:2];
            [statement bindText:row[2] == NSNull.null ? nil : row[2] at:3];
            [statement bindInt64:[row[3] longLongValue] at:4];
            [statement bindInt64:[row[4] longLongValue] at:5];
            [statement bindBlob:row[5] at:6];
            [statement bindBlob:row[6] == NSNull.null ? nil : row[6] at:7];
        } error:error])
        {
            return NO;
        }
    }
    return YES;
}

@end
