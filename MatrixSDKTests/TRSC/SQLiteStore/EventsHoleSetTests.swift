//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

import MatrixSDK
import XCTest

/// Детерминированный генератор для свойств на случайных последовательностях (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Алгебра дыр одной ленты: `MXSQLiteHoleSet` без базы.
final class MXSQLiteHoleSetTests: XCTestCase {
    private func makeSet(_ holes: [(Int64, Int64)] = []) -> MXSQLiteHoleSet {
        let set = MXSQLiteHoleSet(roomId: "!r:x", threadId: nil)
        for (lo, hi) in holes {
            set.addHole(withLowerOrder: lo, upperOrder: hi, backwardToken: "b\(hi)", forwardToken: "f\(lo)")
        }
        return set
    }

    private func bounds(_ set: MXSQLiteHoleSet) -> [[Int64]] {
        set.holes.map { [$0.lowerOrder, $0.upperOrder] }
    }

    func testAddMergesOverlappingAndKeepsOuterTokens() {
        let set = makeSet([(10, 20), (15, 30)])
        XCTAssertEqual(bounds(set), [[10, 30]])
        XCTAssertEqual(set.holes.first?.backwardToken, "b30", "назад — токен самого верхнего куска")
        XCTAssertEqual(set.holes.first?.forwardToken, "f10", "вперёд — токен самого нижнего куска")
        XCTAssertTrue(set.isValid())
    }

    func testAdjacentHolesShareAKnownBoundaryAndStaySeparate() {
        // (10,20) и (20,30): позиция 20 — известное событие, дыры не сливаются.
        let set = makeSet([(10, 20), (20, 30)])
        XCTAssertEqual(bounds(set), [[10, 20], [20, 30]])
        XCTAssertTrue(set.isValid())
    }

    func testEmptyRangesAreIgnored() {
        let set = makeSet([(10, 11), (5, 5), (9, 3)])
        XCTAssertTrue(set.isEmpty, "между 10 и 11 нет позиций — дыры нет")
        XCTAssertTrue(MXSQLiteHoleSet.isEmptyRangeLower(Int64.max - 1, upper: Int64.max))
        XCTAssertFalse(MXSQLiteHoleSet.isEmptyRangeLower(MXRoomHoleOpenStart, upper: Int64.max))
    }

    func testFillSplitsAHoleAndGivesTheNewEdgesTokens() {
        let set = makeSet([(MXRoomHoleOpenStart, MXRoomHoleOpenEnd)])
        set.fill(fromOrder: 50, toOrder: 60, lowToken: "50", highToken: "60")
        XCTAssertEqual(bounds(set), [[MXRoomHoleOpenStart, 50], [60, MXRoomHoleOpenEnd]])
        XCTAssertEqual(set.holes[0].backwardToken, "50")
        XCTAssertEqual(set.holes[1].forwardToken, "60")
        XCTAssertTrue(set.holes[0].isOpenStarted)
        XCTAssertTrue(set.holes[1].isOpenEnded)
        XCTAssertEqual(set.openEndedHole?.lowerOrder, 60)
    }

    func testLookups() {
        let set = makeSet([(10, 20), (20, 30), (40, 50)])
        XCTAssertEqual(set.holeContainingOrder(15)?.upperOrder, 20)
        XCTAssertNil(set.holeContainingOrder(20), "граница — известная позиция")
        XCTAssertNil(set.holeContainingOrder(35))
        XCTAssertEqual(set.highestHoleAtOr(belowOrder: 35)?.upperOrder, 30)
        XCTAssertEqual(set.highestHoleAtOr(belowOrder: 30)?.upperOrder, 30)
        XCTAssertNil(set.highestHoleAtOr(belowOrder: 19))
        XCTAssertEqual(set.lowestHoleAtOr(aboveOrder: 30)?.lowerOrder, 40)
        XCTAssertEqual(set.lowestHoleAtOr(aboveOrder: 20)?.lowerOrder, 20)
        XCTAssertEqual(set.hole(withUpperOrder: 50)?.lowerOrder, 40)
        XCTAssertEqual(set.hole(withLowerOrder: 20)?.upperOrder, 30)
        XCTAssertNil(set.openEndedHole)
    }

    func testReplaceAndRemove() {
        let set = makeSet([(10, 20), (40, 50)])
        XCTAssertTrue(set.replaceHole(withUpperOrder: 50, lowerOrder: 40, upperOrder: 45, backwardToken: "t", forwardToken: nil))
        XCTAssertEqual(bounds(set), [[10, 20], [40, 45]])
        XCTAssertFalse(set.removeHole(withUpperOrder: 50))
        XCTAssertTrue(set.removeHole(withUpperOrder: 20))
        XCTAssertEqual(bounds(set), [[40, 45]])
    }

    func testHoleIdIsUniquePerUpperBound() {
        let set = MXSQLiteHoleSet(roomId: "!r:x", threadId: "$root")
        set.addHole(withLowerOrder: 1, upperOrder: 9, backwardToken: nil, forwardToken: nil)
        XCTAssertEqual(set.holes.first?.holeId, "!r:x|$root|9")
    }

    /// Свойство: после любой последовательности «добавить дыру» / «позиции стали известны» набор равен
    /// максимальным сериям неизвестных позиций модели — дыры не пересекаются, не пустые, ни одна известная
    /// позиция не внутри дыры.
    func testRandomSequencesMatchTheRunsOfUnknownPositions() {
        let size = 120
        for seed in 0..<300 {
            var rng = SeededGenerator(seed: UInt64(seed))
            var unknown = [Bool](repeating: false, count: size + 1)   // позиции 1…size
            let set = MXSQLiteHoleSet(roomId: "!r:x", threadId: nil)
            for _ in 0..<40 {
                let a = Int.random(in: 0...size, using: &rng)
                let b = Int.random(in: 0...size, using: &rng)
                let (lo, hi) = (min(a, b), max(a, b))
                if Bool.random(using: &rng) {
                    set.addHole(withLowerOrder: Int64(lo), upperOrder: Int64(hi), backwardToken: nil, forwardToken: nil)
                    if hi - lo > 1 { for p in (lo + 1)..<hi { unknown[p] = true } }
                } else {
                    set.fill(fromOrder: Int64(lo), toOrder: Int64(hi), lowToken: nil, highToken: nil)
                    for p in lo...hi where p >= 1 && p <= size { unknown[p] = false }
                }
                XCTAssertTrue(set.isValid(), "seed \(seed): \(set)")
            }
            var runs: [[Int64]] = []
            var p = 1
            while p <= size {
                if unknown[p] {
                    let start = p
                    while p <= size && unknown[p] { p += 1 }
                    runs.append([Int64(start - 1), Int64(p)])
                } else {
                    p += 1
                }
            }
            XCTAssertEqual(bounds(set), runs, "seed \(seed)")
        }
    }
}
