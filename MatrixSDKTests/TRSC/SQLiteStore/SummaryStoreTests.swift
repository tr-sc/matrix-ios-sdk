//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP5: сводки комнат в той же базе, что события; первые N по активности для холодного старта.
final class MXSQLiteRoomSummaryStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private var summaries: MXRoomSummaryStore { harness.store.roomSummaryStore }

    static func summary(_ roomId: String, ts: UInt64, name: String? = nil, unread: UInt = 0) -> MXRoomSummary {
        let summary = MXRoomSummary(roomId: roomId, andMatrixSession: nil)!
        summary.displayName = name ?? "Room \(roomId)"
        let event = MXEvent(fromJSON: [
            "type": kMXEventTypeStringRoomMessage,
            "event_id": "$last-\(roomId)-\(ts)",
            "room_id": roomId,
            "sender": "@a:x",
            "origin_server_ts": ts,
            "content": ["msgtype": "m.text", "body": "text \(ts)"],
        ])!
        let lastMessage = MXRoomLastMessage(event: event)
        lastMessage.text = "text \(ts)"
        summary.updateLastMessage(lastMessage)
        summary.others = ["k": "v-\(roomId)" as NSString]
        summary.setValue(unread, forKey: "notificationCount")
        return summary
    }

    private func ids(_ list: [MXRoomSummaryProtocol]) -> [String] { list.map(\.roomId) }

    func testStoreIsSQLiteAndRoundTripsEveryField() throws {
        XCTAssertTrue(summaries is MXSQLiteRoomSummaryStore)
        summaries.storeSummary(Self.summary("!a:x", ts: 1_000, name: "Alpha", unread: 3))
        XCTAssertEqual(summaries.summary(ofRoom: "!a:x")?.displayName, "Alpha", "read-your-writes before commit")

        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM summary"), 1)
        XCTAssertEqual(harness.count("SELECT last_ts FROM summary"), 1_000)

        let reopened = try harness.reopen().roomSummaryStore
        let read = try XCTUnwrap(reopened.summary(ofRoom: "!a:x"))
        XCTAssertEqual(read.displayName, "Alpha")
        XCTAssertEqual(read.notificationCount, 3)
        XCTAssertEqual(read.lastMessage?.eventId, "$last-!a:x-1000")
        XCTAssertEqual(read.lastMessage?.originServerTs, 1_000)
        XCTAssertEqual(read.lastMessage?.text, "text 1000")
        XCTAssertEqual(read.others?["k"] as? String, "v-!a:x")
        XCTAssertEqual(reopened.rooms, ["!a:x"])
        XCTAssertEqual(reopened.countOfRooms, 1)
    }

    func testOrderedByActivityMergesOverlayAndDatabase() throws {
        for (index, roomId) in ["!1:x", "!2:x", "!3:x", "!4:x", "!5:x"].enumerated() {
            summaries.storeSummary(Self.summary(roomId, ts: UInt64(100 * (index + 1))))
        }
        harness.commit()
        let store = harness.store
        XCTAssertEqual(ids(store.summariesOrdered(byActivity: 3)), ["!5:x", "!4:x", "!3:x"])

        // Незакоммиченное: !1 поднимается наверх, !5 удалён, !6 новый.
        summaries.storeSummary(Self.summary("!1:x", ts: 900))
        summaries.removeSummary(ofRoom: "!5:x")
        summaries.storeSummary(Self.summary("!6:x", ts: 350))
        XCTAssertEqual(ids(store.summariesOrdered(byActivity: 4)), ["!1:x", "!4:x", "!6:x", "!3:x"])
        XCTAssertEqual(Set(summaries.rooms), ["!1:x", "!2:x", "!3:x", "!4:x", "!6:x"])
        XCTAssertEqual(summaries.countOfRooms, 5)

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(ids(reopened.summariesOrdered(byActivity: 10)), ["!1:x", "!4:x", "!6:x", "!3:x", "!2:x"])
        XCTAssertEqual(ids(reopened.summariesOrdered(byActivity: 0)), [])
    }

    func testRoomWithoutLastMessageSortsLast() throws {
        let empty = MXRoomSummary(roomId: "!empty:x", andMatrixSession: nil)!
        summaries.storeSummary(empty)
        summaries.storeSummary(Self.summary("!b:x", ts: 5))
        harness.commit()
        XCTAssertEqual(ids(harness.store.summariesOrdered(byActivity: 5)), ["!b:x", "!empty:x"])
    }

    func testRemoveAllHidesDatabaseUntilCommitAndKeepsLaterWrites() throws {
        summaries.storeSummary(Self.summary("!a:x", ts: 1))
        summaries.storeSummary(Self.summary("!b:x", ts: 2))
        harness.commit()

        summaries.removeAllSummaries()
        XCTAssertEqual(summaries.countOfRooms, 0)
        XCTAssertNil(summaries.summary(ofRoom: "!a:x"))
        summaries.storeSummary(Self.summary("!c:x", ts: 3))
        XCTAssertEqual(summaries.rooms, ["!c:x"])
        XCTAssertEqual(ids(harness.store.summariesOrdered(byActivity: 10)), ["!c:x"])

        harness.commit()
        let reopened = try harness.reopen().roomSummaryStore
        XCTAssertEqual(reopened.rooms, ["!c:x"])
    }

    func testDeleteRoomRemovesItsSummary() throws {
        summaries.storeSummary(Self.summary("!a:x", ts: 1))
        summaries.storeSummary(Self.summary("!b:x", ts: 2))
        harness.commit()
        harness.store.deleteRoom("!a:x")
        XCTAssertNil(summaries.summary(ofRoom: "!a:x"))
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM summary"), 1)
        XCTAssertEqual(try harness.reopen().roomSummaryStore.rooms, ["!b:x"])
    }

    func testFetchAllSummariesCompletesOnMain() throws {
        summaries.storeSummary(Self.summary("!a:x", ts: 1))
        harness.commit()
        summaries.storeSummary(Self.summary("!b:x", ts: 2))

        let done = expectation(description: "fetch")
        var fetched: [MXRoomSummaryProtocol] = []
        summaries.fetchAllSummaries { list in
            XCTAssertTrue(Thread.isMainThread)
            fetched = list
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(Set(ids(fetched)), ["!a:x", "!b:x"])
        XCTAssertEqual(Set(ids(summaries.allSummariesSync())), ["!a:x", "!b:x"])
    }

    func testSummaryAndEventLandInOneCommit() throws {
        let roomId = "!one:x"
        let store = harness.store
        let event = MXEvent(fromJSON: [
            "type": kMXEventTypeStringRoomMessage, "event_id": "$e", "room_id": roomId, "sender": "@a:x",
            "origin_server_ts": 7, "content": ["msgtype": "m.text", "body": "e"], "unsigned": ["trsc.count": "1"],
        ])!
        store.storeEvent(forRoom: roomId, event: event, direction: .forwards)
        summaries.storeSummary(Self.summary(roomId, ts: 7))
        store.eventStreamToken = "s42"

        var commits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "MXStoreDidCommitNotification"), object: store, queue: nil) { _ in
            commits += 1
        }
        harness.commit()
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM event"), 1)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM summary"), 1)
        // Одна строка room: сводка и событие ссылаются на один rid.
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM room"), 1)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM summary s JOIN event e ON e.rid = s.rid"), 1)
    }

    func testNonCodingSummaryModelIsStoredAsRoomSummary() throws {
        let model = MXRoomSummary(summaryModel: Self.summary("!m:x", ts: 9, name: "Model"))!
        summaries.storeSummary(model)
        harness.commit()
        XCTAssertEqual(try harness.reopen().roomSummaryStore.summary(ofRoom: "!m:x")?.displayName, "Model")
    }

    /// Критерий iP5: 1 тыс. сводок читаются ≤ 30 мс (первые 50 — для первого кадра — много быстрее).
    func testThousandSummariesReadFast() throws {
        for index in 0..<1_000 {
            summaries.storeSummary(Self.summary("!r\(index):x", ts: UInt64(index)))
        }
        harness.commit()
        let store = try harness.reopen()

        _ = store.summariesOrdered(byActivity: 1) // прогрев соединения и подготовленных запросов
        var best = Double.greatestFiniteMagnitude
        var top: [MXRoomSummaryProtocol] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            top = store.summariesOrdered(byActivity: 1_000)
            best = min(best, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        XCTAssertEqual(top.count, 1_000)
        XCTAssertEqual(top.first?.roomId, "!r999:x")
        XCTAssertLessThanOrEqual(best, 30, "1000 summaries in \(best) ms")
    }
}
