//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// `unsigned["trsc.count"]` — позиция события на сервере (ADR-0022). Раньше SDK выбрасывал это поле.
final class MXEventTrscOrderTests: XCTestCase {
    private func event(unsigned: [String: Any]) -> MXEvent {
        MXEvent(fromJSON: [
            "event_id": "$e:x",
            "room_id": "!r:x",
            "type": "m.room.message",
            "sender": "@a:x",
            "origin_server_ts": 1,
            "content": ["body": "hi", "msgtype": "m.text"],
            "unsigned": unsigned
        ])
    }

    func testParsesServerString() {
        let positive = event(unsigned: ["trsc.count": "1234567"])
        XCTAssertEqual(positive.unsignedData.trscCount, "1234567")
        XCTAssertTrue(positive.hasTrscOrder)
        XCTAssertEqual(positive.trscOrder, 1_234_567)

        // Backfill у Tuwunel отрицательный и сортируется ниже обычных.
        let backfilled = event(unsigned: ["trsc.count": "-42"])
        XCTAssertTrue(backfilled.hasTrscOrder)
        XCTAssertEqual(backfilled.trscOrder, -42)
        XCTAssertLessThan(backfilled.trscOrder, positive.trscOrder)
    }

    func testMissingOrMalformedCountHasNoOrder() {
        XCTAssertFalse(event(unsigned: ["age": 5]).hasTrscOrder)
        XCTAssertEqual(event(unsigned: ["age": 5]).trscOrder, 0)
        var order: Int64 = 0
        for bad in ["", " 1", "1 ", "+1", "-", "1.5", "abc", "12a", "9223372036854775808", "-9223372036854775809", "１２"] {
            XCTAssertFalse(MXEvent.trscOrder(fromCount: bad, order: &order), "accepted \(bad)")
        }
    }

    func testInt64Bounds() {
        var order: Int64 = 0
        XCTAssertTrue(MXEvent.trscOrder(fromCount: "9223372036854775807", order: &order))
        XCTAssertEqual(order, Int64.max)
        XCTAssertTrue(MXEvent.trscOrder(fromCount: "-9223372036854775808", order: &order))
        XCTAssertEqual(order, Int64.min)
        XCTAssertTrue(MXEvent.trscOrder(fromCount: "0", order: &order))
        XCTAssertEqual(order, 0)
    }

    func testNumberFromAReencodingProxyIsAccepted() {
        let numeric = event(unsigned: ["trsc.count": NSNumber(value: 77)])
        XCTAssertEqual(numeric.unsignedData.trscCount, "77")
        XCTAssertEqual(numeric.trscOrder, 77)
        XCTAssertNil(event(unsigned: ["trsc.count": true]).unsignedData.trscCount)
    }

    func testJSONRoundTripKeepsTheCount() throws {
        let original = event(unsigned: ["trsc.count": "-7", "transaction_id": "t1"])
        let json = try XCTUnwrap(original.jsonDictionary() as? [String: Any])
        let unsigned = try XCTUnwrap(json["unsigned"] as? [String: Any])
        XCTAssertEqual(unsigned["trsc.count"] as? String, "-7")
        XCTAssertEqual(unsigned["transaction_id"] as? String, "t1")

        let parsed = MXEvent(fromJSON: json)
        XCTAssertEqual(parsed?.trscOrder, -7)
    }

    func testNSCodingRoundTripKeepsTheCount() throws {
        let original = event(unsigned: ["trsc.count": "9001"])
        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: false)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        let decoded = try XCTUnwrap(unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? MXEvent)
        XCTAssertEqual(decoded.unsignedData.trscCount, "9001")
        XCTAssertEqual(decoded.trscOrder, 9001)
    }

    func testServerFeatureFlagInVersions() {
        let with = MXMatrixVersions(fromJSON: ["versions": ["v1.11"], "unstable_features": ["im.trsc.event_count": true]])
        XCTAssertEqual(with?.supportsTrscEventCount, true)
        let off = MXMatrixVersions(fromJSON: ["versions": ["v1.11"], "unstable_features": ["im.trsc.event_count": false]])
        XCTAssertEqual(off?.supportsTrscEventCount, false)
        let without = MXMatrixVersions(fromJSON: ["versions": ["v1.11"]])
        XCTAssertEqual(without?.supportsTrscEventCount, false)
    }
}
