//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Компонент событий `MXSQLiteStore` (iP2): накладка, страницы, дыры синка и догрузки, окно `/context`,
/// событие из пуша, эхо, редакции, перечислитель, удаление по сроку.
final class MXSQLiteEventStoreTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!
    private let userId = "@me:example.org"
    private let room = "!room:example.org"

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
    }

    override func tearDown() {
        sandbox.remove()
        super.tearDown()
    }

    // MARK: - Helpers

    private func openStore() throws -> MXSQLiteStore {
        let store = MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
        let done = expectation(description: "open")
        var openError: Error?
        store.open(with: MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "t"),
                   onComplete: { done.fulfill() }, failure: { error in
            openError = error
            done.fulfill()
        })
        wait(for: [done], timeout: 10)
        if let openError { throw openError }
        return store
    }

    private func event(_ order: Int64?, id: String? = nil, sender: String = "@other:example.org", type: String = "m.room.message",
                       ts: UInt64? = nil, txn: String? = nil, thread: String? = nil, extra: [String: Any] = [:]) -> MXEvent {
        var unsigned: [String: Any] = [:]
        if let order { unsigned["trsc.count"] = String(order) }
        if let txn { unsigned["transaction_id"] = txn }
        var content: [String: Any] = ["msgtype": "m.text", "body": "m\(order ?? -1)"]
        if let thread { content["m.relates_to"] = ["rel_type": "m.thread", "event_id": thread] }
        var json: [String: Any] = [
            "event_id": id ?? "$e\(order ?? -1)",
            "type": type,
            "sender": sender,
            "origin_server_ts": ts ?? UInt64(1_700_000_000_000 + (order ?? 0)),
            "content": content,
            "unsigned": unsigned,
        ]
        json.merge(extra) { $1 }
        let event = MXEvent(fromJSON: json)!
        event.roomId = room
        return event
    }

    private func ids(_ events: [MXEvent]) -> [String] { events.map { $0.eventId } }
    private func orders(_ events: [MXEvent]) -> [Int64] { events.map { $0.trscOrder } }

    private func holes(_ store: MXSQLiteStore, thread: String? = nil) -> [[Int64]] {
        store.holes(inRoom: room, thread: thread).map { [$0.lowerOrder, $0.upperOrder] }
    }

    /// Синк: noteSync + события вперёд.
    private func sync(_ store: MXSQLiteStore, _ orders: [Int64], limited: Bool) {
        let events = orders.map { event($0) }
        store.noteSyncTimeline(inRoom: room, firstEvent: events.first, limited: limited, prevBatch: "pb")
        for event in events { store.storeEvent(forRoom: room, event: event, direction: .forwards) }
    }

    private func page(_ events: [MXEvent], end: String?) -> MXPaginationResponse {
        let response = MXPaginationResponse()
        response.chunk = events
        response.start = "s"
        response.end = end
        return response
    }

    // MARK: - Read-your-writes and persistence

    func testWritesAreVisibleBeforeCommitAndSurviveReopen() throws {
        let store = try openStore()
        sync(store, [10, 20, 30], limited: false)
        XCTAssertTrue(store.eventExists(withEventId: "$e20", inRoom: room))
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [10, 20, 30])
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 0, "до коммита база пуста")

        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 3)
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [10, 20, 30])
        XCTAssertGreaterThan(store.revision(ofRoom: room), 0)
        store.close()

        let reopened = try openStore()
        let latest = reopened.latestPage(inRoom: room, thread: nil, limit: 2, types: nil)
        XCTAssertEqual(orders(latest.events), [20, 30])
        XCTAssertTrue(latest.reachedLiveEdge)
        XCTAssertFalse(latest.reachedRoomStart)
        XCTAssertEqual(reopened.event(withEventId: "$e30", inRoom: room)?.content["body"] as? String, "m30")
        XCTAssertEqual(reopened.event(withEventId: "$e30", inRoom: room)?.trscOrder, 30, "trsc.count пишется обратно в JSON")
        var order: Int64 = 0
        XCTAssertTrue(reopened.order(ofEvent: "$e10", inRoom: room, order: &order))
        XCTAssertEqual(order, 10)
        reopened.close()
    }

    func testOverlayStaysVisibleWhileCommitIsInFlightAndAfterIt() throws {
        let store = try openStore()
        sync(store, [10, 20], limited: false)
        let committed = expectation(description: "commit")
        store.commit { committed.fulfill() }
        // Пока транзакция идёт — и после — те же строки, без дублей.
        sync(store, [30], limited: false)
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [10, 20, 30])
        wait(for: [committed], timeout: 10)
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [10, 20, 30])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 3)
        store.close()
    }

    func testReplaceDeleteAndDeleteAllBeforeAndAfterCommit() throws {
        let store = try openStore()
        sync(store, [10, 20, 30], limited: false)
        store.flush()
        let edited = event(20, extra: ["content": ["msgtype": "m.text", "body": "edited"]])
        store.replace(edited, inRoom: room)
        XCTAssertEqual(store.event(withEventId: "$e20", inRoom: room)?.content["body"] as? String, "edited")
        store.replace(event(99), inRoom: room)
        XCTAssertFalse(store.eventExists(withEventId: "$e99", inRoom: room), "replace не вставляет неизвестное")
        store.flush()
        XCTAssertEqual(store.event(withEventId: "$e20", inRoom: room)?.content["body"] as? String, "edited")

        store.deleteAllMessages(inRoom: room)
        XCTAssertEqual(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events.count, 0)
        sync(store, [40], limited: false)
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [40])
        store.flush()
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [40])
        store.close()
    }

    // MARK: - Gappy sync

    func testLimitedSyncLeavesAHoleAndThePageStopsAtIt() throws {
        let store = try openStore()
        sync(store, [10, 20, 30], limited: true)
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 10]], "новая комната: начало неизвестно")
        XCTAssertEqual(store.holes(inRoom: room, thread: nil).first?.backwardToken, "10")
        store.flush()

        sync(store, [100, 110], limited: true)
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 10], [30, 100]])
        let gap = store.holes(inRoom: room, thread: nil)[1]
        XCTAssertEqual(gap.backwardToken, "100", "назад — trsc.count первого события пачки")
        XCTAssertEqual(gap.forwardToken, "30")

        let latest = store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil)
        XCTAssertEqual(orders(latest.events), [100, 110], "страница не склеивает через дыру")
        XCTAssertEqual(latest.holeBefore, gap)
        XCTAssertTrue(latest.reachedLiveEdge)
        let older = store.page(inRoom: room, thread: nil, beforeOrder: 100, limit: 50, types: nil)
        XCTAssertEqual(older.events.count, 0)
        XCTAssertEqual(older.holeBefore, gap)
        let below = store.page(inRoom: room, thread: nil, beforeOrder: 31, limit: 50, types: nil)
        XCTAssertEqual(orders(below.events), [10, 20, 30])
        XCTAssertEqual(below.holeBefore?.isOpenStarted, true)
        let after = store.page(inRoom: room, thread: nil, afterOrder: 20, limit: 50, types: nil)
        XCTAssertEqual(orders(after.events), [30])
        XCTAssertEqual(after.holeAfter, gap)

        // Не limited: пачка продолжает живой край, дыр между краем и пачкой нет.
        sync(store, [120, 130], limited: false)
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 10], [30, 100]])
        store.close()
    }

    func testNonLimitedInitialSyncMeansTheWholeHistory() throws {
        let store = try openStore()
        sync(store, [10, 20], limited: false)
        XCTAssertEqual(holes(store), [])
        let latest = store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil)
        XCTAssertTrue(latest.reachedRoomStart)
        XCTAssertTrue(latest.reachedLiveEdge)
        store.close()
    }

    // MARK: - Back pagination into a hole

    func testBackPaginationNarrowsThenClosesTheHole() throws {
        let store = try openStore()
        sync(store, [10, 20], limited: false)
        sync(store, [100, 110], limited: true)
        let gap = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        XCTAssertEqual([gap.lowerOrder, gap.upperOrder], [20, 100])

        // Ответ сервера по убыванию; есть end — дыра сужается до самого старого из ответа.
        store.applyPage(page([event(90), event(80)], end: "80"), to: gap, direction: .backwards)
        XCTAssertEqual(holes(store), [[20, 80]])
        XCTAssertEqual(store.holes(inRoom: room, thread: nil).first?.backwardToken, "80")

        // Повтор того же ответа: дыры с прежней верхней границей уже нет — ничего не меняется.
        store.applyPage(page([event(90), event(80)], end: "80"), to: gap, direction: .backwards)
        XCTAssertEqual(holes(store), [[20, 80]])
        XCTAssertEqual(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events.count, 4)

        // Ответ дошёл до нижней границы (ord <= lo): дыра закрыта, лента непрерывна.
        let narrowed = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        store.applyPage(page([event(70), event(30), event(20)], end: "15"), to: narrowed, direction: .backwards)
        XCTAssertEqual(holes(store), [])
        store.flush()
        let latest = store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil)
        XCTAssertEqual(orders(latest.events), [10, 20, 30, 70, 80, 90, 100, 110])
        XCTAssertTrue(latest.reachedRoomStart)
        store.close()
    }

    func testEmptyEndClosesTheOpenStartHoleAndMarksRoomStart() throws {
        let store = try openStore()
        sync(store, [50, 60], limited: true)
        let bottom = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        XCTAssertTrue(bottom.isOpenStarted)
        store.applyPage(page([event(40), event(30)], end: nil), to: bottom, direction: .backwards)
        XCTAssertEqual(holes(store), [])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT reached_start FROM room") }, 1)
        XCTAssertTrue(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).reachedRoomStart)
        store.close()
    }

    func testForwardPaginationNarrowsFromBelow() throws {
        let store = try openStore()
        sync(store, [10], limited: false)
        sync(store, [100], limited: true)
        let gap = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        store.applyPage(page([event(20), event(30)], end: "30"), to: gap, direction: .forwards)
        XCTAssertEqual(holes(store), [[30, 100]])
        XCTAssertEqual(store.holes(inRoom: room, thread: nil).first?.forwardToken, "30")
        let narrowed = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        store.applyPage(page([event(40), event(100)], end: "100"), to: narrowed, direction: .forwards)
        XCTAssertEqual(holes(store), [])
        store.close()
    }

    // MARK: - Jump to message (/context)

    func testContextWindowSplitsTheHoleAndLaterMergesWithTheTimeline() throws {
        let store = try openStore()
        sync(store, [10], limited: false)
        sync(store, [1000], limited: true)
        let context = MXEventContext()
        context.eventsBefore = [event(490), event(480)]
        context.event = event(500)
        context.eventsAfter = [event(510), event(520)]
        context.start = "ctx-start"
        context.end = "ctx-end"
        store.insert(context, inRoom: room)
        XCTAssertEqual(holes(store), [[10, 480], [520, 1000]])
        let around = try XCTUnwrap(store.pageAroundEvent("$e500", inRoom: room, limit: 10))
        XCTAssertTrue(ids(around.events).contains("$e500"))
        XCTAssertEqual(around.holeBefore.map { [$0.lowerOrder, $0.upperOrder] }, [10, 480])
        XCTAssertEqual(around.holeAfter.map { [$0.lowerOrder, $0.upperOrder] }, [520, 1000])
        XCTAssertFalse(around.reachedLiveEdge)

        // Окно переживает перезапуск и срастается с лентой, когда догрузка доходит до него.
        store.flush()
        store.close()
        let reopened = try openStore()
        let upper = try XCTUnwrap(reopened.holes(inRoom: room, thread: nil).last)
        reopened.applyPage(page([event(900), event(520)], end: "520"), to: upper, direction: .backwards)
        XCTAssertEqual(holes(reopened), [[10, 480]])
        XCTAssertEqual(orders(reopened.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events),
                       [480, 490, 500, 510, 520, 900, 1000])
        reopened.close()
    }

    // MARK: - Detached event from a push

    func testPushEventIsSurroundedByHolesAndTheNextSyncClosesThem() throws {
        let store = try openStore()
        sync(store, [10, 20], limited: false)
        store.flush()

        XCTAssertTrue(store.insertDetachedEvent(event(50), inRoom: room))
        XCTAssertEqual(holes(store), [[20, 50], [50, MXRoomHoleOpenEnd]])
        XCTAssertFalse(store.insertDetachedEvent(event(50), inRoom: room), "второй раз — NO, без дублей")
        XCTAssertFalse(store.insertDetachedEvent(event(nil, id: "$nocount"), inRoom: room), "без trsc.count позиции нет")

        // Чат открыт до синка: сверху — событие из пуша, под ним дыра; живой край не достигнут.
        let latest = store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil)
        XCTAssertEqual(orders(latest.events), [50])
        XCTAssertEqual(latest.holeBefore.map { [$0.lowerOrder, $0.upperOrder] }, [20, 50])
        XCTAssertEqual(latest.holeAfter?.isOpenEnded, true)
        XCTAssertFalse(latest.reachedLiveEdge)
        store.flush()

        // Синк без пропуска дошёл: обе дыры закрыты, событие одно.
        sync(store, [30, 40, 50, 60], limited: false)
        XCTAssertEqual(holes(store), [])
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [10, 20, 30, 40, 50, 60])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event WHERE event_id = '$e50'") }, 1)
        store.close()
    }

    func testPushEventThenLimitedSyncAboveItKeepsBothHoles() throws {
        let store = try openStore()
        sync(store, [10], limited: false)
        XCTAssertTrue(store.insertDetachedEvent(event(50), inRoom: room))
        sync(store, [100, 110], limited: true)
        XCTAssertEqual(holes(store), [[10, 50], [50, 100]])
        XCTAssertEqual(store.holes(inRoom: room, thread: nil)[1].backwardToken, "100")
        store.close()
    }

    func testPushIntoAnEmptyRoomAndIntoAnExistingHole() throws {
        let store = try openStore()
        XCTAssertTrue(store.insertDetachedEvent(event(50), inRoom: room))
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 50], [50, MXRoomHoleOpenEnd]])
        XCTAssertTrue(store.insertDetachedEvent(event(70), inRoom: room))
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 50], [50, 70], [70, MXRoomHoleOpenEnd]])
        XCTAssertTrue(store.insertDetachedEvent(event(60), inRoom: room))
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 50], [50, 60], [60, 70], [70, MXRoomHoleOpenEnd]])
        store.close()
    }

    // MARK: - Echo and server event are one row

    func testServerEventWithTransactionIdTakesOverTheEchoRow() throws {
        let store = try openStore()
        sync(store, [10], limited: false)
        let echo = event(nil, id: "kMXEventLocalId_abc", sender: userId, txn: "txn-1")
        store.storeEvent(forRoom: room, event: echo, direction: .forwards)
        store.flush()
        let echoRowId = store.database?.readValue { $0.scalarInt("SELECT id FROM event WHERE txn_id = 'txn-1'") }

        store.noteSyncTimeline(inRoom: room, firstEvent: event(20, id: "$server", sender: userId, txn: "txn-1"), limited: false, prevBatch: nil)
        store.storeEvent(forRoom: room, event: event(20, id: "$server", sender: userId, txn: "txn-1"), direction: .forwards)
        XCTAssertFalse(store.eventExists(withEventId: "kMXEventLocalId_abc", inRoom: room))
        XCTAssertTrue(store.eventExists(withEventId: "$server", inRoom: room))
        XCTAssertEqual(ids(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), ["$e10", "$server"])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event WHERE txn_id = 'txn-1'") }, 1)
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT id FROM event WHERE event_id = '$server'") }, echoRowId,
                       "та же строка (rowid), не удаление + вставка")
        store.close()
    }

    func testDuplicateDeliveryAndTemporaryOrderMoveToTheRealOne() throws {
        let store = try openStore()
        sync(store, [10, 20], limited: false)
        // Событие без номера встаёт временно у края, потом приходит с номером и переезжает (та же строка в UI).
        store.storeEvent(forRoom: room, event: event(nil, id: "$late"), direction: .forwards)
        var order: Int64 = 0
        XCTAssertTrue(store.order(ofEvent: "$late", inRoom: room, order: &order))
        XCTAssertEqual(order, 20)
        store.flush()
        store.storeEvent(forRoom: room, event: event(15, id: "$late"), direction: .forwards)
        XCTAssertEqual(ids(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), ["$e10", "$late", "$e20"])
        store.storeEvent(forRoom: room, event: event(20), direction: .forwards)
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 3)
        XCTAssertEqual(ids(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), ["$e10", "$late", "$e20"])
        store.close()
    }

    // MARK: - Redactions, relations, threads

    func testRedactionBeforeItsTargetIsAppliedWhenTheTargetArrives() throws {
        let store = try openStore()
        sync(store, [100], limited: true)
        let gap = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        let redaction = event(90, id: "$redaction", type: "m.room.redaction", extra: ["redacts": "$e80"])
        store.applyPage(page([redaction], end: "90"), to: gap, direction: .backwards)
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM redaction_pending") }, 1)
        let narrowed = try XCTUnwrap(store.holes(inRoom: room, thread: nil).first)
        store.applyPage(page([event(80)], end: "80"), to: narrowed, direction: .backwards)
        let target = try XCTUnwrap(store.event(withEventId: "$e80", inRoom: room))
        XCTAssertTrue(target.isRedactedEvent())
        XCTAssertNil(target.content["body"])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM redaction_pending") }, 0)
        XCTAssertTrue(store.event(withEventId: "$e80", inRoom: room)?.isRedactedEvent() ?? false)
        store.close()
    }

    func testRelationsAndThreadPages() throws {
        let store = try openStore()
        sync(store, [10], limited: false)
        let reply = event(20, id: "$reply", thread: "$e10")
        let edit = event(30, id: "$edit", extra: ["content": ["msgtype": "m.text", "body": "* x",
                                                               "m.relates_to": ["rel_type": "m.replace", "event_id": "$e10"]]])
        store.storeEvent(forRoom: room, event: reply, direction: .forwards)
        store.storeEvent(forRoom: room, event: edit, direction: .forwards)
        XCTAssertEqual(ids(store.relations(forEvent: "$e10", inRoom: room, relationType: "m.replace")), ["$edit"])
        let thread = store.latestPage(inRoom: room, thread: "$e10", limit: 50, types: nil)
        XCTAssertEqual(ids(thread.events), ["$e10", "$reply"], "лента треда: корень и ответы")
        store.flush()
        XCTAssertEqual(ids(store.relations(forEvent: "$e10", inRoom: room, relationType: "m.replace")), ["$edit"])
        XCTAssertEqual(ids(store.latestPage(inRoom: room, thread: "$e10", limit: 50, types: nil).events), ["$e10", "$reply"])
        store.close()
    }

    // MARK: - Counts, latest event, enumerator

    func testCountsAndLatestEvent() throws {
        let store = try openStore()
        sync(store, [10, 20, 30, 40], limited: false)
        store.storeEvent(forRoom: room, event: event(50, sender: userId), direction: .forwards)
        XCTAssertEqual(store.countEvents(inRoom: room, afterEventId: "$e20", types: nil, excludingSender: userId, threadId: nil, limit: 10), 2)
        XCTAssertEqual(store.countEvents(inRoom: room, afterEventId: "$e20", types: nil, excludingSender: nil, threadId: nil, limit: 2), 2)
        XCTAssertEqual(store.countEvents(inRoom: room, afterEventId: "$missing", types: nil, excludingSender: nil, threadId: nil, limit: 10),
                       UInt(NSNotFound))
        XCTAssertEqual(store.latestEvent(inRoom: room, types: nil, threadId: nil, beforeOrder: MXRoomHoleOpenEnd)?.eventId, "$e50")
        XCTAssertEqual(store.latestEvent(inRoom: room, types: nil, threadId: nil, beforeOrder: 30)?.eventId, "$e20")
        XCTAssertNil(store.latestEvent(inRoom: room, types: ["m.room.member"], threadId: nil, beforeOrder: MXRoomHoleOpenEnd))
        store.close()
    }

    func testEnumeratorPagesFromTheTopAndStopsAtTheFirstHole() throws {
        let store = try openStore()
        sync(store, Array(1...30).map { Int64($0) }, limited: false)
        store.flush()
        sync(store, Array(101...220).map { Int64($0) }, limited: true)
        let enumerator = store.messagesEnumerator(forRoom: room)
        XCTAssertEqual(enumerator.remaining, 120, "до дыры (30, 101)")
        let first = try XCTUnwrap(enumerator.nextEventsBatch(50, threadId: nil))
        XCTAssertEqual(orders(first), Array(171...220).map { Int64($0) })
        XCTAssertEqual(enumerator.remaining, 70)
        let second = try XCTUnwrap(enumerator.nextEventsBatch(100, threadId: nil))
        XCTAssertEqual(second.count, 70)
        XCTAssertEqual(second.first?.trscOrder, 101)
        XCTAssertNil(enumerator.nextEventsBatch(10, threadId: nil))
        XCTAssertEqual(enumerator.remaining, 0)
        let typed = store.messagesEnumerator(forRoom: room, withTypeIn: ["m.room.member"])
        XCTAssertNil(typed.nextEvent)
        store.close()
    }

    // MARK: - Retention

    func testRemoveMessagesSentBeforePutsARetentionHoleAtTheBottom() throws {
        let store = try openStore()
        let events = [event(10, ts: 1000), event(20, ts: 2000), event(30, ts: 3000)]
        store.noteSyncTimeline(inRoom: room, firstEvent: events[0], limited: false, prevBatch: nil)
        for event in events { store.storeEvent(forRoom: room, event: event, direction: .forwards) }
        store.flush()
        XCTAssertTrue(store.removeAllMessagesSent(before: 2500, inRoom: room))
        XCTAssertEqual(orders(store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events), [30])
        XCTAssertEqual(holes(store), [[MXRoomHoleOpenStart, 30]])
        store.flush()
        XCTAssertEqual(store.database?.readValue { $0.scalarInt("SELECT count(*) FROM event") }, 1)
        XCTAssertFalse(store.removeAllMessagesSent(before: 2500, inRoom: room), "второй раз удалять нечего")
        store.close()
    }

    // MARK: - Property: random sync / push / pagination scenarios

    /// Сервер — растущая лента; клиент получает её синками (limited и нет), пушами и догрузкой дыр в случайном
    /// порядке, с коммитами вперемешку. После каждого шага:
    /// - дыры не пересекаются, ни одно событие клиента не лежит строго внутри дыры;
    /// - любое событие сервера, которого у клиента нет, ниже его самого нового — внутри какой-то дыры (тихих пропусков нет).
    /// В конце дыры догружаются до нуля, и лента клиента равна ленте сервера.
    func testRandomScenariosKeepHoleInvariantsAndConverge() throws {
        for seed in 0..<12 {
            var rng = SeededGenerator(seed: UInt64(seed) &* 7919)
            let store = try openStore()
            var server: [Int64] = []
            var next: Int64 = 1
            var syncedUpTo = -1      // индекс последнего события сервера, отданного синком
            var known = Set<Int64>()

            func appendServer(_ count: Int) {
                for _ in 0..<count {
                    next += Int64.random(in: 1...3, using: &rng)   // trsc.count сервера общий на все комнаты: с пропусками
                    server.append(next)
                }
            }
            func doSync() {
                let fresh = server.count - 1 - syncedUpTo
                guard fresh > 0 else { return }
                let take = min(fresh, 5)
                let batch = Array(server[(server.count - take)...])
                sync(store, batch, limited: take < fresh)
                known.formUnion(batch)
                syncedUpTo = server.count - 1
            }
            func fillRandomHole() {
                let holes = store.holes(inRoom: room, thread: nil).filter { !$0.isOpenEnded }
                guard let hole = holes.randomElement(using: &rng) else { return }
                let older = server.filter { $0 < hole.upperOrder }.reversed()
                let chunk = Array(older.prefix(Int.random(in: 1...4, using: &rng)))
                let more = older.count > chunk.count
                store.applyPage(page(chunk.map { event($0) }, end: more ? "t\(chunk.last ?? 0)" : nil), to: hole, direction: .backwards)
                known.formUnion(chunk)
            }
            func check(_ step: String) {
                let holeList = store.holes(inRoom: room, thread: nil)
                for (a, b) in zip(holeList, holeList.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.upperOrder, b.lowerOrder, "seed \(seed) \(step): дыры пересекаются")
                }
                for order in known {
                    XCTAssertFalse(holeList.contains { $0.lowerOrder < order && order < $0.upperOrder },
                                   "seed \(seed) \(step): событие \(order) внутри дыры")
                }
                if let newest = known.max() {
                    for order in server where order < newest && !known.contains(order) {
                        XCTAssertTrue(holeList.contains { $0.lowerOrder < order && order < $0.upperOrder },
                                      "seed \(seed) \(step): пропуск \(order) без дыры")
                    }
                }
            }

            appendServer(Int.random(in: 3...20, using: &rng))
            doSync()
            for step in 0..<40 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0...2:
                    appendServer(Int.random(in: 1...12, using: &rng))
                    doSync()
                case 3...4:
                    appendServer(Int.random(in: 1...6, using: &rng))
                    if let pushed = server[(syncedUpTo + 1)...].randomElement(using: &rng) {
                        if store.insertDetachedEvent(event(pushed), inRoom: room) { known.insert(pushed) }
                    }
                case 5...7:
                    fillRandomHole()
                default:
                    if Bool.random(using: &rng) { store.flush() } else { store.commit() }
                }
                check("step \(step)")
            }
            doSync()
            var guardCount = 0
            while let hole = store.holes(inRoom: room, thread: nil).first(where: { !$0.isOpenEnded }), guardCount < 500 {
                let older = server.filter { $0 < hole.upperOrder }.reversed()
                let chunk = Array(older.prefix(7))
                store.applyPage(page(chunk.map { event($0) }, end: older.count > chunk.count ? "t" : nil), to: hole, direction: .backwards)
                known.formUnion(chunk)
                guardCount += 1
            }
            check("final")
            XCTAssertEqual(holes(store), [], "seed \(seed)")
            store.flush()
            let all = store.latestPage(inRoom: room, thread: nil, limit: 10_000, types: nil)
            XCTAssertEqual(orders(all.events), server, "seed \(seed): лента клиента = ленте сервера")
            XCTAssertTrue(all.reachedRoomStart && all.reachedLiveEdge, "seed \(seed)")
            store.deleteAllData()
            store.close()
        }
    }
}
