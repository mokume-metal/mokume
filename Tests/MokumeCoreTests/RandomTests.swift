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
