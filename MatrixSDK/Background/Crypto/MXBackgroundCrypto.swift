// 
// Copyright 2022 The Matrix.org Foundation C.I.C
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

/// Light-weight crypto protocol to be used with background services
/// that can receive room keys and decrypt notification messages
protocol MXBackgroundCrypto {
    func handleSyncResponse(_ syncResponse: MXSyncResponse) async
    func canDecryptEvent(_ event: MXEvent) -> Bool
    func decryptEvent(_ event: MXEvent) throws
    
    /// Imports the megolm session of an encrypted event from the server-side key backup.
    ///
    /// Uses the backup decryption key the main application keeps in the shared crypto store.
    func importRoomKeyFromBackup(for event: MXEvent) async -> MXBackgroundKeyBackupLookup
}

/// Outcome of `MXBackgroundCrypto.importRoomKeyFromBackup(for:)`.
enum MXBackgroundKeyBackupLookup {
    /// The session was imported into the crypto store.
    case imported
    /// The current backup has no such session (yet): another device of the user may still upload it.
    case notYetAvailable
    /// No later lookup can do better: there is no backup private key in the crypto store, the key belongs
    /// to a backup version that is no longer the current one, or the backed up session cannot be used.
    case unavailable
}
