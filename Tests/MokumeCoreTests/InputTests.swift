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

    @Test("知らない鍵は無視し、足りない値はゼロとして扱う")
    func ignoresUnknownKeysAndFillsInTheGaps() throws {
        let facet = try makeFacet()
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        try send(#"{"id":"a1","events":[{"type":"mouseDown","x":7,"pressure":0.8}]}"#, to: facet)

        #expect(inbox.drain(into: state)?.accepted == 1)
        state.beginFrame()
        #expect(state.x == 7)
        #expect(state.y == 0)
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
