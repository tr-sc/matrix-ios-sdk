//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Перенос черновиков и неотправленных из папки MXFileStore в новую базу при переключении (решение владельца).
final class MXSQLiteLegacyImportTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!
    private var legacy: URL!
    private let roomA = "!a:example.org"
    private let roomB = "!b:example.org"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
        legacy = harness.sandbox.directory.appendingPathComponent("MXFileStore/@harness:example.org", isDirectory: true)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func roomFolder(_ roomId: String) throws -> URL {
        let url = legacy.appendingPathComponent("rooms/\(roomId)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Архивы в формате MXFileStore: `outgoingMessages` и `messages` (MXFileRoomStore с историей и черновиком).
    private func writeLegacyRoom(_ roomId: String, outgoing: [MXEvent], draft: String?, history: Int = 50) throws {
        let folder = try roomFolder(roomId)
        if !outgoing.isEmpty {
            let store = MXFileRoomOutgoingMessagesStore()
            outgoing.forEach { store.storeOutgoingMessage($0) }
            try NSKeyedArchiver.archivedData(withRootObject: store, requiringSecureCoding: false)
                .write(to: folder.appendingPathComponent("outgoingMessages"))
        }
        let roomStore = MXFileRoomStore()
        for index in 0..<history {
            roomStore.store(MXSQLiteStoreHarness.message(eventId: "$h\(index)", roomId: roomId), direction: .forwards)
        }
        if let draft {
            roomStore.partialAttributedTextMessage = NSAttributedString(string: draft)
        }
        try NSKeyedArchiver.archivedData(withRootObject: roomStore, requiringSecureCoding: false)
            .write(to: folder.appendingPathComponent("messages"))
    }

    private func echo(_ localId: String, roomId: String) -> MXEvent {
        let event = MXSQLiteStoreHarness.message(eventId: localId, roomId: roomId, body: localId)
        event.sentState = MXEventSentStateFailed
        return event
    }

    func testImportsOutgoingAndDraftsButNotHistory() throws {
        try writeLegacyRoom(roomA, outgoing: [echo("~a1", roomId: roomA), echo("~a2", roomId: roomA)], draft: "draft A")
        try writeLegacyRoom(roomB, outgoing: [], draft: "draft B")
        try writeLegacyRoom("!empty:example.org", outgoing: [], draft: nil)

        let result = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store)
        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.outgoingCount, 2)
        XCTAssertEqual(result.draftCount, 2)
        XCTAssertEqual(result.roomCount, 2)

        // Импорт сразу на диске: переоткрытие без commit.
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.outgoingMessages(inRoom: roomA)?.compactMap(\.eventId), ["~a1", "~a2"])
        XCTAssertEqual(reopened.outgoingMessages(inRoom: roomA)?.first?.sentState, MXEventSentStateFailed)
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomA)?.string, "draft A")
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomB)?.string, "draft B")
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM event"), 0, "history is not imported")
    }

    func testImportRunsOnce() throws {
        try writeLegacyRoom(roomA, outgoing: [echo("~a1", roomId: roomA)], draft: "first")
        XCTAssertFalse(MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store).skipped)

        // Пользователь уже поменял черновик в новой базе; папка MXFileStore не удалилась.
        harness.store.storePartialAttributedTextMessage(forRoom: roomA, partialAttributedTextMessage: NSAttributedString(string: "newer"))
        harness.store.removeAllOutgoingMessages(fromRoom: roomA)
        harness.commit()

        let reopened = try harness.reopen()
        XCTAssertTrue(MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: reopened).skipped)
        XCTAssertEqual(reopened.partialAttributedTextMessage(ofRoom: roomA)?.string, "newer")
        XCTAssertEqual(reopened.outgoingMessages(inRoom: roomA)?.count, 0)
    }

    func testMissingFolderImportsNothingAndIsMarkedDone() throws {
        let result = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store)
        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.outgoingCount + result.draftCount, 0)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM meta WHERE key = 'legacy_import_done'"), 1)
    }

    func testCorruptArchivesAreSkipped() throws {
        let folder = try roomFolder(roomA)
        try Data("not an archive".utf8).write(to: folder.appendingPathComponent("outgoingMessages"))
        try Data("not an archive".utf8).write(to: folder.appendingPathComponent("messages"))
        try writeLegacyRoom(roomB, outgoing: [echo("~b1", roomId: roomB)], draft: nil)

        let result = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store)
        XCTAssertEqual(result.outgoingCount, 1)
        XCTAssertEqual(harness.store.outgoingMessages(inRoom: roomB)?.count, 1)
    }

    func testFailedFlushDoesNotMarkImportCompleteAndCanRetry() throws {
        try writeLegacyRoom(roomA, outgoing: [echo("~retry", roomId: roomA)], draft: "retry draft")
        try harness.database.exec("CREATE TRIGGER reject_outgoing BEFORE INSERT ON outgoing BEGIN SELECT RAISE(ABORT, 'test failure'); END")

        let failed = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store)
        XCTAssertFalse(failed.succeeded)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM meta WHERE key = 'legacy_import_done'"), 0)

        try harness.database.exec("DROP TRIGGER reject_outgoing")
        let retried = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: harness.store)
        XCTAssertTrue(retried.succeeded)
        XCTAssertEqual(harness.store.outgoingMessages(inRoom: roomA)?.compactMap(\.eventId), ["~retry"])
        XCTAssertEqual(harness.store.partialAttributedTextMessage(ofRoom: roomA)?.string, "retry draft")
    }

    func testRollbackExportPreservesDraftAndOutgoingForFileStoreImport() throws {
        harness.store.storeOutgoingMessage(forRoom: roomA, outgoingMessage: echo("~rollback", roomId: roomA))
        harness.store.storePartialAttributedTextMessage(forRoom: roomA, partialAttributedTextMessage: NSAttributedString(string: "rollback draft"))

        var exportError: NSError?
        XCTAssertTrue(MXSQLiteLegacyImport.exportLocalOnlyData(from: harness.store, toFileStoreAt: legacy, error: &exportError), "\(String(describing: exportError))")

        let destination = try MXSQLiteStoreHarness(self, name: "\(name)-rollback-destination")
        defer { destination.remove() }
        let imported = MXSQLiteLegacyImport.importFromFileStore(at: legacy, into: destination.store)
        XCTAssertTrue(imported.succeeded)
        XCTAssertEqual(destination.store.outgoingMessages(inRoom: roomA)?.compactMap(\.eventId), ["~rollback"])
        XCTAssertEqual(destination.store.partialAttributedTextMessage(ofRoom: roomA)?.string, "rollback draft")
    }

    func testDefaultFolderIsTheFileStoreLayout() {
        let url = MXSQLiteLegacyImport.fileStoreURL(forUserId: "@me:example.org")
        XCTAssertEqual(url.lastPathComponent, "@me:example.org")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MXFileStore")
    }
}
