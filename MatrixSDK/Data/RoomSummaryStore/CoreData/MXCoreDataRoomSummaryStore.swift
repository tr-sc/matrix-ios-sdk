// 
// Copyright 2021 The Matrix.org Foundation C.I.C
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import CoreData

#if DEBUG
/// Aggregate across context queues without logging every saved room.
private final class MXSummaryWriteDiagnostics {
    private struct Sample {
        var count = 0
        var changed = 0
        var waitTotal = 0.0
        var waitMax = 0.0
        var mapTotal = 0.0
        var saveTotal = 0.0
        var saveMax = 0.0
        var started = ProcessInfo.processInfo.systemUptime
    }
    private let lock = NSLock()
    private var samples: [String: Sample] = [:]

    func record(stage: String, wait: TimeInterval, map: TimeInterval, save: TimeInterval, changed: Bool) {
        lock.lock()
        var sample = samples[stage] ?? Sample()
        sample.count += 1
        sample.changed += changed ? 1 : 0
        sample.waitTotal += wait
        sample.waitMax = max(sample.waitMax, wait)
        sample.mapTotal += map
        sample.saveTotal += save
        sample.saveMax = max(sample.saveMax, save)
        let report = sample.count >= 50 || ProcessInfo.processInfo.systemUptime - sample.started >= 1
        samples[stage] = report ? Sample() : sample
        lock.unlock()
        guard report else { return }
        let scale = 1000 / Double(sample.count)
        MXLog.debug("[MXCoreDataRoomSummaryStore] write_metrics stage=\(stage) operations=\(sample.count) changed=\(sample.changed) waitAvgMs=\(Int(sample.waitTotal * scale)) waitMaxMs=\(Int(sample.waitMax * 1000)) mapAvgMs=\(Int(sample.mapTotal * scale)) saveAvgMs=\(Int(sample.saveTotal * scale)) saveMaxMs=\(Int(sample.saveMax * 1000))")
    }
}
#endif

@objcMembers
public class MXCoreDataRoomSummaryStore: NSObject {
    
    private enum Constants {
        static let modelName: String = "MXCoreDataRoomSummaryStore"
        static let folderName: String = "MXCoreDataRoomSummaryStore"
        static let storeFileName: String = "RoomSummaryStore.sqlite"
    }
    
    private let credentials: MXCredentials
    // Accessed only on backgroundMoc. Each caller still enqueues in context
    // order; deletes and full reads flush staged writes before proceeding.
    private var pendingSummaries: [(summary: MXRoomSummaryProtocol, enqueued: TimeInterval)] = []
    private var summaryFlushScheduled = false
    private static let summaryBatchSize = 32
    #if DEBUG
    private let writeDiagnostics = MXSummaryWriteDiagnostics()
    #endif

    private lazy var persistenceCoordinator: NSPersistentStoreCoordinator = {
        let result = NSPersistentStoreCoordinator(managedObjectModel: Self.managedObjectModel)
        
        let options: [AnyHashable : Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        
        do {
            try result.addPersistentStore(ofType: NSSQLiteStoreType,
                                          configurationName: nil,
                                          at: storeURL,
                                          options: options)
        } catch {
            fatalError(error.localizedDescription)
        }
        return result
    }()
    
    private lazy var storeURL: URL = {
        guard let userId = credentials.userId else {
            fatalError("[MXCoreDataRoomSummaryStore] Credentials must provide a user identifier")
        }
        
        var cachePath: URL!
        if let container = FileManager.default.applicationGroupContainerURL() {
            cachePath = container
        } else {
            cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
        let folderUrl = cachePath.appendingPathComponent(Constants.folderName).appendingPathComponent(userId)
        try? FileManager.default.createDirectoryExcludedFromBackup(at: folderUrl)
        return folderUrl.appendingPathComponent(Constants.storeFileName)
    }()
    
    private static var managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: MXCoreDataRoomSummaryStore.self).url(forResource: Constants.modelName,
                                                                         withExtension: "momd") else {
            fatalError("[MXCoreDataRoomSummaryStore] No MXRoomSummaryStore Core Data model")
        }
        guard let result = NSManagedObjectModel(contentsOf: url) else {
            fatalError("[MXCoreDataRoomSummaryStore] Cannot create managed object model")
        }
        return result
    }()
    
    /// Managed object context to be used when inserting data, whose parent context is `mainMoc`.
    private lazy var backgroundMoc: NSManagedObjectContext = {
        let result = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        result.parent = mainMoc
        return result
    }()
    
    /// Managed object context to be used on main thread for fetching data, whose parent context is `persistentMoc`.
    private lazy var mainMoc: NSManagedObjectContext = {
        let result = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        result.parent = persistentMoc
        result.automaticallyMergesChangesFromParent = true
        return result
    }()
    /// Managed object context bound to persistent store coordinator.
    private lazy var persistentMoc: NSManagedObjectContext = {
        let result = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        result.persistentStoreCoordinator = persistenceCoordinator
        return result
    }()
    
    public init(withCredentials credentials: MXCredentials) {
        self.credentials = credentials
        super.init()
        //  create main context
        _ = mainMoc
    }
    
    //  MARK: - Private
    
    private func countRooms(in moc: NSManagedObjectContext) -> Int {
        let request = MXRoomSummaryMO.typedFetchRequest()
        request.includesSubentities = false
        request.includesPropertyValues = false
        request.resultType = .countResultType
        var result = 0
        moc.performAndWait {
            do {
                result = try moc.count(for: request)
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] countRooms failed", context: error)
            }
        }
        return result
    }
    
    private func fetchRoomIds(in moc: NSManagedObjectContext) -> [String] {
        let propertyName = "s_identifier"
        
        guard let property = MXRoomSummaryMO.entity().propertiesByName[propertyName] else {
            fatalError("[MXCoreDataRoomSummaryStore] Couldn't find \(propertyName) on entity \(String(describing: MXRoomSummaryMO.self)), probably property name changed")
        }
        let request = MXRoomSummaryMO.genericFetchRequest()
        request.includesSubentities = false
        //  only fetch room identifiers
        request.propertiesToFetch = [property]
        //  when specific properties set, use dictionary result type for issues seen mostly on iOS 12 devices
        request.resultType = .dictionaryResultType
        var result: [String] = []
        moc.performAndWait {
            do {
                if let dictionaries = try moc.fetch(request) as? [[String: Any]] {
                    //  other properties than 'propertyName' won't exist in the dictionary
                    result = dictionaries.compactMap({ $0[propertyName] as? String })
                }
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] fetchRoomIds failed", context: error)
            }
        }
        return result
    }
    
    private func fetchSummary(forRoomId roomId: String, in moc: NSManagedObjectContext) -> MXRoomSummary? {
        let request = MXRoomSummaryMO.typedFetchRequest()
        request.predicate = NSPredicate(format: "%K == %@",
                                        #keyPath(MXRoomSummaryMO.s_identifier),
                                        roomId)
        var result: MXRoomSummary? = nil
        moc.performAndWait {
            do {
                let results = try moc.fetch(request)
                if let model = results.first {
                    result = MXRoomSummary(summaryModel: model)
                }
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] fetchSummary failed", context: error)
            }
        }
        return result
    }
    
    /// Inline method to fetch a summary managed object. Only to be called in moc.perform blocks.
    private func fetchSummaryMO(forRoomId roomId: String, in moc: NSManagedObjectContext) -> MXRoomSummaryMO? {
        let request = MXRoomSummaryMO.typedFetchRequest()
        request.predicate = NSPredicate(format: "%K == %@",
                                        #keyPath(MXRoomSummaryMO.s_identifier),
                                        roomId)
        do {
            let results = try moc.fetch(request)
            return results.first
        } catch {
            MXLog.error("[MXCoreDataRoomSummaryStore] fetchSummary failed", context: error)
        }
        return nil
    }
    
    private func saveSummary(_ summary: MXRoomSummaryProtocol) {
        let moc = backgroundMoc
        let enqueued = ProcessInfo.processInfo.systemUptime
        moc.perform {
            self.pendingSummaries.append((summary, enqueued))
            if self.pendingSummaries.count >= Self.summaryBatchSize {
                self.flushPendingSummaries()
            }
            // No debounce timer: flush on the next context turn even if this
            // is the only write, or the app has just moved to the background.
            if !self.summaryFlushScheduled {
                self.summaryFlushScheduled = true
                moc.perform {
                    self.summaryFlushScheduled = false
                    self.flushPendingSummaries()
                }
            }
        }
    }

    /// Only called on backgroundMoc, with at most summaryBatchSize writes.
    private func flushPendingSummaries() {
        guard !pendingSummaries.isEmpty else { return }
        let writes = pendingSummaries
        pendingSummaries.removeAll(keepingCapacity: true)
        let moc = backgroundMoc
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let request = MXRoomSummaryMO.typedFetchRequest()
            request.predicate = NSPredicate(format: "%K IN %@", #keyPath(MXRoomSummaryMO.s_identifier),
                                            Array(Set(writes.map { $0.summary.roomId })))
            var models: [String: MXRoomSummaryMO] = [:]
            for model in try moc.fetch(request) { models[model.s_identifier] = model }
            for write in writes {
                let summary = write.summary
                if let existing = models[summary.roomId] {
                    existing.update(withRoomSummary: summary, in: moc)
                } else {
                    models[summary.roomId] = MXRoomSummaryMO.insert(roomSummary: summary, into: moc)
                }
            }
            // Allocate IDs for summaries and their related objects together.
            // Doing this inside each model update required multiple parent
            // context round trips for every room in a hydration response.
            let inserted = moc.insertedObjects.filter { $0.objectID.isTemporaryID }
            if !inserted.isEmpty { try moc.obtainPermanentIDs(for: Array(inserted)) }
            let mapped = ProcessInfo.processInfo.systemUptime
            let changed = moc.hasChanges
            saveIfNeeded(moc)
            #if DEBUG
            let finished = ProcessInfo.processInfo.systemUptime
            for write in writes {
                writeDiagnostics.record(stage: "summary", wait: started - write.enqueued,
                                        map: (mapped - started) / Double(writes.count),
                                        save: (finished - mapped) / Double(writes.count), changed: changed)
            }
            MXLog.debug("[MXCoreDataRoomSummaryStore] write_batch writes=\(writes.count) rooms=\(models.count) waitMaxMs=\(Int((started - (writes.map(\.enqueued).min() ?? started)) * 1000)) mapMs=\(Int((mapped - started) * 1000)) saveMs=\(Int((finished - mapped) * 1000))")
            #endif
        } catch {
            moc.rollback()
            MXLog.error("[MXCoreDataRoomSummaryStore] flushPendingSummaries failed", context: error)
        }
    }

    /// Drain writes submitted before this barrier through SQLite. Completion
    /// is asynchronous on main, matching MXFileStore's commit contract.
    @objc(flushWithCompletion:)
    public func flush(completion: @escaping () -> Void) {
        backgroundMoc.perform {
            self.flushPendingSummaries()
            self.mainMoc.perform {
                self.saveIfNeeded(self.mainMoc)
                self.persistentMoc.perform {
                    self.saveIfNeeded(self.persistentMoc)
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    private func deleteSummary(forRoomId roomId: String) {
        let moc = backgroundMoc
        
        moc.perform { [weak self] in
            guard let self = self else { return }
            self.flushPendingSummaries()
            if let existing = self.fetchSummaryMO(forRoomId: roomId, in: moc) {
                moc.delete(existing)
            }
            
            self.saveIfNeeded(moc)
        }
    }
    
    private func deleteAllSummaries() {
        let moc = backgroundMoc
        moc.performAndWait {
            // Earlier staged writes are superseded by this ordered deletion.
            self.pendingSummaries.removeAll(keepingCapacity: true)
            do {
                for model in try moc.fetch(MXRoomSummaryMO.typedFetchRequest()) {
                    moc.delete(model)
                }
                self.saveIfNeeded(moc)
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] deleteAllSummaries failed", context: error)
            }
        }
    }

    private func allSummaries(_ completion: @escaping ([MXRoomSummaryProtocol]) -> Void) {
        let request = MXRoomSummaryMO.typedFetchRequest()
        
        let moc = backgroundMoc
        
        moc.perform {
            self.flushPendingSummaries()
            do {
                let results = try moc.fetch(request)
                //  do not attempt to access other properties from the results
                let mapped = results.compactMap({ MXRoomSummary(summaryModel: $0) })
                DispatchQueue.main.async {
                    completion(mapped)
                }
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] fetchAllSummaries failed", context: error)
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
    
    /// Inline method to save a managed object context if needed. Only to be called in moc.perform blocks.
    private func saveIfNeeded(_ moc: NSManagedObjectContext) {
        guard moc.hasChanges else {
            return
        }

        var saved = false
        do {
            try moc.save()
            saved = true
        } catch {
            moc.rollback()
            MXLog.error("[MXCoreDataRoomSummaryStore] saveIfNeeded failed", context: error)
        }

        if saved {
            //  save all parent contexts recursively
            if let parent = moc.parent {
                #if DEBUG
                let enqueued = ProcessInfo.processInfo.systemUptime
                let stage = parent.concurrencyType == .mainQueueConcurrencyType ? "main" : "disk"
                #endif
                parent.perform {
                    #if DEBUG
                    let started = ProcessInfo.processInfo.systemUptime
                    let changed = parent.hasChanges
                    #endif
                    self.saveIfNeeded(parent)
                    #if DEBUG
                    self.writeDiagnostics.record(stage: stage, wait: started - enqueued, map: 0,
                                                 save: ProcessInfo.processInfo.systemUptime - started, changed: changed)
                    #endif
                }
            }
        }
    }
    
}

//  MARK: - MXRoomSummaryStore

extension MXCoreDataRoomSummaryStore: MXRoomSummaryStore {
    
    public var rooms: [String] {
        return fetchRoomIds(in: mainMoc)
    }
    
    public var countOfRooms: UInt {
        return UInt(countRooms(in: mainMoc))
    }
    
    public func storeSummary(_ summary: MXRoomSummaryProtocol) {
        saveSummary(summary)
    }
    
    public func summary(ofRoom roomId: String) -> MXRoomSummaryProtocol? {
        return fetchSummary(forRoomId: roomId, in: persistentMoc)
    }

    public func allSummariesSync() -> [MXRoomSummaryProtocol] {
        let moc = backgroundMoc
        var result: [MXRoomSummaryProtocol] = []
        moc.performAndWait {
            self.flushPendingSummaries()
            let request = MXRoomSummaryMO.typedFetchRequest()
            do {
                result = try moc.fetch(request).compactMap { MXRoomSummary(summaryModel: $0) }
            } catch {
                MXLog.error("[MXCoreDataRoomSummaryStore] allSummariesSync failed", context: error)
            }
        }
        return result
    }

    public func removeSummary(ofRoom roomId: String) {
        deleteSummary(forRoomId: roomId)
    }
    
    public func removeAllSummaries() {
        deleteAllSummaries()
    }
    
    public func fetchAllSummaries(_ completion: @escaping ([MXRoomSummaryProtocol]) -> Void) {
        allSummaries(completion)
    }
    
}

//  MARK: - CoreDataContextable

extension MXCoreDataRoomSummaryStore: CoreDataContextable {
    
    var mainManagedObjectContext: NSManagedObjectContext {
        return mainMoc
    }
    
}
