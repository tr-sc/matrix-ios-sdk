//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP4: квитанции по тредам, отметка «непрочитано».
final class MXSQLiteReceiptStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private let roomId = "!receipts:example.org"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func receipt(_ userId: String, _ eventId: String, ts: UInt64, thread: String? = nil) -> MXReceiptData {
        let receipt = MXReceiptData()
        receipt.userId = userId
        receipt.eventId = eventId
        receipt.ts = ts
        receipt.threadId = thread
        return receipt
    }

    private func eventReceipts(_ eventId: String, thread: String = kMXEventTimelineMain, in store: MXSQLiteStore? = nil) -> [MXReceiptData] {
        let done = expectation(description: "receipts")
        var result: [MXReceiptData] = []
        (store ?? harness.store).getEventReceipts(roomId, eventId: eventId, threadId: thread, sorted: true) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    func testNewerReceiptReplacesOlderAndOlderIsIgnored() throws {
        let store = harness.store
        XCTAssertTrue(store.storeReceipt(receipt("@a:x", "$1", ts: 10, thread: kMXEventTimelineMain), inRoom: roomId))
        XCTAssertTrue(store.storeReceipt(receipt("@a:x", "$2", ts: 20, thread: kMXEventTimelineMain), inRoom: roomId))
        XCTAssertFalse(store.storeReceipt(receipt("@a:x", "$0", ts: 5, thread: kMXEventTimelineMain), inRoom: roomId), "older")
        XCTAssertFalse(store.storeReceipt(receipt("@a:x", "$2", ts: 30, thread: kMXEventTimelineMain), inRoom: roomId), "same event")
        XCTAssertEqual(store.getReceiptInRoom(roomId, threadId: kMXEventTimelineMain, forUserId: "@a:x")?.eventId, "$2")

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.getReceiptInRoom(roomId, threadId: kMXEventTimelineMain, forUserId: "@a:x")?.eventId, "$2")
        XCTAssertFalse(reopened.storeReceipt(receipt("@a:x", "$1", ts: 15, thread: kMXEventTimelineMain), inRoom: roomId),
                       "the rule reads the committed receipt")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM receipt"), 1)
    }

    func testThreadsAreSeparateAndUnthreadedReceiptCoversKnownThreads() throws {
        let store = harness.store
        store.storeReceipt(receipt("@a:x", "$t1", ts: 10, thread: "$root1"), inRoom: roomId)
        harness.commit()
        store.storeReceipt(receipt("@a:x", "$t2", ts: 11, thread: "$root2"), inRoom: roomId)

        // Без треда — в основную ленту и в оба известных треда (один в базе, другой в накладке).
        XCTAssertTrue(store.storeReceipt(receipt("@b:x", "$main", ts: 12), inRoom: roomId))
        let receiptsOfB = store.getReceiptsInRoom(roomId, forUserId: "@b:x")
        XCTAssertEqual(Set(receiptsOfB.keys), [kMXEventTimelineMain, "$root1", "$root2"])

        let receiptsOfA = store.getReceiptsInRoom(roomId, forUserId: "@a:x")
        XCTAssertEqual(receiptsOfA["$root1"]?.eventId, "$t1")
        XCTAssertEqual(receiptsOfA["$root2"]?.eventId, "$t2")
        XCTAssertNil(receiptsOfA[kMXEventTimelineMain])

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(Set(reopened.getReceiptsInRoom(roomId, forUserId: "@b:x").keys), [kMXEventTimelineMain, "$root1", "$root2"])
        XCTAssertEqual(reopened.getReceiptInRoom(roomId, threadId: "$root2", forUserId: "@a:x")?.eventId, "$t2")
    }

    func testEventReceiptsMergeTheFileAndTheOverlay() throws {
        let store = harness.store
        store.storeReceipt(receipt("@a:x", "$e", ts: 10, thread: kMXEventTimelineMain), inRoom: roomId)
        store.storeReceipt(receipt("@b:x", "$e", ts: 30, thread: kMXEventTimelineMain), inRoom: roomId)
        harness.commit()

        store.storeReceipt(receipt("@c:x", "$e", ts: 20, thread: kMXEventTimelineMain), inRoom: roomId)
        store.storeReceipt(receipt("@b:x", "$later", ts: 40, thread: kMXEventTimelineMain), inRoom: roomId)

        let receipts = eventReceipts("$e")
        XCTAssertEqual(receipts.map(\.userId), ["@c:x", "@a:x"], "sorted by ts desc; @b moved on")
        XCTAssertEqual(eventReceipts("$e", thread: "$root").count, 0)
    }

    func testMarkedUnreadSurvivesReopen() throws {
        let store = harness.store
        XCTAssertFalse(store.isRoomMarked(asUnread: roomId))
        store.setUnreadForRoom(roomId)
        XCTAssertTrue(store.isRoomMarked(asUnread: roomId))
        harness.commit()

        var reopened = try harness.reopen()
        XCTAssertTrue(reopened.isRoomMarked(asUnread: roomId))
        reopened.resetUnread(forRoom: roomId)
        harness.commit()
        reopened = try harness.reopen()
        XCTAssertFalse(reopened.isRoomMarked(asUnread: roomId))
    }

    func testDeleteRoomDropsItsReceipts() throws {
        harness.store.storeReceipt(receipt("@a:x", "$e", ts: 10, thread: kMXEventTimelineMain), inRoom: roomId)
        harness.commit()
        harness.store.deleteRoom(roomId)
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM receipt"), 0)
        XCTAssertNil(harness.store.getReceiptInRoom(roomId, threadId: kMXEventTimelineMain, forUserId: "@a:x"))
    }
}
