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

@objcMembers
/// Room list data class. Subclassable.
open class MXRoomListData: NSObject {
    /// Array of rooms
    public let rooms: [MXRoomSummaryProtocol]
    /// Pagination size
    public let paginationOptions: MXRoomListDataPaginationOptions
    /// Counts on the data
    public let counts: MXRoomListDataCounts

    // Summaries are mutable and shared with previously published lists. Capture
    // comparison values now, before a local echo or sync updates those objects.
    // Array equality also preserves order, unlike the former XOR of room hashes.
    private let roomSnapshots: [RoomSnapshot]
    private let countsSnapshot: CountsSnapshot
    private let totalCountsSnapshot: CountsSnapshot?

    private struct RoomSnapshot: Hashable {
        let roomId: String
        let summaryHash: Int
        let lastMessageTimestamp: UInt64?
        let favoriteTagOrder: String?
    }

    private struct CountsSnapshot: Hashable {
        let rooms: Int
        let unsentRooms: Int
        let notifiedRooms: Int
        let highlightedRooms: Int
        let notifications: UInt
        let highlights: UInt
        let invitedRooms: Int

        init(_ counts: MXRoomListDataCounts) {
            rooms = counts.numberOfRooms
            unsentRooms = counts.numberOfUnsentRooms
            notifiedRooms = counts.numberOfNotifiedRooms
            highlightedRooms = counts.numberOfHighlightedRooms
            notifications = counts.numberOfNotifications
            highlights = counts.numberOfHighlights
            invitedRooms = counts.numberOfInvitedRooms
        }
    }
    
    /// Current page. Zero-based. 0 if pagination disabled
    public var currentPage: Int {
        if counts.numberOfRooms == 0 || paginationOptions == .none {
            return 0
        }
        return counts.numberOfRooms / paginationOptions.rawValue - (counts.numberOfRooms % paginationOptions.rawValue == 0 ? 1 : 0)
    }
    
    /// Flag to indicate whether more rooms exist in next pages
    public var hasMoreRooms: Bool {
        let totalNumberOfRooms = counts.total?.numberOfRooms ?? 0
        return counts.numberOfRooms < totalNumberOfRooms
    }
    
    /// Get room at index
    /// - Parameter index: index
    /// - Returns: room
    public func room(atIndex index: Int) -> MXRoomSummaryProtocol {
        guard index < rooms.count else {
            fatalError("Index out of range")
        }
        return rooms[index]
    }
    
    /// Initializer to be used when mocking data
    /// - Parameters:
    ///   - rooms: rooms
    ///   - counts: room counts instance
    ///   - paginationOptions: pagination options
    public init(rooms: [MXRoomSummaryProtocol],
                counts: MXRoomListDataCounts,
                paginationOptions: MXRoomListDataPaginationOptions) {
        self.rooms = rooms
        self.counts = counts
        self.paginationOptions = paginationOptions
        self.roomSnapshots = rooms.map {
            RoomSnapshot(roomId: $0.roomId,
                         summaryHash: $0.hash,
                         lastMessageTimestamp: $0.lastMessage?.originServerTs,
                         favoriteTagOrder: $0.favoriteTagOrder)
        }
        self.countsSnapshot = CountsSnapshot(counts)
        self.totalCountsSnapshot = counts.total.map(CountsSnapshot.init)
        super.init()
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? MXRoomListData else {
            return false
        }
        return paginationOptions == object.paginationOptions
            && roomSnapshots == object.roomSnapshots
            && countsSnapshot == object.countsSnapshot
            && totalCountsSnapshot == object.totalCountsSnapshot
    }
    
    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(paginationOptions.rawValue)
        hasher.combine(roomSnapshots)
        hasher.combine(countsSnapshot)
        hasher.combine(totalCountsSnapshot)
        return hasher.finalize()
    }
}
