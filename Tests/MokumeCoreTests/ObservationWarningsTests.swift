// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// スケッチが言った警告が、次の観測の応答の `warnings` に 1 度だけ載ること (#2761)。GPU を要する。
///
/// 溜め場の単体 (上限・順・隔離) は ``WarningDigestTests`` が持つ。ここは**観測の往復**で、
/// 警告を言う 2 通りの口 (`WarningLog.warnOnce` を通るもの・`Diagnostics.warn` を直に呼ぶもの) が
/// 応答へ載り、2 度目の応答には載らないことを見る。
///
/// 検査は自分の溜め場を差して走る (``Diagnostics/digest``)。差さないと、並んで走る観測の検査が
/// 互いの警告を持っていく。
@MainActor
@Suite(
    "スケッチが言った警告と観測",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ObservationWarningsTests {
    final class Talker: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 4) }
        var onSetup: (Talker) -> Void = { _ in }
        var onDraw: (Talker) -> Void = { _ in }
        var onPressed: (Talker) -> Void = { _ in }
        func setup() { onSetup(self) }
        func draw() {
            background(0)
            onDraw(self)
        }
        func mousePressed() { onPressed(self) }
    }

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-observe-warnings")
        return directory
    }

    private func writePicture() throws -> URL {
        let url = TestScratch.path("mokume-observe-warnings", pathExtension: "png")
        try PNGFile.write(DisplayImage(width: 1, height: 1, bytes: [255, 0, 0, 255]), to: url)
        return url
    }

    private func observe(id: String, _ body: String = "", in facet: URL, with runtime: SketchRuntime) throws
        -> [String]
    {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)"\#(body)}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return report["warnings"] as? [String] ?? []
    }

    private func makeRuntime(_ sketch: Talker, observe facet: URL, inbox: URL? = nil) throws
        -> SketchRuntime
    {
        try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet), inbox: inbox.map { InputInbox(directory: $0) })
    }

    /// 例: `draw()` の中で `loadImage` を呼んだ後の観測に、#2744 の警告が 1 度載る (`WarningLog.warnOnce`
    /// を通る口)。同じ draw で `Diagnostics.warn` を直に呼ぶ口も 1 度だけ載せる。
    @Test("warnOnce を通る警告と Diagnostics.warn を直に呼ぶ警告が、1 度だけ載り、2 度目の応答には載らない")
    func bothKindsRideTheNextReplyOnce() throws {
        let picture = try writePicture()
        defer { try? FileManager.default.removeItem(at: picture) }
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let facet = try makeFacet()
            let sketch = Talker()
            var said = false
            sketch.onDraw = { talker in
                _ = try? talker.loadImage(picture.path)
                if !said {
                    said = true
                    Diagnostics.warn("direct line from a mouth with no memory")
                }
            }
            let runtime = try makeRuntime(sketch, observe: facet)
            try runtime.advance()
            try runtime.advance()

            let first = try observe(id: "a1", in: facet, with: runtime)
            let blocking = BlockingLoads.notice("loadImage(_:)", instead: "requestImage(_:)")
            #expect(first.filter { $0 == blocking }.count == 1, "\(first)")
            #expect(first.filter { $0 == "direct line from a mouth with no memory" }.count == 1, "\(first)")

            // 同じことを続けても、言い直さない口は載らない
            let second = try observe(id: "a2", in: facet, with: runtime)
            #expect(second.isEmpty, "2 度目の応答にも載った: \(second)")
            runtime.closePlugins()
        }
    }

    /// 窓が数える警告 (#3087) は、観測の `warnings` が持っていく行を奪わない。窓の数は読んでも空にならず、
    /// 溜め場の上限にも縛られない。
    @Test("窓のために警告の件数と最後の 1 行を読んでも、次の観測の warnings には欠けずに 1 度載る")
    func theWindowCountDoesNotTakeLinesFromTheObservation() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let facet = try makeFacet()
            let sketch = Talker()
            sketch.onSetup = { _ in Diagnostics.warn("Transforms are written again every frame") }
            let runtime = try makeRuntime(sketch, observe: facet)
            try runtime.advance()
            try runtime.advance()

            // 窓が子の面に載せる数字を採る (毎フレーム採られる)
            let numbers = runtime.frameNumbers
            #expect(numbers.warningCount == 1)
            #expect(numbers.lastWarning == "Transforms are written again every frame")
            _ = runtime.frameNumbers

            let first = try observe(id: "a1", in: facet, with: runtime)
            #expect(first == ["Transforms are written again every frame"], "\(first)")
            // 観測が持っていった後も、窓の数は子が入れ替わるまで残る
            #expect(runtime.frameNumbers.warningCount == 1)
            #expect(try observe(id: "a2", in: facet, with: runtime).isEmpty, "2 度目の応答にも載った")
            runtime.closePlugins()
        }
    }

    /// 同じ文を毎フレーム言う口を差し替えても、応答の行数は上限 + 1 に収まる。
    @Test("毎フレーム同じ文を言う口があっても、応答の行は上限 + 1 に収まる")
    func aChattyMouthIsBounded() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let facet = try makeFacet()
            let sketch = Talker()
            var said = 0
            sketch.onDraw = { _ in
                for _ in 0..<30 {
                    Diagnostics.warn("endDraw(): could not finish drawing")
                    said += 1
                }
            }
            let runtime = try makeRuntime(sketch, observe: facet)
            try runtime.advance()
            try runtime.advance()

            let warnings = try observe(id: "a1", in: facet, with: runtime)
            let limit = WarningDigest.defaultLimit
            #expect(warnings.count == limit + 1, "\(warnings.count) 行")
            #expect(warnings.prefix(limit).allSatisfy { $0 == "endDraw(): could not finish drawing" })
            #expect(warnings.last == WarningDigest.overflowNotice(kept: limit, dropped: said - limit))
            runtime.closePlugins()
        }
    }

    /// 絵が無いときの失敗の理由は、時刻を指定した観測が `warnings` をそのまま理由にする
    /// (`Sources/MokumeCLI/MCP/Tools.swift`)。スケッチが言った警告は、その後ろに足す。
    @Test("失敗の理由の行が先に来て、スケッチが言った警告は最後に足される")
    func failureReasonComesFirst() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let facet = try makeFacet()
            let runtime = try makeRuntime(Talker(), observe: facet)
            try runtime.advance()
            runtime.pause()
            Diagnostics.warn("said by the sketch before the request")

            let warnings = try observe(id: "t1", #","time":3"#, in: facet, with: runtime)
            #expect(warnings.count == 2, "\(warnings)")
            #expect(warnings.first?.contains("specified time") == true, "\(warnings)")
            #expect(warnings.last == "said by the sketch before the request")
            runtime.closePlugins()
        }
    }

    /// 完了条件 1 の例。止まっている間のコールバックで `translate` を呼ぶと警告して無視される。
    /// 入力で押して観測すると、その 1 行が応答に載り、同じ操作をもう一度しても 2 度目には載らない。
    @Test("止まっている間の mousePressed の translate の警告が、押した後の観測に 1 度だけ載る")
    func aPressWhileStoppedIsExplainedOnce() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let observeFacet = try makeFacet()
            let inputFacet = try makeFacet()
            let sketch = Talker()
            sketch.onSetup = { $0.noLoop() }
            sketch.onPressed = { talker in
                talker.translate(100, 0)
                talker.circle(0, 0, 50)
                talker.redraw()
            }
            let runtime = try makeRuntime(sketch, observe: observeFacet, inbox: inputFacet)
            try runtime.advance()

            @MainActor func press(id: String) throws {
                try AtomicFile.write(
                    Data(
                        #"{"id":"\#(id)","events":[{"type":"mouseDown","x":4,"y":2,"button":0},{"type":"mouseUp","x":4,"y":2,"button":0}]}"#
                            .utf8),
                    to: inputFacet.appendingPathComponent("request.json"))
                try runtime.advance()
            }

            let notice = Canvas.OutsideFrame.transform.notice
            try press(id: "p1")
            let first = try observe(id: "o1", in: observeFacet, with: runtime)
            #expect(first.filter { $0 == notice }.count == 1, "\(first)")

            try press(id: "p2")
            let second = try observe(id: "o2", in: observeFacet, with: runtime)
            #expect(second.isEmpty, "2 度目の応答にも載った: \(second)")
            runtime.closePlugins()
        }
    }
}
