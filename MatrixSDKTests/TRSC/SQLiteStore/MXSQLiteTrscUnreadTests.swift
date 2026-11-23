//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP11: непрочитанное строки списка — одним запросом к базе при обновлении сводки, по правилу TRSC
/// (сообщения после своей квитанции основной ленты, без своих, правок, реакций, ответов в тредах, состояний и
/// удалённых). Список читает готовое число из сводки (`MXRoomSummary.trscUnreadCount`), без обхода стора.
final class MXSQLiteTrscUnreadTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private let me = "@harness:example.org"
    private let room = "!unread:example.org"
    private let types = [kMXEventTypeStringRoomName, kMXEventTypeStringRoomTopic, kMXEventTypeStringRoomMessage,
                         kMXEventTypeStringCallInvite, kMXEventTypeStringRoomEncrypted, kMXEventTypeStringSticker]

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name, userId: me)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func event(_ order: Int64, sender: String = "@peer:example.org", type: String = kMXEventTypeStringRoomMessage,
                       stateKey: String? = nil, relation: [String: Any]? = nil) -> MXEvent {
        var content: [String: Any] = ["msgtype": "m.text", "body": "m\(order)"]
        if let relation { content["m.relates_to"] = relation }
        var json: [String: Any] = [
            "event_id": "$e\(order)", "type": type, "sender": sender,
            "origin_server_ts": 1_700_000_000_000 + UInt64(order), "content": content,
            "unsigned": ["trsc.count": String(order)],
        ]
        if let stateKey { json["state_key"] = stateKey }
        let event = MXEvent(fromJSON: json)!
        event.roomId = room
        return event
    }

    private func sync(_ events: [MXEvent]) {
        harness.store.noteSyncTimeline(inRoom: room, firstEvent: events.first, limited: false, prevBatch: "pb")
        for event in events { harness.store.storeEvent(forRoom: room, event: event, direction: .forwards) }
    }

    private func readUpTo(_ eventId: String, ts: UInt64) {
        let receipt = MXReceiptData()
        receipt.userId = me
        receipt.eventId = eventId
        receipt.ts = ts
        receipt.threadId = kMXEventTimelineMain
        harness.store.storeReceipt(receipt, inRoom: room)
    }

    private func count(limit: UInt = 100) -> Int {
        harness.store.trscUnreadMessageCount(inRoom: room, types: types, limit: limit)
    }

    func testWithoutOwnReceiptTheCountIsUnknown() {
        sync([event(10), event(20)])
        XCTAssertEqual(count(), -1, "без квитанции считать не от чего: строка берёт серверный счётчик")
    }

    func testCountsOnlyIncomingMessagesOfTheMainTimelineAfterTheReceipt() {
        sync([
            event(10),
            event(20),                                                                    // считается
            event(30, sender: me),                                                        // своё
            event(40, relation: ["rel_type": "m.replace", "event_id": "$e20"]),           // правка
            event(50, relation: ["rel_type": "m.thread", "event_id": "$e10"]),            // ответ в треде
            event(60, type: kMXEventTypeStringRoomName, stateKey: ""),                    // состояние
            event(70, type: kMXEventTypeStringRoomEncrypted,
                  relation: ["rel_type": "m.annotation", "event_id": "$e20", "key": "👍"]), // реакция
            event(80, type: "m.reaction"),                                                // не тот тип
            event(90),                                                                    // считается
            event(100, relation: ["rel_type": "m.reference", "event_id": "$e20"]),        // ссылка — сообщение
        ])
        readUpTo("$e10", ts: 1_700_000_000_010)
        XCTAssertEqual(count(), 3)
    }

    func testRedactedMessagesAreNotCounted() {
        sync([event(10), event(20), event(30)])
        readUpTo("$e10", ts: 1_700_000_000_010)
        let redaction = MXEvent(fromJSON: ["event_id": "$r", "type": "m.room.redaction", "sender": "@peer:example.org",
                                           "redacts": "$e20", "origin_server_ts": 1_700_000_000_040,
                                           "content": [:], "unsigned": ["trsc.count": "40"]])!
        redaction.roomId = room
        harness.store.storeEvent(forRoom: room, event: redaction, direction: .forwards)
        XCTAssertEqual(count(), 1)
    }

    func testReadUpToTheLastMessageIsZero() {
        sync((1...12).map { event(Int64($0 * 10)) })
        readUpTo("$e120", ts: 1_700_000_000_120)
        XCTAssertEqual(count(), 0)
    }

    func testTheLimitCapsTheCount() {
        sync((1...12).map { event(Int64($0 * 10)) })
        readUpTo("$e20", ts: 1_700_000_000_020)
        XCTAssertEqual(count(), 10)
        XCTAssertEqual(count(limit: 4), 4)
    }

    func testCommittedAndPendingRowsGiveTheSameCount() {
        sync([event(10), event(20), event(30)])
        readUpTo("$e10", ts: 1_700_000_000_010)
        XCTAssertEqual(count(), 2, "накладка до коммита")
        harness.commit()
        XCTAssertEqual(count(), 2, "из базы")
        sync([event(40, relation: ["rel_type": "m.replace", "event_id": "$e30"]), event(50)])
        XCTAssertEqual(count(), 3, "база + накладка")
    }

    func testSummaryKeepsTheCountThroughArchivingAndReadClearsIt() throws {
        let summary = MXRoomSummary(roomId: room, andMatrixSession: nil)!
        XCTAssertEqual(summary.trscUnreadCount, -1, "новая сводка: число неизвестно")
        summary.trscUnreadCount = 7
        let data = try NSKeyedArchiver.archivedData(withRootObject: summary, requiringSecureCoding: false)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchiveObject(with: data) as? MXRoomSummary)
        XCTAssertEqual(restored.trscUnreadCount, 7)
        XCTAssertEqual(MXRoomSummary(summaryModel: restored).trscUnreadCount, 7, "копия модели (монтирование)")
        restored.markAllAsReadLocally()
        XCTAssertEqual(restored.trscUnreadCount, 0)
    }
}
