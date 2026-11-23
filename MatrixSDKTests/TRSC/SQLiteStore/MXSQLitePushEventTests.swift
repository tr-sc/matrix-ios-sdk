//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// NSE и та же база (iP9, dP11): стор расширения открывает только существующую базу тем же ключом, кладёт событие
/// из пуша одной строкой между дырами и больше ничего не пишет; синк приложения потом закрывает дыры без дублей.
final class MXSQLitePushEventTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!
    private let userId = "@push:example.org"
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

    private var credentials: MXCredentials {
        MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "token")
    }

    private func openAppStore() throws -> MXSQLiteStore {
        let store = MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
        let done = expectation(description: "open")
        var openError: Error?
        store.open(with: credentials, onComplete: { done.fulfill() }, failure: { error in
            openError = error
            done.fulfill()
        })
        wait(for: [done], timeout: 10)
        if let openError { throw openError }
        return store
    }

    private func openExtensionStore() throws -> MXSQLiteStore {
        let store = MXSQLiteStore(forExtensionWithKeyProvider: sandbox.keys, rootDirectory: sandbox.directory)
        try store.openSynchronously(with: credentials)
        return store
    }

    private func event(_ order: Int64?, id: String? = nil) -> MXEvent {
        var unsigned: [String: Any] = [:]
        if let order { unsigned["trsc.count"] = String(order) }
        let event = MXEvent(fromJSON: [
            "event_id": id ?? "$e\(order ?? -1)",
            "type": "m.room.message",
            "sender": "@other:example.org",
            "origin_server_ts": 1_700_000_000_000 + (order ?? 0),
            "content": ["msgtype": "m.text", "body": "m\(order ?? -1)"],
            "unsigned": unsigned,
        ])!
        event.roomId = room
        return event
    }

    private func sync(_ store: MXSQLiteStore, _ orders: [Int64], limited: Bool) {
        let events = orders.map { event($0) }
        store.noteSyncTimeline(inRoom: room, firstEvent: events.first, limited: limited, prevBatch: "pb")
        for event in events { store.storeEvent(forRoom: room, event: event, direction: .forwards) }
    }

    private func orders(_ store: MXSQLiteStore) -> [Int64] {
        store.latestPage(inRoom: room, thread: nil, limit: 50, types: nil).events.map(\.trscOrder)
    }

    private func holes(_ store: MXSQLiteStore) -> [[Int64]] {
        store.holes(inRoom: room, thread: nil).map { [$0.lowerOrder, $0.upperOrder] }
    }

    // MARK: - Opening

    func testExtensionOpensOnlyAnExistingDatabaseAndCreatesNothing() throws {
        let store = MXSQLiteStore(forExtensionWithKeyProvider: sandbox.keys, rootDirectory: sandbox.directory)
        XCTAssertThrowsError(try store.openSynchronously(with: credentials), "без базы приложения NSE работает по-старому")
        XCTAssertFalse(MXSQLiteStore.hasDatabase(forUserId: userId, rootDirectory: sandbox.directory))
        XCTAssertEqual(sandbox.keys.keys.count, 0, "ключ не создан")
    }

    func testExtensionReadsWhatTheAppCommittedWithTheSameKey() throws {
        let app = try openAppStore()
        sync(app, [10, 20], limited: false)
        app.eventStreamToken = "s1"
        app.flush()

        let nse = try openExtensionStore()
        XCTAssertEqual(orders(nse), [10, 20])
        XCTAssertEqual(nse.eventStreamToken, "s1")
        XCTAssertNotNil(nse.roomSummaryStore, "сводки нужны NSE для имени комнаты")
        nse.close()
        app.close()

        // Открытый заголовок: первые 32 байта не шифруются, iOS видит WAL-базу и не держит файл.
        let header = sandbox.rawBytes(of: MXSQLiteStore.databaseURL(forUserId: userId, rootDirectory: sandbox.directory)).prefix(16)
        XCTAssertEqual(header, Data("SQLite format 3\0".utf8))
    }

    func testExtensionWritesNothingButThePushEvent() throws {
        let app = try openAppStore()
        sync(app, [10], limited: false)
        app.flush()

        let nse = try openExtensionStore()
        nse.eventStreamToken = "from-nse"
        nse.storePartialAttributedTextMessage(forRoom: room, partialAttributedTextMessage: NSAttributedString(string: "nse"))
        let done = expectation(description: "commit")
        nse.commit { done.fulfill() }
        wait(for: [done], timeout: 5)
        nse.flush()
        nse.close()

        let reopened = try openExtensionStore()
        XCTAssertNil(reopened.eventStreamToken)
        XCTAssertNil(reopened.partialAttributedTextMessage(ofRoom: room))
        reopened.close()
        app.close()
    }

    // MARK: - Push event

    func testPushEventFromTheExtensionOpensTheChatWithoutNetworkThenSyncHasNoDuplicates() throws {
        let app = try openAppStore()
        sync(app, [10, 20], limited: false)
        app.flush()

        // NSE: событие из пуша одной строкой между дырами, сразу на диске.
        let nse = try openExtensionStore()
        XCTAssertNoThrow(try nse.insertPushEvent(event(50), inRoom: room))
        XCTAssertThrowsError(try nse.insertPushEvent(event(50), inRoom: room), "второй раз — без дублей")
        nse.close()

        // Приложение открывает чат до синка: событие из пуша сверху, под ним дыра.
        let page = app.latestPage(inRoom: room, thread: nil, limit: 50, types: nil)
        XCTAssertEqual(page.events.map(\.trscOrder), [50])
        XCTAssertEqual(page.holeBefore.map { [$0.lowerOrder, $0.upperOrder] }, [20, 50])
        XCTAssertEqual(holes(app), [[20, 50], [50, MXRoomHoleOpenEnd]])

        // Синк приносит то же событие: строка одна, дыры закрыты.
        sync(app, [30, 40, 50, 60], limited: false)
        app.flush()
        XCTAssertEqual(orders(app), [10, 20, 30, 40, 50, 60])
        XCTAssertEqual(holes(app), [])
        XCTAssertEqual(app.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM event WHERE event_id = '$e50'") }, 1)
        app.close()
    }

    func testPushEventAfterACachedLiveEdgeKeepsTheAppConsistent() throws {
        let app = try openAppStore()
        sync(app, [10, 20], limited: false)
        app.flush()
        // Приложение уже читало комнату (кеши компонентов прогреты).
        XCTAssertEqual(orders(app), [10, 20])

        let nse = try openExtensionStore()
        try nse.insertPushEvent(event(70), inRoom: room)
        nse.close()

        // Gappy-синк выше события из пуша: событие остаётся, дыры с обеих сторон.
        sync(app, [80, 90], limited: true)
        app.flush()
        XCTAssertEqual(orders(app), [80, 90])
        XCTAssertEqual(holes(app), [[20, 70], [70, 80]])
        XCTAssertEqual(app.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM event") }, 5)
        app.close()
    }

    func testPushEventForAnUnknownRoomOrWithoutPositionIsSkipped() throws {
        let app = try openAppStore()
        sync(app, [10], limited: false)
        app.flush()

        let nse = try openExtensionStore()
        let other = event(50)
        other.roomId = "!unknown:example.org"
        XCTAssertThrowsError(try nse.insertPushEvent(other, inRoom: "!unknown:example.org"),
                             "комнаты нет в базе — без состояния она не откроется, строку не создаём")
        XCTAssertThrowsError(try nse.insertPushEvent(event(nil, id: "$nocount"), inRoom: room), "без trsc.count места нет")
        nse.close()
        XCTAssertEqual(app.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM room") }, 1)
        app.close()
    }

    // MARK: - Envelope (ADR-0023)

    func testEnvelopeWithPositionAndSenderBecomesAStorableEvent() throws {
        let envelope: [String: Any] = ["v": 1, "type": "m.room.encrypted", "ts": 1_700_000_000_123,
                                       "name": "Анна", "count": "77", "sender": "@anna:example.org",
                                       "content": ["algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AAA"]]
        let json = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
        let userInfo: [AnyHashable: Any] = ["event_id": "$push", "room_id": room, "im.trsc.ev": json]

        let event = try XCTUnwrap(MXPushEventEnvelope.storableEvent(fromUserInfo: userInfo))
        XCTAssertEqual(event.eventId, "$push")
        XCTAssertEqual(event.roomId, room)
        XCTAssertEqual(event.sender, "@anna:example.org")
        XCTAssertEqual(event.trscOrder, 77)
        XCTAssertEqual(event.originServerTs, 1_700_000_000_123)
        XCTAssertTrue(event.isEncrypted)
    }

    func testEnvelopeWithoutPositionOrSenderIsNotStored() {
        // ADR-0023 не кладёт MXID и номер: такую строку в ленту не поставить, остаётся /event.
        let bare: [String: Any] = ["v": 1, "type": "m.room.encrypted", "ts": 1, "content": ["ciphertext": "A"]]
        XCTAssertNil(MXPushEventEnvelope.storableEvent(fromUserInfo: ["event_id": "$e", "room_id": room, "im.trsc.ev": bare]))
        var noSender = bare
        noSender["count"] = "5"
        XCTAssertNil(MXPushEventEnvelope.storableEvent(fromUserInfo: ["event_id": "$e", "room_id": room, "im.trsc.ev": noSender]))
        var future = bare
        future["v"] = 2
        future["count"] = "5"
        future["sender"] = "@a:x"
        XCTAssertNil(MXPushEventEnvelope.storableEvent(fromUserInfo: ["event_id": "$e", "room_id": room, "im.trsc.ev": future]))
        XCTAssertNil(MXPushEventEnvelope.storableEvent(fromUserInfo: ["event_id": "$e", "room_id": room]))
    }
}
