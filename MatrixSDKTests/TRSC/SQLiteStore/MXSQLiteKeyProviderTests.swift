//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import Security
import XCTest

/// Ключи в Keychain: 32 + 16 байт, AfterFirstUnlockThisDeviceOnly, без синхронизации.
final class MXSQLiteKeyProviderTests: XCTestCase {
    private let provider = MXSQLiteKeychainKeyProvider(accessGroup: nil)
    private var identifier = ""

    override func setUp() {
        super.setUp()
        identifier = "test.\(UUID().uuidString)"
    }

    override func tearDown() {
        provider.removeKeyMaterial(forIdentifier: identifier)
        super.tearDown()
    }

    func testCreatesKeyOnceAndReturnsTheSameKeyLater() throws {
        let created = try provider.keyMaterial(forIdentifier: identifier, create: true)
        XCTAssertEqual(created.key.count, 32)
        XCTAssertEqual(created.salt.count, 16)
        XCTAssertNotEqual(created.key, Data(count: 32))

        let again = try provider.keyMaterial(forIdentifier: identifier, create: true)
        XCTAssertEqual(again.key, created.key)
        XCTAssertEqual(again.salt, created.salt)

        let readOnly = try provider.keyMaterial(forIdentifier: identifier, create: false)
        XCTAssertEqual(readOnly.key, created.key)
    }

    func testReadOnlyLookupNeverCreates() {
        XCTAssertThrowsError(try provider.keyMaterial(forIdentifier: identifier, create: false))
        XCTAssertThrowsError(try provider.keyMaterial(forIdentifier: identifier, create: false), "still nothing created")
    }

    func testRemoveThenCreateGivesANewKey() throws {
        let first = try provider.keyMaterial(forIdentifier: identifier, create: true)
        provider.removeKeyMaterial(forIdentifier: identifier)
        let second = try provider.keyMaterial(forIdentifier: identifier, create: true)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.salt, second.salt)
    }

    func testKeyIsDeviceOnlyAndAvailableAfterFirstUnlock() throws {
        _ = try provider.keyMaterial(forIdentifier: identifier, create: true)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MXSQLiteKeychainService,
            kSecAttrAccount as String: identifier,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func testDescriptionDoesNotLeakTheKey() throws {
        let material = try provider.keyMaterial(forIdentifier: identifier, create: true)
        let hex = material.key.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(material.description.contains(hex))
    }
}
