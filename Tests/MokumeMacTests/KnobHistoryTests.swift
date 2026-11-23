// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Metal
import SwiftUI
import Testing

@testable import MokumeCore
@testable import MokumeMac
@testable import mokume

/// つまみの手の操作を履歴に積み、⌘Z / ⇧⌘Z で戻す・やり直す (#4124)。
///
/// **書くのはウィンドウが値を書く口 (``KnobBinding``) だけ** — 戻す・やり直すが ``DeclaredParam/write(_:)`` を
/// 通ることも、つまみを通した往復で見る (``KnobBinding`` の説明と同じ理由)。
@Suite("つまみの操作を戻す・やり直す")
@MainActor
struct KnobHistoryTests {
    final class Waves: Sketch {
        @Param(1...50) var count: Int = 12
        @Param(0...1) var amplitude: Double = 0.4
        @Param var tint: LinearRGBA = .linear(red: 0.9, green: 0.4, blue: 0.2)
        @Param var visible: Bool = true
        @Param(-1...1) var pair: Vector2 = Vector2(0.25, -0.5)
    }

    /// 作り直しで範囲が狭まった `count`。
    final class Narrowed: Sketch {
        @Param(1...20) var count: Int = 12
    }

    /// 時刻を手で進める時計。
    final class Clock {
        var time: TimeInterval = 100
    }

    private static func boxes(of sketch: Sketch) -> [any DeclaredParam] {
        ParamCatalog.indexed(from: sketch).map(\.box)
    }

    private static func knob(_ boxes: [any DeclaredParam], _ name: String) throws
        -> any DeclaredParam
    {
        try #require(boxes.first { $0.declaration.name == name })
    }

    /// スライダーを掴み、途中の値を経て `values` の最後で離す。
    private static func drag(
        _ box: any DeclaredParam, through values: [Double], history: KnobHistory
    ) {
        let editing = KnobBinding.editing(box, history: history)
        let slider = KnobBinding.number(box, box.declaration.value, history: history)
        editing(true)
        for value in values { slider.wrappedValue = value }
        editing(false)
    }

    private static let blue = Color(.displayP3, red: 0.1, green: 0.2, blue: 0.9, opacity: 1)

    // MARK: - 作例の 1〜4

    @Test("ドラッグ 1 回と色の変更 1 回を、1 段ずつ新しい順に戻し、古い順にやり直す")
    func undoesAndRedoesOneOperationAtATime() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let clock = Clock()
        let history = KnobHistory(boxes: { boxes }, now: { clock.time })
        let orange = sketch.tint

        // 1. count を 12 → 30 へドラッグし (途中の値を経る)、続けて tint を青へ
        Self.drag(try Self.knob(boxes, "count"), through: [15, 22, 30], history: history)
        let tint = KnobBinding.color(try Self.knob(boxes, "tint"), history: history)
        tint.wrappedValue = Self.blue
        let blueTint = sketch.tint
        #expect(sketch.count == 30)
        #expect(blueTint != orange)

        // 2. ⌘Z → tint が橙に戻る。もう一度 → count が 12 に戻る (途中の値には止まらない)
        #expect(history.undo())
        #expect(sketch.tint == orange)
        #expect(sketch.count == 30)
        #expect(history.undo())
        #expect(sketch.count == 12)
        #expect(!history.canUndo)
        #expect(!history.undo())

        // 3. ⇧⌘Z → count が 30 に、もう一度 → tint が青に
        #expect(history.redo())
        #expect(sketch.count == 30)
        #expect(sketch.tint == orange)
        #expect(history.redo())
        #expect(sketch.tint == blueTint)
        #expect(!history.canRedo)
        #expect(!history.redo())
    }

    @Test("戻してから別のつまみを動かすと、やり直しの履歴は捨てられる")
    func aNewOperationDropsTheRedoSteps() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })

        Self.drag(try Self.knob(boxes, "count"), through: [30], history: history)
        KnobBinding.flag(try Self.knob(boxes, "visible"), history: history).wrappedValue = false
        #expect(history.undo())
        #expect(sketch.visible == true)
        #expect(history.canRedo)

        // 4. amplitude を動かすと、⇧⌘Z は何もしない
        Self.drag(try Self.knob(boxes, "amplitude"), through: [0.8], history: history)
        #expect(!history.canRedo)
        #expect(!history.redo())
        #expect(sketch.visible == true)
        #expect(sketch.amplitude == 0.8)

        // 戻す側は amplitude → count の順に残っている
        #expect(history.undo())
        #expect(sketch.amplitude == 0.4)
        #expect(history.undo())
        #expect(sketch.count == 12)
    }

    // MARK: - 1 操作 = 1 段

    @Test("組の成分のスライダーは、成分ごとのドラッグで 1 段になる")
    func eachComponentDragIsOneStep() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })
        let pair = try Self.knob(boxes, "pair")

        for (index, values) in [(0, [0.5, 0.75]), (1, [0.0, 0.5])] {
            let editing = KnobBinding.editing(pair, history: history)
            let slider = KnobBinding.component(pair, at: index, history: history)
            editing(true)
            for value in values { slider.wrappedValue = value }
            editing(false)
        }
        #expect(sketch.pair == Vector2(0.75, 0.5))

        #expect(history.undo())
        #expect(sketch.pair == Vector2(0.75, -0.5))
        #expect(history.undo())
        #expect(sketch.pair == Vector2(0.25, -0.5))
        #expect(!history.canUndo)
    }

    @Test("色は書き込みが続く間は 1 段で、途切れたら次の書き込みから新しい段になる")
    func colourWritesCloseAStepOnAPause() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let clock = Clock()
        let history = KnobHistory(boxes: { boxes }, now: { clock.time })
        let tint = KnobBinding.color(try Self.knob(boxes, "tint"), history: history)
        let orange = sketch.tint

        // パネルを動かし続ける: 0.2 秒おきに 3 回
        for step in 1...3 {
            tint.wrappedValue = Color(
                .displayP3, red: 0.1 * Double(step), green: 0.2, blue: 0.9, opacity: 1)
            clock.time += 0.2
        }
        let firstPick = sketch.tint
        // 途切れてから、もう 1 度
        clock.time += KnobHistory.continuousGap
        tint.wrappedValue = Color(.displayP3, red: 0.8, green: 0.8, blue: 0.1, opacity: 1)

        #expect(history.undo())
        #expect(sketch.tint == firstPick)
        #expect(history.undo())
        #expect(sketch.tint == orange)
        #expect(!history.canUndo)
    }

    @Test("値が変わらない操作は積まない")
    func anUnchangedValueIsNotAStep() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })

        Self.drag(try Self.knob(boxes, "count"), through: [20, 12], history: history)
        KnobBinding.flag(try Self.knob(boxes, "visible"), history: history).wrappedValue = true
        #expect(!history.canUndo)
    }

    @Test("掴んでいない間のスライダーの書き込みは、1 回で 1 段")
    func aSliderWriteWithoutAGestureIsOneStep() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })
        let box = try Self.knob(boxes, "count")

        KnobBinding.number(box, box.declaration.value, history: history).wrappedValue = 40
        #expect(history.undo())
        #expect(sketch.count == 12)
    }

    // MARK: - 戻すときも同じ入口を通る・積むのは手の操作だけ

    @Test("外から書き換わった宣言の段も、そのまま段の前の値へ戻す。外の書き込みは積まない")
    func externalWritesAreNotStepsButStepsStillUndo() throws {
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })

        Self.drag(try Self.knob(boxes, "count"), through: [30], history: history)
        // 面からの書き込み (MIDI・OSC など) と、コードからの代入
        _ = try Self.knob(boxes, "count").write(.int(45))
        sketch.amplitude = 0.9

        #expect(history.undo())
        #expect(sketch.count == 12)
        #expect(sketch.amplitude == 0.9)
        #expect(!history.canUndo)
    }

    // MARK: - 失敗系

    @Test("宣言が差し替わって消えた名前の段は飛ばし、残った名前の段を戻す")
    func stepsOfVanishedNamesAreSkipped() throws {
        let sketch = Waves()
        var boxes = Self.boxes(of: sketch)
        let history = KnobHistory(boxes: { boxes })

        Self.drag(try Self.knob(boxes, "count"), through: [30], history: history)
        KnobBinding.flag(try Self.knob(boxes, "visible"), history: history).wrappedValue = false
        // 作り直しで visible の宣言が消えた
        boxes.removeAll { $0.declaration.name == "visible" }

        #expect(history.canUndo)
        #expect(history.undo())
        #expect(sketch.count == 12)
        #expect(sketch.visible == false)

        // 残っているのが消えた名前の段だけなら、戻せる段は無い
        boxes.removeAll { $0.declaration.name == "count" }
        #expect(history.redo() == false)
        #expect(!history.canRedo)
    }

    @Test("作り直しで範囲が狭まった後に戻すと、範囲へ収めた値が入る")
    func undoingPastANarrowedRangeIsClamped() throws {
        let wide = Waves()
        var boxes = Self.boxes(of: wide)
        let history = KnobHistory(boxes: { boxes })

        // 12 → 40 → 45 の 2 段
        Self.drag(try Self.knob(boxes, "count"), through: [40], history: history)
        Self.drag(try Self.knob(boxes, "count"), through: [45], history: history)
        #expect(history.undo())
        #expect(wide.count == 40)

        // 作り直しで count が 1...20 になった
        let narrowed = Narrowed()
        boxes = Self.boxes(of: narrowed)
        #expect(history.redo())
        #expect(narrowed.count == 20)
    }

    // MARK: - ⌘Z / ⇧⌘Z

    @Test("⌘Z は戻す、⇧⌘Z はやり直す。⌃・⌥ を伴うキーや Z 以外は取らない")
    func undoKeysAreReadFromTheCharacter() {
        typealias Surface = SketchSurface
        #expect(Surface.knobUndoCommand(charactersIgnoringModifiers: "z", flags: .command) == .undo)
        #expect(
            Surface.knobUndoCommand(charactersIgnoringModifiers: "Z", flags: [.command, .shift])
                == .redo)
        // Caps Lock は見ない
        #expect(
            Surface.knobUndoCommand(charactersIgnoringModifiers: "Z", flags: [.command, .capsLock])
                == .undo)
        #expect(Surface.knobUndoCommand(charactersIgnoringModifiers: "z", flags: []) == nil)
        #expect(
            Surface.knobUndoCommand(charactersIgnoringModifiers: "z", flags: [.command, .option])
                == nil)
        #expect(
            Surface.knobUndoCommand(charactersIgnoringModifiers: "z", flags: [.command, .control])
                == nil)
        #expect(Surface.knobUndoCommand(charactersIgnoringModifiers: "y", flags: .command) == nil)
    }

    private static func key(
        _ type: NSEvent.EventType, _ characters: String, flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 6))
    }

    @Test(
        "戻す段があれば ⌘Z を押下も解放もスケッチへ配らず、無ければいまどおり配る",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func theSurfaceConsumesUndoOnlyWithAStep() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: InputState(),
            canvasSize: (64, 64))
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        let sketch = Waves()
        let boxes = Self.boxes(of: sketch)
        let overlay = KnobOverlay(boxes: boxes)
        overlay.attach(to: surface)
        let history = overlay.history
        Self.drag(try Self.knob(boxes, "count"), through: [30], history: history)

        // 段がある: 戻して、押下も解放も配らない
        surface.keyDown(with: try Self.key(.keyDown, "z", flags: .command))
        surface.keyUp(with: try Self.key(.keyUp, "z", flags: .command))
        #expect(sketch.count == 12)
        #expect(lines.isEmpty)

        // ⇧⌘Z でやり直す
        surface.keyDown(with: try Self.key(.keyDown, "Z", flags: [.command, .shift]))
        surface.keyUp(with: try Self.key(.keyUp, "Z", flags: [.command, .shift]))
        #expect(sketch.count == 30)
        #expect(lines.isEmpty)

        // やり直す段はもう無いので、⇧⌘Z はスケッチへ届く
        surface.keyDown(with: try Self.key(.keyDown, "Z", flags: [.command, .shift]))
        surface.keyUp(with: try Self.key(.keyUp, "Z", flags: [.command, .shift]))
        #expect(lines.count == 2)
        #expect(sketch.count == 30)

        // 消費した後の素の z も、押下と解放の両方が届く
        lines.removeAll()
        surface.keyDown(with: try Self.key(.keyDown, "z", flags: .command))
        surface.keyDown(with: try Self.key(.keyDown, "z", flags: []))
        surface.keyUp(with: try Self.key(.keyUp, "z", flags: []))
        #expect(sketch.count == 12)
        #expect(lines.count == 2)
    }
}
