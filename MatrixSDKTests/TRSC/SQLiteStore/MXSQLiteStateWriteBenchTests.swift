//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Замер записи iP3/iP4 без сервера: большая комната и пачка квитанций. Время — транзакция писателя
/// (`MXStoreMetricsDelegate`) и вызов `storeState` на вызывающем потоке. Строки `[TRSC-STATE-BENCH]` в логе.
final class MXSQLiteStateWriteBenchTests: XCTestCase, MXStoreMetricsDelegate {
    private var harness: MXSQLiteStoreHarness!
    private var commits: [Double] = []
    private let lock = NSLock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MXSQLiteStoreHarness(self, name: name)
        harness.store.metricsDelegate = self
    }

    override func tearDown() {
        harness.remove()
        super.tearDown()
    }

    func store(_ store: MXTimelineStore, didCommitInMilliseconds milliseconds: Double, events: Int, rooms: Int) {
        lock.lock()
        commits.append(milliseconds)
        lock.unlock()
    }

    private func lastCommit() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return commits.last ?? -1
    }

    private func report(_ name: String, _ value: Double, _ extra: String = "") {
        print(String(format: "[TRSC-STATE-BENCH] %@ %.2f ms %@", name, value, extra))
    }

    private func members(_ count: Int, changed: Int? = nil) -> [MXEvent] {
        (0..<count).map { index in
            MXSQLiteStoreHarness.stateEvent(stateKey: "@u\(index):x", eventId: index == changed ? "$m\(index)-v2" : "$m\(index)",
                                            content: ["membership": "join", "displayname": "User \(index)"])
        }
    }

    func testRoomStateOfFiveThousandMembers() {
        let roomId = "!big:x"
        let full = members(5000)
        var start = CFAbsoluteTimeGetCurrent()
        harness.store.storeState(forRoom: roomId, stateEvents: full)
        report("state_store_call_initial", (CFAbsoluteTimeGetCurrent() - start) * 1000, "members=5000")
        harness.commit()
        report("state_commit_initial", lastCommit(), "rows=5000")

        var diffCalls: [Double] = []
        var diffCommits: [Double] = []
        for round in 0..<10 {
            let changed = members(5000, changed: round * 100)
            start = CFAbsoluteTimeGetCurrent()
            harness.store.storeState(forRoom: roomId, stateEvents: changed)
            diffCalls.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            harness.commit()
            diffCommits.append(lastCommit())
        }
        report("state_store_call_one_change_p50", diffCalls.sorted()[diffCalls.count / 2], "members=5000")
        report("state_commit_one_change_p50", diffCommits.sorted()[diffCommits.count / 2], "rows=1")
    }

    func testReceiptsOfOneSync() {
        // Одна пачка синка: 50 комнат × 20 пользователей.
        var calls: [Double] = []
        var syncCommits: [Double] = []
        for round in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            for room in 0..<50 {
                for user in 0..<20 {
                    let receipt = MXReceiptData()
                    receipt.userId = "@u\(user):x"
                    receipt.eventId = "$e\(round)-\(room)-\(user)"
                    receipt.ts = UInt64(1_700_000_000_000 + round * 1000 + user)
                    receipt.threadId = kMXEventTimelineMain
                    harness.store.storeReceipt(receipt, inRoom: "!r\(room):x")
                }
            }
            calls.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            harness.commit()
            syncCommits.append(lastCommit())
        }
        report("receipt_store_calls_1000_p50", calls.sorted()[calls.count / 2])
        report("receipt_commit_1000_p50", syncCommits.sorted()[syncCommits.count / 2], "rows=1000")
    }
}
