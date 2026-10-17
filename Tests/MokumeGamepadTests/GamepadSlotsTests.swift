// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeGamepad

/// 識別子の振り方と抜き差し (ADR-0028 決定 3)。機材も OS も要らない。
///
/// GameController は機材ごとの識別子を持たないので、識別子は機種名と番号から振る。抜き差しは
/// 手で行うので実機では組み合わせを回せない。判断を ``GamepadSlots`` に閉じてあるので、ここで
/// 全部の道を通す。
@Suite("ゲームパッドの識別子")
struct GamepadSlotsTests {
    @Test("同じ機種の 2 台は、繋がった順に #1 と #2 になる。違う機種は別に数える")
    func numbersPerModel() {
        var slots = GamepadSlots()
        #expect(slots.connect(model: "Xbox Wireless Controller") == "Xbox Wireless Controller #1")
        #expect(slots.connect(model: "DualSense Wireless Controller") == "DualSense Wireless Controller #1")
        #expect(slots.connect(model: "Xbox Wireless Controller") == "Xbox Wireless Controller #2")
        #expect(
            slots.known == [
                "Xbox Wireless Controller #1", "DualSense Wireless Controller #1", "Xbox Wireless Controller #2",
            ])
        #expect(slots.connected.count == 3)
    }

    @Test("1 台を抜いて挿し直すと、同じ識別子に戻り、一覧の並びは動かない")
    func replugKeepsIdentifier() {
        var slots = GamepadSlots()
        let first = slots.connect(model: "Xbox Wireless Controller")
        let second = slots.connect(model: "Xbox Wireless Controller")
        slots.disconnect(first)
        #expect(!slots.isConnected(first))
        #expect(slots.isConnected(second))
        // 抜いたものも一覧に残る
        #expect(slots.known == [first, second])

        #expect(slots.connect(model: "Xbox Wireless Controller") == first)
        #expect(slots.isConnected(first))
        #expect(slots.known == [first, second])
    }

    @Test("抜かれている席が無ければ、挿し直しでも新しい番号になる")
    func noVacancyMeansNewNumber() {
        var slots = GamepadSlots()
        let first = slots.connect(model: "Pad")
        #expect(slots.connect(model: "Pad") == "Pad #2")
        slots.disconnect(first)
        #expect(slots.connect(model: "Pad") == first)
        #expect(slots.connect(model: "Pad") == "Pad #3")
    }

    @Test("違う機種の席には戻らない")
    func vacancyIsPerModel() {
        var slots = GamepadSlots()
        let xbox = slots.connect(model: "Xbox Wireless Controller")
        slots.disconnect(xbox)
        #expect(slots.connect(model: "DualSense Wireless Controller") == "DualSense Wireless Controller #1")
        #expect(!slots.isConnected(xbox))
    }

    /// 代償の確かめ。**同じ機種の 2 台を両方抜いて逆の順に挿すと、入れ替わる** — 見分ける材料が
    /// OS から来ない。挿した順に、番号の小さい席から埋まる。
    @Test("同じ機種の 2 台を両方抜いて挿し直すと、挿した順に番号の小さい席から埋まる")
    func bothUnpluggedRefillInOrder() {
        var slots = GamepadSlots()
        let first = slots.connect(model: "Pad")
        let second = slots.connect(model: "Pad")
        slots.disconnect(second)
        slots.disconnect(first)
        #expect(slots.connect(model: "Pad") == first)
        #expect(slots.connect(model: "Pad") == second)
    }
}
