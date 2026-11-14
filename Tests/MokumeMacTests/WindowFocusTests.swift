// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import IOSurface
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeMac

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

    /// **退いた知らせそのものは押下を離さない** ([#3709](https://github.com/mokume-metal/mokume/issues/3709) の決定)。
    /// 合流点に積まれた押下は、ウィンドウのものも注入したものも同じ形なので、ここで離すと注入した押下まで離す
    /// (#2443 の約束を破る)。ウィンドウの押下を離すのはウィンドウ (`SketchSurface`・下の `FocusLossSurfaceTests`)。
    @Test("注入した押下は、退いた知らせが届いても残り、呼び出しも出ない。注入した解放で離れる")
    func injectedPressesSurviveLeaving() {
        let state = InputState()
        _ = run(
            state,
            [
                .keyDown(code: .arrowRight, characters: "\u{F703}", isRepeat: false),
                .mouseDown(x: 4, y: 5, button: .left),
            ])
        let seen = run(state, [.focusChanged(focused: false)])
        #expect(seen.isEmpty, "退いた知らせで呼び出しを出した: \(seen)")
        #expect(!state.focused)
        #expect(Keyboard(state: state).isPressed(.arrowRight), "注入したキーを離した")
        #expect(state.isMouseDown, "注入したボタンを離した")

        // 注入した側の解放で離れる (退いている間でも)
        let released = run(state, [.keyUp(code: .arrowRight), .mouseUp(x: 4, y: 5, button: .left)])
        #expect(released == [.keyReleased, .mouseReleased, .mouseClicked], "\(released)")
        #expect(state.pressedKeys.isEmpty && !state.isMouseDown)
        #expect(!state.focused, "解放で前に戻った扱いになった")
    }

    @Test("溜めきれずに先に当てる 1 件が退いた知らせでも、状態に入り、押下は離さない")
    func overflowAppliesTheFocusOnly() {
        let state = InputState()
        _ = run(state, [.keyDown(code: .a, characters: "a", isRepeat: false)])
        state.enqueue(.focusChanged(focused: false))
        for _ in 0..<InputState.queueLimit { state.enqueue(.scrolled(dx: 0, dy: 1)) }
        #expect(!state.focused, "溢れて当てた知らせが状態に入っていない")
        #expect(state.pressedKeys == [.a], "溢れて当てた知らせが押下を離した")
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

    @Test("注入した focusChanged で focused が変わる。注入した押下は退いても残り、注入した解放で離れる")
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
        #expect(sketch.focusedWhenKeyReleased.isEmpty, "注入したキーを退いた知らせで離した")
        #expect(sketch.mouseReleases == 0, "注入したボタンを退いた知らせで離した")
        #expect(runtime.input.pressedKeys == [.a] && runtime.input.isMouseDown)

        try send(#"{"type":"keyUp","code":0},{"type":"mouseUp","x":2,"y":3}"#, id: "f3", to: facet)
        try runtime.advance()
        #expect(sketch.focusedWhenKeyReleased == [false])
        #expect(sketch.mouseReleases == 1)
        #expect(runtime.input.pressedKeys.isEmpty && !runtime.input.isMouseDown)

        try send(#"{"type":"focusChanged","focused":true}"#, id: "f4", to: facet)
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

/// **ウィンドウが退いたときに離すのは、ウィンドウが流した押下だけ** ([#2443](https://github.com/mokume-metal/mokume/issues/2443)・
/// [#3709](https://github.com/mokume-metal/mokume/issues/3709) の決定)。面をウィンドウへ載せるが前には出さず、退いた知らせを
/// 送って、ウィンドウの押下と注入した押下が混ざった合流点を見る。面を作るのに Metal の装置が要る。
@Suite(
    "ウィンドウが退いたときの押下",
    .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
@MainActor
struct FocusLossSurfaceTests {
    @Test("退くと、ウィンドウの押下だけが離れ、注入した押下は残る。離した呼び出しの中から読む focused は false")
    func onlyWindowPressesAreReleased() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let input = InputState()
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: input,
            canvasSize: (64, 64))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.contentView = nil }
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        // ウィンドウの押下 (面が流す) と、注入した押下 (合流点へ直に積む)
        surface.deliver(.keyDown(code: .a, characters: "a", isRepeat: false))
        surface.deliver(.mouseDown(x: 5, y: 6, button: .left))
        input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
        input.enqueue(.mouseDown(x: 5, y: 6, button: .right))
        input.beginFrame()
        input.endFrame()
        lines.removeAll()

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        // 運び先 (道具のウィンドウなら子) へも、退いた知らせの後にウィンドウの分の解放だけが流れる
        #expect(
            lines == [
                InputEvent.focusChanged(focused: false).wireLine,
                InputEvent.keyUp(code: .a).wireLine,
                InputEvent.mouseUp(x: 5, y: 6, button: .left).wireLine,
            ], "\(lines)")

        var calls: [InputCallback] = []
        var focusedInCalls: [Bool] = []
        input.beginFrame { callback in
            calls.append(callback)
            focusedInCalls.append(input.focused)
        }
        #expect(calls == [.keyReleased, .mouseReleased, .mouseClicked], "\(calls)")
        #expect(focusedInCalls.allSatisfy { !$0 }, "離した呼び出しの中で、まだ前にある扱いだった")
        let keyboard = Keyboard(state: input)
        #expect(!keyboard.isPressed(.a), "ウィンドウのキーが残った")
        #expect(keyboard.isPressed(.space), "注入したキーを離した")
        #expect(input.pressedButtons == [.right], "離したボタンが違う: \(input.pressedButtons)")
        #expect(!input.focused)
    }
}
