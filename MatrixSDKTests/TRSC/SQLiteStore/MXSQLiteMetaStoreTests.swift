//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP3: мета сессии (`meta`), пользователи, фильтры.
final class MXSQLiteMetaStoreTests: XCTestCase {
    private var harness: MXSQLiteStoreHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    func testSessionMetaSurvivesReopen() throws {
        let store = harness.store
        XCTAssertNil(store.eventStreamToken)
        XCTAssertEqual(store.maxUploadSize, -1)

        store.eventStreamToken = "s_42"
        store.syncFilterId = "f1"
        store.userAccountData = ["m.push_rules": ["global": [:]]]
        store.areAllIdentityServerTermsAgreed = true
        store.storeMaxUploadSize(10_485_760)
        store.storeHomeserverWellknown(MXWellKnown(fromJSON: ["m.homeserver": ["base_url": "https://hs.example.org"]])!)
        store.storeSupportedMatrixVersions(MXMatrixVersions(fromJSON: [
            "versions": ["v1.6"], "unstable_features": ["im.trsc.event_count": true],
        ])!)
        XCTAssertEqual(store.eventStreamToken, "s_42", "read-your-writes before commit")

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.eventStreamToken, "s_42")
        XCTAssertEqual(reopened.syncFilterId, "f1")
        XCTAssertNotNil(reopened.userAccountData?["m.push_rules"])
        XCTAssertTrue(reopened.areAllIdentityServerTermsAgreed)
        XCTAssertEqual(reopened.maxUploadSize, 10_485_760)
        XCTAssertEqual(reopened.homeserverWellknown?.homeServer.baseUrl, "https://hs.example.org")
        XCTAssertEqual(reopened.supportedMatrixVersions?.supportsTrscEventCount, true)
    }

    func testTokenOverwriteKeepsOneRow() throws {
        harness.store.eventStreamToken = "a"
        harness.commit()
        harness.store.eventStreamToken = "b"
        harness.commit()
        XCTAssertEqual(harness.count("SELECT COUNT(*) FROM meta WHERE key = 'event_stream_token'"), 1)
        XCTAssertEqual(try harness.reopen().eventStreamToken, "b")
    }

    func testUsersSurviveReopen() throws {
        let alice = MXUser(userId: "@alice:x")!
        alice.setValue("Alice", forKey: "displayname")
        harness.store.store(alice)
        harness.store.store(MXUser(userId: "@bob:x")!)
        XCTAssertEqual(harness.store.user(withUserId: "@alice:x")?.displayname, "Alice")

        harness.commit()
        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.user(withUserId: "@alice:x")?.displayname, "Alice")
        XCTAssertNil(reopened.user(withUserId: "@nobody:x"))
        XCTAssertEqual(Set(reopened.users()?.map(\.userId) ?? []), ["@alice:x", "@bob:x"])
    }

    func testFiltersSurviveReopen() throws {
        let filter = MXFilterJSONModel.syncFilter(withMessageLimit: 10)!
        harness.store.storeFilter(filter, withFilterId: "f-10")
        harness.commit()

        let reopened = try harness.reopen()
        XCTAssertEqual(reopened.allFilterIds(), ["f-10"])
        var found: String?
        reopened.filterId(forFilter: filter, success: { found = $0 }, failure: nil)
        XCTAssertEqual(found, "f-10")
        var loaded: MXFilterJSONModel?
        reopened.filter(withFilterId: "f-10", success: { loaded = $0 }, failure: nil)
        XCTAssertEqual(loaded, filter)
    }

    func testDeleteAllDataForgetsMeta() throws {
        harness.store.eventStreamToken = "s"
        harness.commit()
        harness.store.deleteAllData()
        XCTAssertNil(harness.store.eventStreamToken)

        let reopened = try harness.reopen()
        XCTAssertNil(reopened.eventStreamToken)
    }
}
