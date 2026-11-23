//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// iP11: список чатов главной (`MXRoomListDataManager` по умолчанию — CoreData) работает на сторе SQLite:
/// сводки читаются одним запросом из той же базы, а не падают на «store is not CoreDataContextable».
final class MXSQLiteRoomListTests: XCTestCase {
    private final class Session: MXSession {
        private let testStore: MXStore
        init(store: MXStore) {
            testStore = store
            super.init(matrixRestClient: MXRestClient(credentials: MXCredentials(
                homeServer: "https://example.org", userId: "@harness:example.org", accessToken: "token")))
        }
        override var store: MXStore! {
            get { testStore }
            set {}
        }
    }

    private final class Delegate: MXRoomListDataFetcherDelegate {
        let changed: XCTestExpectation
        init(_ changed: XCTestExpectation) { self.changed = changed }
        func fetcherDidChangeData(_ fetcher: MXRoomListDataFetcher, totalCountsChanged: Bool) {
            changed.fulfill()
        }
    }

    private var harness: MXSQLiteStoreHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    private func store(rooms: Int) {
        for index in 0..<rooms {
            let summary = MXSQLiteRoomSummaryStoreTests.summary("!r\(index):x", ts: UInt64(1_000 + index))
            summary.membership = .join
            harness.store.roomSummaryStore.storeSummary(summary)
        }
        harness.commit()
    }

    private func options(_ pagination: MXRoomListDataPaginationOptions) -> MXRoomListDataFetchOptions {
        MXRoomListDataFetchOptions(filterOptions: MXRoomListDataFilterOptions(showAllRoomsInHomeSpace: true),
                                   sortOptions: MXRoomListDataSortOptions(missedNotificationsFirst: false, unreadMessagesFirst: false),
                                   paginationOptions: pagination)
    }

    func testDefaultManagerServesTheSQLiteStoreNewestFirst() {
        store(rooms: 5)
        let session = Session(store: harness.store)
        let manager = MXCoreDataRoomListDataManager()
        manager.configure(withSession: session)

        let fetcher = manager.fetcher(withOptions: options(.none))
        let delegate = Delegate(expectation(description: "data"))
        fetcher.addDelegate(delegate)
        fetcher.paginate()
        wait(for: [delegate.changed], timeout: 5)

        XCTAssertEqual(fetcher.data?.rooms.map(\.roomId), ["!r4:x", "!r3:x", "!r2:x", "!r1:x", "!r0:x"])
        fetcher.stop()
    }

    func testFirstPageStillCountsEveryRoom() {
        store(rooms: 30)
        let session = Session(store: harness.store)
        let manager = MXCoreDataRoomListDataManager()
        manager.configure(withSession: session)

        let fetcher = manager.fetcher(withOptions: options(.custom(10)))
        let delegate = Delegate(expectation(description: "data"))
        fetcher.addDelegate(delegate)
        fetcher.paginate()
        wait(for: [delegate.changed], timeout: 5)

        XCTAssertEqual(fetcher.data?.rooms.count, 10)
        XCTAssertEqual(fetcher.data?.rooms.first?.roomId, "!r29:x")
        XCTAssertEqual(fetcher.data?.counts.total?.numberOfRooms, 30)
        fetcher.stop()
    }
}
