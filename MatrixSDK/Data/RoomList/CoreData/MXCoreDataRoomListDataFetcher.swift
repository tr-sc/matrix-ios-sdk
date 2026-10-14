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

private let kPropertyNameDataTypesInt: String = "s_dataTypesInt"
private let kPropertyNameSentStatusInt: String = "s_sentStatusInt"
private let kPropertyNameNotificationCount: String = "s_notificationCount"
private let kPropertyNameHighlightCount: String = "s_highlightCount"

internal typealias MXRoomSummaryCoreDataContextableStore = MXRoomSummaryStore & CoreDataContextable

@objcMembers
internal class MXCoreDataRoomListDataFetcher: NSObject, MXRoomListDataFetcher {
    
    private let multicastDelegate: MXMulticastDelegate<MXRoomListDataFetcherDelegate> = MXMulticastDelegate()
    
    internal let fetchOptions: MXRoomListDataFetchOptions
    private let dataUpdateDebounceInterval: TimeInterval
    private var pendingDataUpdate: DispatchWorkItem?
    private var dataUpdateGeneration: UInt = 0
    private var needsFetchAfterFailure = false

    /// Network state used by the last published snapshot. Content changes still
    /// arrive independently through the FRC / summary-store observers.
    private struct SlidingSyncListState: Equatable {
        let order: [String]
        let networkComplete: Bool
        let initialWindowIDs: [String]?
    }

    @nonobjc private var lastComputedSlidingSyncState: SlidingSyncListState?

    @nonobjc private var currentSlidingSyncState: SlidingSyncListState {
        SlidingSyncListState(order: session?.slidingSyncRoomOrder ?? [],
                            networkComplete: session?.roomListTotalsArePartial != true,
                            initialWindowIDs: session == nil ? [] : session?.slidingSyncInitialWindowRoomIds)
    }
    
    internal private(set) var data: MXRoomListData? {
        didSet {
            guard let data = data else {
                //  do not notify when stopped
                return
            }
            if data != oldValue {
                let totalCountsChanged: Bool
                if fetchOptions.paginationOptions == .none {
                    //  pagination disabled, we don't need to track number of rooms in this case
                    totalCountsChanged = true
                } else {
                    totalCountsChanged = oldValue?.counts.total?.numberOfRooms != data.counts.total?.numberOfRooms
                }
                notifyDataChange(totalCountsChanged: totalCountsChanged)
            }
        }
    }
    private let store: MXRoomSummaryCoreDataContextableStore
    private weak var session: MXSession?

    /// Inputs of the last complete `localStoreCoverage` answer. Every data update re-fetched
    /// all stored room IDs on the main context to answer it again; while the server order and
    /// the stored ID set stay the same, a complete answer stays complete. Incomplete answers
    /// (hydration) are never cached.
    private var completeCoverage: (serverOrder: [String], initialIDs: [String]?, networkComplete: Bool)?
    
    private lazy var fetchedResultsController: NSFetchedResultsController<MXRoomSummaryMO> = {
        let request = MXRoomSummaryMO.typedFetchRequest()
        request.predicate = filterPredicate(for: filterOptions)
        request.sortDescriptors = sortDescriptors(for: sortOptions)
        request.fetchLimit = fetchOptions.paginationOptions.rawValue
        return NSFetchedResultsController(fetchRequest: request,
                                          managedObjectContext: store.mainManagedObjectContext,
                                          sectionNameKeyPath: nil,
                                          cacheName: nil)
    }()
    
    private var totalRoomsCount: Int {
        let request = MXRoomSummaryMO.typedFetchRequest()
        request.predicate = filterPredicate(for: filterOptions)
        request.resultType = .countResultType
        do {
            return try store.mainManagedObjectContext.count(for: request)
        } catch let error {
            MXLog.error("[MXCoreDataRoomListDataFetcher] failed to count rooms", context: error)
            return 0
        }
    }
    
    private var totalCounts: MXRoomListDataCounts? {
        guard fetchOptions.paginationOptions != .none else {
            return nil
        }
        let request = MXRoomSummaryMO.genericFetchRequest()
        request.predicate = filterPredicate(for: filterOptions)
        let propertyNames: [String] = [
            kPropertyNameDataTypesInt,
            kPropertyNameSentStatusInt,
            kPropertyNameNotificationCount,
            kPropertyNameHighlightCount
        ]
        var properties: [NSPropertyDescription] = []
        
        for propertyName in propertyNames {
            guard let property = MXRoomSummaryMO.entity().propertiesByName[propertyName] else {
                fatalError("[MXCoreDataRoomSummaryStore] Couldn't find \(propertyName) on entity \(String(describing: MXRoomSummaryMO.self)), probably property name changed")
            }
            properties.append(property)
        }
        request.propertiesToFetch = properties
        var result: MXRoomListDataCounts?
        do {
            let summaries = try store.mainManagedObjectContext.fetch(request) as? [MXRoomSummaryMO]
            result = summaries.map {
                MXStoreRoomListDataCounts(withRooms: $0, total: nil)
            }
        } catch let error {
            MXLog.error("[MXCoreDataRoomListDataFetcher] failed to calculate total counts", context: error)
        }
        return result
    }
    
    internal init(fetchOptions: MXRoomListDataFetchOptions,
                  store: MXRoomSummaryCoreDataContextableStore,
                  session: MXSession? = nil,
                  dataUpdateDebounceInterval: TimeInterval = 0.2) {
        self.fetchOptions = fetchOptions
        self.store = store
        self.session = session
        self.dataUpdateDebounceInterval = dataUpdateDebounceInterval
        super.init()
        self.fetchOptions.fetcher = self
        self.fetchedResultsController.delegate = self
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(slidingSyncOrderUpdated(_:)),
                                               name: Notification.Name(rawValue: "MXSessionSlidingSyncRoomOrderDidChangeNotification"),
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(roomListProgressUpdated(_:)),
                                               name: Notification.Name(rawValue: "MXSessionRoomListStateDidChangeNotification"),
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(summaryStoreUpdated(_:)),
                                               name: .NSManagedObjectContextObjectsDidChange,
                                               object: store.mainManagedObjectContext)
    }
    
    //  MARK: - Delegate
    
    internal func addDelegate(_ delegate: MXRoomListDataFetcherDelegate) {
        multicastDelegate.addDelegate(delegate)
    }
    
    internal func removeDelegate(_ delegate: MXRoomListDataFetcherDelegate) {
        multicastDelegate.removeDelegate(delegate)
    }
    
    internal func removeAllDelegates() {
        multicastDelegate.removeAllDelegates()
    }
    
    //  MARK: - Data
    
    func paginate() {
        guard let oldData = data else {
            //  load first page
            performFetch(reason: "firstPage")
            return
        }
        
        guard oldData.hasMoreRooms else {
            //  no more rooms
            return
        }
        removeCacheIfRequired()
        let numberOfItems = (oldData.currentPage + 2) * oldData.paginationOptions.rawValue
        fetchedResultsController.fetchRequest.fetchLimit = numberOfItems > 0 ? numberOfItems : 0
        performFetch(reason: "paginate")
    }
    
    func resetPagination() {
        removeCacheIfRequired()
        let numberOfItems = fetchOptions.paginationOptions.rawValue
        fetchedResultsController.fetchRequest.fetchLimit = numberOfItems > 0 ? numberOfItems : 0
        performFetch(reason: "resetPagination")
    }
    
    func refresh() {
        guard let oldData = data else {
            // data will still be nil if the fetchRequest properties have changed before fetching the first page.
            // In this instance, update the fetchRequest so it is correctly configured for the first page fetch. 
            fetchedResultsController.fetchRequest.predicate = filterPredicate(for: filterOptions)
            fetchedResultsController.fetchRequest.sortDescriptors = sortDescriptors(for: sortOptions)
            fetchedResultsController.fetchRequest.fetchLimit = fetchOptions.paginationOptions.rawValue
            return
        }
        data = nil
        recomputeData(using: oldData)
    }
    
    func stop() {
        NotificationCenter.default.removeObserver(self)
        cancelPendingDataUpdate()
        fetchedResultsController.delegate = nil
        removeCacheIfRequired()
    }
    
    deinit {
        stop()
    }
    
    //  MARK: - Private
    
    private func removeCacheIfRequired() {
        if let cacheName = fetchedResultsController.cacheName {
            NSFetchedResultsController<NSFetchRequestResult>.deleteCache(withName: cacheName)
        }
    }
    
    private func performFetch(reason: String) {
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            MXLog.debug("[TrscRoomListPerf] fullFetch fetcher=\(ObjectIdentifier(self)) reason=\(reason) limit=\(fetchedResultsController.fetchRequest.fetchLimit) rows=\(fetchedResultsController.fetchedObjects?.count ?? 0) failed=\(needsFetchAfterFailure) ms=\(elapsedMS)")
        }
        #endif
        do {
            try fetchedResultsController.performFetch()
            needsFetchAfterFailure = false
            computeData()
        } catch let error {
            needsFetchAfterFailure = true
            MXLog.error("[MXCoreDataRoomListDataFetcher] failed to perform fetch", context: error)
        }
    }
    
    private func notifyDataChange(totalCountsChanged: Bool) {
        multicastDelegate.invoke({ $0.fetcherDidChangeData(self,
                                                           totalCountsChanged: totalCountsChanged) })
    }

    private func scheduleDataUpdate() {
        // Bound the wait from the first change. Preview backfill can save
        // summaries continuously; a trailing debounce would hide the full
        // room list until that unrelated work finishes.
        guard pendingDataUpdate == nil else { return }
        dataUpdateGeneration &+= 1
        let generation = dataUpdateGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.dataUpdateGeneration == generation else {
                return
            }
            self.pendingDataUpdate = nil
            self.computeData()
        }
        pendingDataUpdate = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dataUpdateDebounceInterval,
                                      execute: workItem)
    }

    private func cancelPendingDataUpdate() {
        pendingDataUpdate?.cancel()
        pendingDataUpdate = nil
        dataUpdateGeneration &+= 1
    }
    
    /// Recompute data with the same number of rooms of the given `data`
    private func recomputeData(using data: MXRoomListData) {
        removeCacheIfRequired()
        let numberOfItems = (data.currentPage + 1) * data.paginationOptions.rawValue
        fetchedResultsController.fetchRequest.predicate = filterPredicate(for: filterOptions)
        fetchedResultsController.fetchRequest.sortDescriptors = sortDescriptors(for: sortOptions)
        fetchedResultsController.fetchRequest.fetchLimit = numberOfItems > 0 ? numberOfItems : 0
        performFetch(reason: "recomputeData")
    }
    
    private func computeData() {
        // An explicit fetch may have already consumed the changes for which a
        // delayed update was queued. Do not build the same snapshot again.
        cancelPendingDataUpdate()
        guard let summaries = fetchedResultsController.fetchedObjects else {
            data = nil
            return
        }
        
        let fetchLimit = fetchedResultsController.fetchRequest.fetchLimit
        var mapped: [MXRoomSummary]
        
        if fetchLimit > 0 && summaries.count > fetchLimit {
            data = nil
            mapped = mapSummaries(summaries[0..<fetchLimit])
        } else {
            mapped = mapSummaries(summaries)
        }
        let syncState = currentSlidingSyncState
        let serverOrder = syncState.order
        if !serverOrder.isEmpty {
            let rank: [String: Int] = Dictionary(uniqueKeysWithValues: serverOrder.enumerated().map { ($1, $0) })
            // Keys are read once per room: inside the comparator every comparison bridged two
            // `roomId`s from NSString and looked both up, ~17k times for 1.5k rooms per update.
            // Spelled out with explicit types: as one chained expression Swift 6.2 (Xcode 26.3 on
            // CI) gave up type-checking it "in reasonable time".
            var ranked: [(rank: Int, ts: UInt64, summary: MXRoomSummary)] = []
            ranked.reserveCapacity(mapped.count)
            for summary in mapped {
                let position: Int = rank[summary.roomId] ?? Int.max
                let ts: UInt64 = summary.lastMessage?.originServerTs ?? 0
                ranked.append((rank: position, ts: ts, summary: summary))
            }
            ranked.sort { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.ts > rhs.ts
            }
            mapped = ranked.map { $0.summary }
        }
        let counts = MXStoreRoomListDataCounts(withRooms: mapped,
                                               total: totalCounts)
        let coverage = localStoreCoverage(syncState)
        // Set before publishing: delegates may synchronously request updates.
        lastComputedSlidingSyncState = syncState
        data = MXRoomListData(rooms: mapped,
                              counts: counts,
                              paginationOptions: fetchOptions.paginationOptions,
                              isRoomListSnapshotComplete: coverage.complete,
                              isInitialRoomListWindowReady: coverage.initialWindowReady)
        fetchedResultsController.delegate = self
    }

    /// Check identity coverage before section filters (archive, spaces, etc.).
    /// This runs on the same main context as the FRC and fetches identifiers
    /// only; it never waits for or decrypts the background summary queue.
    @nonobjc private func localStoreCoverage(_ state: SlidingSyncListState) -> (complete: Bool, initialWindowReady: Bool) {
        let serverOrder = state.order
        let networkComplete = state.networkComplete
        let initialIDs = state.initialWindowIDs
        guard !serverOrder.isEmpty else { return (networkComplete, initialIDs != nil) }
        if let cached = completeCoverage, cached.networkComplete == networkComplete,
           cached.initialIDs == initialIDs, cached.serverOrder == serverOrder {
            return (true, true)
        }
        let request = NSFetchRequest<NSDictionary>(entityName: MXRoomSummaryMO.entity().name!)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["s_identifier"]
        do {
            let records = try store.mainManagedObjectContext.fetch(request)
            let storedIDs = Set(records.compactMap { $0["s_identifier"] as? String })
            let missing = Set(serverOrder).subtracting(storedIDs)
            if networkComplete && !missing.isEmpty {
                MXLog.debug("[MXCoreDataRoomListDataFetcher] local snapshot incomplete: server=\(serverOrder.count) stored=\(storedIDs.count) missing=\(missing.count)")
            }
            let result = (complete: networkComplete && missing.isEmpty,
                          initialWindowReady: initialIDs.map { Set($0).isSubset(of: storedIDs) } ?? false)
            completeCoverage = result.complete && result.initialWindowReady
                ? (serverOrder, initialIDs, networkComplete)
                : nil
            return result
        } catch {
            MXLog.error("[MXCoreDataRoomListDataFetcher] cannot verify local snapshot coverage", context: error)
            return (false, false)
        }
    }

    @objc
    private func roomListProgressUpdated(_ notification: Notification) {
        // Every long-poll return re-posts the progress notification with nothing changed;
        // recomputing ~1.5k summaries on the main thread for it cost ~100 ms per response.
        guard currentSlidingSyncState != lastComputedSlidingSyncState else { return }
        scheduleDataUpdate()
    }

    @objc
    private func summaryStoreUpdated(_ notification: Notification) {
        // The stored ID set changed: the cached complete answer may no longer hold.
        if notification.userInfo?[NSInsertedObjectsKey] != nil
            || notification.userInfo?[NSDeletedObjectsKey] != nil
            || notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            completeCoverage = nil
        }
        // A section with zero matching rows may receive no FRC callback when
        // the final room belongs to another section. Its completeness must
        // still advance, or Home would stay partial indefinitely.
        guard data?.isRoomListSnapshotComplete == false,
              notification.userInfo?[NSInsertedObjectsKey] != nil
                || notification.userInfo?[NSDeletedObjectsKey] != nil
                || notification.userInfo?[NSUpdatedObjectsKey] != nil else { return }
        scheduleDataUpdate()
    }

    @objc
    private func slidingSyncOrderUpdated(_ notification: Notification) {
        let request = fetchedResultsController.fetchRequest
        let predicate = filterPredicate(for: filterOptions)
        // Server rank is applied in computeData, not in the Core Data query.
        // Insertions/deletions/summary changes are maintained by the FRC.
        // Only entering unrestricted mode, a new predicate (e.g. excluded
        // rooms), or an uninitialised FRC requires another database fetch.
        // Record all applicable reasons before changing the request. A fetch
        // may both retry a failure and apply a newly changed predicate.
        var fetchReasons: [String] = []
        if needsFetchAfterFailure { fetchReasons.append("retryAfterFailure") }
        if fetchedResultsController.fetchedObjects == nil { fetchReasons.append("uninitialized") }
        if request.fetchLimit != 0 { fetchReasons.append("removeLimit(\(request.fetchLimit))") }
        if request.predicate != predicate { fetchReasons.append("predicateChanged") }
        if !fetchReasons.isEmpty {
            request.fetchLimit = 0
            request.predicate = predicate
            performFetch(reason: "slidingSync:" + fetchReasons.joined(separator: ","))
        } else if currentSlidingSyncState != lastComputedSlidingSyncState {
            // Coalesce with progress and content notifications in this sync.
            scheduleDataUpdate()
        }
    }

    /// The session cache is pre-warmed before room-list fetchers are created.
    /// Reusing it avoids decrypting and unarchiving every persisted last message
    /// again whenever the FRC emits an update. A fresh detached snapshot keeps
    /// MXRoomListData's existing value/equality semantics.
    private func mapSummaries<S: Sequence>(_ summaries: S) -> [MXRoomSummary] where S.Element == MXRoomSummaryMO {
        var cacheMissCount = 0
        let mapped = summaries.compactMap { model -> MXRoomSummary? in
            if let cached = session?.cachedRoomSummary(withRoomId: model.s_identifier) {
                return MXRoomSummary(summaryModel: cached)
            }

            cacheMissCount += 1
            return MXRoomSummary(summaryModel: model)
        }

        if session != nil && cacheMissCount > 0 {
            MXLog.warning("[MXCoreDataRoomListDataFetcher] \(cacheMissCount) summaries were missing from the session cache")
        }
        return mapped
    }
    
}

//  MARK: MXRoomListDataSortable

extension MXCoreDataRoomListDataFetcher: MXRoomListDataSortable {
    
    var sortOptions: MXRoomListDataSortOptions {
        return fetchOptions.sortOptions
    }
    
    func sortDescriptors(for sortOptions: MXRoomListDataSortOptions) -> [NSSortDescriptor] {
        var result: [NSSortDescriptor] = []
        
        if sortOptions.alphabetical {
            result.append(NSSortDescriptor(key: "s_displayName", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:))))
        }
        
        if sortOptions.invitesFirst {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_membershipInt, ascending: true))
        }
        
        if sortOptions.sentStatus {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_sentStatusInt, ascending: false))
        }
        
        if sortOptions.missedNotificationsFirst {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_hasAnyHighlight, ascending: false))
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_hasAnyNotification, ascending: false))
        }
        
        if sortOptions.unreadMessagesFirst {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_hasAnyUnread, ascending: false))
        }
        
        if sortOptions.lastEventDate {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_lastMessage?.s_originServerTs, ascending: false))
        }
        
        if sortOptions.favoriteTag {
            result.append(NSSortDescriptor(keyPath: \MXRoomSummaryMO.s_favoriteTagOrder, ascending: false))
        }
        
        return result
    }
    
}

//  MARK: MXRoomListDataFilterable

extension MXCoreDataRoomListDataFetcher: MXRoomListDataFilterable {
    
    var filterOptions: MXRoomListDataFilterOptions {
        return fetchOptions.filterOptions
    }
    
    func filterPredicate(for filterOptions: MXRoomListDataFilterOptions) -> NSPredicate? {
        var predicates: [NSPredicate] = []
        if let excluded = session?.slidingSyncExcludedRoomIds, !excluded.isEmpty {
            predicates.append(NSPredicate(format: "NOT (%K IN %@)",
                                          #keyPath(MXRoomSummaryMO.s_identifier), Array(excluded).sorted()))
        }
        
        if !filterOptions.onlySuggested {
            if filterOptions.hideUnknownMembershipRooms {
                let memberPredicate = NSPredicate(format: "%K != %d",
                                                  #keyPath(MXRoomSummaryMO.s_membershipInt),
                                                  MXMembership.unknown.rawValue)
                predicates.append(memberPredicate)
            }
            
            //  data types
            if !filterOptions.dataTypes.isEmpty {
                let predicate: NSPredicate
                if filterOptions.strictMatches {
                    predicate = NSPredicate(format: "(%K & %d) == %d",
                                            #keyPath(MXRoomSummaryMO.s_dataTypesInt),
                                            filterOptions.dataTypes.rawValue,
                                            filterOptions.dataTypes.rawValue)

                } else {
                    predicate = NSPredicate(format: "(%K & %d) != 0",
                                            #keyPath(MXRoomSummaryMO.s_dataTypesInt),
                                            filterOptions.dataTypes.rawValue)
                }
                predicates.append(predicate)
            }
            
            //  not data types
            if !filterOptions.notDataTypes.isEmpty {
                let predicate = NSPredicate(format: "(%K & %d) == 0",
                                            #keyPath(MXRoomSummaryMO.s_dataTypesInt),
                                            filterOptions.notDataTypes.rawValue)
                predicates.append(predicate)
            }
            
            //  space
            if let space = filterOptions.space {
                //  specific space
                let predicate = NSPredicate(format: "%K CONTAINS[c] %@",
                                            #keyPath(MXRoomSummaryMO.s_parentSpaceIds),
                                            space.spaceId)
                predicates.append(predicate)
            } else {
                //  home space
                
                // In case of home space we show a room if one of the following conditions is true:
                // - Show All Rooms is enabled
                // - It's a direct room
                // - The room is a favourite
                // - The room is orphaned
                
                let predicate1 = NSPredicate(value: filterOptions.showAllRoomsInHomeSpace)
                
                let directDataTypes: MXRoomSummaryDataTypes = .direct
                let predicate2 = NSPredicate(format: "(%K & %d) != 0",
                                             #keyPath(MXRoomSummaryMO.s_dataTypesInt),
                                             directDataTypes.rawValue)
                
                let favoritedDataTypes: MXRoomSummaryDataTypes = .favorited
                let predicate3 = NSPredicate(format: "(%K & %d) != 0",
                                             #keyPath(MXRoomSummaryMO.s_dataTypesInt),
                                             favoritedDataTypes.rawValue)
                
                let predicate4 = NSPredicate(format: "%K MATCHES %@",
                                             #keyPath(MXRoomSummaryMO.s_parentSpaceIds),
                                             "^$")
                
                let predicate = NSCompoundPredicate(type: .or,
                                                    subpredicates: [predicate1, predicate2, predicate3, predicate4])
                predicates.append(predicate)
            }
        }
        
        //  query
        if let query = filterOptions.query, !query.isEmpty {
            let predicate = NSPredicate(format: "%K CONTAINS[cd] %@",
                                        #keyPath(MXRoomSummaryMO.s_displayName),
                                        query)
            predicates.append(predicate)
        }
        
        guard !predicates.isEmpty else {
            return nil
        }
        
        if predicates.count == 1 {
            return predicates.first
        }
        return NSCompoundPredicate(type: .and,
                                   subpredicates: predicates)
    }
    
}

//  MARK: - NSFetchedResultsControllerDelegate

extension MXCoreDataRoomListDataFetcher: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        scheduleDataUpdate()
    }
}
