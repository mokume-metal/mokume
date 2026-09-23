// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作者が上書きするコールバックへ、**呼び出しがその名前と引数のまま届く**こと。GPU を要する。
///
/// どの出来事がどの呼び出しになるかは ``InputState`` が決め、`InputCallbackTests` が
/// 固めている。ここが見るのはその先 — 呼び出しを `Sketch` のメソッドへ配る `switch`
/// (``SketchRuntime`` の `deliver`) で、**9 つのメソッドへの唯一の写し**である。
/// `keyPressed` と `keyReleased` を取り違えても、`mouseDragged` の 2 つの引数を入れ替えても
/// 型は合うので、コンパイルは通り、`InputState` を見る検査も緑のままになる
/// ([#1386](https://github.com/mokume-metal/mokume/issues/1386))。
///
/// 出来事は**外から送る区画** (`.mokume/input`、`Schemas/input-request.schema.json`) から
/// 送る。窓からの実操作も同じ ``InputState`` を通るので、ここで配り分けが合っていれば
/// 窓でも合っている。
@Suite(
    "コールバックへの配り分け",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CallbackDeliveryTests {
    /// 呼ばれた口と、口が受け取った値。
    enum Call: Equatable {
        case setup
        /// `draw()`。そのときのフレーム番号を控える。
        case draw(frame: Int)
        case mousePressed
        case mouseReleased
        case mouseClicked
        case mouseMoved
        case mouseDragged(deltaX: Float, deltaY: Float)
        case mouseWheel(deltaX: Float, deltaY: Float)
        /// どのキーが動いたかは ``Sketch/keyCode`` から読む (口の約束どおり)。
        case keyPressed(Key?)
        case keyReleased(Key?)
        /// 打たれた文字は ``Sketch/key`` から読む。
        case keyTyped(String)
    }

    /// 呼ばれた順に、名前と値を控えるだけのスケッチ。
    final class Recorder: Sketch {
        var calls: [Call] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }

        func setup() { calls.append(.setup) }
        func draw() {
            calls.append(.draw(frame: frameCount))
            background(.display(red: 0, green: 0, blue: 0))
        }
        func mousePressed() { calls.append(.mousePressed) }
        func mouseReleased() { calls.append(.mouseReleased) }
        func mouseClicked() { calls.append(.mouseClicked) }
        func mouseMoved() { calls.append(.mouseMoved) }
        func mouseDragged(deltaX: Float, deltaY: Float) {
            calls.append(.mouseDragged(deltaX: deltaX, deltaY: deltaY))
        }
        func mouseWheel(deltaX: Float, deltaY: Float) {
            calls.append(.mouseWheel(deltaX: deltaX, deltaY: deltaY))
        }
        func keyPressed() { calls.append(.keyPressed(keyCode)) }
        func keyReleased() { calls.append(.keyReleased(keyCode)) }
        func keyTyped() { calls.append(.keyTyped(key)) }
    }

    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-callbacks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return facet
    }

    private func send(_ events: String, id: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    /// **値は、どの 2 つを入れ替えても列が変わるものにした。** 引きずりの 2 件と
    /// スクロールの 1 件は、横と縦で大きさも符号も違う。押すキーと離すキーは同じだが、
    /// 押下のあとには打鍵が続くので、押下と解放を取り違えると並びがずれる。
    ///
    /// 矢印キーは**打鍵を生まない** (``Sketch/keyTyped()`` の約束)。押下から打鍵を
    /// 導く写しがどこかに紛れ込めば、ここに余計な 1 件が出る。
    @Test("出来事の列が、名前と引数のまま、draw() より先に届く")
    func callbacksArriveByNameWithTheirArgumentsBeforeDraw() throws {
        let facet = try makeFacet()
        let sketch = Recorder()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        // 何も送らずに 1 枚。**送った列が 2 枚目の draw() の前に挟まる**ことを見るため
        try runtime.advance()
        try send(
            #"""
            {"type":"mouseMoved","x":10,"y":12},
            {"type":"mouseDown","x":10,"y":12,"button":0},
            {"type":"mouseMoved","x":13,"y":16},
            {"type":"mouseMoved","x":8,"y":22},
            {"type":"mouseUp","x":8,"y":22,"button":0},
            {"type":"scrolled","dx":1.5,"dy":-2},
            {"type":"keyDown","code":0,"characters":"a"},
            {"type":"keyUp","code":0},
            {"type":"keyDown","code":126,"characters":"\uf700"},
            {"type":"keyUp","code":126}
            """#, id: "c1", to: facet)
        try runtime.advance()

        #expect(
            sketch.calls == [
                .setup,
                .draw(frame: 1),
                .mouseMoved,
                .mousePressed,
                // 1 件で動いた量 (当てる前の位置との差)。横と縦を取り違えると (4, 3) になる
                .mouseDragged(deltaX: 3, deltaY: 4),
                .mouseDragged(deltaX: -5, deltaY: 6),
                .mouseReleased,
                .mouseClicked,
                .mouseWheel(deltaX: 1.5, deltaY: -2),
                .keyPressed(.a),
                .keyTyped("a"),
                .keyReleased(.a),
                .keyPressed(.arrowUp),
                .keyReleased(.arrowUp),
                // **回っている間、コールバックは同じフレームの draw() より先に呼ばれる**
                // (``Sketch/mousePressed()`` の「`draw()` の直前に、届いた順で呼ばれる」)
                .draw(frame: 2),
            ])
    }

    /// ``Sketch/keyPressed()`` の説明が勧める「1 回だけ効かせる」書き方を、そのまま写した
    /// スケッチ。**説明の例を書き換えたら、ここも同じ形に揃える** — 見ているのは、説明が
    /// 約束する書き方で約束どおりに効くことである。
    final class OncePerPress: Sketch {
        /// `setup()` で ``Sketch/noLoop()`` を呼ぶか。
        var stopsInSetup = false
        var spaceHeld = false
        /// 1 回だけ効かせたいことが、実際に効いた回数。
        var fired = 0
        /// 呼ばれた時点で `isKeyDown(.space)` が返した値。
        var seenKeyDown: [Bool] = []
        var drawCalls = 0
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }

        func setup() {
            if stopsInSetup { noLoop() }
        }
        func draw() {
            drawCalls += 1
            background(.display(red: 0, green: 0, blue: 0))
        }
        func keyPressed() {
            seenKeyDown.append(isKeyDown(.space))
            guard keyCode == .space, !spaceHeld else { return }
            spaceHeld = true
            fired += 1
        }
        func keyReleased() {
            if keyCode == .space { spaceHeld = false }
        }
    }

    /// **連射と最初の 1 回の違いは、送る列の `isRepeat` にしか無い** — 窓の実操作でも
    /// OS のキーリピートは同じ形で届く。スケッチからはそれが読めないので、勧める書き方が
    /// 見分けに使えるのは押下と解放の対だけである
    /// ([#1365](https://github.com/mokume-metal/mokume/issues/1365))。
    ///
    /// 止めた側も見るのは、止めている間は `draw()` が呼ばれず、前のフレームと比べる
    /// 形が使えないためである。コールバックだけで閉じていれば、そこでも同じに効く。
    @Test(
        "keyPressed の説明が勧める書き方なら、押しっぱなしの連射では効かず、押し直すと効く",
        arguments: [false, true])
    func recommendedFormFiresOncePerPress(stopsInSetup: Bool) throws {
        let facet = try makeFacet()
        let sketch = OncePerPress()
        sketch.stopsInSetup = stopsInSetup
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        try runtime.advance()
        try send(
            #"""
            {"type":"keyDown","code":49,"characters":" ","isRepeat":false},
            {"type":"keyDown","code":49,"characters":" ","isRepeat":true},
            {"type":"keyDown","code":49,"characters":" ","isRepeat":true},
            {"type":"keyUp","code":49},
            {"type":"keyDown","code":49,"characters":" ","isRepeat":false}
            """#, id: "k1", to: facet)
        try runtime.advance()

        #expect(sketch.fired == 2, "押した 2 回のぶんだけ効くはずが、\(sketch.fired) 回効いた")
        // 説明が名乗る事実: 呼ばれた時点でそのキーは既に押されている集合に入っている。
        // **最初の 1 回でも `true`** なので、`isKeyDown` では連射と見分けられない
        #expect(sketch.seenKeyDown == [true, true, true, true])
        // 止めた側は、止まった経路 (`draw()` を呼ばずにコールバックだけを配る) を通っている
        #expect(sketch.drawCalls == (stopsInSetup ? 1 : 2))
    }
}
