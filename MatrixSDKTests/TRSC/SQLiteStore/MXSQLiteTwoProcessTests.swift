//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Приложение и NSE на одной базе (iP9). У каждого свои соединения SQLite, как у двух процессов: блокировки WAL
/// между соединениями одного процесса SQLite ведёт так же, как между процессами (общий inode, те же shm-замки).
/// Проверяем: одновременное открытие, запись NSE во время коммитов приложения, короткое ожидание NSE, если
/// приложение держит писателя, — и что приложение NSE не ждёт.
final class MXSQLiteTwoProcessTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!
    private let userId = "@two:example.org"
    private let room = "!room:example.org"

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
    }

    override func tearDown() {
        sandbox.remove()
        super.tearDown()
    }

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

    private func event(_ order: Int64, prefix: String = "$e") -> MXEvent {
        let event = MXEvent(fromJSON: [
            "event_id": "\(prefix)\(order)",
            "type": "m.room.message",
            "sender": "@other:example.org",
            "origin_server_ts": 1_700_000_000_000 + order,
            "content": ["msgtype": "m.text", "body": "m\(order)"],
            "unsigned": ["trsc.count": String(order)],
        ])!
        event.roomId = room
        return event
    }

    private func seed(_ app: MXSQLiteStore) {
        let first = event(1)
        app.noteSyncTimeline(inRoom: room, firstEvent: first, limited: false, prevBatch: nil)
        app.storeEvent(forRoom: room, event: first, direction: .forwards)
        app.flush()
    }

    func testAppAndExtensionOpenTheSameDatabaseAtOnce() throws {
        let app = try openAppStore()
        seed(app)
        app.close()

        // Холодный старт приложения из пуша: NSE и приложение открывают базу одновременно, много раз.
        for round in 0..<20 {
            let appStore = MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
            let nse = MXSQLiteStore(forExtensionWithKeyProvider: sandbox.keys, rootDirectory: sandbox.directory)
            let appOpened = expectation(description: "app \(round)")
            var appError: Error?
            appStore.open(with: credentials, onComplete: { appOpened.fulfill() }, failure: { error in
                appError = error
                appOpened.fulfill()
            })
            var nseError: Error?
            let nseOpened = expectation(description: "nse \(round)")
            DispatchQueue.global(qos: .userInitiated).async {
                do { try nse.openSynchronously(with: self.credentials) } catch { nseError = error }
                nseOpened.fulfill()
            }
            wait(for: [appOpened, nseOpened], timeout: 10)
            XCTAssertNil(appError, "round \(round)")
            XCTAssertNil(nseError, "round \(round)")
            XCTAssertEqual(nse.latestPage(inRoom: room, thread: nil, limit: 10, types: nil).events.count, 1)
            nse.close()
            appStore.close()
        }
    }

    func testExtensionInsertsWhileTheAppCommitsAndNeitherWaitsLong() throws {
        let app = try openAppStore()
        seed(app)
        let nse = MXSQLiteStore(forExtensionWithKeyProvider: sandbox.keys, rootDirectory: sandbox.directory)
        try nse.openSynchronously(with: credentials)

        // Приложение пишет синк пачками по 20 событий, NSE в это время кладёт события из пушей в ту же комнату.
        let appDone = expectation(description: "app")
        var appCommitMs: [Double] = []
        DispatchQueue.global(qos: .userInitiated).async {
            var order: Int64 = 10
            for _ in 0..<40 {
                let events = (0..<20).map { _ -> MXEvent in
                    order += 10
                    return self.event(order)
                }
                app.noteSyncTimeline(inRoom: self.room, firstEvent: events.first, limited: false, prevBatch: nil)
                events.forEach { app.storeEvent(forRoom: self.room, event: $0, direction: .forwards) }
                let start = CFAbsoluteTimeGetCurrent()
                app.flush()
                appCommitMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            appDone.fulfill()
        }
        var nseMs: [Double] = []
        var nseErrors: [Error] = []
        for index in 0..<40 {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                // Номера между событиями приложения: строки не совпадают ни по event_id, ни по позиции.
                try nse.insertPushEvent(event(100_000 + Int64(index), prefix: "$push"), inRoom: room)
            } catch {
                nseErrors.append(error)
            }
            nseMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        wait(for: [appDone], timeout: 60)

        XCTAssertTrue(nseErrors.isEmpty, "\(nseErrors)")
        let nseWorst = nseMs.max() ?? 0
        let appWorst = appCommitMs.max() ?? 0
        print("[TRSC-WIRING-BENCH] two_process nse_insert_p50_ms=\(nseMs.sorted()[nseMs.count / 2]) nse_insert_max_ms=\(nseWorst) app_commit_p50_ms=\(appCommitMs.sorted()[appCommitMs.count / 2]) app_commit_max_ms=\(appWorst)")
        XCTAssertLessThan(nseWorst, 1000, "NSE не ждёт дольше своего busy_timeout")
        XCTAssertLessThan(appWorst, 1000, "приложение NSE не ждёт")

        let pushRows = app.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM event WHERE event_id LIKE '$push%'") }
        let appRows = app.database?.readValue { $0.scalarInt("SELECT COUNT(*) FROM event WHERE event_id LIKE '$e%'") }
        XCTAssertEqual(pushRows, 40)
        XCTAssertEqual(appRows, 801)
        nse.close()
        app.close()
    }

    func testExtensionGivesUpQuicklyWhenTheAppHoldsTheWriter() throws {
        let app = try openAppStore()
        seed(app)
        let nse = MXSQLiteStore(forExtensionWithKeyProvider: sandbox.keys, rootDirectory: sandbox.directory)
        try nse.openSynchronously(with: credentials)

        // Долгая транзакция приложения (миграция, большая догрузка): NSE не должен висеть до конца 30 с пуша.
        let holding = expectation(description: "holding")
        let released = expectation(description: "released")
        app.database?.write({ connection, _ in
            holding.fulfill()
            Thread.sleep(forTimeInterval: 3)
            return true
        }, completion: { _ in released.fulfill() })
        wait(for: [holding], timeout: 5)

        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertThrowsError(try nse.insertPushEvent(event(500), inRoom: room))
        let waited = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(waited, 2.5, "busy_timeout NSE короче транзакции приложения")
        wait(for: [released], timeout: 10)

        // Писатель освободился — следующий пуш ложится.
        XCTAssertNoThrow(try nse.insertPushEvent(event(600), inRoom: room))
        nse.close()
        app.close()
    }
}
