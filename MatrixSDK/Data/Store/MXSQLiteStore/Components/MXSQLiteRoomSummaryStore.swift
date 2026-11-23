//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import Foundation

/**
 Сводки комнат в таблице `summary` базы `MXSQLiteStore` (ADR-0022 §1.9, iP5).

 Запись — накладкой, как у компонентов стора: `storeSummary` сразу виден чтению, на диск сводка уходит в общей
 транзакции `commit` вместе с событиями и токеном синка. Кодирование (`NSKeyedArchiver`) — при `takePendingWrites`
 на потоке коммита (main), а не в теле транзакции: сводку меняет main, а несколько сохранений одной комнаты между
 коммитами кодируются один раз.

 `last_ts` — `lastMessage.originServerTs`, по нему `summariesOrdered(byActivity:)` отдаёт первые N для первого
 кадра главной без чтения всех сводок.
 */
@objcMembers
public final class MXSQLiteRoomSummaryStore: NSObject, MXSQLiteStoreComponent {

    private let context: MXSQLiteStoreContext
    private let lock = NSLock()
    /// roomId → сводка или `nil`-надгробие. После последнего `takePendingWrites`.
    private var pending: [String: MXRoomSummaryProtocol?] = [:]
    /// Отданные коммиту и ещё не подтверждённые партии, от старой к новой.
    private var inflight: [Batch] = []
    /// `removeAllSummaries` до следующего коммита: строки базы не видны.
    private var pendingClear = false

    private struct Batch {
        var writes: [String: MXRoomSummaryProtocol?]
        var clears: Bool
    }

    public init(context: MXSQLiteStoreContext) {
        self.context = context
        super.init()
    }

    // MARK: - Overlay

    /// Незакоммиченное: pending поверх партий в полёте. Значение `.some(nil)` — сводка удалена.
    private func overlaySnapshot() -> (writes: [String: MXRoomSummaryProtocol?], hidesDatabase: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // Слои от старого к новому; очистка в слое прячет базу и всё, что старше неё.
        var writes: [String: MXRoomSummaryProtocol?] = [:]
        var hidesDatabase = false
        for batch in inflight + [Batch(writes: pending, clears: pendingClear)] {
            if batch.clears {
                writes.removeAll()
                hidesDatabase = true
            }
            writes.merge(batch.writes) { $1 }
        }
        return (writes, hidesDatabase)
    }

    private func overlayValue(forRoom roomId: String) -> (found: Bool, summary: MXRoomSummaryProtocol?, hidesDatabase: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let value = pending[roomId] {
            return (true, value, true)
        }
        var hidesDatabase = pendingClear
        if hidesDatabase {
            return (false, nil, true)
        }
        for batch in inflight.reversed() {
            if let value = batch.writes[roomId] {
                return (true, value, true)
            }
            if batch.clears {
                hidesDatabase = true
                break
            }
        }
        return (false, nil, hidesDatabase)
    }

    private static func activity(of summary: MXRoomSummaryProtocol) -> Int64 {
        Int64(clamping: summary.lastMessage?.originServerTs ?? 0)
    }

    private static func archive(_ summary: MXRoomSummaryProtocol) -> Data? {
        let object = (summary as? MXRoomSummary) ?? MXRoomSummary(summaryModel: summary)
        return MXSQLiteArchive(object)
    }

    private static func unarchive(_ data: Data?) -> MXRoomSummary? {
        MXSQLiteUnarchive(data) as? MXRoomSummary
    }

    // MARK: - Database reads

    private struct Row {
        let roomId: String
        let activity: Int64
        let data: Data?
    }

    private func readRows(_ sql: String, bind: ((MXSQLiteStatement) -> Void)? = nil, withData: Bool) -> [Row] {
        guard let database = context.database else { return [] }
        let rows = database.read { connection -> Any? in
            try? connection.query(sql, bind: bind) { statement -> Any? in
                guard let roomId = statement.text(at: 0) else { return nil }
                return Row(roomId: roomId, activity: statement.int64(at: 1), data: withData ? statement.blob(at: 2) : nil)
            }
        }
        return (rows as? [Any])?.compactMap { $0 as? Row } ?? []
    }

    private static let selectAll = "SELECT r.room_id, s.last_ts, s.data FROM summary s JOIN room r ON r.rid = s.rid"

    // MARK: - Cold start

    /// Первые `limit` по убыванию `lastMessage.originServerTs`, накладка учтена.
    public func summariesOrdered(byActivity limit: UInt) -> [MXRoomSummaryProtocol] {
        guard limit > 0 else { return [] }
        let overlay = overlaySnapshot()
        var candidates: [(activity: Int64, roomId: String, summary: MXRoomSummaryProtocol?, data: Data?)] = []
        for case let (roomId, summary?) in overlay.writes {
            candidates.append((Self.activity(of: summary), roomId, summary, nil))
        }
        if !overlay.hidesDatabase {
            // Каждый ключ накладки вытесняет не больше одной строки базы — берём с запасом на них.
            let fetch = Int64(limit) + Int64(overlay.writes.count)
            let rows = readRows(Self.selectAll + " ORDER BY s.last_ts DESC LIMIT ?1",
                                bind: { $0.bindInt64(fetch, at: 1) }, withData: true)
            for row in rows where overlay.writes[row.roomId] == nil {
                candidates.append((row.activity, row.roomId, nil, row.data))
            }
        }
        // Стабильная сортировка: при равной активности строки базы идут в порядке индекса.
        let ordered = candidates.enumerated().sorted {
            $0.element.activity != $1.element.activity ? $0.element.activity > $1.element.activity : $0.offset < $1.offset
        }
        return ordered.prefix(Int(limit)).compactMap { $0.element.summary ?? Self.unarchive($0.element.data) }
    }

    // MARK: - MXSQLiteStoreComponent

    public func takePendingWrites() -> MXSQLiteCommitBody? {
        lock.lock()
        guard !pending.isEmpty || pendingClear else {
            lock.unlock()
            return nil
        }
        let batch = Batch(writes: pending, clears: pendingClear)
        pending = [:]
        pendingClear = false
        inflight.append(batch)
        lock.unlock()

        var upserts: [(roomId: String, activity: Int64, data: Data)] = []
        var deletions: [String] = []
        for (roomId, summary) in batch.writes {
            if let summary, let data = Self.archive(summary) {
                upserts.append((roomId, Self.activity(of: summary), data))
            } else if summary == nil {
                deletions.append(roomId)
            }
        }
        let rooms = context.rooms

        return { connection, _, error in
            do {
                if batch.clears {
                    try connection.run("DELETE FROM summary", bind: nil)
                }
                for roomId in deletions {
                    let rid = rooms.rid(forRoomId: roomId, connection: connection)
                    if rid != MXSQLiteNoRoom {
                        try connection.run("DELETE FROM summary WHERE rid = ?1") { $0.bindInt64(rid, at: 1) }
                    }
                }
                for upsert in upserts {
                    let rid = rooms.ensureRid(forRoomId: upsert.roomId, connection: connection, error: error)
                    if rid == MXSQLiteNoRoom {
                        return false
                    }
                    try connection.run("INSERT INTO summary (rid, last_ts, data) VALUES (?1, ?2, ?3) "
                                       + "ON CONFLICT(rid) DO UPDATE SET last_ts = excluded.last_ts, data = excluded.data") {
                        $0.bindInt64(rid, at: 1)
                        $0.bindInt64(upsert.activity, at: 2)
                        $0.bindBlob(upsert.data, at: 3)
                    }
                }
                return true
            } catch let caught {
                error?.pointee = caught as NSError
                return false
            }
        }
    }

    public func didFinishPendingWrites(_ committed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !inflight.isEmpty else { return }
        let batch = inflight.removeFirst()
        guard !committed else { return }
        // Откат: вернуть то, что с тех пор не переписано.
        let newer = inflight.reduce(into: Set(pending.keys)) { $0.formUnion($1.writes.keys) }
        let superseded = pendingClear || inflight.contains { $0.clears }
        if !superseded {
            for (roomId, summary) in batch.writes where !newer.contains(roomId) {
                pending[roomId] = summary
            }
            if batch.clears {
                pendingClear = true
            }
        }
    }

    public func didDeleteAllData() {
        lock.lock()
        pending = [:]
        pendingClear = false
        // Партии остаются (подтверждения ещё придут и снимут их по одной), но пустыми.
        inflight = inflight.map { _ in Batch(writes: [:], clears: false) }
        lock.unlock()
    }
}

// MARK: - MXRoomSummaryStore

extension MXSQLiteRoomSummaryStore: MXRoomSummaryStore {

    public var rooms: [String] {
        let overlay = overlaySnapshot()
        var result = Set<String>()
        if !overlay.hidesDatabase {
            result.formUnion(readRows("SELECT r.room_id, 0 FROM summary s JOIN room r ON r.rid = s.rid", withData: false).map(\.roomId))
        }
        for (roomId, summary) in overlay.writes {
            if summary == nil {
                result.remove(roomId)
            } else {
                result.insert(roomId)
            }
        }
        return Array(result)
    }

    public var countOfRooms: UInt {
        let overlay = overlaySnapshot()
        if overlay.writes.isEmpty && !overlay.hidesDatabase, let database = context.database {
            let count = database.read { connection -> Any? in
                connection.int64(forQuery: "SELECT COUNT(*) FROM summary", defaultValue: 0, error: nil) as NSNumber
            } as? NSNumber
            return UInt(count?.int64Value ?? 0)
        }
        return UInt(rooms.count)
    }

    public func storeSummary(_ summary: MXRoomSummaryProtocol) {
        lock.lock()
        pending[summary.roomId] = .some(summary)
        lock.unlock()
    }

    public func summary(ofRoom roomId: String) -> MXRoomSummaryProtocol? {
        let overlay = overlayValue(forRoom: roomId)
        if overlay.found || overlay.hidesDatabase {
            return overlay.summary
        }
        let rows = readRows(Self.selectAll + " WHERE r.room_id = ?1", bind: { $0.bindText(roomId, at: 1) }, withData: true)
        return Self.unarchive(rows.first?.data)
    }

    public func allSummariesSync() -> [MXRoomSummaryProtocol] {
        let overlay = overlaySnapshot()
        var result: [MXRoomSummaryProtocol] = overlay.writes.values.compactMap { $0 }
        if !overlay.hidesDatabase {
            for row in readRows(Self.selectAll, withData: true) where overlay.writes[row.roomId] == nil {
                if let summary = Self.unarchive(row.data) {
                    result.append(summary)
                }
            }
        }
        return result
    }

    public func removeSummary(ofRoom roomId: String) {
        lock.lock()
        pending[roomId] = .some(nil)
        lock.unlock()
    }

    public func removeAllSummaries() {
        lock.lock()
        pending = [:]
        // Без базы (до open, после deleteAllData) прятать нечего.
        pendingClear = context.database != nil
        if !pendingClear {
            inflight = inflight.map { _ in Batch(writes: [:], clears: false) }
        }
        lock.unlock()
    }

    /// Чтение и разархивирование вне main, completion — на main (контракт `MXCoreDataRoomSummaryStore`).
    public func fetchAllSummaries(_ completion: @escaping ([MXRoomSummaryProtocol]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = self.allSummariesSync()
            DispatchQueue.main.async {
                completion(summaries)
            }
        }
    }
}
