// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeGamepad

/// 記録した入力の列で、パッド 1 台の入り口を回す (ADR-0028 決定 6)。機材も GPU も要らない。
///
/// 入り口の口 (``Gamepad/open()`` / ``Gamepad/supply()``) を直に呼ぶ。走っているスケッチの中で
/// 同じことが起きるのは ``GamepadSketchTests`` が見る。
@Suite("ゲームパッドの入り口 (記録した入力)")
struct GamepadTests {
    private func pad(_ inputs: [GamepadInput?]) throws -> Gamepad {
        let pad = Gamepad(
            id: "recorded #1", name: "gamepad (recorded #1)", source: RecordedGamepadSource(inputs: inputs))
        try pad.open()
        return pad
    }

    /// 1 フレームずつ進め、そのフレームの値を写す。
    private func frames(_ pad: Gamepad, _ count: Int) -> [(tilt: SIMD2<Float>, a: Bool, b: Bool, state: SourceState)] {
        (0..<count).map { _ in
            pad.supply()
            return (pad.leftStick, pad.isPressed(.a), pad.isPressed(.b), pad.state)
        }
    }

    @Test("i 番目のフレームに i 番目の入力が入り、最後まで行けば最初に戻る")
    func inputsArriveInOrder() throws {
        let inputs: [GamepadInput?] = [
            GamepadInput(leftStick: [1, 0]),
            GamepadInput(leftStick: [0, 0.5], pressed: [.a]),
            GamepadInput(leftStick: [-1, -1], pressed: [.a, .b]),
        ]
        let seen = frames(try pad(inputs), 4)
        #expect(seen.map(\.tilt) == [[1, 0], [0, 0.5], [-1, -1], [1, 0]])
        #expect(seen.map(\.a) == [false, true, true, false])
        #expect(seen.map(\.b) == [false, false, true, false])
        #expect(seen.allSatisfy { $0.state == .running })
    }

    @Test("同じ列を 2 度回すと、同じフレームに同じ値が出る")
    func sameInputsSameResult() throws {
        let inputs: [GamepadInput?] = [
            GamepadInput(leftStick: [0.25, 0], pressed: [.x]), nil, GamepadInput(pressed: [.y]),
        ]
        func record() throws -> [String] {
            frames(try pad(inputs), 7).map { "\($0.tilt) \($0.a) \($0.b) \($0.state)" }
        }
        #expect(try record() == record())
    }

    @Test("nil のフレームは抜かれていて、押していた釦は離れ、傾きは 0 に戻る。次の入力で戻る")
    func nilIsUnplugged() throws {
        let inputs: [GamepadInput?] = [
            GamepadInput(leftStick: [1, 0], pressed: [.a]), nil, nil, GamepadInput(leftStick: [0, 1]),
        ]
        let seen = frames(try pad(inputs), 4)
        #expect(seen.map(\.state) == [.running, .disconnected, .disconnected, .running])
        #expect(seen.map(\.a) == [true, false, false, false])
        #expect(seen.map(\.tilt) == [[1, 0], [0, 0], [0, 0], [0, 1]])
    }

    @Test("抜かれる前に押していた釦は、挿し直した後に押していなければ押されていない")
    func unpluggedPressDoesNotLinger() throws {
        // 押したまま抜け、挿し直した後は押していない。抜けたことを当てずにいると A が残る
        let seen = frames(try pad([GamepadInput(pressed: [.a]), nil, GamepadInput()]), 3)
        #expect(seen.map(\.a) == [true, false, false])
    }

    @Test("1 フレームに届いた押し離しは、届いた順に全部当てる")
    func changesWithinAFrameApplyInOrder() throws {
        let pad = Gamepad(id: "x", name: "x", source: SilentSource())
        try pad.open()
        pad.inbox.changes.send(.pressed(.a))
        pad.inbox.changes.send(.pressed(.b))
        pad.inbox.changes.send(.released(.a))
        pad.supply()
        #expect(!pad.isPressed(.a))
        #expect(pad.isPressed(.b))

        // 抜けて挿し直すまでが 1 フレームに収まっても、抜く前の釦は残らない
        pad.inbox.changes.send(.releasedAll)
        pad.inbox.changes.send(.pressed(.x))
        pad.supply()
        #expect(!pad.isPressed(.b))
        #expect(pad.isPressed(.x))
    }

    @Test("スティックは最新の 1 つだけが効く")
    func stickKeepsOnlyTheLatest() throws {
        let pad = Gamepad(id: "x", name: "x", source: SilentSource())
        try pad.open()
        pad.inbox.stick.send([1, 0])
        pad.inbox.stick.send([0, -1])
        pad.supply()
        #expect(pad.leftStick == [0, -1])
        // 何も届かないフレームは、前の値のまま
        pad.supply()
        #expect(pad.leftStick == [0, -1])
    }

    @Test("列が空なら機材なしを名乗り、何も入らない")
    func emptyInputsAreUnavailable() throws {
        let seen = frames(try pad([]), 2)
        #expect(seen.allSatisfy { $0.state == .unavailable && $0.tilt == .zero && !$0.a })
    }

    @Test("閉じると止まったと名乗り、値は空に戻り、以後は入らない")
    func closeStops() throws {
        let pad = try pad([GamepadInput(leftStick: [1, 1], pressed: [.a])])
        pad.supply()
        #expect(pad.isPressed(.a))
        pad.close()
        pad.supply()
        #expect(pad.state == .stopped)
        #expect(!pad.isPressed(.a))
        #expect(pad.leftStick == .zero)
        #expect(pad.report?.state == .stopped)
    }

    @Test("名乗りは状態と、最後に値が届いたフレームを持つ")
    func reportNamesState() throws {
        let pad = try pad([GamepadInput(pressed: [.a])])
        #expect(pad.report?.name == "gamepad (recorded #1)")
        #expect(pad.report?.lastArrival == nil)
        pad.supply()
        #expect(pad.report?.state == .running)
        #expect(pad.report?.lastArrival != nil)
    }

    @Test("名前の付いた釦は GameController の名前を包み、知らない名前も表せる")
    func buttonsWrapGameControllerNames() {
        #expect(GamepadButton.a.rawValue == "Button A")
        #expect(GamepadButton.b.rawValue == "Button B")
        #expect(GamepadButton.x.rawValue == "Button X")
        #expect(GamepadButton.y.rawValue == "Button Y")
        #expect(GamepadButton(rawValue: "Left Shoulder") != .a)
    }
}

/// 何も入れない出どころ。入れ物へ直に入れて、入り口の当て方だけを見るために使う。
final class SilentSource: GamepadSource {
    func start(into inbox: GamepadInbox) { inbox.setState(.running) }
    func pump(into inbox: GamepadInbox) {}
    func stop() {}
}
