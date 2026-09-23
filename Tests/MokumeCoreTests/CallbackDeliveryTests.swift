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
}
