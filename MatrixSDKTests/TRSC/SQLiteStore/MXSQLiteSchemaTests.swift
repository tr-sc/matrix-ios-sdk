//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Схема v1 и смена её версии: кеш пересоздаётся, неотправленные сообщения и черновики переживают.
final class MXSQLiteSchemaTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
    }

    override func tearDown() {
        sandbox.remove()
        super.tearDown()
    }

    private func prepare(
        _ database: MXSQLiteDatabase,
        version: Int32,
        migrations: [Int: @convention(block) (MXSQLiteConnection, NSErrorPointer) -> Bool] = [:]
    ) throws -> MXSQLiteSchemaOutcome {
        // Swift не мостит замыкания внутри коллекций: кладём готовые блоки как объекты.
        var steps: [NSNumber: Any] = [:]
        for (version, step) in migrations {
            steps[NSNumber(value: version)] = step as AnyObject
        }
        var outcome = MXSQLiteSchemaOutcome.upToDate
        try database.writer { connection in
            try MXSQLiteSchema.prepare(
                connection,
                targetVersion: version,
                statements: MXSQLiteSchema.statements,
                migrations: steps,
                outcome: &outcome
            )
        }
        return outcome
    }

    private func tables(_ database: MXSQLiteDatabase) -> Set<String> {
        let names: [String]? = database.readValue { connection in
            try? connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                bind: nil,
                row: { $0.text(at: 0) }
            ) as? [String]
        }
        return Set(names ?? [])
    }

    private func seed(_ database: MXSQLiteDatabase) throws {
        try database.write { connection in
            try connection.run("INSERT INTO room (rid, room_id, draft) VALUES (7, '!a:x', x'cafe')", bind: nil)
            try connection.run("INSERT INTO room (rid, room_id) VALUES (8, '!b:x')", bind: nil)
            try connection.run(
                "INSERT INTO event (rid, ord, event_id, type, ts, json) VALUES (7, 10, '$e1', 'm.room.message', 1, x'7b7d')",
                bind: nil
            )
            try connection.run(
                "INSERT INTO hole (rid, lo, hi, hi_token) VALUES (7, -9223372036854775808, 10, '10')",
                bind: nil
            )
            try connection.run(
                "INSERT INTO outgoing (local_id, rid, txn_id, created_ts, sent_state, json, clear) "
                    + "VALUES ('kMXEventLocalId_1', 8, 'txn1', 42, 1, x'7b2261223a317d', NULL)",
                bind: nil
            )
            try connection.run("INSERT INTO meta (key, value) VALUES ('event_stream_token', 's1')", bind: nil)
        }
    }

    func testFreshFileGetsSchemaV1() throws {
        let database = try sandbox.open()
        XCTAssertEqual(try prepare(database, version: MXSQLiteSchema.currentVersion), .created)

        let version = database.readValue { $0.scalarInt("PRAGMA user_version") }
        XCTAssertEqual(version, Int64(MXSQLiteSchema.currentVersion))
        XCTAssertEqual(MXSQLiteSchema.currentVersion, 1)
        XCTAssertEqual(tables(database), [
            "meta", "room", "event", "hole", "redaction_pending", "room_state", "room_account_data", "receipt",
            "outgoing", "summary", "user", "filter", "reaction_count", "reaction_relation"
        ])
        for table in MXSQLiteSchema.roomScopedTables {
            XCTAssertTrue(tables(database).contains(table), table)
        }
    }

    func testSameVersionIsUpToDateAndKeepsData() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)
        XCTAssertEqual(try prepare(database, version: 1), .upToDate)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 1)
    }

    func testEventKeyIsUniquePerPosition() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)
        XCTAssertThrowsError(try database.write { connection in
            try connection.run(
                "INSERT INTO event (rid, ord, event_id, type, ts, json) VALUES (7, 10, '$other', 'm.room.message', 1, x'00')",
                bind: nil
            )
        }, "(rid, ord, sub) must be unique")
        XCTAssertThrowsError(try database.write { connection in
            try connection.run(
                "INSERT INTO event (rid, ord, event_id, type, ts, json) VALUES (8, 11, '$e1', 'm.room.message', 1, x'00')",
                bind: nil
            )
        }, "event_id must be unique")
    }

    func testVersionWithoutMigrationRebuildsButKeepsOutgoingAndDrafts() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)

        XCTAssertEqual(try prepare(database, version: 2), .rebuilt)

        XCTAssertEqual(database.readValue { $0.scalarInt("PRAGMA user_version") }, 2)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 0, "events are a cache")
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM hole") }, 0)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM meta") }, 0, "the sync restarts from scratch")

        let outgoing: [String]? = database.readValue { connection in
            try? connection.query(
                "SELECT r.room_id || '|' || o.local_id || '|' || o.txn_id || '|' || o.created_ts || '|' || o.sent_state || '|' || hex(o.json) "
                    + "FROM outgoing o JOIN room r ON r.rid = o.rid",
                bind: nil,
                row: { $0.text(at: 0) }
            ) as? [String]
        }
        XCTAssertEqual(outgoing, ["!b:x|kMXEventLocalId_1|txn1|42|1|7B2261223A317D"])

        let drafts: [String]? = database.readValue { connection in
            try? connection.query("SELECT room_id || '|' || hex(draft) FROM room WHERE draft IS NOT NULL", bind: nil, row: { $0.text(at: 0) }) as? [String]
        }
        XCTAssertEqual(drafts, ["!a:x|CAFE"])
    }

    func testFutureVersionRebuilds() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)
        try database.writer { connection in try connection.execute("PRAGMA user_version = 5") }

        XCTAssertEqual(try prepare(database, version: 1), .rebuilt)
        XCTAssertEqual(database.readValue { $0.scalarInt("PRAGMA user_version") }, 1)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM outgoing") }, 1)
    }

    func testRegisteredMigrationKeepsData() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)

        let step: @convention(block) (MXSQLiteConnection, NSErrorPointer) -> Bool = { connection, errorPointer in
            do {
                try connection.execute("ALTER TABLE event ADD COLUMN extra INTEGER")
                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return false
            }
        }
        XCTAssertEqual(try prepare(database, version: 2, migrations: [1: step]), .migrated)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 1)
        XCTAssertEqual(database.readValue { $0.scalarInt("PRAGMA user_version") }, 2)
    }

    func testFailedMigrationRollsBackEverything() throws {
        let database = try sandbox.openWithSchema()
        try seed(database)

        let step: @convention(block) (MXSQLiteConnection, NSErrorPointer) -> Bool = { connection, errorPointer in
            try? connection.execute("DELETE FROM event")
            errorPointer?.pointee = NSError(domain: "test", code: 1)
            return false
        }
        XCTAssertThrowsError(try prepare(database, version: 2, migrations: [1: step]))
        XCTAssertEqual(database.readValue { $0.scalarInt("PRAGMA user_version") }, 1)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 1)
    }

    func testRebuildSurvivesReopenWithSameKey() throws {
        let material = try sandbox.material()
        let database = try sandbox.openWithSchema(material: material)
        try seed(database)
        _ = try prepare(database, version: 2)
        database.close()

        let reopened = try sandbox.open(material: material)
        XCTAssertEqual(try prepare(reopened, version: 2), .upToDate)
        XCTAssertEqual(reopened.readValue { $0.scalarInt("SELECT count(*) FROM outgoing") }, 1)
        reopened.close()
    }
}
