//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP3: состояние комнаты (разница), room account data, флаги комнаты, атомарность токена синка.
final class MXSQLiteStateStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private let roomId = "!state:example.org"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func members(_ count: Int, changed: Int? = nil) -> [MXEvent] {
        var events = [MXSQLiteStoreHarness.stateEvent(type: kMXEventTypeStringRoomCreate, stateKey: "", eventId: "$create")]
        for index in 0..<count {
            let eventId = index == changed ? "$m\(index)-v2" : "$m\(index)"
            events.append(MXSQLiteStoreHarness.stateEvent(stateKey: "@u\(index):x", eventId: eventId))
        }
        return events
    }

    /// Журнал изменений `room_state`: сколько строк коммит реально вставил, обновил и удалил.
    private func installStateWriteLog() throws {
        try harness.database.exec("""
            CREATE TABLE test_state_log (op TEXT);
            CREATE TRIGGER test_state_ins AFTER INSERT ON room_state BEGIN INSERT INTO test_state_log VALUES ('i'); END;
            CREATE TRIGGER test_state_upd AFTER UPDATE ON room_state BEGIN INSERT INTO test_state_log VALUES ('u'); END;
            CREATE TRIGGER test_state_del AFTER DELETE ON room_state BEGIN INSERT INTO test_state_log VALUES ('d'); END;
            """)
    }

    // MARK: - State

    func testStateIsReadableBeforeCommitAndAfterReopen() throws {
        let store = harness.store
        store.storeState(forRoom: roomId, stateEvents: members(3))
        XCTAssertEqual(harness.state(of: roomId).count, 4, "read-your-writes before commit")

        harness.commit()
        let reopened = try harness.reopen()
        let state = harness.state(of: roomId, in: reopened)
        XCTAssertEqual(Set(state.compactMap(\.eventId)), ["$create", "$m0", "$m1", "$m2"])
        let member = state.first { $0.stateKey == "@u1:x" }
        XCTAssertEqual(member?.content["membership"] as? String, "join")
    }

    func testOneChangedMemberOfFiveThousandWritesOneRow() throws {
        let store = harness.store
        store.storeState(forRoom: roomId, stateEvents: members(5000))
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 5001)

        try installStateWriteLog()
        store.storeState(forRoom: roomId, stateEvents: members(5000, changed: 4321))
        harness.commit()

        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM test_state_log"), 1, "only the changed member is written")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state WHERE event_id = '$m4321-v2'"), 1)
    }

    func testDiffIsComputedAgainstTheFileAfterReopen() throws {
        harness.store.storeState(forRoom: roomId, stateEvents: members(100))
        harness.commit()
        let reopened = try harness.reopen()

        try installStateWriteLog()
        reopened.storeState(forRoom: roomId, stateEvents: members(100, changed: 7))
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM test_state_log"), 1)
    }

    func testRemovedStateKeyDeletesTheRow() throws {
        harness.store.storeState(forRoom: roomId, stateEvents: members(3))
        harness.commit()
        harness.store.storeState(forRoom: roomId, stateEvents: Array(members(3).dropLast()))
        harness.commit()

        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 3)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state WHERE state_key = '@u2:x'"), 0)
    }

    func testSeveralWritesBeforeOneCommitMergeTheirDiffs() throws {
        let store = harness.store
        store.storeState(forRoom: roomId, stateEvents: members(3))
        store.storeState(forRoom: roomId, stateEvents: members(3, changed: 0))
        store.storeState(forRoom: roomId, stateEvents: members(3, changed: 0) + [
            MXSQLiteStoreHarness.stateEvent(type: kMXEventTypeStringRoomName, stateKey: "", eventId: "$name", content: ["name": "N"]),
        ])
        harness.commit()

        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 5)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state WHERE event_id = '$m0-v2'"), 1)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state WHERE event_id = '$m0'"), 0)
    }

    func testStateStoredBeforeOpenReplacesTheRoomStateInTheFile() throws {
        harness.store.storeState(forRoom: roomId, stateEvents: members(3))
        harness.commit()
        harness.store.close()

        // Новый экземпляр пишет до открытия: отпечатка базы нет — коммит пишет состояние целиком.
        let store = harness.makeStore()
        store.storeState(forRoom: roomId, stateEvents: Array(members(3).dropLast()))
        try harness.open(store)
        harness.commit(store)

        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM room_state") }, 3)
        store.close()
    }

    func testDeletedRoomCanBeStoredAgainInTheSameCommit() throws {
        let store = harness.store
        store.storeState(forRoom: roomId, stateEvents: members(2))
        harness.commit()

        store.deleteRoom(roomId)
        store.storeState(forRoom: roomId, stateEvents: members(1))
        store.storeHasLoadedAllRoomMembers(forRoom: roomId, andValue: true)
        harness.commit()

        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 2)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state s JOIN room r ON r.rid = s.rid"), 2,
                       "rows belong to an existing room row")
        let reopened = try harness.reopen()
        XCTAssertTrue(reopened.hasLoadedAllRoomMembers(forRoom: roomId))
    }

    // MARK: - Account data and flags

    func testRoomAccountDataSurvivesReopen() throws {
        let accountData = MXRoomAccountData()
        accountData.handle(MXEvent(fromJSON: [
            "type": kMXEventTypeStringRoomTag,
            "content": ["tags": ["m.favourite": ["order": 0.5]]],
        ]))
        harness.store.storeAccountData(forRoom: roomId, userData: accountData)
        XCTAssertNotNil(harness.store.accountData(ofRoom: roomId)?.tags?["m.favourite"])

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertNotNil(reopened.accountData(ofRoom: roomId)?.tags?["m.favourite"])
        XCTAssertNil(reopened.accountData(ofRoom: "!other:x"))
    }

    func testRoomFlagsSurviveReopen() throws {
        let store = harness.store
        XCTAssertNil(store.paginationToken(ofRoom: roomId))
        XCTAssertFalse(store.hasReachedHomeServerPaginationEnd(forRoom: roomId))
        XCTAssertEqual(store.backwardPaginationState(forRoom: roomId), .unknown)

        store.storePaginationToken(ofRoom: roomId, andToken: "t-42")
        store.storeHasReachedHomeServerPaginationEnd(forRoom: roomId, andValue: true)
        store.storeBackwardPaginationState(forRoom: roomId, state: .exhausted)
        store.storeHasLoadedAllRoomMembers(forRoom: roomId, andValue: true)
        XCTAssertEqual(store.paginationToken(ofRoom: roomId), "t-42")

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.paginationToken(ofRoom: roomId), "t-42")
        XCTAssertTrue(reopened.hasReachedHomeServerPaginationEnd(forRoom: roomId))
        XCTAssertEqual(reopened.backwardPaginationState(forRoom: roomId), .exhausted)
        XCTAssertTrue(reopened.hasLoadedAllRoomMembers(forRoom: roomId))
    }

    // MARK: - Atomicity of the sync token

    func testSyncTokenIsWrittenInTheSameTransactionAsTheRoomData() throws {
        let store = harness.store
        store.eventStreamToken = "s1"
        harness.commit()

        // Прерванный коммит: вставка состояния падает — токен не должен оказаться в файле.
        try harness.database.exec("""
            CREATE TRIGGER test_fail BEFORE INSERT ON room_state BEGIN SELECT RAISE(ABORT, 'disk full'); END;
            """)
        store.storeState(forRoom: roomId, stateEvents: members(2))
        store.eventStreamToken = "s2"
        harness.commit()

        XCTAssertEqual(store.eventStreamToken, "s2", "the overlay keeps the write")
        XCTAssertEqual(storedToken(), "s1", "the failed transaction did not move the token")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 0)

        // Следующий коммит повторяет отложенное целиком.
        try harness.database.exec("DROP TRIGGER test_fail;")
        harness.commit()
        XCTAssertEqual(storedToken(), "s2")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room_state"), 3)

        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.eventStreamToken, "s2")
        XCTAssertEqual(harness.state(of: roomId, in: reopened).count, 3)
    }

    private func storedToken() -> String? {
        let data: Data? = harness.database.readValue { connection in
            try? connection.query(
                "SELECT value FROM meta WHERE key = ?1",
                bind: { $0.bindText("event_stream_token", at: 1) },
                row: { $0.blob(at: 0) }
            ).first as? Data
        }
        guard let data else { return nil }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)) as String?
    }
}
