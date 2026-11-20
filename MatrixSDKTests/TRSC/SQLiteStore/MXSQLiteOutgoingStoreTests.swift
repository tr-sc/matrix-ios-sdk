//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP4: исходящие (очередь, связь txn_id → local_id), черновики, переживание пересборки схемы.
final class MXSQLiteOutgoingStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private let roomId = "!outgoing:example.org"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func echo(_ localId: String, body: String = "hi", state: MXEventSentState = MXEventSentStateSending) -> MXEvent {
        let event = MXSQLiteStoreHarness.message(eventId: localId, roomId: roomId, body: body)
        event.sentState = state
        return event
    }

    private func ids(_ store: MXSQLiteStore? = nil) -> [String] {
        ((store ?? harness.store).outgoingMessages(inRoom: roomId) ?? []).compactMap(\.eventId)
    }

    func testQueueKeepsSendOrderAndUpdatesInPlace() throws {
        let store = harness.store
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~1"))
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~2"))
        harness.commit()
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~3"))
        // Обновление первой строки (стала failed) не двигает её в конец очереди.
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~1", body: "edited", state: MXEventSentStateFailed))
        XCTAssertEqual(ids(), ["~1", "~2", "~3"])

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(ids(reopened), ["~1", "~2", "~3"])
        let first = reopened.outgoingMessages(inRoom: roomId)?.first
        XCTAssertEqual(first?.sentState, MXEventSentStateFailed)
        XCTAssertEqual(first?.content["body"] as? String, "edited")
        XCTAssertEqual(first?.roomId, roomId)
    }

    func testRemoveAndRemoveAll() throws {
        let store = harness.store
        for id in ["~1", "~2", "~3"] {
            store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo(id))
        }
        harness.commit()
        store.removeOutgoingMessage(fromRoom: roomId, outgoingMessage: "~2")
        XCTAssertEqual(ids(), ["~1", "~3"])
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM outgoing"), 2)

        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~4"))
        store.removeAllOutgoingMessages(fromRoom: roomId)
        XCTAssertEqual(ids(), [])
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~5"))
        XCTAssertEqual(ids(), ["~5"])
        harness.commit()
        XCTAssertEqual(ids(try harness.reopen()), ["~5"])
    }

    func testConsumeByTransactionIdLinksTheServerEventToTheLocalRow() throws {
        let store = harness.store
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~committed"))
        harness.commit()
        store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~pending"))

        // txn_id отправки = local_id эха.
        XCTAssertEqual(store.consumeOutgoing(forTransactionId: "~committed", inRoom: roomId), "~committed")
        XCTAssertEqual(store.consumeOutgoing(forTransactionId: "~pending", inRoom: roomId), "~pending")
        XCTAssertNil(store.consumeOutgoing(forTransactionId: "~committed", inRoom: roomId), "consumed once")
        XCTAssertNil(store.consumeOutgoing(forTransactionId: "~unknown", inRoom: roomId))
        XCTAssertNil(store.consumeOutgoing(forTransactionId: "~pending", inRoom: "!other:x"), "scoped to the room")
        XCTAssertEqual(ids(), [])

        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM outgoing"), 0, "removed in the same commit")
    }

    func testConsumeMatchesAnExplicitTransactionId() throws {
        let event = MXSQLiteStoreHarness.message(eventId: "~local", roomId: roomId, transactionId: "txn-9")
        harness.store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: event)
        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.consumeOutgoing(forTransactionId: "txn-9", inRoom: roomId), "~local")
    }

    func testEncryptedEchoKeepsItsClearPayload() throws {
        let event = MXEvent(fromJSON: [
            "type": kMXEventTypeStringRoomEncrypted,
            "event_id": "~enc",
            "room_id": roomId,
            "sender": "@me:x",
            "origin_server_ts": 1_700_000_000_000,
            "content": ["algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AAAA"],
        ])!
        let result = MXEventDecryptionResult()
        result.clearEvent = ["type": kMXEventTypeStringRoomMessage, "room_id": roomId,
                             "content": ["msgtype": "m.text", "body": "secret"]]
        event.setClearData(result)
        harness.store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: event)
        harness.commit()

        let restored = try harness.reopen().outgoingMessages(inRoom: roomId)?.first
        XCTAssertTrue(restored?.isEncrypted ?? false)
        XCTAssertEqual(restored?.content["body"] as? String, "secret")
    }

    func testDraftSurvivesReopenAndCanBeCleared() throws {
        let store = harness.store
        let draft = NSAttributedString(string: "draft", attributes: [.font: UIFont.systemFont(ofSize: 15)])
        store.storePartialAttributedTextMessage(forRoom: roomId, partialAttributedTextMessage: draft)
        XCTAssertEqual(store.partialAttributedTextMessage(ofRoom: roomId)?.string, "draft")
        harness.commit()

        var reopened = try harness.reopen()
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomId)?.string, "draft")
        reopened.storePartialAttributedTextMessage(forRoom: roomId, partialAttributedTextMessage: NSAttributedString())
        XCTAssertNil(reopened.partialAttributedTextMessage(ofRoom: roomId))
        harness.commit()
        reopened = try harness.reopen()
        XCTAssertNil(reopened.partialAttributedTextMessage(ofRoom: roomId))
    }

    func testOutgoingAndDraftSurviveSchemaRebuild() throws {
        harness.store.storeOutgoingMessage(forRoom: roomId, outgoingMessage: echo("~1"))
        harness.store.storePartialAttributedTextMessage(forRoom: roomId, partialAttributedTextMessage: NSAttributedString(string: "d"))
        harness.store.eventStreamToken = "s"
        harness.commit()

        // Версия схемы без пути миграции → пересборка базы с переносом outgoing и draft.
        try harness.database.exec("PRAGMA user_version = 99;")
        let reopened = try harness.reopen()
        XCTAssertNil(reopened.eventStreamToken, "the rest is dropped")
        XCTAssertEqual(ids(reopened), ["~1"])
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomId)?.string, "d")
    }
}
