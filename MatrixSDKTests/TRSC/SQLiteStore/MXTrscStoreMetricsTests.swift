//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP12: метрики хранилища для журнала запуска — те же имена, что у Android (`TrscStartupTimings.kt`), и
/// `store=sqlite|file` в detail, чтобы один отчёт сравнивал старый и новый стор.
final class MXTrscStoreMetricsTests: XCTestCase {
    private final class Sink: NSObject, MXTrscStoreMetricsSink {
        var events: [(name: String, ms: Double, detail: String)] = []
        var context: [String: Any] = [:]
        func storeMetricsEvent(_ name: String, milliseconds: Double, detail: String) {
            events.append((name, milliseconds, detail))
        }
        func storeMetricsContext(_ key: String, value: Any) {
            context[key] = value
        }
        var shownRoomId: String? = "!open:x"
        func storeMetricsShowsRoom(_ roomId: String) -> Bool {
            roomId == shownRoomId
        }
    }

    private var sink: Sink!

    override func setUp() {
        super.setUp()
        sink = Sink()
        MXTrscStoreMetrics.sink = sink
        MXTrscStoreMetrics.resetForTests()
    }

    override func tearDown() {
        MXTrscStoreMetrics.sink = nil
        super.tearDown()
    }

    func testStoreKindNamesBothStores() throws {
        let sandbox = MXSQLiteTestSandbox(name)
        defer { sandbox.remove() }
        let sqlite = MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
        XCTAssertEqual(MXTrscStoreMetrics.kind(of: sqlite), "sqlite")
        XCTAssertEqual(MXTrscStoreMetrics.kind(of: MXFileStore()), "file")
        XCTAssertEqual(MXTrscStoreMetrics.kind(of: MXMemoryStore()), "memory")
        XCTAssertEqual(MXTrscStoreMetrics.kind(of: nil), "none")
    }

    func testStoreOpenGoesToTheLaunchContextOncePerProcess() {
        let store = MXFileStore()
        MXTrscStoreMetrics.reportStoreOpen(store, milliseconds: 12.6)
        MXTrscStoreMetrics.reportStoreOpen(store, milliseconds: 99)
        XCTAssertEqual(sink.context["db_open_ms"] as? Int, 13)
        XCTAssertEqual(sink.context["store_open_ms"] as? Int, 13)
        XCTAssertEqual(sink.context["store"] as? String, "file")
    }

    func testSQLiteDbOpenIsTheDatabaseOpenNotTheMainQueueHop() throws {
        // db_open_ms — как у Android: ключ, PRAGMA, схема. Ожидание main на холодном старте — в store_open_ms.
        let harness = try MXSQLiteStoreHarness(self, name: name)
        defer { harness.remove() }
        MXTrscStoreMetrics.reportStoreOpen(harness.store, milliseconds: 950)
        XCTAssertEqual(sink.context["db_open_ms"] as? Int, Int(harness.database.openMilliseconds.rounded()))
        XCTAssertEqual(sink.context["store_open_ms"] as? Int, 950)
        XCTAssertEqual(sink.context["store"] as? String, "sqlite")
        XCTAssertNotNil(sink.context["db_mb"])
    }

    func testSyncPersistSkipsEmptyLongPollsButNotTheInitialSync() {
        let store = MXFileStore()
        MXTrscStoreMetrics.reportSyncPersist(store, milliseconds: 3, events: 0, rooms: 0, initial: false)
        MXTrscStoreMetrics.reportSyncPersist(store, milliseconds: 40, events: 0, rooms: 0, initial: true)
        MXTrscStoreMetrics.reportSyncPersist(store, milliseconds: 4.4, events: 2, rooms: 1, initial: false)
        XCTAssertEqual(sink.events.map(\.name), ["sync_persist_ms", "sync_persist_ms"])
        XCTAssertEqual(sink.events[0].detail, "events=0 rooms=0 initial=true store=file")
        XCTAssertEqual(sink.events[1].detail, "events=2 rooms=1 initial=false store=file")
        XCTAssertEqual(sink.events[1].ms, 4.4, accuracy: 0.001)
    }

    func testFileStoreSyncPersistIsTheCommitCallToItsCompletion() {
        let store = MXFileStore()
        MXTrscStoreMetrics.beginSyncPersist(of: store, events: 3, rooms: 2, initial: false)
        MXTrscStoreMetrics.endSyncPersist(of: store)
        MXTrscStoreMetrics.endSyncPersist(of: store)
        XCTAssertEqual(sink.events.map(\.name), ["sync_persist_ms"])
        XCTAssertEqual(sink.events[0].detail, "events=3 rooms=2 initial=false store=file")
        MXTrscStoreMetrics.beginSyncPersist(of: store, events: 0, rooms: 0, initial: false)
        MXTrscStoreMetrics.endSyncPersist(of: store)
        XCTAssertEqual(sink.events.count, 1, "пустой long-poll не пишется")
    }

    func testChatWindowAndPageFetchCarryTheStoreKind() {
        let store = MXMemoryStore()
        MXTrscStoreMetrics.reportChatWindow(store, milliseconds: 2, rows: 30, anchor: "live")
        MXTrscStoreMetrics.reportPageFetch(store, milliseconds: 120, direction: "back", count: 50, rows: 48)
        XCTAssertEqual(sink.events.map(\.name), ["chat_window_ms", "page_fetch_ms"])
        XCTAssertEqual(sink.events[0].detail, "rows=30 anchor=live store=memory")
        XCTAssertEqual(sink.events[1].detail, "dir=back count=50 rows=48 store=memory")
    }

    func testLiveInsertMeasuresFromTheSyncResponseToTheOpenTimeline() {
        let store = MXFileStore()
        MXTrscStoreMetrics.noteSyncEventIds(["$a", "$b"], at: 10.0)
        MXTrscStoreMetrics.reportLiveEventDelivered("$x", roomId: "!open:x", store: store, at: 10.5)
        XCTAssertTrue(sink.events.isEmpty, "событие не из синка")
        MXTrscStoreMetrics.reportLiveEventDelivered("$b", roomId: "!open:x", store: store, at: 10.020)
        MXTrscStoreMetrics.reportLiveEventDelivered("$b", roomId: "!open:x", store: store, at: 10.030)
        XCTAssertEqual(sink.events.count, 1, "одно событие — один замер")
        XCTAssertEqual(sink.events[0].name, "live_insert_ms")
        XCTAssertEqual(sink.events[0].ms, 20, accuracy: 0.5)
        XCTAssertEqual(sink.events[0].detail, "store=file")
    }

    func testLiveInsertCountsOnlyTheChatOnScreen() {
        // Ленты с подписчиками есть и у закрытых комнат (догоняющий синк на старте) — это не вставка в чат.
        MXTrscStoreMetrics.noteSyncEventIds(["$a", "$b"], at: 1)
        MXTrscStoreMetrics.reportLiveEventDelivered("$a", roomId: "!closed:x", store: nil, at: 2)
        XCTAssertTrue(sink.events.isEmpty)
        MXTrscStoreMetrics.reportLiveEventDelivered("$b", roomId: "!open:x", store: nil, at: 2)
        XCTAssertEqual(sink.events.map(\.name), ["live_insert_ms"])
    }

    func testLiveProbeIsBounded() {
        let ids = (0..<600).map { "$e\($0)" }
        MXTrscStoreMetrics.noteSyncEventIds(ids, at: 1)
        MXTrscStoreMetrics.reportLiveEventDelivered("$e0", roomId: "!open:x", store: nil, at: 2)
        XCTAssertTrue(sink.events.isEmpty, "старые записи вытеснены")
        MXTrscStoreMetrics.reportLiveEventDelivered("$e599", roomId: "!open:x", store: nil, at: 2)
        XCTAssertEqual(sink.events.count, 1)
    }

    func testWithoutSinkNothingIsKept() {
        MXTrscStoreMetrics.sink = nil
        MXTrscStoreMetrics.noteSyncEventIds(["$a"], at: 1)
        MXTrscStoreMetrics.sink = sink
        MXTrscStoreMetrics.reportLiveEventDelivered("$a", roomId: "!open:x", store: nil, at: 2)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testSQLiteCommitOfASyncIsReportedByTheStoreItself() throws {
        // Транзакция SQLite мерится на писателе (`didCommitInMilliseconds`), а не вызовом commit на main.
        let harness = try MXSQLiteStoreHarness(self, name: name)
        defer { harness.remove() }
        harness.store.metricsDelegate = MXTrscStoreMetrics.shared
        MXTrscStoreMetrics.beginSyncPersist(of: harness.store, events: 1, rooms: 1, initial: false)
        let event = MXSQLiteStoreHarness.message(eventId: "$m", roomId: "!r:x")
        harness.store.storeEvent(forRoom: "!r:x", event: event, direction: .forwards)
        harness.commit()
        MXTrscStoreMetrics.endSyncPersist(of: harness.store)
        let persist = sink.events.filter { $0.name == "sync_persist_ms" }
        XCTAssertEqual(persist.count, 1)
        XCTAssertEqual(persist.first?.detail, "events=1 rooms=1 initial=false store=sqlite")
        // Коммит не синка (догрузка, квитанция) — не sync_persist.
        harness.store.storeEvent(forRoom: "!r:x", event: MXSQLiteStoreHarness.message(eventId: "$n", roomId: "!r:x"),
                                 direction: .forwards)
        harness.commit()
        XCTAssertEqual(sink.events.filter { $0.name == "sync_persist_ms" }.count, 1)
    }
}
