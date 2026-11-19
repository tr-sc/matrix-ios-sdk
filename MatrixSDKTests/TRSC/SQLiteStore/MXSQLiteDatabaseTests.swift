//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Ядро SQLCipher (ADR-0022 §iOS): ключ без KDF, открытый заголовок, fail-closed, писатель и читатели.
final class MXSQLiteDatabaseTests: XCTestCase {
    private var sandbox: MXSQLiteTestSandbox!

    override func setUp() {
        super.setUp()
        sandbox = MXSQLiteTestSandbox(name)
    }

    override func tearDown() {
        MXSQLiteDatabase.setCipherVersionQueryForTesting(nil)
        sandbox.remove()
        super.tearDown()
    }

    private let marker = "TRSC-PLAINTEXT-MARKER-3f1c9a"

    private func insertMarker(_ database: MXSQLiteDatabase, rows: Int = 50) throws {
        try database.write { connection in
            for index in 0..<rows {
                try connection.run("INSERT INTO meta (key, value) VALUES (?1, ?2)") { statement in
                    statement.bindText("\(self.marker)-\(index)", at: 1)
                    statement.bindBlob(Data("\(self.marker) body \(index)".utf8), at: 2)
                }
            }
        }
    }

    // MARK: - Encryption on disk

    func testFileIsCiphertextWithPlaintextSQLiteHeader() throws {
        let database = try sandbox.openWithSchema()
        try insertMarker(database)

        // До чекпойнта данные лежат в WAL — он тоже должен быть шифротекстом.
        let walBytes = sandbox.rawBytes()
        XCTAssertNil(walBytes.range(of: Data(marker.utf8)), "plaintext in the database or its WAL")

        database.checkpoint(.truncate)
        database.close()

        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: sandbox.databaseURL.path))
        XCTAssertGreaterThan(bytes.count, 4096)
        XCTAssertNil(bytes.range(of: Data(marker.utf8)), "plaintext in the database file")
        XCTAssertNil(bytes.range(of: Data("CREATE TABLE".utf8)), "schema is readable without the key")

        // Первые 16 байт — заголовок SQLite: iOS видит базу SQLite и не убивает приложение с 0xdead10cc
        // за блокировку файла в app group. Соль в файле не хранится.
        XCTAssertEqual(bytes.prefix(16), Data("SQLite format 3\0".utf8))
    }

    func testPlainSQLiteHeaderDoesNotLeakSalt() throws {
        let material = try sandbox.material()
        let database = try sandbox.openWithSchema(material: material)
        database.checkpoint(.truncate)
        database.close()

        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: sandbox.databaseURL.path))
        XCTAssertNil(bytes.range(of: material.salt), "the salt must live in the Keychain, not in the file")
        XCTAssertNil(bytes.range(of: material.key))
    }

    // MARK: - Linking: SQLCipher, not the sqlite3 copy inside MatrixSDKCrypto

    func testCipherIsLinked() throws {
        let database = try sandbox.open()
        XCTAssertFalse(database.cipherVersion.isEmpty)
        XCTAssertTrue(
            MXSQLiteDatabase.sqliteLibraryPath.contains("SQLCipher"),
            "MatrixSDK resolves sqlite3_open_v2 into \(MXSQLiteDatabase.sqliteLibraryPath)"
        )
        XCTAssertFalse(MXSQLiteDatabase.sqliteLibraryPath.contains("MatrixSDKCrypto"))
    }

    func testOpenFailsClosedWithoutCipher() {
        // Как если бы sqlite3_* разрешились в MatrixSDKCrypto: cipher_version пустой.
        MXSQLiteDatabase.setCipherVersionQueryForTesting("SELECT ''")
        XCTAssertThrowsError(try sandbox.open()) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, MXSQLiteErrorDomain)
            XCTAssertEqual(error.code, MXSQLiteError.Code.cipherUnavailable.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.databaseURL.path + "-wal"))
    }

    // MARK: - Keys

    func testReopenWithSameKeyReadsData() throws {
        let material = try sandbox.material()
        let database = try sandbox.openWithSchema(material: material)
        try insertMarker(database, rows: 3)
        database.close()

        let reopened = try sandbox.open(material: material)
        let count = reopened.readValue { $0.scalarInt("SELECT count(*) FROM meta") }
        XCTAssertEqual(count, 3)
        reopened.close()
    }

    func testWrongKeyIsRejected() throws {
        let database = try sandbox.openWithSchema()
        database.close()

        let other = try sandbox.keys.keyMaterial(forIdentifier: "other", create: true)
        XCTAssertThrowsError(try sandbox.open(material: other)) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.keyRejected.rawValue)
        }
    }

    func testWrongSaltIsRejected() throws {
        let material = try sandbox.material()
        let database = try sandbox.openWithSchema(material: material)
        database.close()

        var salt = material.salt
        salt[0] ^= 0xff
        let wrongSalt = MXSQLiteKeyMaterial(key: material.key, salt: salt)
        XCTAssertThrowsError(try sandbox.open(material: wrongSalt)) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.keyRejected.rawValue)
        }
    }

    func testInvalidKeyLengthIsRejected() {
        XCTAssertThrowsError(try sandbox.open(material: MXSQLiteKeyMaterial(key: Data(count: 16), salt: Data(count: 16)))) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.invalidKey.rawValue)
        }
        XCTAssertThrowsError(try sandbox.open(material: MXSQLiteKeyMaterial(key: Data(count: 32), salt: Data(count: 8)))) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.invalidKey.rawValue)
        }
    }

    func testReopenIsFast() throws {
        let material = try sandbox.material()
        try sandbox.openWithSchema(material: material).close()

        // Без KDF открытие — это файлы и PRAGMA. Медиана из пяти, чтобы не мигать от планировщика.
        var timings: [Double] = []
        for _ in 0..<5 {
            let database = try sandbox.open(material: material)
            timings.append(database.openMilliseconds)
            database.close()
        }
        let median = timings.sorted()[timings.count / 2]
        XCTAssertLessThan(median, 20, "reopen took \(timings) ms")
    }

    // MARK: - Pragmas

    func testWriterPragmas() throws {
        let database = try sandbox.openWithSchema()
        var journal: String?
        var plaintextHeader: Int64 = 0
        var foreignKeys: Int64 = -1
        try database.writer { connection in
            journal = connection.scalarText("PRAGMA journal_mode")
            plaintextHeader = connection.scalarInt("PRAGMA cipher_plaintext_header_size")
            foreignKeys = connection.scalarInt("PRAGMA foreign_keys")
        }
        XCTAssertEqual(journal, "wal")
        XCTAssertEqual(plaintextHeader, 32)
        XCTAssertEqual(foreignKeys, 0)

        let queryOnly = database.readValue { $0.scalarInt("PRAGMA query_only") }
        XCTAssertEqual(queryOnly, 1, "readers must not write")
    }

    // MARK: - Transactions and threads

    func testFailedTransactionRollsBack() throws {
        let database = try sandbox.openWithSchema()
        XCTAssertThrowsError(try database.write { connection in
            try connection.run("INSERT INTO meta (key, value) VALUES ('a', x'00')", bind: nil)
            throw NSError(domain: "test", code: 1)
        })
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM meta") }, 0)
    }

    func testAsyncWriteIsVisibleToReadersAfterCompletion() throws {
        let database = try sandbox.openWithSchema()
        let done = expectation(description: "write")
        database.write({ connection, errorPointer in
            do {
                try connection.run("INSERT INTO meta (key, value) VALUES ('async', x'01')", bind: nil)
                return true
            } catch {
                errorPointer?.pointee = error as NSError
                return false
            }
        }, completion: { error in
            XCTAssertNil(error)
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM meta WHERE key = 'async'") }, 1)
    }

    func testReadsFromTwoThreadsWhileWriting() throws {
        let database = try sandbox.openWithSchema()
        try insertMarker(database, rows: 10)

        let writes = expectation(description: "writes")
        DispatchQueue.global().async {
            for index in 0..<100 {
                try? database.write { connection in
                    try connection.run("INSERT INTO meta (key, value) VALUES (?1, x'02')") { statement in
                        statement.bindText("w\(index)", at: 1)
                    }
                }
            }
            writes.fulfill()
        }

        let lock = NSLock()
        var observed: [Int64] = []
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            for _ in 0..<200 {
                let count = database.readValue { $0.scalarInt("SELECT count(*) FROM meta") } ?? -1
                lock.lock()
                observed.append(count)
                lock.unlock()
            }
        }
        wait(for: [writes], timeout: 30)

        XCTAssertEqual(observed.count, 400)
        XCTAssertTrue(observed.allSatisfy { $0 >= 10 && $0 <= 110 }, "a reader saw a torn or failed state")
        XCTAssertEqual(database.readValue { $0.scalarInt("SELECT count(*) FROM meta") }, 110)
    }

    func testReadOnlyDatabaseHasNoWriter() throws {
        let material = try sandbox.material()
        let database = try sandbox.openWithSchema(material: material)
        try insertMarker(database, rows: 2)
        database.close()

        let readOnly = try sandbox.open(material: material, readOnly: true, readers: 1)
        XCTAssertTrue(readOnly.readOnly)
        XCTAssertEqual(readOnly.readValue { $0.scalarInt("SELECT count(*) FROM meta") }, 2)
        XCTAssertThrowsError(try readOnly.write { _ in }) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.closed.rawValue)
        }
        readOnly.close()
    }

    func testReadOnlyOpenOfMissingFileFails() {
        XCTAssertThrowsError(try sandbox.open(readOnly: true)) { error in
            XCTAssertEqual((error as NSError).code, MXSQLiteError.Code.openFailed.rawValue)
        }
    }

    func testClosedDatabaseRefusesWork() throws {
        let database = try sandbox.openWithSchema()
        database.close()
        database.close()
        XCTAssertTrue(database.isClosed)
        XCTAssertNil(database.read { _ in NSNumber(value: 1) })
        XCTAssertThrowsError(try database.write { _ in })
    }
}
