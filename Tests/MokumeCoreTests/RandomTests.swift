// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 種を決めれば同じ列が出ることを見る ([ADR-0001] 原則 2)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
@Suite("種から同じ列が出る")
struct RandomTests {
    private func sequence(_ generator: inout Randomness, count: Int = 16) -> [Float] {
        (0..<count).map { _ in generator.unitValue() }
    }

    @Test("同じ種からは同じ列が出る")
    func theSameSeedGivesTheSameSequence() {
        var first = Randomness(seed: 20260829)
        var second = Randomness(seed: 20260829)
        #expect(sequence(&first) == sequence(&second))
    }

    @Test("違う種からは違う列が出る")
    func differentSeedsGiveDifferentSequences() {
        var first = Randomness(seed: 1)
        var second = Randomness(seed: 2)
        #expect(sequence(&first) != sequence(&second))
    }

    @Test("種を決めなくても、始まりは毎回同じ")
    func theDefaultSeedIsFixedToo() {
        var first = Randomness()
        var second = Randomness()
        #expect(sequence(&first) == sequence(&second))
        // 時刻から作っていれば、種 0 を明示したものとは食い違う
        var explicit = Randomness(seed: 0)
        var again = Randomness()
        #expect(sequence(&explicit) == sequence(&again))
    }

    @Test("0 以上 1 未満に収まる")
    func unitValuesStayInRange() {
        var generator = Randomness(seed: 7)
        for _ in 0..<10000 {
            let value = generator.unitValue()
            #expect(value >= 0 && value < 1)
        }
    }

    @Test("列は縮退しない (同じ値が並び続けない)")
    func theSequenceDoesNotCollapse() {
        var generator = Randomness(seed: 0)
        let values = sequence(&generator, count: 64)
        #expect(Set(values).count == values.count)
    }

    @Test("下から上までの範囲に収まる")
    func rangesAreRespected() {
        var generator = Randomness(seed: 3)
        for _ in 0..<1000 {
            let value = generator.value(from: -5, to: 12)
            #expect(value >= -5 && value < 12)
        }
    }

    @Test("上下が逆でも受け取る")
    func reversedBoundsStillWork() {
        var generator = Randomness(seed: 3)
        for _ in 0..<1000 {
            let value = generator.value(from: 12, to: -5)
            #expect(value >= -5 && value < 12)
        }
    }

    /// 丸めが上へ効く組み合わせ。`low` が 0 なら積がそのまま `high` 未満へ丸まるので、
    /// **`low` が 0 でないもの**を混ぜて見る (#1304)。
    nonisolated static var boundaryRanges: [(low: Float, high: Float)] {
        [(100, 110), (1, 2), (-5, 12), (0, 10), (1e7, 1e7 + 1)]
    }

    @Test("1 の直前を引いても high にならない", arguments: boundaryRanges)
    func theHighestUnitValueStaysBelowHigh(_ range: (low: Float, high: Float)) {
        // unitValue() が返しうる最大 = 16777215/16777216
        let highest = Float(1).nextDown
        let value = Randomness.scaled(highest, from: range.low, to: range.high)
        #expect(value >= range.low && value < range.high)
    }

    @Test("0 を引けば low ちょうど", arguments: boundaryRanges)
    func theLowestUnitValueGivesLow(_ range: (low: Float, high: Float)) {
        #expect(Randomness.scaled(0, from: range.low, to: range.high) == range.low)
    }

    /// 幅 (`high - low`) が `Float` で溢れる組。端はどちらも有限なのに
    /// `upper - lower` が `inf` になり、そのあとの積と和が壊れる (#1312)。
    nonisolated static var overflowingSpans: [(low: Float, high: Float)] {
        [
            (-.greatestFiniteMagnitude, .greatestFiniteMagnitude),
            (-3e38, 3e38),
            (-1e38, 2.5e38),
        ]
    }

    /// `unitValue()` が返しうる引きのうち、端と真ん中。
    nonisolated static var representativeUnits: [Float] {
        [0, 1.0 / 16_777_216.0, 0.5, Float(1).nextDown]
    }

    @Test(
        "幅が溢れても範囲に収まる",
        arguments: overflowingSpans, representativeUnits)
    func anOverflowingSpanStaysInRange(_ span: (low: Float, high: Float), _ unit: Float) {
        let value = Randomness.scaled(unit, from: span.low, to: span.high)
        #expect(value.isFinite)
        #expect(value >= span.low && value < span.high)
    }

    @Test("幅が溢れても、引きを動かせば値が動く", arguments: overflowingSpans)
    func anOverflowingSpanStillSpreads(_ span: (low: Float, high: Float)) {
        // 上端へ張り付いていれば、どの引きからも同じ値が返る
        let values = (0..<16).map { step in
            Randomness.scaled(Float(step) / 16, from: span.low, to: span.high)
        }
        #expect(Set(values).count == values.count)
    }

    @Test("上を下回らせない — 上下が同じなら、上の直前へ落とさない")
    func anEmptyRangeIsNotPushedBelowItself() {
        #expect(Randomness.scaled(Float(1).nextDown, from: 4, to: 4) == 4)
    }

    @Test("上で止めても、列は余分に進まない")
    func stoppingBelowHighDoesNotConsumeExtraDraws() {
        var ranged = Randomness(seed: 11)
        var plain = Randomness(seed: 11)
        for _ in 0..<1000 {
            _ = ranged.value(from: 1, to: 2)
            _ = plain.unitValue()
        }
        #expect(ranged.unitValue() == plain.unitValue())
    }

    @Test("上下が同じなら常にその値")
    func anEmptyRangeAlwaysGivesThatValue() {
        var generator = Randomness(seed: 3)
        #expect(generator.value(from: 4, to: 4) == 4)
    }

    @Test("数でない端を渡しても落ちない")
    func nonFiniteBoundsDoNotCrash() {
        var generator = Randomness(seed: 3)
        #expect(generator.value(from: 0, to: .nan).isFinite)
        #expect(generator.value(from: .infinity, to: .nan).isFinite)
    }
}
