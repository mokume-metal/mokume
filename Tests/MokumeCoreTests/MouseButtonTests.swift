// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import MokumeCore

/// マウスの釦の番号が名乗る体系 ([ADR-0034] 決定 1〜3 を釦へ当てたもの)。
///
/// **定数を手で書いている以上、正典と突き合わせないと嘘に気付けない。** 番号が 1 つ
/// ずれても絵は出るし検査も通り、症状は「右で押したのに中と読まれる」としか出ない。
/// だから macOS 自身が持つ定数 (CoreGraphics の `CGMouseButton`) と 1 つずつ比べる。
///
/// この検査だけが `CGMouseButton` を引く。**面には出さない** ([ADR-0020] 決定 6)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
@Suite("マウスの釦の番号")
struct MouseButtonTests {
    @Test(
        "名前の付いた釦の番号は、macOS の定数と一致する",
        arguments: [
            (MouseButton.left, CGMouseButton.left),
            (.right, .right),
            (.center, .center),
        ])
    func matchesTheSystemButtonNumbers(button: MouseButton, expected: CGMouseButton) {
        #expect(button.rawValue == Int(expected.rawValue))
    }

    /// 外からは任意の番号が送られてくる ([ADR-0018] 決定 1)。戻る・進むのような 4 番目
    /// 以降の釦も、名前が無いだけで押せば届く — **名前の付いたものしか表せない形にすると、
    /// その釦を押しただけで出来事が消える。**
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    @Test("名前の無い番号も、そのまま表せる")
    func carriesUnnamedNumbers() {
        let unnamed = MouseButton(rawValue: 4)
        #expect(unnamed.rawValue == 4)
        #expect(![MouseButton.left, .right, .center].contains(unnamed))
    }

    /// **`mouseButton == 0` や、手本の定数を写した `mouseButton == 37` を型で止める。**
    /// 整数のリテラルから作れると、写した比較が黙って通り、別の釦か常に偽になる。
    @Test("数のリテラルからは作れない")
    func cannotBeWrittenAsANumber() {
        #expect(!(MouseButton.self is any ExpressibleByIntegerLiteral.Type))
    }
}

@Suite("釦を読む面")
@MainActor
struct MouseButtonSurfaceTests {
    /// **外から送った番号が、面では名前として読める。** 線は macOS の番号のまま据え置いた
    /// ので ([ADR-0034] 決定 4)、送り手を変えずに書き味だけが変わる。`button` を省いた
    /// 1 件は主釦 (左) として読む — 省略が自然に読める値である。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    @Test(
        "外から送った番号は、面では名前の付いた釦になる",
        arguments: [
            (#"{"type":"mouseDown","x":1,"y":2,"button":1}"#, MouseButton.right),
            (#"{"type":"mouseDown","x":1,"y":2,"button":2}"#, .center),
            (#"{"type":"mouseDown","x":1,"y":2}"#, .left),
        ])
    func readsTheSentNumberAsANamedButton(json: String, expected: MouseButton) throws {
        let raw = try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8))
        let state = InputState()
        state.enqueue(try #require(raw.event))
        state.beginFrame()

        #expect(state.button == expected)
    }

    @Test("知らない番号も、落とさずに届く")
    func carriesAnUnknownNumber() throws {
        let raw = try JSONDecoder().decode(
            RawInputEvent.self,
            from: Data(#"{"type":"mouseDown","x":1,"y":2,"button":4}"#.utf8))
        let state = InputState()
        state.enqueue(try #require(raw.event))
        state.beginFrame()

        #expect(state.isMouseDown)
        #expect(state.button == MouseButton(rawValue: 4))
    }

    /// **`MouseButton(rawValue: 0)` は左であって「無い」ではない。** 何も押していない
    /// ときに左を返すと、押す前に読んだ `mouseButton == .left` が真になる — `keyCode` を
    /// `Key?` にした理由と同じ ([ADR-0034] 影響節)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    @Test("まだ押していなければ、指している釦は無い")
    func hasNoButtonBeforeAnyPress() {
        let state = InputState()
        #expect(state.button == nil)

        // 押さずに動いても、スクロールしても、キーを押しても釦は現れない
        state.enqueue(.mouseMoved(x: 3, y: 4))
        state.enqueue(.scrolled(dx: 1, dy: 1))
        state.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
        state.beginFrame()
        #expect(state.button == nil)

        // 走っていないときに面が返す空の状態も同じ
        #expect(InputState.empty.button == nil)
    }

    /// `mouseReleased()` の中から「どの釦が離されたか」を知る口は他に無い
    /// ([ADR-0034] 影響節の `keyCode` と同じ)。押した釦と違う釦で離すと、離した側に
    /// 入れ替わる。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    @Test("最後に動いた釦は、押しても離しても入れ替わる")
    func remembersTheButtonThatMovedLast() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 1, y: 2, button: .right))
        state.beginFrame()
        #expect(state.button == .right)

        state.enqueue(.mouseUp(x: 1, y: 2, button: .center))
        state.beginFrame()
        #expect(!state.isMouseDown)
        #expect(state.button == .center)
    }
}

/// 面 (``Sketch/mouseButton``) から、コールバックの中で読む。GPU を要する。
@Suite(
    "釦をコールバックから読む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MouseButtonCallbackTests {
    /// 呼ばれた口と、その中で読めた釦を控える。
    final class Recorder: Sketch {
        var seen: [(name: String, button: MouseButton?)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            seen.append(("draw", mouseButton))
        }
        func mousePressed() { seen.append(("pressed", mouseButton)) }
        func mouseReleased() { seen.append(("released", mouseButton)) }
    }

    /// works の Quarry が `mouseReleased()` の中で離した釦を見て、掘る / 置くを分けている。
    /// 押す前の `draw()` では `nil` で、送った番号は面では名前で読める。
    @Test("離した釦を、mouseReleased() の中から読める")
    func readsTheReleasedButtonInMouseReleased() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-mouse-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        let sketch = Recorder()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        try runtime.advance()
        try AtomicFile.write(
            Data(
                #"""
                {"id":"b1","events":[
                  {"type":"mouseDown","x":4,"y":4,"button":1},
                  {"type":"mouseUp","x":4,"y":4,"button":1}]}
                """#.utf8),
            to: facet.appendingPathComponent("request.json"))
        try runtime.advance()

        #expect(sketch.seen.map(\.name) == ["draw", "pressed", "released", "draw"])
        #expect(sketch.seen.map(\.button) == [nil, .right, .right, .right])
    }
}
