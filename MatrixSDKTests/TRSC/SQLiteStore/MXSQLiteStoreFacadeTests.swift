//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import ObjectiveC
import XCTest

/// Фасад `MXSQLiteStore`: каждый метод контракта кем-то реализован, открытие, самовосстановление, удаление.
final class MXSQLiteStoreFacadeTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!
    private let userId = "@facade:example.org"

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
    }

    override func tearDown() {
        sandbox.remove()
        super.tearDown()
    }

    private func makeStore(readOnly: Bool = false) -> MXSQLiteStore {
        MXSQLiteStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: readOnly)
    }

    private func credentials() -> MXCredentials {
        MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "token")
    }

    private func open(_ store: MXSQLiteStore) throws {
        let done = expectation(description: "open")
        var openError: Error?
        store.open(with: credentials(), onComplete: { done.fulfill() }, failure: { error in
            openError = error
            done.fulfill()
        })
        wait(for: [done], timeout: 10)
        if let openError {
            throw openError
        }
    }

    // MARK: - Every method of the contract has an owner

    private func selectors(of proto: Protocol) -> [Selector] {
        var result: [Selector] = []
        for required in [true, false] {
            var count: UInt32 = 0
            guard let methods = protocol_copyMethodDescriptionList(proto, required, true, &count) else { continue }
            for index in 0..<Int(count) {
                if let name = methods[index].name {
                    result.append(name)
                }
            }
            free(methods)
        }
        return result
    }

    func testStoreRespondsToEveryMethodOfMXStoreAndMXTimelineStore() {
        let store = makeStore()
        XCTAssertTrue(store.conforms(to: MXStore.self))
        XCTAssertTrue(store.conforms(to: MXTimelineStore.self))

        let all = selectors(of: MXStore.self) + selectors(of: MXTimelineStore.self)
        XCTAssertGreaterThan(all.count, 90)
        let missing = all.filter { !store.responds(to: $0) }.map(NSStringFromSelector)
        XCTAssertEqual(missing, [], "no owner for: \(missing)")
    }

    func testForwardedCallsWorkBeforeOpen() {
        // MXFileStore до загрузки отвечает пусто; новый стор не должен падать на «unrecognized selector».
        let store = makeStore()
        XCTAssertFalse(store.eventExists(withEventId: "$e", inRoom: "!r:x"))
        XCTAssertNil(store.event(withEventId: "$e", inRoom: "!r:x"))
        XCTAssertEqual(store.roomIds, [])
        XCTAssertNil(store.eventStreamToken)
        store.eventStreamToken = "s1"
        XCTAssertEqual(store.eventStreamToken, "s1")

        let page = store.latestPage(inRoom: "!r:x", thread: nil, limit: 50, types: nil)
        XCTAssertEqual(page.events.count, 0)
        XCTAssertEqual(store.holes(inRoom: "!r:x", thread: nil), [])
        XCTAssertEqual(
            store.countEvents(inRoom: "!r:x", afterEventId: nil, types: nil, excludingSender: nil, threadId: nil, limit: 10),
            UInt(NSNotFound)
        )
        XCTAssertEqual(store.historyContexts(forRoom: "!r:x"), [])
    }

    // MARK: - Open

    func testOpenCreatesEncryptedDatabaseAtAccountPath() throws {
        let store = makeStore()
        try open(store)

        let url = MXSQLiteStore.databaseURL(forUserId: userId, rootDirectory: sandbox.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.path.contains(userId), "the path must not reveal the MXID")
        XCTAssertEqual(url.lastPathComponent, "store.sqlite")

        let database = try XCTUnwrap(store.database)
        XCTAssertFalse(database.cipherVersion.isEmpty)
        XCTAssertEqual(database.readValue { $0.scalarInt("PRAGMA user_version") }, Int64(MXSQLiteSchema.currentVersion))
        XCTAssertNotNil(sandbox.keys.keys[MXSQLiteStore.keyIdentifier(forUserId: userId)])
        XCTAssertTrue(store.isPermanent)
        store.close()
    }

    func testLostKeyRecreatesTheStore() throws {
        let first = makeStore()
        try open(first)
        try first.database?.write { connection in
            try connection.run("INSERT INTO meta (key, value) VALUES ('event_stream_token', 's9')", bind: nil)
        }
        first.close()

        // Восстановление на другое устройство: ключ ThisDeviceOnly не переехал, файл есть.
        sandbox.keys.removeKeyMaterial(forIdentifier: MXSQLiteStore.keyIdentifier(forUserId: userId))

        let metrics = MetricsRecorder()
        let second = makeStore()
        second.metricsDelegate = metrics
        try open(second)
        XCTAssertEqual(metrics.resets, ["key_rejected"])
        XCTAssertEqual(second.database?.readValue { $0.scalarInt("SELECT count(*) FROM meta") }, 0)
        XCTAssertEqual(metrics.opens, 1)
        second.close()
    }

    func testOpenFailsClosedWithoutCipherAndKeepsTheFile() throws {
        let first = makeStore()
        try open(first)
        first.close()
        let url = MXSQLiteStore.databaseURL(forUserId: userId, rootDirectory: sandbox.directory)
        let before = try XCTUnwrap(FileManager.default.contents(atPath: url.path))

        MXSQLiteDatabase.setCipherVersionQueryForTesting("SELECT ''")
        defer { MXSQLiteDatabase.setCipherVersionQueryForTesting(nil) }

        let second = makeStore()
        XCTAssertThrowsError(try open(second)) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.cipherUnavailable.rawValue)
        }
        XCTAssertNil(second.database)
        XCTAssertEqual(FileManager.default.contents(atPath: url.path), before, "fail-closed must not wipe the store")
    }

    func testReadOnlyStoreNeedsAnExistingFile() throws {
        let readOnly = makeStore(readOnly: true)
        XCTAssertThrowsError(try open(readOnly))

        let writer = makeStore()
        try open(writer)
        writer.close()

        let nse = makeStore(readOnly: true)
        try open(nse)
        XCTAssertEqual(nse.database?.readOnly, true)
        nse.close()
    }

    // MARK: - Commit and deletion

    func testCommitWithNothingPendingCompletes() throws {
        let store = makeStore()
        try open(store)
        let done = expectation(description: "commit")
        store.commit { done.fulfill() }
        wait(for: [done], timeout: 5)
        store.close()
    }

    func testDeleteRoomRemovesItsRowsOnCommit() throws {
        let store = makeStore()
        try open(store)
        let database = try XCTUnwrap(store.database)
        try database.write { connection in
            try connection.run("INSERT INTO room (rid, room_id) VALUES (3, '!gone:x'), (4, '!kept:x')", bind: nil)
            try connection.run(
                "INSERT INTO event (rid, ord, event_id, type, ts, json) VALUES (3, 1, '$a', 't', 1, x'00'), (4, 1, '$b', 't', 1, x'00')",
                bind: nil
            )
            try connection.run("INSERT INTO hole (rid, lo, hi) VALUES (3, 0, 1)", bind: nil)
        }

        store.deleteRoom("!gone:x")
        let done = expectation(description: "commit")
        store.commit { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(database.readValue { $0.scalarText("SELECT group_concat(room_id) FROM room") }, "!kept:x")
        XCTAssertEqual(database.readValue { $0.scalarText("SELECT group_concat(event_id) FROM event") }, "$b")
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM hole") }, 0)
        store.close()
    }

    func testDeleteAllDataRemovesFileAndKey() throws {
        let store = makeStore()
        try open(store)
        let url = MXSQLiteStore.databaseURL(forUserId: userId, rootDirectory: sandbox.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.deleteAllData()

        XCTAssertNil(store.database)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertNil(sandbox.keys.keys[MXSQLiteStore.keyIdentifier(forUserId: userId)])

        // Как MXFileStore после clearCache: тот же объект открывается заново пустым.
        try open(store)
        XCTAssertNotNil(store.database)
        store.close()
    }
}

private final class MetricsRecorder: NSObject, MXStoreMetricsDelegate {
    private let lock = NSLock()
    private var _resets: [String] = []
    private var _opens = 0

    var resets: [String] { lock.lock(); defer { lock.unlock() }; return _resets }
    var opens: Int { lock.lock(); defer { lock.unlock() }; return _opens }

    func store(_ store: MXStore, didResetWithReason reason: String) {
        lock.lock(); _resets.append(reason); lock.unlock()
    }

    func store(_ store: MXStore, didOpenInMilliseconds milliseconds: Double, databaseBytes bytes: UInt64) {
        lock.lock(); _opens += 1; lock.unlock()
    }
}
