// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// ウィンドウが前にあるか (`focused`) と、ウィンドウの題名を変える頼み (`windowTitle(_:)`)
/// ([#3709](https://github.com/mokume-metal/mokume/issues/3709))。
///
/// **ウィンドウを開かずに見る。** `focused` はウィンドウの key の出入りを入力の出来事 `focusChanged` にして運ぶので、
/// 外から送る線・合流点・走っている実行で、機材も人の操作も無しに確かめられる。題名の頼みは、走っている実行の
/// 格納と共有面の属性で見る。本物のウィンドウで題名が変わるか・⌘Tab で `focused` が変わるかは人の手 (PR 本文)。
@Suite("ウィンドウが前にあるか: 線")
struct FocusChangedWireTests {
    private func decode(_ json: String) throws -> RawInputEvent {
        try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8))
    }

    @Test("前に出た・退いたは、線へ書いて読み戻すと同じ出来事になる", arguments: [true, false])
    func survivesTheWire(focused: Bool) throws {
        let event = InputEvent.focusChanged(focused: focused)
        #expect(event.wireLine == #"{"type":"focusChanged","focused":\#(focused)}"# + "\n")
        #expect(try decode(event.wireLine).event == event)
    }

    @Test("focused が無い・null の focusChanged は読めない 1 件。真偽でない値は解けない")
    func focusedIsRequired() throws {
        #expect(try decode(#"{"type": "focusChanged"}"#).event == nil)
        #expect(try decode(#"{"type": "focusChanged", "focused": null}"#).event == nil)
        #expect(throws: (any Error).self) { try decode(#"{"type": "focusChanged", "focused": 0}"#) }
    }

    @Test("focused は focusChanged でだけ読む。ほかの種別に付いていても、その 1 件は通る")
    func focusedIsReadOnFocusChangedOnly() throws {
        #expect(RawInputEvent.readKeys(forType: "focusChanged").contains("focused"))
        #expect(!RawInputEvent.readKeys(forType: "keyUp").contains("focused"))
        #expect(!RawInputEvent.readKeys(forType: "focusChanged").contains("paths"))
        // 型の違う値でも、読まない種別ではその 1 件を落とさない (解放が落ちるとキーが押されたまま残る)
        #expect(
            try decode(#"{"type": "keyUp", "code": 0, "focused": "no"}"#).event == .keyUp(code: .a))
    }
}

@Suite("ウィンドウが前にあるか: 合流点")
@MainActor
struct FocusChangedInputTests {
    private func run(_ state: InputState, _ events: [InputEvent]) -> [InputCallback] {
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    @Test("true から始まり、届いたフレームから変わる。呼び出しは生まない")
    func followsTheEvents() {
        let state = InputState()
        #expect(state.focused, "前に出る前から退いた扱いにした")
        state.enqueue(.focusChanged(focused: false))
        #expect(state.focused, "フレームの頭より前に変わった")
        #expect(run(state, []).isEmpty)
        #expect(!state.focused)
        #expect(run(state, [.focusChanged(focused: true)]).isEmpty)
        #expect(state.focused)
    }

    @Test("退いたら、押しているキーとボタンを離し、keyReleased・mouseReleased を配る")
    func leavingReleasesWhatIsHeld() {
        let state = InputState()
        _ = run(
            state,
            [
                .keyDown(code: .s, characters: "s", isRepeat: false),
                .keyDown(code: .a, characters: "a", isRepeat: false),
                .keyDown(code: .shift, characters: "", isRepeat: false),
                .mouseDown(x: 4, y: 5, button: .right),
            ])
        var seen: [InputCallback] = []
        var focusedWhenReleased: [Bool] = []
        state.enqueue(.focusChanged(focused: false))
        state.beginFrame { callback in
            seen.append(callback)
            focusedWhenReleased.append(state.focused)
        }
        // キーは番号順 (a = 0, s = 1)。修飾キーは押下の状態だけを戻す。ボタンは押したまま離すのでクリックにもなる
        #expect(seen == [.keyReleased, .keyReleased, .mouseReleased, .mouseClicked], "\(seen)")
        #expect(focusedWhenReleased.allSatisfy { !$0 }, "離した呼び出しの中で、まだ前にある扱いだった")
        #expect(state.pressedKeys.isEmpty)
        #expect(!state.isMouseDown)
        #expect(state.x == 4 && state.y == 5, "離した扱いで位置が動いた")
    }

    @Test("離すのは当てる時点で押されているものだけ。退いた後の押下は残り、前に出ても離さない")
    func releasesAreDecidedWhenApplied() {
        let state = InputState()
        // 同じフレームで、押す → 退く → 押す
        let seen = run(
            state,
            [
                .keyDown(code: .a, characters: "a", isRepeat: false),
                .focusChanged(focused: false),
                .keyDown(code: .s, characters: "s", isRepeat: false),
            ])
        #expect(
            seen == [.keyPressed, .keyTyped, .keyReleased, .keyPressed, .keyTyped], "\(seen)")
        #expect(state.pressedKeys == [.s])
        // 前に出ても何も離さない
        #expect(run(state, [.focusChanged(focused: true)]).isEmpty)
        #expect(state.pressedKeys == [.s])
        // 何も押していないときに退いても、何も配らない
        _ = run(state, [.keyUp(code: .s)])
        #expect(run(state, [.focusChanged(focused: false)]).isEmpty)
    }

    @Test("溜めきれずに先に当てる 1 件が退いた知らせでも、押しているキーを離す")
    func overflowStillReleases() {
        let state = InputState()
        _ = run(state, [.keyDown(code: .a, characters: "a", isRepeat: false)])
        state.enqueue(.focusChanged(focused: false))
        for _ in 0..<InputState.queueLimit { state.enqueue(.scrolled(dx: 0, dy: 1)) }
        #expect(!state.focused, "溢れて当てた知らせが状態に入っていない")
        #expect(state.pressedKeys.isEmpty, "溢れて当てた知らせが押下を離していない")
    }

    @Test("区画から送ると accepted。focused の無い 1 件は ignored")
    func theInboxTakesIt() throws {
        let facet = try TestScratch.directory("mokume-focus")
        defer { try? FileManager.default.removeItem(at: facet) }
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try AtomicFile.write(
            Data(
                (#"{"id":"f1","events":[{"type":"focusChanged","focused":false},"#
                    + #"{"type":"focusChanged"}]}"#).utf8),
            to: facet.appendingPathComponent("request.json"))
        let report = try #require(inbox.drain(into: state))
        #expect(report.accepted == 1 && report.ignored == 1, "\(report)")
        state.beginFrame()
        #expect(!state.focused)
    }
}

@Suite("ウィンドウの題名を変える頼み: 面の属性")
struct WindowTitleAttributeTests {
    private func makeSurface() throws -> IOSurfaceRef {
        try #require(IOSurfaceCreate(SharedFrameSurface.properties(width: 4, height: 4)))
    }

    @Test("載せた題名を読める。日本語も運ぶ。頼んでいなければ属性ごと消す")
    func publishesAndRemoves() throws {
        let surface = try makeSurface()
        #expect(SharedFrameSurface.windowTitleRequest(on: surface) == nil)
        SharedFrameSurface.publishWindowTitle("押した 3 回", to: surface)
        #expect(SharedFrameSurface.windowTitleRequest(on: surface) == "押した 3 回")
        SharedFrameSurface.publishWindowTitle(nil, to: surface)
        #expect(SharedFrameSurface.windowTitleRequest(on: surface) == nil)
        #expect(IOSurfaceCopyValue(surface, SharedFrameSurface.windowTitleAttribute as CFString) == nil)
        // 文字列でない値は頼みとして読まない
        IOSurfaceSetValue(surface, SharedFrameSurface.windowTitleAttribute as CFString, NSNumber(value: 3))
        #expect(SharedFrameSurface.windowTitleRequest(on: surface) == nil)
    }
}

/// 題名を変えるスケッチ。押すと題名を変える。
final class Retitler: Sketch {
    var title: String?
    init() {}
    var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
    func draw() {
        background(0)
        if let title { windowTitle(title) }
    }
}

/// 走っていないスケッチから呼んでも止まらない。GPU は使わない。
@Suite("走っていないときの題名と focused")
@MainActor
struct WindowTitleOutsideRunTests {
    @Test("走っていないときに題名を変えても止まらず 1 度だけ警告し、focused は警告せずに true")
    func warnsOnceAndDoesNothing() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            #expect(runningSketch == nil)
            let sketch = Retitler()
            sketch.windowTitle("a")
            sketch.windowTitle("b")
            #expect(log.message(for: "windowTitle(_:)") != nil)
            #expect(sketch.focused)
            #expect(log.messages.count == 1, "\(log.messages)")
        }
    }
}

/// 外から送った `focusChanged` が作品の `focused` と呼び出しに届くか、題名の頼みがどこへ行くか。GPU を要する。
@Suite(
    "ウィンドウが前にあるか・題名: スケッチから",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct WindowFocusSketchTests {
    final class Watcher: Sketch {
        var seen: [Bool] = []
        var focusedWhenKeyReleased: [Bool] = []
        var mouseReleases = 0
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(0)
            seen.append(focused)
        }
        func keyReleased() { focusedWhenKeyReleased.append(focused) }
        func mouseReleased() { mouseReleases += 1 }
    }

    private func send(_ events: String, id: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    @Test("注入した focusChanged で focused が変わり、false で押しているキーとボタンが離れる")
    func injectedFocusReachesTheSketch() throws {
        let facet = try TestScratch.directory("mokume-focus-sketch")
        defer { try? FileManager.default.removeItem(at: facet) }
        let sketch = Watcher()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try send(
            #"{"type":"keyDown","code":0,"characters":"a"},{"type":"mouseDown","x":2,"y":3}"#,
            id: "f1", to: facet)
        try runtime.advance()
        #expect(runtime.input.pressedKeys == [.a] && runtime.input.isMouseDown, "検査の前提: 押している")

        try send(#"{"type":"focusChanged","focused":false}"#, id: "f2", to: facet)
        try runtime.advance()
        #expect(sketch.seen == [true, true, false], "\(sketch.seen)")
        #expect(sketch.focusedWhenKeyReleased == [false])
        #expect(sketch.mouseReleases == 1)
        #expect(runtime.input.pressedKeys.isEmpty && !runtime.input.isMouseDown)

        try send(#"{"type":"focusChanged","focused":true}"#, id: "f3", to: facet)
        try runtime.advance()
        #expect(sketch.seen.last == true)
    }

    @Test("ウィンドウの無い実行では、題名の頼みを覚えるだけで止まらず、呼び直すと差し替わる")
    func aWindowlessRunKeepsTheRequest() throws {
        let sketch = Retitler()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)
        try runtime.advance()
        #expect(runtime.windowTitleRequest == nil, "呼んでいないのに頼みがある")
        sketch.title = "one"
        try runtime.advance()
        #expect(runtime.windowTitleRequest == "one")
        sketch.title = "two"
        try runtime.advance()
        #expect(runtime.windowTitleRequest == "two")
        // 呼ぶのをやめても、次に呼ぶまで残る
        sketch.title = nil
        try runtime.advance()
        #expect(runtime.windowTitleRequest == "two")
    }

    @Test("SketchView の中では題名の頼みを持たず、何度呼んでも 1 度だけ知らせる")
    func anEmbeddedRunWarnsOnce() throws {
        let sketch = Retitler()
        sketch.title = "host's"
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, embedded: true)
        for _ in 0..<3 { try runtime.advance() }
        #expect(runtime.windowTitleRequest == nil, "ホストの題名を奪う頼みを持った")
        #expect(runtime.warnings.message(for: .windowTitleInSketchView) != nil)
        #expect(runtime.warnings.count { $0 == .windowTitleInSketchView } == 1)
    }

    /// 見張りの子はウィンドウを持たない ([ADR-0032] 決定 1)。題名を変えるのは道具の作品のウィンドウなので、頼みは共有面の
    /// 属性で渡る。名乗るのは 1 枚遅れる (#748)。止まったスケッチの頼みの変化も、絵の鍵に入るので焼き直して渡る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("見張りの子は、題名の頼みを共有面に載せる")
    func theChildPublishesTheTitle() throws {
        let facet = try TestScratch.directory("mokume-window-title")
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let sketch = Retitler()
        let gpu = try RenderDevice()
        let application = try SketchApplication(sketch: sketch, gpu: gpu)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        #expect(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")

        func refresh() {
            application.displayLinkFired()
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        }
        for _ in 0..<3 { refresh() }
        let manifest = try #require(SharedFrameSurface.readManifest(at: facet))
        let untitled = try #require(SharedFrameSurface.newest(among: manifest.ids))
        let untitledSurface = try #require(IOSurfaceLookup(untitled.id))
        #expect(SharedFrameSurface.windowTitleRequest(on: untitledSurface) == nil)

        sketch.title = "clicked 3"
        for _ in 0..<3 { refresh() }
        let titled = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(titled.frame > untitled.frame)
        let titledSurface = try #require(IOSurfaceLookup(titled.id))
        #expect(SharedFrameSurface.windowTitleRequest(on: titledSurface) == "clicked 3")
    }
}
