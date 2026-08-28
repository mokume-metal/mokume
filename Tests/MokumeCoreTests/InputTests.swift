// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

@Suite("入力の合流点")
struct InputStateTests {
    @Test("流し込むまでは見えず、流し込んだら見える")
    func appliesOnlyAtTheStartOfAFrame() {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 10, y: 20))
        // 溜めただけでは、走っている絵の見え方は変わらない
        #expect(state.x == 0)

        state.beginFrame()
        #expect(state.x == 10)
        #expect(state.y == 20)
    }

    @Test("前のフレームでの位置は、ちょうど 1 フレーム前を指す")
    func remembersWhereItWasLastFrame() {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 10, y: 10))
        state.beginFrame()
        state.enqueue(.mouseMoved(x: 30, y: 40))
        state.beginFrame()

        #expect(state.x == 30)
        #expect(state.previousX == 10)
        #expect(state.previousY == 10)
    }

    @Test("押した瞬間は、引きずった量が増えない")
    func pressingDoesNotCountAsDragging() {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 10, y: 10))
        state.beginFrame()

        // 前の位置から遠く離れた場所で押す。位置の差は大きいが、押下は移動ではない
        state.enqueue(.mouseDown(x: 200, y: 150, button: 0))
        state.beginFrame()
        #expect(state.x - state.previousX == 190)
        #expect(state.dragX == 0)
        #expect(state.dragY == 0)
    }

    @Test("押している間の移動だけが、引きずった量になる")
    func onlyMovementWhileHeldCounts() {
        let state = InputState()
        // 押す前の移動は数えない
        state.enqueue(.mouseMoved(x: 10, y: 10))
        state.enqueue(.mouseDown(x: 10, y: 10, button: 0))
        state.enqueue(.mouseMoved(x: 30, y: 25))
        state.beginFrame()
        #expect(state.dragX == 20)
        #expect(state.dragY == 15)

        // 離したあとの移動も数えない
        state.enqueue(.mouseUp(x: 30, y: 25, button: 0))
        state.enqueue(.mouseMoved(x: 100, y: 100))
        state.beginFrame()
        #expect(state.dragX == 0)
        #expect(state.dragY == 0)
    }

    @Test("1 フレームにまとめて届いても、引きずった量は取りこぼさない")
    func draggingAccumulatesAcrossEventsInOneFrame() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 0, y: 0, button: 0))
        state.beginFrame()

        // 行って戻る。**足し込みなので経路のとおりに数える**
        for step in [10, 25, 40, 30] {
            state.enqueue(.mouseMoved(x: Float(step), y: 0))
        }
        state.beginFrame()
        #expect(state.dragX == 30)

        // フレームが変われば 0 から数え直す
        state.beginFrame()
        #expect(state.dragX == 0)
    }

    @Test("押して離すと、押されている状態がその通りに変わる")
    func followsTheButton() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 1, y: 2, button: 1))
        state.beginFrame()
        #expect(state.isMouseDown)
        #expect(state.button == 1)

        state.enqueue(.mouseUp(x: 1, y: 2, button: 1))
        state.beginFrame()
        #expect(!state.isMouseDown)
    }

    @Test("スクロールはそのフレームのぶんだけ")
    func scrollIsPerFrame() {
        let state = InputState()
        state.enqueue(.scrolled(dx: 1, dy: 2))
        state.enqueue(.scrolled(dx: 3, dy: 4))
        state.beginFrame()
        #expect(state.scrollX == 4)
        #expect(state.scrollY == 6)

        state.beginFrame()
        #expect(state.scrollX == 0)
    }

    @Test("押されているキーを覚え、離したら忘れる")
    func tracksHeldKeys() {
        let state = InputState()
        state.enqueue(.keyDown(code: 49, characters: " ", isRepeat: false))
        state.beginFrame()
        #expect(state.pressedKeys.contains(49))
        #expect(state.characters == " ")

        state.enqueue(.keyUp(code: 49))
        state.beginFrame()
        #expect(!state.pressedKeys.contains(49))
    }

    @Test("送りすぎても、溜めた量は上限で頭打ちになる")
    func doesNotGrowWithoutBound() {
        let state = InputState()
        for i in 0..<(InputState.queueLimit + 500) {
            state.enqueue(.mouseMoved(x: Float(i), y: 0))
        }
        // 捨てたのは古い方。最後に送ったものは残っている
        #expect(state.droppedEvents == 500)
        state.beginFrame()
        #expect(state.x == Float(InputState.queueLimit + 499))
    }
}

@Suite("外から送られた入力")
struct InputInboxTests {
    private func makeFacet() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func send(_ body: String, to facet: URL) throws {
        try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
    }

    @Test("送った出来事が合流点へ入り、何件受けたかが返る")
    func deliversTheEventsAndAnswers() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(
            #"{"id":"a1","events":[{"type":"mouseMoved","x":12,"y":34},{"type":"mouseDown","x":12,"y":34}]}"#,
            to: facet)

        let report = try #require(inbox.drain(into: state))
        #expect(report.id == "a1")
        #expect(report.accepted == 2)
        #expect(report.ignored == 0)

        state.beginFrame()
        #expect(state.x == 12)
        #expect(state.isMouseDown)
    }

    @Test("知らない種別は、その 1 件だけが捨てられる")
    func skipsOnlyTheUnknownOne() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(
            #"{"id":"a1","events":[{"type":"somethingNew"},{"type":"mouseMoved","x":5,"y":6}]}"#,
            to: facet)

        let report = try #require(inbox.drain(into: state))
        #expect(report.accepted == 1)
        #expect(report.ignored == 1)
        state.beginFrame()
        #expect(state.x == 5)
    }

    @Test("知らない鍵は無視する")
    func ignoresUnknownKeys() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(
            #"{"id":"a1","events":[{"type":"mouseDown","x":7,"y":9,"pressure":0.8}]}"#, to: facet)

        #expect(inbox.drain(into: state)?.accepted == 1)
        state.beginFrame()
        #expect(state.x == 7)
        #expect(state.y == 9)
    }

    @Test(
        "意味を持つ既定値が無い値が欠けていたら、その 1 件は通らない",
        arguments: [
            #"{"type":"mouseDown"}"#,
            #"{"type":"mouseDown","x":7}"#,
            #"{"type":"mouseUp","y":9}"#,
            #"{"type":"mouseMoved","x":7}"#,
            #"{"type":"keyDown"}"#,
            #"{"type":"keyDown","characters":"a"}"#,
            #"{"type":"keyUp"}"#,
        ])
    func rejectsEventsMissingValuesThatHaveNoDefault(_ event: String) throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(#"{"id":"a1","events":[\#(event)]}"#, to: facet)

        // 知らない種別と同じ扱い — 解けなかったものとして数える
        let report = try #require(inbox.drain(into: state))
        #expect(report.accepted == 0)
        #expect(report.ignored == 1)

        // **合流点は動かない。** 0 で埋めて通していた頃は、ここが
        // 「面の左上を押した」「A を押した」になっていた (#322)
        state.beginFrame()
        #expect(state.x == 0)
        #expect(state.y == 0)
        #expect(!state.isMouseDown)
        #expect(state.pressedKeys.isEmpty)
    }

    @Test("値の欠けた 1 件が混ざっても、残りは通る")
    func skipsOnlyTheBrokenOne() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(
            #"{"id":"a1","events":[{"type":"mouseMoved"},{"type":"mouseMoved","x":5,"y":6}]}"#,
            to: facet)

        let report = try #require(inbox.drain(into: state))
        #expect(report.accepted == 1)
        #expect(report.ignored == 1)
        state.beginFrame()
        #expect(state.x == 5)
        #expect(state.y == 6)
    }

    @Test("省略が自然に読める値は、省いても通る")
    func fillsInTheValuesThatHaveADefault() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        // button は 0 (主釦)・dx dy は 0 (動かない)・characters は空・isRepeat は false
        try send(
            #"{"id":"a1","events":[{"type":"mouseDown","x":7,"y":9},{"type":"scrolled"},{"type":"keyDown","code":49}]}"#,
            to: facet)

        #expect(inbox.drain(into: state)?.accepted == 3)
        state.beginFrame()
        #expect(state.isMouseDown)
        #expect(state.button == 0)
        #expect(state.scrollX == 0)
        #expect(state.scrollY == 0)
        #expect(state.pressedKeys.contains(49))
        #expect(state.characters.isEmpty)
    }

    @Test("壊れた要求で走っているスケッチを止めない")
    func survivesAMalformedRequest() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        try send("{ これは JSON ではない", to: facet)
        #expect(inbox.drain(into: InputState()) == nil)
    }

    @Test("同じ識別子の要求を二度は流し込まない")
    func handlesEachRequestOnce() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(#"{"id":"a1","events":[{"type":"mouseMoved","x":1,"y":1}]}"#, to: facet)
        #expect(inbox.drain(into: state) != nil)

        // 同じ内容を置き直しても (最終更新時刻は変わる) 二度は流れない
        try send(#"{"id":"a1","events":[{"type":"mouseMoved","x":1,"y":1}]}"#, to: facet)
        #expect(inbox.drain(into: state) == nil)
    }

    @Test("区画が無ければ、入力の受け口は立たない")
    func staysOffWithoutTheFacet() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(InputInbox.makeIfEnabled(at: absent) == nil)
    }
}

@Suite(
    "スケッチが入力を受け取る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchInputTests {
    /// 見えた位置を記録するだけのスケッチ。
    final class Recorder: Sketch {
        var seen: [(x: Float, y: Float, pressed: Bool)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            seen.append((mouseX, mouseY, isMousePressed))
        }
    }

    @Test("送った出来事が、同じフレームの draw から見える")
    func arrivesInTheSameFrame() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        let sketch = Recorder()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        try runtime.advance()
        #expect(sketch.seen.last?.x == 0)

        try AtomicFile.write(
            Data(#"{"id":"a1","events":[{"type":"mouseDown","x":8,"y":9}]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
        try runtime.advance()

        // 1 フレーム遅れて効く形にすると、外から動かして確かめるたびに 1 枚ぶんずれる
        #expect(sketch.seen.last?.x == 8)
        #expect(sketch.seen.last?.y == 9)
        #expect(sketch.seen.last?.pressed == true)
    }
}
