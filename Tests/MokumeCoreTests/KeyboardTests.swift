// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Metal
import Testing

@testable import MokumeCore

/// 押下の 3 語 (``Keyboard``) と、押下の集合の出入りで決まる呼び出し
/// ([#2599](https://github.com/mokume-metal/mokume/issues/2599))。
///
/// 出来事は ``InputState`` へ直に注入する。窓からも外からも同じここへ入るので、ここで
/// 決まった答えはどちらの経路でも同じになる。フレームはランタイムと同じ順で回す —
/// 頭で流し込み (`beginFrame`)、`draw()` の後で端を消す (`endFrame`)。
@Suite("キーボードの 3 語")
@MainActor
struct KeyboardTests {
    /// 1 フレーム分の出来事を流し込み、`draw()` から見える答えを読んでからフレームを終える。
    private func frame(
        _ state: InputState, _ events: [InputEvent] = [], read: (Keyboard) -> Void = { _ in }
    ) {
        for event in events { state.enqueue(event) }
        state.beginFrame()
        read(Keyboard(state: state))
        state.endFrame()
    }

    private static let spaceDown = InputEvent.keyDown(code: .space, characters: " ", isRepeat: false)
    private static let spaceRepeat = InputEvent.keyDown(code: .space, characters: " ", isRepeat: true)

    @Test("押したフレームだけ justPressed、押している間は isPressed、離したフレームで justReleased")
    func edgesFollowTheFrames() {
        let state = InputState()
        var seen: [(isPressed: Bool, justPressed: Bool, justReleased: Bool)] = []
        let record: (Keyboard) -> Void = {
            seen.append(($0.isPressed(.space), $0.justPressed(.space), $0.justReleased(.space)))
        }
        frame(state, [Self.spaceDown], read: record)
        frame(state, [Self.spaceRepeat], read: record)
        frame(state, [Self.spaceRepeat], read: record)
        frame(state, [.keyUp(code: .space)], read: record)
        frame(state, read: record)

        #expect(seen.map(\.isPressed) == [true, true, true, false, false])
        #expect(seen.map(\.justPressed) == [true, false, false, false, false])
        #expect(seen.map(\.justReleased) == [false, false, false, true, false])
    }

    @Test("1 フレームに押して離すと、justPressed と justReleased が両方立ち、isPressed は偽")
    func pressAndReleaseInOneFrame() {
        let state = InputState()
        frame(state, [Self.spaceDown, .keyUp(code: .space)]) { keyboard in
            #expect(keyboard.justPressed(.space))
            #expect(keyboard.justReleased(.space))
            #expect(!keyboard.isPressed(.space))
        }
    }

    /// **端を消すのは描いたフレームの終わり。** 止めている間 (`noLoop()`) も届いた入力は
    /// フレームの外で流し込まれる (`beginFrame` だけが回り、`endFrame` は回らない)。
    @Test("止めている間に押して離した分は、次に描くフレームで読める")
    func edgesSurviveDeliveriesWhileStopped() {
        let state = InputState()
        frame(state, [Self.spaceDown])
        // 止めている間の 2 回の配り。`draw()` を呼ばないので `endFrame` を通らない
        state.enqueue(.keyUp(code: .space))
        state.beginFrame()
        state.beginFrame()
        // 次に描くフレーム
        frame(state) { keyboard in
            #expect(keyboard.justReleased(.space))
            #expect(!keyboard.isPressed(.space))
        }
        frame(state) { #expect(!$0.justReleased(.space)) }
    }

    @Test("ほかのキーの押下では立たない")
    func edgesArePerKey() {
        let state = InputState()
        frame(state, [.keyDown(code: .a, characters: "a", isRepeat: false)]) { keyboard in
            #expect(keyboard.justPressed(.a))
            #expect(!keyboard.justPressed(.space))
            #expect(!keyboard.isPressed(.space))
        }
    }

    // MARK: - 修飾キー

    @Test("修飾キーは、左右どちらでも名前の付いた定数で問える", arguments: [56, 60])
    func modifiersAnswerForEitherSide(_ code: Int) {
        let state = InputState()
        frame(state, [.keyDown(code: Key(rawValue: code), characters: "", isRepeat: false)]) {
            #expect($0.isPressed(.shift))
            #expect($0.justPressed(.shift))
            #expect(!$0.isPressed(.control))
        }
        frame(state, [.keyUp(code: Key(rawValue: code))]) {
            #expect(!$0.isPressed(.shift))
            #expect($0.justReleased(.shift))
        }
    }

    @Test("右の番号で問えば、右だけを読める")
    func theRightSideReadsAlone() {
        let state = InputState()
        frame(state, [.keyDown(code: .shift, characters: "", isRepeat: false)]) {
            #expect($0.isPressed(.shift))
            #expect(!$0.isPressed(Key(rawValue: 60)))
        }
    }

    /// ⌘Tab で Command の `keyPressed()` が呼ばれたり、大文字を打った後に `keyCode` が Shift の
    /// まま残ったりしないため ([#2435](https://github.com/mokume-metal/mokume/issues/2435))。
    @Test(
        "修飾キーは押下の状態だけを変え、呼び出しも keyCode も key も動かさない",
        arguments: [56, 60, 59, 62, 58, 61, 55, 54])
    func modifiersOnlyChangeTheHeldState(_ code: Int) {
        let state = InputState()
        state.enqueue(.keyDown(code: .a, characters: "a", isRepeat: false))
        state.enqueue(.keyUp(code: .a))
        state.beginFrame()

        state.enqueue(.keyDown(code: Key(rawValue: code), characters: "", isRepeat: false))
        state.enqueue(.keyUp(code: Key(rawValue: code)))
        var calls: [InputCallback] = []
        state.beginFrame { calls.append($0) }

        #expect(calls.isEmpty)
        #expect(state.lastKey == .a)
        #expect(state.characters == "a")
    }

    // MARK: - 呼び出しは集合の出入りで決まる

    private func callbacks(_ events: [InputEvent]) -> [InputCallback] {
        let state = InputState()
        for event in events { state.enqueue(event) }
        var calls: [InputCallback] = []
        state.beginFrame { calls.append($0) }
        return calls
    }

    @Test("押しっぱなしのキーリピートでは keyPressed は 1 回で、keyTyped はリピートごと")
    func repeatsReachOnlyKeyTyped() {
        #expect(
            callbacks([Self.spaceDown, Self.spaceRepeat, Self.spaceRepeat, .keyUp(code: .space)])
                == [.keyPressed, .keyTyped, .keyTyped, .keyTyped, .keyReleased])
    }

    /// 窓が退いて離した扱いにした後で、本物の解放が届く形 (#2443)。
    @Test("押されていないキーの解放は、keyReleased を呼ばない")
    func releasingAnUnheldKeyDoesNotCall() {
        #expect(
            callbacks([Self.spaceDown, .keyUp(code: .space), .keyUp(code: .space)])
                == [.keyPressed, .keyTyped, .keyReleased])
    }

    /// 離した扱いにした後も押し続けていれば、戻ってきたリピートで押下として入り直す。
    @Test("押されていないキーにリピートが届くと、押下として入り直す")
    func aRepeatAfterAReleaseCountsAsAPress() {
        let state = InputState()
        frame(state, [Self.spaceDown, .keyUp(code: .space)])
        var calls: [InputCallback] = []
        state.enqueue(Self.spaceRepeat)
        state.beginFrame { calls.append($0) }
        #expect(calls == [.keyPressed, .keyTyped])
        #expect(Keyboard(state: state).isPressed(.space))
        #expect(Keyboard(state: state).justPressed(.space))
    }

    // MARK: - マウスの釦

    @Test("左を押したまま右を押して離しても、左は押されたまま")
    func buttonsAreHeldPerButton() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 1, y: 1, button: .left))
        state.enqueue(.mouseDown(x: 1, y: 1, button: .right))
        state.enqueue(.mouseUp(x: 1, y: 1, button: .right))
        state.beginFrame()
        #expect(state.isMouseDown)
        #expect(state.pressedButtons == [.left])

        state.enqueue(.mouseUp(x: 1, y: 1, button: .left))
        state.beginFrame()
        #expect(!state.isMouseDown)
    }

    @Test("ほかの釦を押していても、押していない釦の解放はクリックにならない")
    func clickNeedsThatButtonHeld() {
        #expect(
            callbacks([
                .mouseDown(x: 1, y: 1, button: .left), .mouseUp(x: 1, y: 1, button: .right),
            ]) == [.mousePressed, .mouseReleased])
        #expect(
            callbacks([
                .mouseDown(x: 1, y: 1, button: .left), .mouseDown(x: 1, y: 1, button: .right),
                .mouseUp(x: 1, y: 1, button: .right),
            ]) == [.mousePressed, .mousePressed, .mouseReleased, .mouseClicked])
    }

    @Test("片方の釦を離しても、押したままの移動は引きずりのまま")
    func dragContinuesWhileAnotherButtonIsHeld() {
        #expect(
            callbacks([
                .mouseDown(x: 0, y: 0, button: .left), .mouseDown(x: 0, y: 0, button: .right),
                .mouseUp(x: 0, y: 0, button: .right), .mouseMoved(x: 3, y: 4),
            ]).last == .mouseDragged(deltaX: 3, deltaY: 4))
    }
}

/// 窓の面が、修飾キーの変化と、退いたときの解放を合流点の出来事にする形。
@Suite("窓の押下の受け口")
@MainActor
struct SurfaceHeldInputTests {
    /// 左右を分けた修飾のビット (`NX_DEVICE*KEYMASK`) と、まとめた旗 (`.shift` など)。
    @Test("修飾キーの変化は、左右を分けたビットで押下か解放かを決める")
    func modifierChangesReadTheSideBits() {
        let shiftFlag = NSEvent.ModifierFlags.shift.rawValue
        // 左の Shift を押した
        #expect(
            SketchSurface.modifierEvent(keyCode: 56, flags: shiftFlag | 0x02)
                == .keyDown(code: .shift, characters: "", isRepeat: false))
        // 両方押してから左を離した。まとめた旗は立ったままだが、左のビットは落ちている
        #expect(
            SketchSurface.modifierEvent(keyCode: 56, flags: shiftFlag | 0x04)
                == .keyUp(code: .shift))
        // 右の Command を押した
        #expect(
            SketchSurface.modifierEvent(
                keyCode: 54, flags: NSEvent.ModifierFlags.command.rawValue | 0x10)
                == .keyDown(code: Key(rawValue: 54), characters: "", isRepeat: false))
        // Caps Lock と fn は修飾キーとして流さない
        #expect(
            SketchSurface.modifierEvent(
                keyCode: 57, flags: NSEvent.ModifierFlags.capsLock.rawValue) == nil)
        #expect(
            SketchSurface.modifierEvent(
                keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue) == nil)
    }

    private func makeSurface() throws -> (SketchSurface, InputState) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let input = InputState()
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: input,
            canvasSize: (64, 64))
        return (surface, input)
    }

    /// アプリが退く知らせは窓を持たずに出せるので、窓を開かずに通る経路を見る。窓が key で
    /// なくなる経路は `SketchApplicationTests` が本物の窓で見る。
    @Test(
        "アプリが退くと、面が流した押下に解放を流し、注入した押下は離さない",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func releasesWhatTheSurfaceHeldWhenTheAppResigns() throws {
        let (surface, input) = try makeSurface()
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        surface.deliver(.keyDown(code: .arrowRight, characters: "\u{F703}", isRepeat: false))
        surface.deliver(.keyDown(code: .a, characters: "a", isRepeat: false))
        surface.deliver(.keyUp(code: .a))
        surface.deliver(.mouseDown(x: 5, y: 6, button: .left))
        // 外から注入した押下。人が触っていないので、窓の都合では離さない
        input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
        input.beginFrame()
        input.endFrame()
        lines.removeAll()

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification, object: NSApplication.shared)

        #expect(
            lines == [
                InputEvent.keyUp(code: .arrowRight).wireLine,
                InputEvent.mouseUp(x: 5, y: 6, button: .left).wireLine,
            ])
        var calls: [InputCallback] = []
        input.beginFrame { calls.append($0) }
        // 釦の解放には、押していた釦なのでクリックが続く (離した扱いの代償。PR の反証の節に記録)
        #expect(Array(calls.prefix(2)) == [.keyReleased, .mouseReleased])
        let keyboard = Keyboard(state: input)
        #expect(keyboard.justReleased(.arrowRight))
        #expect(!keyboard.isPressed(.arrowRight))
        #expect(keyboard.isPressed(.space))
        #expect(!input.isMouseDown)

        // 2 度目の知らせでは、もう何も流さない
        lines.removeAll()
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        #expect(lines.isEmpty)
    }
}
