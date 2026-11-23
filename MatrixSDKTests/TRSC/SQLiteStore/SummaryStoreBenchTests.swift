//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Замер iP5 без сервера: 1500 комнат, CoreData (`MXCoreDataRoomSummaryStore`) против SQLite (`MXSQLiteRoomSummaryStore`).
/// Строки `[TRSC-SUMMARY-BENCH] <метрика> <стор> p50 … p90 … ms` в логе теста.
///
/// - чтение для первого кадра: SQLite — `summariesOrdered(byActivity: N)`; CoreData первых N не умеет, поэтому
///   `fetchAllSummaries` + сортировка по `lastMessage.originServerTs` (так главная получает их сегодня);
/// - запись при синке: вызов `storeSummary` на main и время до записи на диск (CoreData — `flush(completion:)`,
///   SQLite — `commit` с completion).
final class MXSQLiteRoomSummaryStoreBenchTests: XCTestCase {
    private let roomCount = 1_500
    private let iterations = 7

    private func report(_ metric: String, _ store: String, _ samples: [Double], _ extra: String = "") {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
        print(String(format: "[TRSC-SUMMARY-BENCH] %@ %@ p50 %.2f p90 %.2f ms n=%d %@",
                     metric, store, percentile(0.5), percentile(0.9), samples.count, extra))
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func roomSummaries(generation: Int, rooms: Range<Int>) -> [MXRoomSummary] {
        rooms.map { index in
            let summary = MXSQLiteRoomSummaryStoreTests.summary("!bench\(index):example.org",
                                                         ts: UInt64(1_700_000_000_000 + index * 1_000 + generation),
                                                         name: "Room \(index) with a longer display name",
                                                         unread: UInt(index % 7))
            summary.setValue("Topic of room \(index)", forKey: "topic")
            return summary
        }
    }

    private func wait(_ body: (@escaping () -> Void) -> Void) {
        let done = expectation(description: "done")
        body { done.fulfill() }
        wait(for: [done], timeout: 60)
    }

    /// `commit` фасада: синхронная часть на main (забор накладок и кодирование сводок) и ожидание записи.
    private func commitMeasuringMain(_ store: MXSQLiteStore) -> Double {
        let done = expectation(description: "commit")
        let main = milliseconds { store.commit { done.fulfill() } }
        wait(for: [done], timeout: 60)
        return main
    }

    // MARK: - SQLite

    func testSQLite() throws {
        let harness = try MXSQLiteStoreHarness(self, name: name)
        defer { harness.remove() }

        var calls: [Double] = []
        var durable: [Double] = []
        var commitsMain: [Double] = []
        let initial = roomSummaries(generation: 0, rooms: 0..<roomCount)
        var callMs = 0.0
        var commitMain = 0.0
        let total = milliseconds {
            callMs = milliseconds { initial.forEach { harness.store.roomSummaryStore.storeSummary($0) } }
            commitMain = commitMeasuringMain(harness.store)
        }
        report("write_initial_call", "sqlite", [callMs], "rooms=\(roomCount)")
        report("write_initial_commit_main", "sqlite", [commitMain], "rooms=\(roomCount)")
        report("write_initial_durable", "sqlite", [total], "rooms=\(roomCount)")

        for generation in 1...iterations * 3 {
            let changed = roomSummaries(generation: generation, rooms: (generation * 30 % roomCount)..<(generation * 30 % roomCount + 30))
            var call = 0.0
            let all = milliseconds {
                call = milliseconds { changed.forEach { harness.store.roomSummaryStore.storeSummary($0) } }
                commitsMain.append(commitMeasuringMain(harness.store))
            }
            calls.append(call)
            durable.append(all)
        }
        report("write_sync30_call", "sqlite", calls)
        report("write_sync30_commit_main", "sqlite", commitsMain)
        report("write_sync30_durable", "sqlite", durable)

        var opens: [Double] = []
        var firstN: [Int: [Double]] = [20: [], 50: []]
        var everything: [Double] = []
        for _ in 0..<iterations {
            harness.store.close()
            let store = harness.makeStore()
            opens.append(milliseconds { try? harness.open(store) })
            for limit in firstN.keys.sorted() {
                var top: [MXRoomSummaryProtocol] = []
                firstN[limit]!.append(milliseconds { top = store.summariesOrdered(byActivity: UInt(limit)) })
                XCTAssertEqual(top.count, limit)
            }
            var list: [MXRoomSummaryProtocol] = []
            everything.append(milliseconds { list = store.roomSummaryStore.allSummariesSync() })
            XCTAssertEqual(list.count, roomCount)
            store.close()
        }
        report("store_open", "sqlite", opens)
        for limit in firstN.keys.sorted() {
            report("read_first\(limit)", "sqlite", firstN[limit]!, "rooms=\(roomCount)")
        }
        report("read_all", "sqlite", everything, "rooms=\(roomCount)")
    }

    // MARK: - CoreData

    func testCoreData() throws {
        let userId = "@bench-\(UUID().uuidString):example.org"
        let credentials = MXCredentials(homeServer: "https://example.org", userId: userId, accessToken: "t")
        var store: MXCoreDataRoomSummaryStore! = MXCoreDataRoomSummaryStore(withCredentials: credentials)
        defer {
            // Не `removeAllSummaries`: из теста на main он ловит deadlock (`performAndWait` при ждущем сохранении
            // main-контекста). Папку стора удаляем целиком.
            store = nil
            let container = FileManager.default.applicationGroupContainerURL()
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: container.appendingPathComponent("MXCoreDataRoomSummaryStore")
                .appendingPathComponent(userId))
        }

        let initial = roomSummaries(generation: 0, rooms: 0..<roomCount)
        var callMs = 0.0
        let total = milliseconds {
            callMs = milliseconds { initial.forEach { store.storeSummary($0) } }
            wait { done in store.flush(completion: done) }
        }
        report("write_initial_call", "coredata", [callMs], "rooms=\(roomCount)")
        report("write_initial_durable", "coredata", [total], "rooms=\(roomCount)")

        var calls: [Double] = []
        var durable: [Double] = []
        for generation in 1...iterations * 3 {
            let changed = roomSummaries(generation: generation, rooms: (generation * 30 % roomCount)..<(generation * 30 % roomCount + 30))
            var call = 0.0
            let all = milliseconds {
                call = milliseconds { changed.forEach { store.storeSummary($0) } }
                wait { done in store.flush(completion: done) }
            }
            calls.append(call)
            durable.append(all)
        }
        report("write_sync30_call", "coredata", calls)
        report("write_sync30_durable", "coredata", durable)

        var opens: [Double] = []
        var firstN: [Int: [Double]] = [20: [], 50: []]
        var everything: [Double] = []
        for _ in 0..<iterations {
            store = MXCoreDataRoomSummaryStore(withCredentials: credentials)
            // Открытие файла у CoreData ленивое: первый count открывает persistent store.
            opens.append(milliseconds { _ = store.countOfRooms })
            // Первых N у CoreData нет: всё, сортировка, префикс.
            for limit in firstN.keys.sorted() {
                var top: [MXRoomSummaryProtocol] = []
                firstN[limit]!.append(milliseconds {
                    var all: [MXRoomSummaryProtocol] = []
                    wait { done in store.fetchAllSummaries { all = $0; done() } }
                    top = Array(all.sorted { ($0.lastMessage?.originServerTs ?? 0) > ($1.lastMessage?.originServerTs ?? 0) }.prefix(limit))
                })
                XCTAssertEqual(top.count, limit)
            }
            var list: [MXRoomSummaryProtocol] = []
            everything.append(milliseconds { wait { done in store.fetchAllSummaries { list = $0; done() } } })
            XCTAssertEqual(list.count, roomCount)
        }
        report("store_open", "coredata", opens)
        for limit in firstN.keys.sorted() {
            report("read_first\(limit)", "coredata", firstN[limit]!, "rooms=\(roomCount)")
        }
        report("read_all", "coredata", everything, "rooms=\(roomCount)")
    }
}
