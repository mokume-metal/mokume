// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作者が進行を止める・戻す・1 枚だけ描き直す ([#900](https://github.com/mokume-metal/mokume/issues/900))。
///
/// 手本の `Basics/Structure/NoLoop` / `Loop` / `Redraw` の 3 本は「止まっていること」が
/// 主題で、口が無いと写せなかった。ここの検査はその 3 本の形をそのまま踏む。
@Suite(
    "作者が進行を止める",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LoopTests {
    /// 手本の NoLoop / Loop / Redraw を 1 つにしたもの。線が上へ 1 段ずつ上がる。
    final class Lines: Sketch {
        var settings = SketchSettings(width: 32, height: 16)
        /// `setup()` で止めるか。
        var stopsInSetup = true
        /// 押したときに呼ぶ口。
        var onPress: ((Lines) -> Void)?
        /// `draw()` の最後に呼ぶもの。
        var afterDraw: ((Lines) -> Void)?
        var y: Float = 16
        var drawCalls = 0
        var seenFrameCounts: [Int] = []
        var seenDeltas: [Float] = []
        var pressedCalls = 0

        init() {}
        func setup() {
            if stopsInSetup { noLoop() }
        }
        func draw() {
            drawCalls += 1
            seenFrameCounts.append(frameCount)
            seenDeltas.append(deltaTime)
            background(0)
            stroke(255)
            y -= 4
            if y < 0 { y = height }
            line(0, y, width, y)
            afterDraw?(self)
        }
        func mousePressed() {
            pressedCalls += 1
            onPress?(self)
        }
    }

    private func makeRuntime(
        _ sketch: Lines, inbox: URL? = nil, observer: URL? = nil, clock: Clock? = nil,
        now: @escaping () -> Double = { 0 }
    ) throws -> SketchRuntime {
        try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: clock, now: now,
            observer: observer.map { FrameObserver(directory: $0) },
            inbox: inbox.map { InputInbox(directory: $0) })
    }

    private func makeFacet() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 押して離す 1 回を、入力の区画へ置く。
    private func click(in facet: URL) throws {
        try AtomicFile.write(
            Data(
                #"{"id":"c\#(UUID().uuidString)","events":[{"type":"mouseDown","x":4,"y":4,"button":0},{"type":"mouseUp","x":4,"y":4,"button":0}]}"#
                    .utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    // MARK: - 止める

    @Test("setup() で noLoop() を呼ぶと、draw() は 1 度だけ呼ばれて、書き出す絵が変わらない")
    func noLoopInSetupDrawsOnceAndHoldsThePicture() throws {
        let directory = try makeFacet()
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)

        let first = directory.appendingPathComponent("1.png")
        let second = directory.appendingPathComponent("2.png")
        let third = directory.appendingPathComponent("3.png")
        try runtime.renderFrame(to: first)
        try runtime.renderFrame(to: second)
        try runtime.renderFrame(to: third)

        #expect(sketch.drawCalls == 1)
        #expect(runtime.frameCount == 1)
        #expect(sketch.y == 12)
        // 連続するフレームを書き出して、バイト列が一致する (ADR-0001 原則 2 の決定論)
        let bytes = try [first, second, third].map { try Data(contentsOf: $0) }
        #expect(bytes[0] == bytes[1])
        #expect(bytes[1] == bytes[2])
    }

    @Test("draw() の中で noLoop() を呼ぶと、そのフレームを描き切ってから止まる")
    func noLoopInDrawStopsAfterThatFrame() throws {
        let sketch = Lines()
        sketch.stopsInSetup = false
        sketch.afterDraw = { if $0.drawCalls == 2 { $0.noLoop() } }
        let runtime = try makeRuntime(sketch)
        for _ in 0..<5 { try runtime.advance() }

        #expect(sketch.drawCalls == 2)
        #expect(sketch.seenFrameCounts == [1, 2])
    }

    // MARK: - 戻す・描き直す

    @Test("止まっている間に redraw() を呼ぶと、draw() が 1 度だけ呼ばれる")
    func redrawDrawsExactlyOnce() throws {
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runSketch(runtime) { sketch.redraw(); sketch.redraw() }
        for _ in 0..<3 { try runtime.advance() }

        #expect(sketch.drawCalls == 2)
        #expect(sketch.seenFrameCounts == [1, 2])
    }

    @Test("loop() で進行が戻る")
    func loopResumes() throws {
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        try runtime.advance()

        runSketch(runtime) { sketch.loop() }
        for _ in 0..<3 { try runtime.advance() }

        #expect(sketch.drawCalls == 4)
        #expect(sketch.seenFrameCounts == [1, 2, 3, 4])
    }

    @Test("回っている間の redraw() は、余分に描かない")
    func redrawWhileLoopingDoesNothing() throws {
        let sketch = Lines()
        sketch.stopsInSetup = false
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runSketch(runtime) { sketch.redraw() }
        // 回っている間に頼んだ描き直しが残っていると、止めた直後に 1 枚余分に描く
        sketch.afterDraw = { $0.noLoop() }
        try runtime.advance()
        try runtime.advance()

        #expect(sketch.drawCalls == 2)
    }

    @Test("draw() の中の redraw() は効かない")
    func redrawInsideDrawIsIgnored() throws {
        let sketch = Lines()
        sketch.afterDraw = { $0.redraw() }
        let runtime = try makeRuntime(sketch)
        for _ in 0..<4 { try runtime.advance() }

        #expect(sketch.drawCalls == 1)
    }

    @Test("止めていた実時間は、戻った後の最初の経過に乗らない")
    func loopResyncsTheClock() throws {
        let sketch = Lines()
        var now: Double = 0
        let runtime = try makeRuntime(sketch, clock: .wallClock, now: { now })
        now = 0.016
        try runtime.advance()

        now = 10.0
        try runtime.advance()
        runSketch(runtime) { sketch.loop() }
        now = 10.016
        try runtime.advance()

        #expect(sketch.seenDeltas.count == 2)
        #expect(abs(sketch.seenDeltas[1] - 0.016) < 1e-5)
    }

    // MARK: - 止まっていても応える

    @Test("止まっている間の押下で redraw() を呼ぶと、そのフレームで 1 度だけ描く (手本の Redraw)")
    func pressToRedraw() throws {
        let facet = try makeFacet()
        let sketch = Lines()
        sketch.onPress = { $0.redraw() }
        let runtime = try makeRuntime(sketch, inbox: facet)
        try runtime.advance()
        try runtime.advance()
        #expect(sketch.drawCalls == 1)

        try click(in: facet)
        try runtime.advance()
        #expect(sketch.pressedCalls == 1)
        #expect(sketch.drawCalls == 2)

        try runtime.advance()
        #expect(sketch.drawCalls == 2)
    }

    @Test("止まっている間の押下で loop() を呼ぶと、そのフレームから回り出す (手本の Loop)")
    func pressToLoop() throws {
        let facet = try makeFacet()
        let sketch = Lines()
        sketch.onPress = { $0.loop() }
        let runtime = try makeRuntime(sketch, inbox: facet)
        try runtime.advance()
        try runtime.advance()

        try click(in: facet)
        try runtime.advance()
        try runtime.advance()

        #expect(sketch.drawCalls == 3)
        #expect(sketch.seenFrameCounts == [1, 2, 3])
    }

    @Test("止まっている間に届いた押下は、描き直すフレームでも押した位置として読める")
    func deliveredInputIsNotAppliedTwice() throws {
        /// 押したフレームで読める位置を控える。
        final class Positions: Sketch {
            var settings = SketchSettings(width: 16, height: 16)
            var seen: [(x: Float, previousX: Float)] = []
            init() {}
            func setup() { noLoop() }
            func draw() {
                background(0)
                seen.append((mouseX, pmouseX))
            }
            func mousePressed() { redraw() }
        }
        let facet = try makeFacet()
        let sketch = Positions()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()

        try AtomicFile.write(
            Data(
                #"{"id":"m1","events":[{"type":"mouseMoved","x":9,"y":3},{"type":"mouseDown","x":9,"y":3,"button":0}]}"#
                    .utf8),
            to: facet.appendingPathComponent("request.json"))
        try runtime.advance()

        // 当て直すと、前のフレームの位置 (`pmouseX`) が押した位置で上書きされる
        #expect(sketch.seen.count == 2)
        #expect(sketch.seen.last?.x == 9)
        #expect(sketch.seen.last?.previousX == 0)
    }

    @Test("止まっている間も観測に応え、そのときフレームは進まない")
    func answersObservationWhileStopped() throws {
        let facet = try makeFacet()
        let sketch = Lines()
        let runtime = try makeRuntime(sketch, observer: facet)
        try runtime.advance()
        try runtime.advance()

        try AtomicFile.write(
            Data(#"{"id":"o1"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()

        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(report["id"] as? String == "o1")
        #expect(report["frame"] as? Int == 1)
        #expect(report["image"] as? String == "frame-000.png")
        #expect(sketch.drawCalls == 1)
    }

    // MARK: - 外からの停止との関係

    @Test("外から resume() しても、作者の noLoop() は覆らない")
    func resumeDoesNotOverrideNoLoop() throws {
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runtime.pause()
        try runtime.advance()
        runtime.resume()
        for _ in 0..<3 { try runtime.advance() }

        #expect(sketch.drawCalls == 1)
        #expect(runtime.isRunning)
    }

    @Test("外が止めている間に頼んだ redraw() は、再開した後の最初のフレームで効く")
    func redrawRequestedWhilePausedWaitsForResume() throws {
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runtime.pause()
        runSketch(runtime) { sketch.redraw() }
        try runtime.advance()
        #expect(sketch.drawCalls == 1)

        runtime.resume()
        try runtime.advance()
        try runtime.advance()
        #expect(sketch.drawCalls == 2)
    }

    // MARK: - 絵をファイルにする

    @Test("止めたスケッチの save() は、次のフレームを待たずにファイルになる")
    func saveInTheFrameThatStopsIsWrittenRightAway() throws {
        let facet = try makeFacet()
        let out = facet.appendingPathComponent("still.png")
        let sketch = Lines()
        sketch.afterDraw = { $0.save(out.path) }
        let runtime = try makeRuntime(sketch)

        try runtime.advance()

        // 止めたスケッチに次のフレームは来ない。ここで書かれなければ、終わりまで
        // (SIGTERM で終わるなら永久に) 出ないことになる (#1300)
        #expect(pollUntilSettled(within: 5) { FileManager.default.fileExists(atPath: out.path) })
        #expect(sketch.drawCalls == 1)
    }

    @Test("止まっている間の押下から頼んだ save() も、描き直さずにファイルになる")
    func saveAskedForWhileStoppedIsWritten() throws {
        let facet = try makeFacet()
        let out = facet.appendingPathComponent("pressed.png")
        let sketch = Lines()
        sketch.onPress = { $0.save(out.path) }
        let runtime = try makeRuntime(sketch, inbox: facet)
        try runtime.advance()

        try click(in: facet)
        var advances = 0
        while sketch.pressedCalls == 0, advances < 10 {
            try runtime.advance()
            advances += 1
        }
        #expect(sketch.pressedCalls == 1)

        // 宛先の絵は既に描かれている。組み直して配るほかに、届ける機会は無い
        #expect(pollUntilSettled(within: 5) { FileManager.default.fileExists(atPath: out.path) })
        #expect(sketch.drawCalls == 1)
    }

    @Test("save() の直後に外から pause() しても、ファイルになる")
    func saveIsWrittenEvenIfThePauseComesFirst() throws {
        let facet = try makeFacet()
        let out = facet.appendingPathComponent("paused.png")
        let sketch = Lines()
        sketch.stopsInSetup = false
        sketch.afterDraw = { if $0.drawCalls == 1 { $0.save(out.path) } }
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runtime.pause()
        try runtime.advance()

        #expect(pollUntilSettled(within: 5) { FileManager.default.fileExists(atPath: out.path) })
        #expect(sketch.drawCalls == 1)
    }

    @Test("止まっている間に頼んだ save() は、次の advance() が無くても終わりまでに書かれる")
    func aSaveAskedForWhileStoppedIsWrittenWhenTheSketchEnds() throws {
        let facet = try makeFacet()
        let out = facet.appendingPathComponent("ending.png")
        let sketch = Lines()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        runSketch(runtime) { sketch.save(out.path) }
        runtime.closePlugins()

        // 終わりの経路が最後の受け皿である。ここも抜けると、頼んだファイルは出ない
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test("止まっている間、頼まれていなければ道を 1 回も通らない")
    func aStoppedSketchDoesNotKeepHandingOutTheSamePicture() throws {
        let facet = try makeFacet()
        let out = facet.appendingPathComponent("once.png")
        let sketch = Lines()
        sketch.afterDraw = { $0.save(out.path) }
        let runtime = try makeRuntime(sketch)

        for _ in 0..<20 { try runtime.advance() }

        // 止まっている絵は変わらない。頼まれた 1 回を越えて読み戻すのは、
        // 止まったスケッチが毎フレーム費用を払っているということである (ADR-0023 決定 5)
        #expect(runtime.target.encodePassCount == 1)
    }

    /// 作者の口は走っているランタイムを通るので、検査からもそれを差してから呼ぶ。
    private func runSketch(_ runtime: SketchRuntime, _ body: () -> Void) {
        let previous = runningSketch
        runningSketch = runtime
        defer { runningSketch = previous }
        body()
    }
}
