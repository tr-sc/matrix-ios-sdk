//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP6: реакции (агрегации) в таблицах `reaction_count` и `reaction_relation` базы стора.
final class MXSQLiteAggregationsStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private var aggregations: MXSQLiteAggregationsStore!
    private let room = "!agg:x"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
        aggregations = MXSQLiteAggregationsStore(store: harness.store)
        createRooms([room, "!other:x"])
    }

    /// Строки `room` создаёт стор событий: реакции на событие в комнате, которой в базе нет, ждут её коммита.
    private func createRooms(_ roomIds: [String]) {
        for (index, roomId) in roomIds.enumerated() {
            let event = MXEvent(fromJSON: [
                "type": kMXEventTypeStringRoomMessage, "event_id": "$seed-\(roomId)", "room_id": roomId, "sender": "@a:x",
                "origin_server_ts": 1, "content": ["msgtype": "m.text", "body": "seed"], "unsigned": ["trsc.count": "\(index + 1)"],
            ])!
            harness.store.storeEvent(forRoom: roomId, event: event, direction: .forwards)
        }
        harness.commit()
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func count(_ reaction: String, _ count: UInt, ts: UInt64, mine: String? = nil) -> MXReactionCount {
        let result = MXReactionCount()
        result.reaction = reaction
        result.count = count
        result.originServerTs = ts
        result.myUserReactionEventId = mine
        return result
    }

    private func relation(_ reactionEventId: String, on eventId: String, _ reaction: String, ts: UInt64 = 1) -> MXReactionRelation {
        let result = MXReactionRelation()
        result.reactionEventId = reactionEventId
        result.eventId = eventId
        result.reaction = reaction
        result.originServerTs = ts
        return result
    }

    /// Дождаться записи накладки и открыть новый стор агрегаций на переоткрытом файле.
    private func persistAndReopen() throws -> MXSQLiteAggregationsStore {
        aggregations.flush()
        let store = try harness.reopen()
        return MXSQLiteAggregationsStore(store: store)
    }

    private func reactions(_ list: [MXReactionCount]?) -> [String] { (list ?? []).map { "\($0.reaction)\($0.count)" } }

    func testCountsAreVisibleAtOnceAndPersistSortedByTimestamp() throws {
        aggregations.addOrUpdate(count("👍", 2, ts: 20, mine: "$mine"), onEvent: "$e", inRoom: room)
        aggregations.addOrUpdate(count("😀", 1, ts: 10), onEvent: "$e", inRoom: room)
        XCTAssertTrue(aggregations.hasReactionCounts(onEvent: "$e"))
        XCTAssertFalse(aggregations.hasReactionCounts(onEvent: "$other"))
        XCTAssertEqual(reactions(aggregations.reactionCounts(onEvent: "$e")), ["😀1", "👍2"])
        XCTAssertNil(aggregations.reactionCounts(onEvent: "$other"), "no counts → nil, like the Realm store")

        let reopened = try persistAndReopen()
        XCTAssertEqual(reactions(reopened.reactionCounts(onEvent: "$e")), ["😀1", "👍2"])
        let thumbs = try XCTUnwrap(reopened.reactionCount(forReaction: "👍", onEvent: "$e"))
        XCTAssertEqual(thumbs.myUserReactionEventId, "$mine")
        XCTAssertEqual(thumbs.originServerTs, 20)
        XCTAssertNil(reopened.reactionCount(forReaction: "😀", onEvent: "$e")?.myUserReactionEventId)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_count"), 2)
    }

    func testUpdateAndDeleteOverCommittedRows() throws {
        aggregations.addOrUpdate(count("👍", 1, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.addOrUpdate(count("❤️", 1, ts: 2), onEvent: "$e", inRoom: room)
        aggregations.flush()

        aggregations.addOrUpdate(count("👍", 5, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.deleteReactionCounts(forReaction: "❤️", onEvent: "$e")
        XCTAssertEqual(reactions(aggregations.reactionCounts(onEvent: "$e")), ["👍5"])
        XCTAssertNil(aggregations.reactionCount(forReaction: "❤️", onEvent: "$e"))

        let reopened = try persistAndReopen()
        XCTAssertEqual(reactions(reopened.reactionCounts(onEvent: "$e")), ["👍5"])
    }

    func testSetReactionCountsReplacesTheWholeEvent() throws {
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.addOrUpdate(count("b", 1, ts: 2), onEvent: "$e", inRoom: room)
        aggregations.addOrUpdate(count("z", 1, ts: 2), onEvent: "$other", inRoom: room)
        aggregations.flush()
        aggregations.addOrUpdate(count("c", 1, ts: 3), onEvent: "$e", inRoom: room)

        aggregations.setReactionCounts([count("b", 7, ts: 2), count("d", 1, ts: 4)], onEvent: "$e", inRoom: room)
        XCTAssertEqual(reactions(aggregations.reactionCounts(onEvent: "$e")), ["b7", "d1"])

        let reopened = try persistAndReopen()
        XCTAssertEqual(reactions(reopened.reactionCounts(onEvent: "$e")), ["b7", "d1"])
        XCTAssertEqual(reactions(reopened.reactionCounts(onEvent: "$other")), ["z1"])
    }

    func testRelations() throws {
        aggregations.add(relation("$r1", on: "$e", "👍"), inRoom: room)
        aggregations.add(relation("$r2", on: "$e", "😀"), inRoom: room)
        aggregations.flush()
        aggregations.add(relation("$r3", on: "$f", "👍"), inRoom: room)
        aggregations.delete(relation("$r1", on: "$e", "👍"))

        XCTAssertNil(aggregations.reactionRelation(withReactionEventId: "$r1"))
        XCTAssertEqual(aggregations.reactionRelation(withReactionEventId: "$r3")?.eventId, "$f")
        XCTAssertEqual(aggregations.reactionRelations(onEvent: "$e")?.map(\.reactionEventId), ["$r2"])
        XCTAssertNil(aggregations.reactionRelations(onEvent: "$none"))

        let reopened = try persistAndReopen()
        XCTAssertEqual(reopened.reactionRelations(onEvent: "$e")?.map(\.reactionEventId), ["$r2"])
        let r3 = try XCTUnwrap(reopened.reactionRelation(withReactionEventId: "$r3"))
        XCTAssertEqual(r3.reaction, "👍")
        XCTAssertEqual(r3.originServerTs, 1)
    }

    func testDeleteAllInRoomKeepsOtherRooms() throws {
        let other = "!other:x"
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.add(relation("$r1", on: "$e", "a"), inRoom: room)
        aggregations.addOrUpdate(count("b", 1, ts: 1), onEvent: "$o", inRoom: other)
        aggregations.add(relation("$r2", on: "$o", "b"), inRoom: other)
        aggregations.flush()
        aggregations.addOrUpdate(count("c", 1, ts: 2), onEvent: "$e2", inRoom: room)

        aggregations.deleteAllReactionCounts(inRoom: room)
        aggregations.deleteAllReactionRelations(inRoom: room)
        XCTAssertNil(aggregations.reactionCounts(onEvent: "$e"))
        XCTAssertNil(aggregations.reactionCounts(onEvent: "$e2"))
        XCTAssertNil(aggregations.reactionRelations(onEvent: "$e"))

        let reopened = try persistAndReopen()
        XCTAssertNil(reopened.reactionCounts(onEvent: "$e"))
        XCTAssertNil(reopened.reactionCounts(onEvent: "$e2"))
        XCTAssertEqual(reactions(reopened.reactionCounts(onEvent: "$o")), ["b1"])
        XCTAssertEqual(reopened.reactionRelations(onEvent: "$o")?.count, 1)
    }

    func testDeleteAll() throws {
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.add(relation("$r1", on: "$e", "a"), inRoom: room)
        aggregations.flush()
        aggregations.addOrUpdate(count("b", 1, ts: 1), onEvent: "$f", inRoom: room)
        aggregations.deleteAll()
        XCTAssertNil(aggregations.reactionCounts(onEvent: "$e"))
        XCTAssertNil(aggregations.reactionCounts(onEvent: "$f"))

        _ = try persistAndReopen()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_count"), 0)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_relation"), 0)
    }

    func testDeletingTheRoomInTheStoreDropsItsReactions() throws {
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$e", inRoom: room)
        aggregations.flush()
        harness.store.deleteRoom(room)
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_count"), 0)
    }

    func testWritesBeforeTheStoreOpensAreKept() throws {
        // Стор закрыт: база nil. Запись остаётся в накладке и уходит после открытия.
        harness.store.close()
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$e", inRoom: room)
        XCTAssertEqual(reactions(aggregations.reactionCounts(onEvent: "$e")), ["a1"])
        try harness.open(harness.store)
        aggregations.flush()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_count"), 1)
    }

    func testReactionInARoomNotYetInTheStoreWaitsForTheStoreCommit() throws {
        let newRoom = "!new:x"
        aggregations.addOrUpdate(count("a", 1, ts: 1), onEvent: "$n", inRoom: newRoom)
        aggregations.flush()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM reaction_count"), 0, "no room row: deferred")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room WHERE room_id = '!new:x'"), 0, "reactions do not create rooms")
        XCTAssertEqual(reactions(aggregations.reactionCounts(onEvent: "$n")), ["a1"], "still visible")

        // Синк приносит комнату: после коммита стора реакция дописывается сама.
        let written = expectation(for: NSPredicate { _, _ in
            self.harness.count("SELECT COUNT(*) FROM reaction_count") == 1
        }, evaluatedWith: nil)
        createRooms([newRoom])
        wait(for: [written], timeout: 5)
        XCTAssertEqual(reactions(try persistAndReopen().reactionCounts(onEvent: "$n")), ["a1"])
    }

    // MARK: - Выбор стора в MXAggregations

    func testSQLiteSessionStoreGetsSQLiteAggregationsAndDropsRealmOnce() throws {
        let userId = harness.userId
        let realmFolder = MXSQLiteAggregationsStore.legacyRealmFolder(forUserId: userId)
        try FileManager.default.createDirectory(at: realmFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: realmFolder.appendingPathComponent("Aggregations.realm").path, contents: Data([1]))

        let chosen = MXAggregations.aggregationsStore(forSessionStore: harness.store, credentials: harness.credentials)
        XCTAssertTrue(chosen is MXSQLiteAggregationsStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realmFolder.path), "Realm aggregations are dropped")

        let legacy: AnyObject = MXAggregations.aggregationsStore(forSessionStore: MXMemoryStore(), credentials: harness.credentials)
        XCTAssertEqual(NSStringFromClass(type(of: legacy)), "MXRealmAggregationsStore", "old path stays for MXFileStore / MXMemoryStore")
    }
}
