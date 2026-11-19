//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import MatrixSDK
import XCTest

/// Временный каталог и ключи для тестов ядра SQLite-стора.
final class MXSQLiteTestSandbox {
    let directory: URL
    let keys = MXSQLiteMemoryKeyProvider()

    init(_ name: String = #function) {
        let safeName = name.replacingOccurrences(of: "()", with: "")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MXSQLiteTests", isDirectory: true)
            .appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var databaseURL: URL { directory.appendingPathComponent("store.sqlite") }

    func material(_ identifier: String = "test") throws -> MXSQLiteKeyMaterial {
        try keys.keyMaterial(forIdentifier: identifier, create: true)
    }

    func open(
        _ url: URL? = nil,
        material: MXSQLiteKeyMaterial? = nil,
        readOnly: Bool = false,
        readers: UInt = 2
    ) throws -> MXSQLiteDatabase {
        let keyMaterial = try material ?? self.material()
        return try MXSQLiteDatabase.open(
            at: url ?? databaseURL,
            key: keyMaterial.key,
            salt: keyMaterial.salt,
            readOnly: readOnly,
            readerCount: readers
        )
    }

    /// Открыть и привести схему к текущей версии.
    func openWithSchema(material: MXSQLiteKeyMaterial? = nil) throws -> MXSQLiteDatabase {
        let database = try open(material: material)
        try database.writer { connection in
            try MXSQLiteSchema.prepare(
                connection,
                targetVersion: MXSQLiteSchema.currentVersion,
                statements: MXSQLiteSchema.statements,
                migrations: [:],
                outcome: nil
            )
        }
        return database
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Все байты файла базы и её WAL.
    func rawBytes(of url: URL? = nil) -> Data {
        let base = url ?? databaseURL
        var data = Data()
        for suffix in ["", "-wal"] {
            if let chunk = FileManager.default.contents(atPath: base.path + suffix) {
                data.append(chunk)
            }
        }
        return data
    }
}

/// Тело с NSError** → Swift throws.
func mxsqliteBody(
    _ body: @escaping (MXSQLiteConnection) throws -> Void
) -> (MXSQLiteConnection, NSErrorPointer) -> Bool {
    { connection, errorPointer in
        do {
            try body(connection)
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }
}

extension MXSQLiteDatabase {
    /// Синхронная транзакция для тестов.
    func write(_ body: (MXSQLiteConnection) throws -> Void) throws {
        try withoutActuallyEscaping(body) { body in
            try writeSync(mxsqliteBody(body))
        }
    }

    /// Писатель без транзакции.
    func writer(_ body: (MXSQLiteConnection) throws -> Void) throws {
        try withoutActuallyEscaping(body) { body in
            try withWriter(mxsqliteBody(body))
        }
    }

    func readValue<T>(_ body: @escaping (MXSQLiteConnection) -> T?) -> T? {
        read { connection in body(connection) as Any? } as? T
    }
}

extension MXSQLiteConnection {
    func scalarInt(_ sql: String) -> Int64 {
        int64(forQuery: sql, defaultValue: Int64.min, error: nil)
    }

    func scalarText(_ sql: String) -> String? {
        try? string(forQuery: sql)
    }
}
