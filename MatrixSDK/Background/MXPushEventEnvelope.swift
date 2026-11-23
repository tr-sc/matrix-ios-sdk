//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Тело события в пуше (`im.trsc.ev`, формат пушера `im.trsc.event_v1`, ADR-0023).
///
/// В ленту (`MXSQLiteStore.insertPushEvent`) событие из конверта ставится, только если в нём есть позиция
/// (`count` = `trsc.count`) и отправитель (`sender`): без позиции строке нет места между дырами, без MXID
/// отправителя расшифровка в ленте не пройдёт. ADR-0023 сейчас не кладёт ни того, ни другого — тогда NSE берёт
/// событие из `/event`, а в ленту попадает оно.
@objcMembers
public final class MXPushEventEnvelope: NSObject {
    public static let userInfoKey = "im.trsc.ev"
    public static let supportedVersion = 1

    /// Событие для ленты из пуша или nil (нет конверта, чужая версия, нет позиции или отправителя).
    public static func storableEvent(fromUserInfo userInfo: [AnyHashable: Any]) -> MXEvent? {
        guard let eventId = userInfo["event_id"] as? String, !eventId.isEmpty,
              let roomId = userInfo["room_id"] as? String, !roomId.isEmpty,
              let envelope = envelope(from: userInfo[userInfoKey]),
              (envelope["v"] as? NSNumber)?.intValue == supportedVersion,
              let type = envelope["type"] as? String, !type.isEmpty,
              let content = envelope["content"] as? [String: Any],
              let sender = envelope["sender"] as? String, sender.hasPrefix("@"),
              let count = envelope["count"] as? String,
              isPosition(count)
        else {
            return nil
        }
        let ts = (envelope["ts"] as? NSNumber)?.uint64Value ?? 0
        let json: [String: Any] = [
            "event_id": eventId,
            "room_id": roomId,
            "type": type,
            "sender": sender,
            "origin_server_ts": ts,
            "content": content,
            "unsigned": [kMXEventUnsignedTrscCountKey: count],
        ]
        return MXEvent(fromJSON: json)
    }

    private static func isPosition(_ count: String) -> Bool {
        var order: Int64 = 0
        return MXEvent.trscOrder(fromCount: count, order: &order)
    }

    /// Конверт приходит строкой JSON (`default_payload` Sygnal) или словарём.
    private static func envelope(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let string = value as? String, let data = string.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
