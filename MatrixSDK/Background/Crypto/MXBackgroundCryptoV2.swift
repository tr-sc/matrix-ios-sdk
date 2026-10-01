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

import MatrixSDKCrypto

/// An implementation of `MXBackgroundCrypto` which uses [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk/tree/main/crates/matrix-sdk-crypto)
/// under the hood.
class MXBackgroundCryptoV2: MXBackgroundCrypto {
    enum Error: Swift.Error {
        case missingCredentials
        case missingKeyBackupData
    }
    
    private let credentials: MXCredentials
    private let restClient: MXRestClient
    private let log = MXNamedLog(name: "MXBackgroundCryptoV2")
    
    init(credentials: MXCredentials, restClient: MXRestClient) {
        self.credentials = credentials
        self.restClient = restClient
        log.debug("Initialized background crypto module")
    }
    
    func handleSyncResponse(_ syncResponse: MXSyncResponse) async {
        let syncId = UUID().uuidString
        let details = """
        Handling new sync response `\(syncId)`
          - to-device events : \(syncResponse.toDevice?.events.count ?? 0)
          - devices changed  : \(syncResponse.deviceLists?.changed?.count ?? 0)
          - devices left     : \(syncResponse.deviceLists?.left?.count ?? 0)
          - one time keys    : \(syncResponse.deviceOneTimeKeysCount?[kMXKeySignedCurve25519Type] ?? 0)
          - fallback keys    : \(syncResponse.unusedFallbackKeys ?? [])
        """
        log.debug(details)
        
        do {
            let machine = try createMachine()
            _ = try await machine.handleSyncResponse(
                toDevice: syncResponse.toDevice,
                deviceLists: syncResponse.deviceLists,
                deviceOneTimeKeysCounts: syncResponse.deviceOneTimeKeysCount ?? [:],
                unusedFallbackKeys: syncResponse.unusedFallbackKeys,
                nextBatchToken: syncResponse.nextBatch
            )
        } catch {
            log.error("Failed handling sync response", context: error)
        }
        
        log.debug("Completed handling sync response `\(syncId)`")
    }
    
    func canDecryptEvent(_ event: MXEvent) -> Bool {
        let eventId = event.eventId ?? ""
        
        if !event.isEncrypted {
            log.debug("Event \(eventId) is not encrypted")
            return true
        }
        
        guard
            let _ = event.content["sender_key"] as? String,
            let sessionId = event.content["session_id"] as? String
        else {
            log.error("Event does not contain session_id", context: [
                "event_id": eventId
            ])
            return false
        }
        
        do {
            // Rust-sdk does not expose api to see if we have a given session key yet (will be added in the future)
            // so for the time being to find out if we can decrypt we simply perform the (more expensive) decryption
            let machine = try createMachine()
            _ = try machine.decryptRoomEvent(event)
            log.debug("Event `\(eventId)` can be decrypted with session `\(sessionId)`")
            return true
        } catch DecryptionError.MissingRoomKey {
            log.warning("We do not have keys to decrypt event `\(eventId)` with session `\(sessionId)`")
            return false
        } catch {
            log.warning("We cannot decrypt event `\(eventId)` with session `\(sessionId)`")
            return false
        }
    }
    
    func decryptEvent(_ event: MXEvent) throws {
        let eventId = event.eventId ?? ""
        log.debug("Decrypting event `\(eventId)`")
        
        do {
            let machine = try createMachine()
            let decrypted = try machine.decryptRoomEvent(event)
            let result = try MXEventDecryptionResult(event: decrypted)
            event.setClearData(result)
            
            log.debug("Successfully decrypted event `\(result.clearEvent["type"] ?? "unknown")` eventId `\(eventId)`")
        } catch {
            log.error("Failed to decrypt event", context: error)
            throw error
        }
    }
    
    func importRoomKeyFromBackup(for event: MXEvent) async -> Bool {
        let eventId = event.eventId ?? ""
        guard
            event.isEncrypted,
            let roomId = event.roomId,
            let sessionId = event.content["session_id"] as? String
        else {
            return false
        }
        
        do {
            let machine = try createMachine()
            // The main application saves the backup private key next to its version when it
            // creates, trusts or restores the backup (`MXKeyBackup`). Deriving it from a passphrase
            // here instead (PBKDF2, 500k rounds) does not fit the extension's memory and time limits.
            guard let backupKeys = machine.backupKeys else {
                log.debug("No key backup private key in the crypto store, cannot look up session `\(sessionId)`")
                return false
            }
            let version = backupKeys.backupVersion()
            
            let keyBackupData: MXKeyBackupData
            do {
                keyBackupData = try await self.keyBackupData(sessionId: sessionId, roomId: roomId, version: version)
            } catch {
                // 404 until a device of the user that has this session uploads it.
                log.debug("Session `\(sessionId)` of event `\(eventId)` is not in key backup v\(version)")
                return false
            }
            
            guard let sessionData = decrypt(
                keyBackupData: keyBackupData,
                recoveryKey: backupKeys.recoveryKey(),
                sessionId: sessionId,
                roomId: roomId
            ) else {
                return false
            }
            
            let result = try machine.importDecryptedKeys(roomKeys: [sessionData], progressListener: BackupImportProgressListener())
            log.debug("Imported \(result.imported)/\(result.total) keys of session `\(sessionId)` from key backup v\(version)")
            return result.imported > 0
        } catch {
            log.error("Failed importing a room key from key backup", context: error)
            return false
        }
    }
    
    private func keyBackupData(sessionId: String, roomId: String, version: String) async throws -> MXKeyBackupData {
        try await withCheckedThrowingContinuation { continuation in
            _ = restClient.keyBackup(forSession: sessionId, inRoom: roomId, version: version, success: { keyBackupData in
                if let keyBackupData {
                    continuation.resume(returning: keyBackupData)
                } else {
                    continuation.resume(throwing: Error.missingKeyBackupData)
                }
            }, failure: { error in
                continuation.resume(throwing: error ?? Error.missingKeyBackupData)
            })
        }
    }
    
    /// Same as `MXCryptoKeyBackupEngine.decrypt`, which needs a whole key backup engine.
    private func decrypt(
        keyBackupData: MXKeyBackupData,
        recoveryKey: BackupRecoveryKey,
        sessionId: String,
        roomId: String
    ) -> MXMegolmSessionData? {
        guard
            let ciphertext = keyBackupData.sessionData["ciphertext"] as? String,
            let mac = keyBackupData.sessionData["mac"] as? String,
            let ephemeral = keyBackupData.sessionData["ephemeral"] as? String
        else {
            log.error("Missing session data properties")
            return nil
        }
        
        do {
            let plaintext = try recoveryKey.decryptV1(ephemeralKey: ephemeral, mac: mac, ciphertext: ciphertext)
            guard
                let json = MXTools.deserialiseJSONString(plaintext) as? [AnyHashable: Any],
                let data = MXMegolmSessionData(fromJSON: json)
            else {
                log.error("Failed serializing data")
                return nil
            }
            data.sessionId = sessionId
            data.roomId = roomId
            data.isUntrusted = true // Asymmetric backups are untrusted by default
            return data
        } catch {
            log.error("Failed decrypting backup data", context: error)
            return nil
        }
    }
    
    // `MXCryptoMachine` will load the same store as the main application meaning that background and foreground
    // sync services have access to the same data / keys. The machine is not fully multi-thread and multi-process
    // safe, and until this is resolved we open a new instance of `MXCryptoMachine` on each background operation
    // to ensure we are always up-to-date with whatever has been written by the foreground process in the meanwhile.
    // See https://github.com/matrix-org/matrix-rust-sdk/issues/1415 for more details.
    private func createMachine() throws -> MXCryptoMachine {
        guard
            let userId = credentials.userId,
            let deviceId = credentials.deviceId
        else {
            throw Error.missingCredentials
        }
         
        return try MXCryptoMachine(
            userId: userId,
            deviceId: deviceId,
            restClient: restClient,
            getRoomAction: { [log] _ in
                log.error("The background crypto should not be accessing rooms")
                return nil
            }
        )
    }
}

/// A single session is imported at a time, there is no progress worth reporting.
private final class BackupImportProgressListener: ProgressListener {
    func onProgress(progress: Int32, total: Int32) {}
}
