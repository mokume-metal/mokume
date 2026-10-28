// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 作者が上書きするコールバックへ、**呼び出しがその名前と引数のまま届く**こと。GPU を要する。
///
/// どの出来事がどの呼び出しになるかは ``InputState`` が決め、`InputCallbackTests` が
/// 固めている。ここが見るのはその先 — 呼び出しを `Sketch` のメソッドへ配る `switch`
/// (``SketchRuntime`` の `deliver`) で、**10 のメソッドへの唯一の写し**である。
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
        /// `mouseMoved(deltaX:deltaY:)`。Swift は同じ基底名の case を 2 つ持てないので綴りを変える
        case mouseMovedBy(deltaX: Float, deltaY: Float)
        /// 引数なしの `mouseDragged()`。呼ばれた中で読んだ `mouseX` も控える (その出来事まで当てた位置になる)
        case mouseDraggedAt(mouseX: Float)
        /// `mouseDragged(deltaX:deltaY:)`。同じ基底名の case を 2 つ持てないので、引数なしの側は綴りを変えた
        case mouseDragged(deltaX: Float, deltaY: Float)
        case mouseWheel(deltaX: Float, deltaY: Float)
        /// `fileDropped(_:)`。呼ばれた中で読んだ `mouseX`・`mouseY` も控える ([#3061](https://github.com/mokume-metal/mokume/issues/3061))
        case fileDropped(paths: [String], mouseX: Float, mouseY: Float)
        /// どのキーが動いたかは ``Sketch/keyCode`` から読む (口の約束どおり)。
        case keyPressed(Key?)
        case keyReleased(Key?)
        /// 打たれた文字は ``Sketch/key`` から読む。
        case keyTyped(String)
    }

    /// 呼ばれた順に、名前と値を控えるだけのスケッチ。
    final class Recorder: Sketch {
        var calls: [Call] = []
        /// `setup()` で ``Sketch/noLoop()`` を呼ぶか。
        var stopsInSetup = false
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }

        func setup() {
            calls.append(.setup)
            if stopsInSetup { noLoop() }
        }
        func draw() {
            calls.append(.draw(frame: frameCount))
            background(.display(red: 0, green: 0, blue: 0))
        }
        func mousePressed() { calls.append(.mousePressed) }
        func mouseReleased() { calls.append(.mouseReleased) }
        func mouseClicked() { calls.append(.mouseClicked) }
        func mouseMoved() { calls.append(.mouseMoved) }
        func mouseMoved(deltaX: Float, deltaY: Float) {
            calls.append(.mouseMovedBy(deltaX: deltaX, deltaY: deltaY))
        }
        func mouseDragged() { calls.append(.mouseDraggedAt(mouseX: mouseX)) }
        func mouseDragged(deltaX: Float, deltaY: Float) {
            calls.append(.mouseDragged(deltaX: deltaX, deltaY: deltaY))
        }
        func mouseWheel(deltaX: Float, deltaY: Float) {
            calls.append(.mouseWheel(deltaX: deltaX, deltaY: deltaY))
        }
        func fileDropped(_ paths: [String]) {
            calls.append(.fileDropped(paths: paths, mouseX: mouseX, mouseY: mouseY))
        }
        func keyPressed() { calls.append(.keyPressed(keyCode)) }
        func keyReleased() { calls.append(.keyReleased(keyCode)) }
        func keyTyped() { calls.append(.keyTyped(key)) }
    }

    private func makeFacet() throws -> URL {
        let facet = try TestScratch.directory("mokume-callbacks")
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
            {"type":"mouseMovedBy","dx":-3,"dy":7},
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
                // 移動の直後に、その 1 件の量が続く。横と縦を取り違えると (12, 10) になる
                .mouseMovedBy(deltaX: 10, deltaY: 12),
                // 位置を持たない移動も同じ 2 つを呼ぶ。位置は動かないので次の押下の量は変わらない
                .mouseMoved,
                .mouseMovedBy(deltaX: -3, deltaY: 7),
                .mousePressed,
                // 1 件で動いた量 (当てる前の位置との差)。横と縦を取り違えると (4, 3) になる
                // 1 件ごとに、引数なしが先・量付きが後。引数なしの中の `mouseX` は、その出来事まで当てた位置
                .mouseDraggedAt(mouseX: 13),
                .mouseDragged(deltaX: 3, deltaY: 4),
                .mouseDraggedAt(mouseX: 8),
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

    /// 量付きの `mouseDragged(deltaX:deltaY:)` だけを書いたスケッチ。引数なしの口が増えても、
    /// 呼ばれ方が変わらないことを見る。
    final class DeltaOnlyDragRecorder: Sketch {
        var calls: [Call] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() { background(.display(red: 0, green: 0, blue: 0)) }
        func mouseDragged(deltaX: Float, deltaY: Float) {
            calls.append(.mouseDragged(deltaX: deltaX, deltaY: deltaY))
        }
    }

    /// 押したまま動いた 1 件ごとに、引数なしの `mouseDragged()` が 1 回、続けて
    /// `mouseDragged(deltaX:deltaY:)` が 1 回呼ばれる。**引数なしの中で読んだ `mouseX` は、その出来事まで
    /// 当てた位置**になる ([#3258](https://github.com/mokume-metal/mokume/issues/3258))。量付きだけを
    /// 書いた型は、これまでどおり 1 件につき 1 回だけ呼ばれる。
    @Test("押したまま動いた 1 件ごとに、引数なしの mouseDragged() が先、量付きが後に 1 回ずつ届く")
    func dragArrivesWithAndWithoutAmounts() throws {
        let events = #"""
            {"type":"mouseDown","x":10,"y":10,"button":0},
            {"type":"mouseMoved","x":20,"y":10},
            {"type":"mouseMoved","x":30,"y":10}
            """#

        let both = Recorder()
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: both, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try send(events, id: "d1", to: facet)
        try runtime.advance()
        #expect(
            both.calls.filter { call in
                switch call {
                case .mouseDraggedAt, .mouseDragged: true
                default: false
                }
            } == [
                .mouseDraggedAt(mouseX: 20), .mouseDragged(deltaX: 10, deltaY: 0),
                .mouseDraggedAt(mouseX: 30), .mouseDragged(deltaX: 10, deltaY: 0),
            ], "\(both.calls)")

        let deltaOnly = DeltaOnlyDragRecorder()
        let facet2 = try makeFacet()
        let runtime2 = try SketchRuntime(
            sketch: deltaOnly, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet2))
        try runtime2.advance()
        try send(events, id: "d2", to: facet2)
        try runtime2.advance()
        #expect(
            deltaOnly.calls == [
                .mouseDragged(deltaX: 10, deltaY: 0), .mouseDragged(deltaX: 10, deltaY: 0),
            ], "\(deltaOnly.calls)")
    }

    /// 外から落としを送ると、**次のフレームの頭**で `fileDropped(_:)` が 1 回、`draw()` より先に呼ばれ、
    /// その中で落とした所が `mouseX`・`mouseY` から読める。`mouseMoved()` は呼ばれない
    /// ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。止めている間 (`noLoop()`) も届く。
    @Test("落としは fileDropped(_:) に届き、中で mouseX・mouseY が落とした所になる", arguments: [false, true])
    func aDropArrivesByNameWithItsPosition(stopped: Bool) throws {
        let facet = try makeFacet()
        let sketch = Recorder()
        sketch.stopsInSetup = stopped
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try send(
            #"{"type":"fileDropped","paths":["/tmp/a.png","/tmp/b.png"],"x":10,"y":20}"#,
            id: "f1", to: facet)
        try runtime.advance()
        let expected: [Call] = [
            .setup, .draw(frame: 1),
            .fileDropped(paths: ["/tmp/a.png", "/tmp/b.png"], mouseX: 10, mouseY: 20),
        ]
        // 回っているときは、同じフレームの draw() より先に呼ばれる。止めている間は draw() を呼ばない
        #expect(sketch.calls == expected + (stopped ? [] : [.draw(frame: 2)]), "\(sketch.calls)")
    }

    /// ``Sketch/keyPressed()`` の説明が勧める「1 回だけ効かせる」書き方を、そのまま写した
    /// スケッチ。**説明の例を書き換えたら、ここも同じ形に揃える** — 見ているのは、説明が
    /// 約束する書き方で約束どおりに効くことである。
    final class OncePerPress: Sketch {
        /// `setup()` で ``Sketch/noLoop()`` を呼ぶか。
        var stopsInSetup = false
        /// 1 回だけ効かせたいことが、実際に効いた回数。
        var fired = 0
        /// 呼ばれた時点で `keyboard.justPressed(.space)` が返した値。
        var seenJustPressed: [Bool] = []
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
            seenJustPressed.append(keyboard.justPressed(.space))
            if keyCode == .space { fired += 1 }
        }
    }

    /// **`keyPressed()` は押した 1 回だけ呼ばれる** ([#2400](https://github.com/mokume-metal/mokume/issues/2400))。
    /// 窓の実操作でも OS のキーリピートは同じ形 (`isRepeat`) で届くので、外から送った列で
    /// 窓の振る舞いを見られる ([#1365](https://github.com/mokume-metal/mokume/issues/1365))。
    ///
    /// 止めた側も見るのは、止めている間は `draw()` が呼ばれず、前のフレームと比べる
    /// 形が使えないためである。コールバックだけで閉じていれば、そこでも同じに効く。
    @Test(
        "keyPressed は押しっぱなしのリピートでは呼ばれず、押し直すと呼ばれる",
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
        // 呼ばれた中からも、押した瞬間として読める (止めている間に配った分も含む)
        #expect(sketch.seenJustPressed == [true, true])
        // 止めた側は、止まった経路 (`draw()` を呼ばずにコールバックだけを配る) を通っている
        #expect(sketch.drawCalls == (stopsInSetup ? 1 : 2))
    }
    /// `draw()` から見た押下の 3 語を、描いたフレームごとに控えるスケッチ。
    final class EdgeReader: Sketch {
        enum Stop { case none, noLoop, pauseTime }
        var stop = Stop.none
        /// 描いたフレームごとの (`isPressed`, `justPressed`, `justReleased`) (space)。
        var seen: [Seen] = []
        struct Seen: Equatable {
            let isPressed: Bool
            let justPressed: Bool
            let justReleased: Bool
        }
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }

        func setup() {
            switch stop {
            case .none: break
            case .noLoop: noLoop()
            case .pauseTime: pauseTime()
            }
        }
        func draw() {
            seen.append(
                Seen(
                    isPressed: keyboard.isPressed(.space),
                    justPressed: keyboard.justPressed(.space),
                    justReleased: keyboard.justReleased(.space)))
            background(.display(red: 0, green: 0, blue: 0))
        }
        /// 止めている間に 1 枚描かせる口
        func keyPressed() {
            if keyCode == .enter { redraw() }
        }
    }

    /// **端を消すのは描いたフレームの終わり** (#2599 の条件 7・#2580 の R2)。止めている間
    /// (`noLoop()`) の配りはフレームの外で回るので、頭で消すと次に描く 1 枚から見えない。
    /// 時刻を止めている間 (`pauseTime()`) はフレームが回るので、解放の次のフレームで読める。
    @Test("止めている間に離したキーは、次に描くフレームで 1 度だけ justReleased になる")
    func releaseWhileStoppedShowsInTheNextDrawnFrame() throws {
        let enterDown = #"{"type":"keyDown","code":36},{"type":"keyUp","code":36}"#

        // noLoop: 押す・離すは止まった配りで届き、return の描き直しで初めて描く
        let facet = try makeFacet()
        let stopped = EdgeReader()
        stopped.stop = .noLoop
        let runtime = try SketchRuntime(
            sketch: stopped, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try send(#"{"type":"keyDown","code":49,"characters":" "}"#, id: "s1", to: facet)
        try runtime.advance()
        try send(#"{"type":"keyUp","code":49}"#, id: "s2", to: facet)
        try runtime.advance()
        try send(enterDown, id: "s3", to: facet)
        try runtime.advance()
        try send(enterDown, id: "s4", to: facet)
        try runtime.advance()
        #expect(
            stopped.seen == [
                .init(isPressed: false, justPressed: false, justReleased: false),
                .init(isPressed: false, justPressed: true, justReleased: true),
                .init(isPressed: false, justPressed: false, justReleased: false),
            ])

        // pauseTime: フレームは回るので、解放の次のフレームで 1 度だけ立つ
        let pausedFacet = try makeFacet()
        let paused = EdgeReader()
        paused.stop = .pauseTime
        let pausedRuntime = try SketchRuntime(
            sketch: paused, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: pausedFacet))
        try pausedRuntime.advance()
        try send(#"{"type":"keyDown","code":49,"characters":" "}"#, id: "p1", to: pausedFacet)
        try pausedRuntime.advance()
        try send(#"{"type":"keyUp","code":49}"#, id: "p2", to: pausedFacet)
        try pausedRuntime.advance()
        try pausedRuntime.advance()
        #expect(
            paused.seen == [
                .init(isPressed: false, justPressed: false, justReleased: false),
                .init(isPressed: true, justPressed: true, justReleased: false),
                .init(isPressed: false, justPressed: false, justReleased: true),
                .init(isPressed: false, justPressed: false, justReleased: false),
            ])
    }
}
