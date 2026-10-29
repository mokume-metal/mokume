// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeMIDI

/// 識別子の振り方 (機材にも OS にも触れない)。
nonisolated struct MIDISlotsTests {
    @Test("同じ名前の機材は、初めて繋がった順に #1・#2。名前が違えば別の番号で数える")
    func numbering() {
        var slots = MIDISlots()
        #expect(slots.connect(uniqueID: 10, name: "Pad") == "Pad #1")
        #expect(slots.connect(uniqueID: 11, name: "Pad") == "Pad #2")
        #expect(slots.connect(uniqueID: 12, name: "Keys") == "Keys #1")
        #expect(slots.known == ["Pad #1", "Pad #2", "Keys #1"])
    }

    @Test("抜いても一覧に残り、挿し直せば同じ識別子に戻る")
    func replugKeepsTheId() {
        var slots = MIDISlots()
        let id = slots.connect(uniqueID: 10, name: "Pad")
        slots.disconnect(id)
        #expect(slots.known == [id])
        #expect(!slots.isConnected(id))
        #expect(slots.connect(uniqueID: 10, name: "Pad") == id)
        #expect(slots.isConnected(id))
        #expect(slots.known == [id])
    }

    @Test("同じ機種の 2 台を両方抜いて逆の順に挿しても、一意な番号で同じ機材へ戻る")
    func reverseOrderReplugKeepsIdentity() {
        var slots = MIDISlots()
        let first = slots.connect(uniqueID: 10, name: "Pad")
        let second = slots.connect(uniqueID: 11, name: "Pad")
        slots.disconnect(first)
        slots.disconnect(second)
        #expect(slots.connect(uniqueID: 11, name: "Pad") == second)
        #expect(slots.connect(uniqueID: 10, name: "Pad") == first)
    }

    @Test("一意な番号が変わって見える機材は、同じ名前で抜かれている小さい番号へ戻る。新しく増えない")
    func changedUniqueIDFallsBackToTheName() {
        var slots = MIDISlots()
        let id = slots.connect(uniqueID: 10, name: "Pad")
        slots.disconnect(id)
        #expect(slots.connect(uniqueID: 99, name: "Pad") == id)
        #expect(slots.known == [id])
    }

    @Test("繋がっている間は、同じ名前の別の機材が席を奪わない")
    func connectedSlotIsNotTaken() {
        var slots = MIDISlots()
        let first = slots.connect(uniqueID: 10, name: "Pad")
        let second = slots.connect(uniqueID: 99, name: "Pad")
        #expect(first != second)
    }
}
