//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Стор сессии при включённом флаге (iP9): первое открытие переносит неотправленные и черновики из MXFileStore
/// и удаляет его папку и сводки; повторное — ничего не делает; выключение флага стирает базу и ключ.
final class MXSQLiteSessionStoreTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!
    private var legacy: URL!
    private let userId = "@session-store:example.org"
    private let roomA = "!a:example.org"
    private let roomB = "!b:example.org"

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
        legacy = sandbox.directory.appendingPathComponent("MXFileStore/\(userId)", isDirectory: true)
    }

    override func tearDown() {
        sandbox.remove()
        try? FileManager.default.removeItem(at: MXSQLiteLegacyImport.fileStoreURL(forUserId: userId))
        super.tearDown()
    }

    // MARK: - Helpers

    private var credentials: MXCredentials {
        MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "token")
    }

    private func makeStore() -> MXSQLiteSessionStore {
        let store = MXSQLiteSessionStore(keyProvider: sandbox.keys, rootDirectory: sandbox.directory, readOnly: false)
        store.legacyFileStoreURL = legacy
        return store
    }

    private func open(_ store: MXSQLiteStore) throws {
        let done = expectation(description: "open")
        var openError: Error?
        store.open(with: credentials, onComplete: { done.fulfill() }, failure: { error in
            openError = error
            done.fulfill()
        })
        wait(for: [done], timeout: 10)
        if let openError { throw openError }
    }

    private func writeLegacyRoom(_ roomId: String, outgoing: [String], draft: String?) throws {
        let folder = legacy.appendingPathComponent("rooms/\(roomId)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !outgoing.isEmpty {
            let store = MXFileRoomOutgoingMessagesStore()
            for localId in outgoing {
                let echo = MXSQLiteStoreHarness.message(eventId: localId, roomId: roomId, body: localId)
                echo.sentState = MXEventSentStateFailed
                store.storeOutgoingMessage(echo)
            }
            try NSKeyedArchiver.archivedData(withRootObject: store, requiringSecureCoding: false)
                .write(to: folder.appendingPathComponent("outgoingMessages"))
        }
        let roomStore = MXFileRoomStore()
        for index in 0..<20 {
            roomStore.store(MXSQLiteStoreHarness.message(eventId: "$h\(index)", roomId: roomId), direction: .forwards)
        }
        if let draft {
            roomStore.partialAttributedTextMessage = NSAttributedString(string: draft)
        }
        try NSKeyedArchiver.archivedData(withRootObject: roomStore, requiringSecureCoding: false)
            .write(to: folder.appendingPathComponent("messages"))
    }

    private func count(_ store: MXSQLiteStore, _ sql: String) -> Int64 {
        store.database?.readValue { $0.scalarInt(sql) } ?? -1
    }

    // MARK: - Tests

    func testFirstOpenMovesOutgoingAndDraftsAndRemovesTheFileStore() throws {
        try writeLegacyRoom(roomA, outgoing: ["~a1", "~a2"], draft: "draft A")
        try writeLegacyRoom(roomB, outgoing: [], draft: "draft B")

        let store = makeStore()
        try open(store)

        // Перенос уже на диске к моменту onComplete: сессия монтируется с неотправленными и черновиками.
        XCTAssertEqual(store.outgoingMessages(inRoom: roomA)?.compactMap(\.eventId), ["~a1", "~a2"])
        XCTAssertEqual(store.partialAttributedTextMessage(ofRoom: roomB)?.string, "draft B")
        XCTAssertEqual(store.legacyImportResult?.outgoingCount, 2)
        XCTAssertEqual(store.legacyImportResult?.draftCount, 2)
        XCTAssertEqual(count(store, "SELECT COUNT(*) FROM event"), 0, "история не переносится — её принесёт синк")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "папка MXFileStore удалена после переноса")
        XCTAssertNil(store.eventStreamToken, "новая база пустая: первый синк — начальный")
        XCTAssertEqual(store.roomSummaryStore.countOfRooms, 0, "сводки старого стора сброшены, иначе позиция Sliding Sync восстановится")

        store.close()
        let reopened = makeStore()
        try open(reopened)
        XCTAssertEqual(reopened.outgoingMessages(inRoom: roomA)?.count, 2)
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomA)?.string, "draft A")
        XCTAssertEqual(reopened.legacyImportResult?.skipped ?? true, true, "второе открытие ничего не переносит")
        reopened.close()
    }

    func testOpenWithoutFileStoreGivesAnEmptyStore() throws {
        let store = makeStore()
        try open(store)
        XCTAssertNil(store.legacyImportResult, "папки нет — переноса нет")
        XCTAssertEqual(store.roomIds.count, 0)
        XCTAssertTrue(MXSQLiteStore.hasDatabase(forUserId: userId, rootDirectory: sandbox.directory))
        store.close()
    }

    func testFileStoreLeftAfterAnInterruptedSwitchIsRemovedWithoutDuplicates() throws {
        try writeLegacyRoom(roomA, outgoing: ["~a1"], draft: "first")
        let store = makeStore()
        try open(store)
        store.close()

        // Процесс умер между переносом и удалением папки: она снова на месте.
        try writeLegacyRoom(roomA, outgoing: ["~a1"], draft: "first")
        let reopened = makeStore()
        try open(reopened)
        XCTAssertEqual(reopened.outgoingMessages(inRoom: roomA)?.count, 1, "отметка в meta: второй раз не переносится")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        reopened.close()
    }

    func testDeactivationRemovesTheDatabaseAndTheKey() throws {
        let store = makeStore()
        try open(store)
        store.storePartialAttributedTextMessage(forRoom: roomA, partialAttributedTextMessage: NSAttributedString(string: "x"))
        store.close()
        XCTAssertTrue(MXSQLiteStore.hasDatabase(forUserId: userId, rootDirectory: sandbox.directory))

        XCTAssertTrue(MXSQLiteSessionStore.deactivate(for: credentials, rootDirectory: sandbox.directory, keyProvider: sandbox.keys))

        XCTAssertFalse(MXSQLiteStore.hasDatabase(forUserId: userId, rootDirectory: sandbox.directory))
        let identifier = MXSQLiteStore.keyIdentifier(forUserId: userId)
        XCTAssertThrowsError(try sandbox.keys.keyMaterial(forIdentifier: identifier, create: false), "ключ удалён")
    }

    func testFailedOpenIsRememberedSoTheNextLaunchFallsBack() throws {
        MXSQLiteSessionStore.clearOpenFailure(forUserId: userId)
        XCTAssertFalse(MXSQLiteSessionStore.hasOpenFailure(forUserId: userId))
        // Каталог базы занят обычным файлом: открыть нельзя.
        let url = MXSQLiteStore.databaseURL(forUserId: userId, rootDirectory: sandbox.directory)
        try Data("x".utf8).write(to: url.deletingLastPathComponent())
        let store = makeStore()
        XCTAssertThrowsError(try open(store))
        XCTAssertTrue(MXSQLiteSessionStore.hasOpenFailure(forUserId: userId))
        MXSQLiteSessionStore.clearOpenFailure(forUserId: userId)
    }
}
