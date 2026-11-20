//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import MatrixSDK
import XCTest

/// Открытый `MXSQLiteStore` во временной папке: открыть, закоммитить, переоткрыть тот же файл.
final class MXSQLiteStoreHarness {
    let sandbox: MXSQLiteTestSandbox
    let userId: String
    private(set) var store: MXSQLiteStore
    private let test: XCTestCase

    init(_ test: XCTestCase, name: String = #function, userId: String = "@harness:example.org") throws {
        self.test = test
        self.userId = userId
        sandbox = MXSQLiteTestSandbox(name)
        store = MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
        try open(store)
    }

    var credentials: MXCredentials {
        MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "token")
    }

    func makeStore() -> MXSQLiteStore {
        MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
    }

    func open(_ store: MXSQLiteStore) throws {
        let done = test.expectation(description: "open")
        var openError: Error?
        store.open(with: credentials, onComplete: { done.fulfill() }, failure: { error in
            openError = error
            done.fulfill()
        })
        test.wait(for: [done], timeout: 10)
        if let openError {
            throw openError
        }
    }

    func commit(_ store: MXSQLiteStore? = nil) {
        let done = test.expectation(description: "commit")
        (store ?? self.store).commit { done.fulfill() }
        test.wait(for: [done], timeout: 10)
    }

    /// Закрыть и открыть заново: чтение только из файла.
    @discardableResult
    func reopen() throws -> MXSQLiteStore {
        store.close()
        store = makeStore()
        try open(store)
        return store
    }

    var database: MXSQLiteDatabase { store.database! }

    func count(_ sql: String) -> Int64 {
        database.readValue { $0.scalarInt(sql) } ?? -1
    }

    func remove() {
        store.close()
        sandbox.remove()
    }

    // MARK: - Fixtures

    static func stateEvent(
        type: String = kMXEventTypeStringRoomMember,
        stateKey: String,
        eventId: String,
        content: [String: Any] = ["membership": "join"]
    ) -> MXEvent {
        MXEvent(fromJSON: [
            "type": type,
            "state_key": stateKey,
            "event_id": eventId,
            "sender": stateKey.isEmpty ? "@a:x" : stateKey,
            "origin_server_ts": 1_700_000_000_000,
            "content": content,
        ])!
    }

    static func message(eventId: String, roomId: String, body: String = "hi", transactionId: String? = nil) -> MXEvent {
        var json: [String: Any] = [
            "type": kMXEventTypeStringRoomMessage,
            "event_id": eventId,
            "room_id": roomId,
            "sender": "@me:x",
            "origin_server_ts": 1_700_000_000_000,
            "content": ["msgtype": "m.text", "body": body],
        ]
        if let transactionId {
            json["unsigned"] = ["transaction_id": transactionId]
        }
        return MXEvent(fromJSON: json)!
    }

    func state(of roomId: String, in store: MXSQLiteStore? = nil) -> [MXEvent] {
        let done = test.expectation(description: "state")
        var result: [MXEvent] = []
        (store ?? self.store).state(ofRoom: roomId, success: { events in
            result = events
            done.fulfill()
        }, failure: { _ in done.fulfill() })
        test.wait(for: [done], timeout: 10)
        return result
    }
}

extension MXSQLiteDatabase {
    /// SQL на писателе вне транзакции (триггеры, порча строк в тестах).
    func exec(_ sql: String) throws {
        try writer { try $0.execute(sql) }
    }
}

extension MXSQLiteStore {
    /// `MXSQLiteOutgoingStoring` не публичный протокол фасада: вызов через маршрутизацию селектора.
    func consumeOutgoing(forTransactionId transactionId: String, inRoom roomId: String) -> String? {
        let selector = NSSelectorFromString("consumeOutgoingForTransactionId:inRoom:")
        return perform(selector, with: transactionId, with: roomId)?.takeUnretainedValue() as? String
    }
}
