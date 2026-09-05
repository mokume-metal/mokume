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
        state.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
        state.beginFrame()
        #expect(state.pressedKeys.contains(.space))
        #expect(state.characters == " ")

        state.enqueue(.keyUp(code: .space))
        state.beginFrame()
        #expect(!state.pressedKeys.contains(.space))
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

@Suite("出来事がコールバックになる")
struct InputCallbackTests {
    /// 溜めて 1 フレームぶん流し込み、配られた呼び出しの並びを返す。
    private func callbacks(from events: [InputEvent]) -> [InputCallback] {
        let state = InputState()
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    /// **これが #723 の実害そのもの。** 畳むだけにすると `isMouseDown` は `false` へ
    /// 戻り、押されたことがどこにも残らない。外から送る経路では 1 回の要求がまとめて
    /// 1 フレームへ入るので、クリックを 1 件送るという最も素直な使い方が常に消える。
    @Test("1 フレームに押して離しても、押下が消えない")
    func keepsAPressThatFitsInOneFrame() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 200, y: 250, button: 0))
        state.enqueue(.mouseUp(x: 200, y: 250, button: 0))

        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }

        #expect(seen == [.mousePressed, .mouseReleased, .mouseClicked])
        // 畳んだ結果は今までどおり「押されていない」
        #expect(!state.isMouseDown)
    }

    @Test("押下を伴わない解放は、クリックにならない")
    func doesNotClickWithoutAPress() {
        // 窓の外で押して中で離した、溜める上限で押下だけ捨てられた、など
        #expect(callbacks(from: [.mouseUp(x: 10, y: 10, button: 0)]) == [.mouseReleased])
    }

    @Test("クリックは、解放の直後に続く")
    func clickFollowsTheRelease() {
        let events: [InputEvent] = [
            .mouseDown(x: 10, y: 10, button: 0),
            .mouseMoved(x: 20, y: 20),
            .mouseUp(x: 20, y: 20, button: 0),
        ]
        #expect(
            callbacks(from: events) == [
                .mousePressed, .mouseDragged(deltaX: 10, deltaY: 10), .mouseReleased,
                .mouseClicked,
            ])
    }

    /// **足し込みで数える量は、呼び出しが自分で運ぶ** ([ADR-0034] 決定 5)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    @Test("スクロールは、その 1 件ぶんの量を配る")
    func deliversTheAmountOfEachScroll() {
        let events: [InputEvent] = [
            .scrolled(dx: 1, dy: 2),
            .scrolled(dx: 3, dy: 4),
            .scrolled(dx: 5, dy: 6),
        ]
        #expect(
            callbacks(from: events) == [
                .mouseWheel(deltaX: 1, deltaY: 2),
                .mouseWheel(deltaX: 3, deltaY: 4),
                .mouseWheel(deltaX: 5, deltaY: 6),
            ])
    }

    /// **これが #807 の実害そのもの。** フレーム合計 (`scrollY`) をコールバックの中から
    /// 読むと、1 フレームに 3 件届いたとき `a` + `(a+b)` + `(a+b+c)` = `3a + 2b + c` を
    /// 足し込む形になる。欲しいのは `a+b+c` である。
    ///
    /// **フレームに 1 件しか届かない環境では、間違えた側も正しく動く** ので、窓を触って
    /// 確かめている限り気付けない。外から送る経路では 1 回の要求がまとめて 1 フレームへ
    /// 入るので、そこで初めて出る。
    @Test("まとめて届いても、配られた量の合計は送った合計と一致する")
    func deliveredAmountsSumToWhatWasSent() {
        let sent: [(Float, Float)] = [(1, 2), (3, 4), (5, 6)]
        let delivered = callbacks(from: sent.map { .scrolled(dx: $0.0, dy: $0.1) })
            .compactMap { callback -> (Float, Float)? in
                guard case .mouseWheel(let deltaX, let deltaY) = callback else { return nil }
                return (deltaX, deltaY)
            }

        #expect(delivered.map(\.0).reduce(0, +) == sent.map(\.0).reduce(0, +))
        #expect(delivered.map(\.1).reduce(0, +) == sent.map(\.1).reduce(0, +))
        // 部分累計を配っていれば 3a + 2b + c = 3*1 + 2*3 + 5 = 14 になる
        #expect(delivered.map(\.0).reduce(0, +) == 9)
    }

    /// 引きずりも同じ規則で、**1 件ぶんを足し合わせるとフレーム合計 (``InputState/dragX``)
    /// と一致する**。用途の違う 2 つが、食い違わずに並んでいる。
    @Test("引きずりの 1 件ぶんを足すと、フレーム合計と一致する")
    func draggedAmountsSumToTheFrameTotal() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 10, y: 10, button: 0))
        state.enqueue(.mouseMoved(x: 20, y: 15))
        state.enqueue(.mouseMoved(x: 50, y: 35))
        state.enqueue(.mouseMoved(x: 60, y: 60))
        var deltaX: Float = 0
        var deltaY: Float = 0
        state.beginFrame { callback in
            guard case .mouseDragged(let x, let y) = callback else { return }
            deltaX += x
            deltaY += y
        }

        #expect(deltaX == state.dragX)
        #expect(deltaY == state.dragY)
        #expect(deltaX == 50)
    }

    /// 規則は 1 つ — **状態はその出来事まで適用した値**。
    @Test("配られた時点で読める値は、その出来事を当てた直後の姿")
    func readsTheStateAsOfThatEvent() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 30, y: 40, button: 1))
        state.enqueue(.mouseUp(x: 70, y: 80, button: 1))

        var seen: [(InputCallback, Float, Float, Bool, Int)] = []
        state.beginFrame { seen.append(($0, state.x, state.y, state.isMouseDown, state.button)) }

        #expect(seen.count == 3)
        // 押した瞬間は、押した場所で押されている
        #expect(seen[0].0 == .mousePressed)
        #expect(seen[0].1 == 30)
        #expect(seen[0].2 == 40)
        #expect(seen[0].3)
        #expect(seen[0].4 == 1)
        // 離した瞬間は、離した場所で押されていない
        #expect(seen[1].0 == .mouseReleased)
        #expect(seen[1].1 == 70)
        #expect(seen[1].2 == 80)
        #expect(!seen[1].3)
        // クリックは解放と同じ姿を見る
        #expect(seen[2].0 == .mouseClicked)
        #expect(seen[2].1 == 70)
    }

    @Test("押していない移動は移動、押したままの移動は引きずり")
    func splitsMotionByWhetherTheButtonIsDown() {
        // 押す前の移動 → 移動。押した後の移動 → 引きずり。離した後の移動 → 移動
        let events: [InputEvent] = [
            .mouseMoved(x: 10, y: 10),
            .mouseDown(x: 10, y: 10, button: 0),
            .mouseMoved(x: 30, y: 25),
            .mouseUp(x: 30, y: 25, button: 0),
            .mouseMoved(x: 60, y: 60),
        ]
        #expect(
            callbacks(from: events) == [
                .mouseMoved, .mousePressed, .mouseDragged(deltaX: 20, deltaY: 15),
                .mouseReleased, .mouseClicked, .mouseMoved,
            ])
    }

    /// **窓にしか無い情報を使っていない。** 窓は押している間の移動を `mouseDragged` と
    /// して拾うが、合流点へ流れるのは `.mouseMoved` だけなので、外から送れるものと
    /// 同じ材料 (押下状態) で分けている。
    @Test("引きずりの判定は、外から送れる材料だけで決まる")
    func derivesDraggingWithoutWindowOnlyInformation() {
        let held: [InputEvent] = [.mouseDown(x: 0, y: 0, button: 0), .mouseMoved(x: 5, y: 5)]
        #expect(callbacks(from: held) == [.mousePressed, .mouseDragged(deltaX: 5, deltaY: 5)])
        #expect(callbacks(from: [.mouseMoved(x: 5, y: 5)]) == [.mouseMoved])
    }

    @Test("キーは、押した瞬間と離した瞬間に配られる")
    func deliversKeyPressAndRelease() {
        let events: [InputEvent] = [
            .keyDown(code: .space, characters: " ", isRepeat: false),
            .keyUp(code: .space),
        ]
        #expect(callbacks(from: events) == [.keyPressed, .keyTyped, .keyReleased])
    }

    /// **押しっぱなしは連射する** (手本 — Processing / p5.js — と同じ)。
    @Test("押しっぱなしのキーは、届いたぶんだけ配られる")
    func repeatsWhileHeld() {
        let events: [InputEvent] = [
            .keyDown(code: .a, characters: "a", isRepeat: false),
            .keyDown(code: .a, characters: "a", isRepeat: true),
        ]
        #expect(callbacks(from: events) == [.keyPressed, .keyTyped, .keyPressed, .keyTyped])
    }

    /// **「`characters` が空でない」では判定できない。** AppKit は矢印に私用領域
    /// (U+F700 台)、Escape に U+001B、Delete に U+007F を返す — どれも空ではないので、
    /// 空でないことを打鍵の合図にすると手本では呼ばれないキーで発火する。
    @Test(
        "文字を生まないキーでは、打鍵にならない",
        arguments: [
            ("\u{F700}", "上矢印"), ("\u{F701}", "下矢印"), ("\u{F702}", "左矢印"),
            ("\u{F704}", "F1"), ("\u{001B}", "Escape"), ("\u{007F}", "Delete"),
            ("\u{0009}", "Tab"), ("\u{000D}", "Return"), ("", "文字を持たないキー"),
        ])
    func doesNotTypeForKeysThatProduceNoText(_ characters: String, _ name: String) {
        let event = InputEvent.keyDown(code: .arrowUp, characters: characters, isRepeat: false)
        #expect(callbacks(from: [event]) == [.keyPressed], "\(name) で打鍵になった")
    }

    @Test(
        "文字を生むキーでは、押下の直後に打鍵が続く",
        arguments: ["a", "あ", " ", "1", "🌱"])
    func typesForKeysThatProduceText(_ characters: String) {
        let event = InputEvent.keyDown(code: .a, characters: characters, isRepeat: false)
        #expect(callbacks(from: [event]) == [.keyPressed, .keyTyped])
    }

    /// 同じ判定が ``InputState/characters`` にも効く。割れていた頃は、矢印を押すと
    /// 画面に見えない文字が出ていた ([#805](https://github.com/mokume-metal/mokume/issues/805))。
    @Test("矢印キーを押しても、読める文字が壊れない")
    func keepsTheReadableCharacterIntact() {
        let state = InputState()
        state.enqueue(.keyDown(code: .a, characters: "a", isRepeat: false))
        state.beginFrame()
        #expect(state.characters == "a")

        // 上矢印。押されているキーの集合には入るが、読める文字は変わらない
        state.enqueue(.keyDown(code: .arrowUp, characters: "\u{F700}", isRepeat: false))
        state.beginFrame()
        #expect(state.pressedKeys.contains(.arrowUp))
        #expect(state.characters == "a")
    }

    /// 配ることで畳み方が変わっていないか。**`draw()` から見える最終状態は今までどおり。**
    @Test("配っても、フレームの終わりに見える状態は変わらない")
    func foldingIsUnchangedByDispatching() {
        let events: [InputEvent] = [
            .mouseMoved(x: 10, y: 10),
            .mouseDown(x: 10, y: 10, button: 0),
            .mouseMoved(x: 30, y: 25),
            .scrolled(dx: 1, dy: 2),
        ]
        let dispatching = InputState()
        for event in events { dispatching.enqueue(event) }
        dispatching.beginFrame { _ in }

        let quiet = InputState()
        for event in events { quiet.enqueue(event) }
        quiet.beginFrame()

        #expect(dispatching.x == quiet.x)
        #expect(dispatching.dragX == quiet.dragX)
        #expect(dispatching.dragY == quiet.dragY)
        #expect(dispatching.scrollY == quiet.scrollY)
        #expect(dispatching.isMouseDown == quiet.isMouseDown)
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
        #expect(state.pressedKeys.contains(.space))
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

    /// コールバックが呼ばれた順と、呼ばれた時点で読める値を控える。
    final class Callbacks: Sketch {
        struct Seen: Equatable {
            let name: String
            let x: Float
            let y: Float
            let pressed: Bool
        }
        var seen: [Seen] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() { background(.display(red: 0, green: 0, blue: 0)) }
        func mousePressed() { note("pressed") }
        func mouseReleased() { note("released") }
        func mouseClicked() { note("clicked") }
        private func note(_ name: String) {
            seen.append(Seen(name: name, x: mouseX, y: mouseY, pressed: isMousePressed))
        }
    }

    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return facet
    }

    private func send(_ events: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"a1","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    /// **#723 が測った実害を、直った側で踏む。** 1 回の要求へ押下と解放を並べて送ると、
    /// 畳むだけの頃は 1 つも植わらなかった (`accepted: 5` / `dropped: 0` で受理されて
    /// いるので、送った側からは成功に見えた)。
    @Test("1 回の要求に並べたクリックが、そのぶんだけ届く")
    func deliversClicksThatArriveTogether() throws {
        let facet = try makeFacet()
        let sketch = Callbacks()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        try send(
            #"""
            {"type":"mouseMoved","x":200,"y":250},
            {"type":"mouseDown","x":200,"y":250,"button":0},
            {"type":"mouseUp","x":200,"y":250,"button":0},
            {"type":"mouseDown","x":40,"y":60,"button":0},
            {"type":"mouseUp","x":40,"y":60,"button":0}
            """#, to: facet)
        try runtime.advance()

        #expect(sketch.seen.filter { $0.name == "clicked" }.count == 2)
        // コールバックの中で読む位置は、その出来事を当てた直後の値
        #expect(
            sketch.seen == [
                .init(name: "pressed", x: 200, y: 250, pressed: true),
                .init(name: "released", x: 200, y: 250, pressed: false),
                .init(name: "clicked", x: 200, y: 250, pressed: false),
                .init(name: "pressed", x: 40, y: 60, pressed: true),
                .init(name: "released", x: 40, y: 60, pressed: false),
                .init(name: "clicked", x: 40, y: 60, pressed: false),
            ])
    }

    /// 観測がまだ 1 枚も描いていないスケッチを叩いたときの 1 枚も、通常のフレームと
    /// 同じ手順で描かれる ([#808](https://github.com/mokume-metal/mokume/issues/808))。
    /// **配布を片方の経路にだけ書くと、外から観測したときだけ飛ばない**という、窓では
    /// 再現しない壊れ方になる。
    @Test("観測が最初に叩いた 1 枚でも、コールバックが飛ぶ")
    func deliversOnTheFirstObservedFrame() throws {
        // 入力と観測は区画が別なので、要求を置く場所も分ける
        let inputFacet = try makeFacet()
        let observeFacet = try makeFacet()
        let sketch = Callbacks()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: observeFacet),
            inbox: InputInbox(directory: inputFacet))
        runtime.pause()

        try send(
            #"""
            {"type":"mouseDown","x":5,"y":6,"button":0},
            {"type":"mouseUp","x":5,"y":6,"button":0}
            """#, to: inputFacet)
        try AtomicFile.write(
            Data(#"{"id":"o1"}"#.utf8), to: observeFacet.appendingPathComponent("request.json"))
        try runtime.advance()

        #expect(sketch.seen.map(\.name) == ["pressed", "released", "clicked"])
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
