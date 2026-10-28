// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

// `save("x.svg")` の意味と、書く道 ([#3139]・完了条件 10〜12・15)。
//
// 意味は呼ぶ場所で決まる (A′・メンテナの決定)。`draw()` の中なら呼んだ時点から、外なら次の `draw()` を
// 丸ごと。書くのは `draw()` の終わりで、組みも書き込みも隔離の外で走る。
//
// [#3139]: https://github.com/mokume-metal/mokume/issues/3139

/// 検査のあいだだけ使う一時ディレクトリ。
@MainActor
private func withTemporaryDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// 呼ぶ場所を変えて `save("x.svg")` を呼ぶ検査用のスケッチ。
final class PlotterSketch: Sketch {
    var onSetup: ((PlotterSketch) -> Void)?
    var onDraw: ((PlotterSketch) -> Void)?
    var onKey: ((PlotterSketch) -> Void)?

    init() {}
    var settings: SketchSettings { SketchSettings(width: 100, height: 80) }
    func setup() { onSetup?(self) }
    func draw() { onDraw?(self) }
    func keyPressed() { onKey?(self) }
}

@Suite(
    "SVG を書く save()",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct VectorSaveTests {
    private func makeRuntime(_ sketch: PlotterSketch) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
    }

    /// `body` を走らせ、その間に言った警告の行を返す。
    private func saying<T>(_ body: () throws -> T) rethrows -> (value: T, lines: [String]) {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let value = try body()
            return (value, Diagnostics.takeUnreported())
        }
    }

    private func elements(of url: URL) throws -> [String] {
        SVG.elements(try String(contentsOf: url, encoding: .utf8))
    }

    private func late(_ lines: [String]) -> [String] {
        lines.filter { $0.contains("after something had already been drawn") }
    }

    // MARK: - 10a draw() の中

    /// 図形 A を置く → `save` → 図形 B を置く。**ファイルには B だけがあり、A は無い。**
    @Test("draw() の中で呼ぶと、呼んだ時点から draw() の終わりまでの図形を書く")
    func savingInsideDrawWritesFromTheCall() throws {
        try withTemporaryDirectory("mokume-svg-inside") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.line(0, 0, 10, 0)  // A
                sketch.save(url.path)
                sketch.line(0, 10, 20, 10)  // B
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            let elements = try elements(of: url)
            #expect(elements.count == 1, "\(elements)")
            #expect(SVG.attribute("d", in: elements.first ?? "") == "M0 10L20 10")
            // 10c: 呼ぶ前に置いた図形があったので、知らせる
            #expect(late(lines).count == 1, "\(lines)")
        }
    }

    /// 呼んだ時点は行き先ごとに決まる。**先に頼んだ行き先は後に置いた図形も受け、後で頼んだ行き先は
    /// 呼んだ時点から後ろだけを受ける。**
    @Test("draw() の中で 2 回呼べば、それぞれが呼んだ時点から後ろを書く")
    func twoCallsEachStartWhereTheyWereMade() throws {
        try withTemporaryDirectory("mokume-svg-two") { directory in
            let earlyURL = directory.appendingPathComponent("early.svg")
            let lateURL = directory.appendingPathComponent("late.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.save(earlyURL.path)
                sketch.line(0, 0, 10, 0)  // A
                sketch.save(lateURL.path)
                sketch.line(0, 10, 20, 10)  // B
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            #expect(try elements(of: earlyURL).map { SVG.attribute("d", in: $0) } == ["M0 0L10 0", "M0 10L20 10"])
            #expect(try elements(of: lateURL).map { SVG.attribute("d", in: $0) } == ["M0 10L20 10"])
            // 2 つ目は、呼ぶ前に A を置いていたので知らせる。1 つ目は何も置く前に呼んだので知らせない
            #expect(late(lines).count == 1 && late(lines).first?.contains("late.svg") == true, "\(lines)")
        }
    }

    @Test("draw() の先頭で呼べば、その draw() が置いた図形がすべて入り、背景があっても知らせない")
    func savingFirstWritesEverythingAndSaysNothing() throws {
        try withTemporaryDirectory("mokume-svg-first") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.save(url.path)
                sketch.background(255)
                sketch.stroke(0)
                sketch.line(0, 0, 10, 0)
                sketch.line(0, 10, 20, 10)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            #expect(try elements(of: url).count == 2)
            #expect(lines.isEmpty, "\(lines)")
        }
    }

    /// 15: `background()` は SVG に書かず、警告もしない。作例の要素は折れ線だけ。
    @Test("background() は要素にならず、警告も出ない")
    func backgroundIsNeitherWrittenNorWarned() throws {
        try withTemporaryDirectory("mokume-svg-background") { directory in
            let url = directory.appendingPathComponent("flow.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.save(url.path)
                sketch.background(255)
                sketch.noFill()
                sketch.stroke(0)
                sketch.strokeWeight(0.5)
                for seed in 0..<2_000 {
                    sketch.beginShape()
                    for step in 0..<10 { sketch.vertex(Float(seed % 90) + Float(step), Float(step) * 3) }
                    sketch.endShape()
                }
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            let svg = try String(contentsOf: url, encoding: .utf8)
            #expect(SVG.elements(svg).count == 2_000)
            #expect(svg.components(separatedBy: "<rect").count == 1, "塗りの矩形は無い")
            #expect(lines.isEmpty, "\(lines)")
        }
    }

    // MARK: - 10b draw() の外

    @Test("setup() で呼べば、最初の draw() を丸ごと書く")
    func savingInSetupWritesTheFirstDraw() throws {
        try withTemporaryDirectory("mokume-svg-setup") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onSetup = { $0.save(url.path) }
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.line(0, 0, Float(sketch.frameCount) * 10, 0)
                sketch.line(0, 5, Float(sketch.frameCount) * 10, 5)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                for _ in 0..<3 { try? runtime.advance() }
                runtime.closePlugins()
            }
            // 最初の draw() の図形がすべてあり、2 つ目以降の draw() は無い
            let elements = try elements(of: url)
            #expect(elements.map { SVG.attribute("d", in: $0) } == ["M0 0L10 0", "M0 5L10 5"])
            #expect(late(lines).isEmpty, "draw() の外で呼んだときは知らせない: \(lines)")
        }
    }

    @Test("入力のコールバックで呼べば、次の draw() を丸ごと書き、呼んだ回の 1 つ前の draw() は無い")
    func savingInACallbackWritesTheNextDraw() throws {
        try withTemporaryDirectory("mokume-svg-callback") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onKey = { $0.save(url.path) }
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.line(0, 0, Float(sketch.frameCount) * 10, 0)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                for _ in 0..<2 { try? runtime.advance() }
                // 3 フレーム目の頭で押す。2 フレーム目までの draw() は書かれない
                runtime.input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
                for _ in 0..<2 { try? runtime.advance() }
                runtime.closePlugins()
            }
            let elements = try elements(of: url)
            #expect(elements.map { SVG.attribute("d", in: $0) } == ["M0 0L30 0"], "\(elements)")
            #expect(late(lines).isEmpty, "\(lines)")
        }
    }

    @Test("止まっているスケッチで呼んでも、redraw() が次の draw() を描けば書く")
    func aStoppedSketchWritesOnRedraw() throws {
        try withTemporaryDirectory("mokume-svg-redraw") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onSetup = { $0.noLoop() }
            sketch.onKey = { sketch in
                sketch.save(url.path)
                sketch.redraw()
            }
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.line(0, 0, Float(sketch.frameCount) * 10, 0)
            }
            let runtime = try makeRuntime(sketch)
            _ = saying {
                try? runtime.advance()
                runtime.input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
                try? runtime.advance()
                runtime.closePlugins()
            }
            let elements = try elements(of: url)
            #expect(elements.map { SVG.attribute("d", in: $0) } == ["M0 0L20 0"], "\(elements)")
        }
    }

    @Test("次の draw() が来ないまま終わったら、書けなかったと 1 度言う")
    func aRequestThatNeverGetsADrawIsSaid() throws {
        try withTemporaryDirectory("mokume-svg-never") { directory in
            let url = directory.appendingPathComponent("never.svg")
            let sketch = PlotterSketch()
            sketch.onSetup = { $0.noLoop() }
            sketch.onKey = { $0.save(url.path) }
            sketch.onDraw = { $0.line(0, 0, 10, 0) }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
                try? runtime.advance()
                runtime.closePlugins()
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let said = lines.filter { $0.contains("never.svg") && $0.contains("before the next draw()") }
            #expect(said.count == 1, "\(lines)")
        }
    }

    // MARK: - 10c 知らせる回数

    @Test("呼ぶ前に置いた図形があっても、知らせるのは 1 度だけで、毎フレームではない")
    func theLateWarningIsOnceNotPerFrame() throws {
        try withTemporaryDirectory("mokume-svg-late-once") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.rect(1, 1, 5, 5)
                sketch.save(url.path)
                sketch.rect(10, 10, 5, 5)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                for _ in 0..<5 { try? runtime.advance() }
                runtime.closePlugins()
            }
            #expect(late(lines).count == 1, "\(lines)")
            let said = late(lines).first ?? ""
            #expect(said.contains("save(\"\(url.path)\")") && said.contains("Call it first in draw()"), "\(said)")
        }
    }

    // MARK: - background() と save (反証の直し)

    /// 画面は `background()` で前の図形を消す。ペンプロッタは画面に無い線を引かない。
    @Test("background() が画面を塗り直すと、それより前の図形は書かれない (save の前でも後でも)")
    func backgroundErasesWhatCameBefore() throws {
        try withTemporaryDirectory("mokume-svg-erased") { directory in
            let afterURL = directory.appendingPathComponent("after.svg")
            let beforeURL = directory.appendingPathComponent("before.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.line(0, 0, 10, 0)  // A
                sketch.background(255)  // A を画面から消す
                sketch.save(beforeURL.path)  // 呼ぶ前に残っているものは無い
                sketch.line(0, 10, 20, 10)  // B
                sketch.save(afterURL.path)
                sketch.line(0, 20, 30, 20)  // C
                sketch.background(255)  // B・C も消す
                sketch.line(0, 30, 40, 30)  // D
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            #expect(try elements(of: beforeURL).map { SVG.attribute("d", in: $0) } == ["M0 30L40 30"])
            #expect(try elements(of: afterURL).map { SVG.attribute("d", in: $0) } == ["M0 30L40 30"])
            // before.svg は、呼ぶ前の A が画面から消えているので「呼ぶ前に置いた」とは言わない。
            // after.svg は B を置いた後に呼んだので、1 度言う
            let said = late(lines)
            #expect(said.count == 1 && said.first?.contains("after.svg") == true, "\(lines)")
        }
    }

    // MARK: - 同じ行き先へ 2 回

    @Test("同じ draw() で同じファイルへ 2 回頼むと、先の頼みを書き、後の頼みが何も変えなかったと 1 度言う")
    func askingTwiceForTheSameFileWritesTheFirstAndSaysSo() throws {
        try withTemporaryDirectory("mokume-svg-twice") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.stroke(0)
                sketch.save(url.path)
                sketch.line(0, 0, 10, 0)  // A
                // 同じファイルを別の綴りで頼む
                sketch.save(directory.path + "/./plot.svg")
                sketch.line(0, 10, 20, 10)  // B
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                for _ in 0..<3 { try? runtime.advance() }
                runtime.closePlugins()
            }
            #expect(
                try elements(of: url).map { SVG.attribute("d", in: $0) } == ["M0 0L10 0", "M0 10L20 10"],
                "先の頼みが書かれ、A も B も欠けない")
            let said = lines.filter { $0.contains("called twice") }
            #expect(said.count == 1, "毎フレームではなく 1 度: \(lines)")
            #expect(said.first?.contains("the later call changed nothing") == true, "\(said)")
        }
    }

    // MARK: - 8 書けない図形

    @Test("書けない図形は、種類と数を 1 度だけ名乗る")
    func unwritableFiguresAreNamedOnce() throws {
        try withTemporaryDirectory("mokume-svg-dropped") { directory in
            let url = directory.appendingPathComponent("plot.svg")
            let sketch = PlotterSketch()
            var layer: Canvas?
            sketch.onSetup = { sketch in layer = creating({ try sketch.canvas.createGraphics(8, 8) }) }
            sketch.onDraw = { sketch in
                sketch.save(url.path)
                sketch.stroke(0)
                sketch.line(0, 0, 10, 0)
                sketch.text("a", 10, 10)
                sketch.text("b", 10, 20)
                if let layer { sketch.canvas.image(layer, 0, 0) }
                sketch.box(10)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                for _ in 0..<4 { try? runtime.advance() }
                runtime.closePlugins()
            }
            #expect(try elements(of: url).count == 1)
            let said = lines.filter { $0.contains("left out of the file") }
            #expect(said.count == 1, "毎フレームではない: \(lines)")
            let text = said.first ?? ""
            #expect(text.contains("text x2") && text.contains("image x1") && text.contains("3D solid x1"), "\(text)")
        }
    }

    // MARK: - 11 決定論

    @Test("同じ入力を 2 回書くと、バイトまで一致する")
    func twoRunsWriteTheSameBytes() throws {
        try withTemporaryDirectory("mokume-svg-same") { directory in
            @MainActor func run(_ name: String) throws -> Data {
                let url = directory.appendingPathComponent(name)
                let sketch = PlotterSketch()
                sketch.onDraw = { sketch in
                    sketch.save(url.path)
                    sketch.stroke(.display(red: 0.3, green: 0.2, blue: 0.9, alpha: 0.6))
                    sketch.fill(.display(red: 0.9, green: 0.5, blue: 0.1))
                    sketch.rect(10, 10, 30, 30, 5)
                    sketch.ellipse(60, 40, 30, 20)
                    sketch.arc(30, 60, 30, 30, 0.2, 2.2)
                    sketch.strokeDash(4, 2)
                    sketch.line(0, 0, 99, 79)
                    sketch.rotate(0.3)
                    sketch.triangle(0, 0, 20, 0, 0, 20)
                }
                let runtime = try makeRuntime(sketch)
                try runtime.advance()
                runtime.closePlugins()
                return try Data(contentsOf: url)
            }
            let first = try run("a.svg")
            let second = try run("b.svg")
            #expect(!first.isEmpty)
            #expect(first == second)
        }
    }

    // MARK: - 12 書き込み

    @Test("書き出し先を作れなければ、書き損じとして名乗る")
    func anUnwritableDestinationIsNamed() throws {
        try withTemporaryDirectory("mokume-svg-blocked") { directory in
            // 親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let path = blocker.appendingPathComponent("plot.svg").path
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.save(path)
                sketch.line(0, 0, 10, 0)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            let said = lines.filter { $0.contains("Could not write") && $0.contains("plot.svg") }
            #expect(said.count == 1, "\(lines)")
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("作れない長さの名前は書かず、長さを名指す")
    func aTooLongNameIsRefused() throws {
        let path = String(repeating: "a", count: 300) + ".svg"
        let sketch = PlotterSketch()
        sketch.onDraw = { sketch in
            sketch.save(path)
            sketch.line(0, 0, 10, 0)
        }
        let runtime = try makeRuntime(sketch)
        let (_, lines) = saying {
            try? runtime.advance()
            runtime.closePlugins()
        }
        let said = lines.filter { $0.contains("Nothing was saved") }
        #expect(said.count == 1, "\(lines)")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("同じ行き先へ毎フレーム書くと、最後に頼んだ図形が残る")
    func theLastFrameWins() throws {
        try withTemporaryDirectory("mokume-svg-last") { directory in
            let url = directory.appendingPathComponent("now.svg")
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.save(url.path)
                sketch.stroke(0)
                sketch.line(0, 0, Float(sketch.frameCount), 0)
            }
            let runtime = try makeRuntime(sketch)
            for _ in 0..<12 { try runtime.advance() }
            runtime.closePlugins()
            let elements = try elements(of: url)
            #expect(elements.map { SVG.attribute("d", in: $0) } == ["M0 0L12 0"], "\(elements)")
        }
    }

    @Test("書き出し先が既にディレクトリなら、黙らずに書き損じとして名乗る")
    func aDirectoryInTheWayIsNamed() throws {
        try withTemporaryDirectory("mokume-svg-directory") { directory in
            let taken = directory.appendingPathComponent("taken.svg", isDirectory: true)
            try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
            let sketch = PlotterSketch()
            sketch.onDraw = { sketch in
                sketch.save(taken.path)
                sketch.line(0, 0, 10, 0)
            }
            let runtime = try makeRuntime(sketch)
            let (_, lines) = saying {
                try? runtime.advance()
                runtime.closePlugins()
            }
            #expect(lines.filter { $0.contains("Could not write") && $0.contains("taken.svg") }.count == 1, "\(lines)")
        }
    }

    // MARK: - 5 画面は変わらない

    /// **`save("x.svg")` の有無で、同じスケッチの画素が一致する** (控えるだけで、組み立てを別の経路にしない)。
    /// 窓を開いて控える道と、控えない道の両方を、本物のランタイムで回す (GPU を使う。単発で 1 回)。
    @Test("save(\"x.svg\") の有無で、同じスケッチの画素が一致する")
    func savingDoesNotChangeThePicture() throws {
        try withTemporaryDirectory("mokume-svg-pixels") { directory in
            @MainActor func pixels(saving: Bool) throws -> [UInt8] {
                let sketch = PlotterSketch()
                sketch.onDraw = { sketch in
                    if saving { sketch.save(directory.appendingPathComponent("p.svg").path) }
                    sketch.background(30)
                    sketch.fill(.display(red: 1, green: 0.5, blue: 0.2, alpha: 0.7))
                    sketch.stroke(.display(red: 0.2, green: 0.8, blue: 1))
                    sketch.strokeWeight(3)
                    sketch.rect(10, 10, 40, 30, 6)
                    sketch.ellipse(70, 30, 30, 20)
                    sketch.arc(30, 60, 30, 30, 0.3, 2.5)
                    sketch.strokeDash(4, 3)
                    sketch.line(5, 70, 90, 40)
                    sketch.noStrokeDash()
                    sketch.push()
                    sketch.translate(70, 60)
                    sketch.rotate(0.5)
                    sketch.triangle(0, 0, 20, 0, 0, 20)
                    sketch.pop()
                    sketch.text("a", 5, 20)
                }
                let runtime = try makeRuntime(sketch)
                for _ in 0..<3 { try runtime.advance() }
                let bytes = try runtime.target.encodeForDisplay().bytes
                runtime.closePlugins()
                return bytes
            }
            let withSave = try pixels(saving: true)
            let without = try pixels(saving: false)
            #expect(withSave == without)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("p.svg").path))
        }
    }

    // MARK: - 7 頼まない作品は払わない

    @Test("save() を呼ばない作品は、控えの器も撮る係も作らない")
    func aSketchThatNeverSavesPaysNothing() throws {
        let sketch = PlotterSketch()
        sketch.onDraw = { sketch in
            sketch.fill(.display(red: 1, green: 0, blue: 0))
            sketch.rect(5, 5, 20, 20)
            sketch.ellipse(50, 40, 30, 30)
            sketch.beginShape()
            for step in 0..<20 { sketch.vertex(Float(step) * 4, Float(step * step) / 6) }
            sketch.endShape()
            #expect(sketch.canvas.vector.capture == nil)
        }
        let runtime = try makeRuntime(sketch)
        for _ in 0..<6 { try runtime.advance() }
        #expect(runtime.recorderWarnings == nil, "撮る係は頼まれてはじめて作る")
        runtime.closePlugins()
    }

    /// 長く回しても、頼まない作品の置き場が増えない ([ADR-0019] 決定 6 の長回し)。
    ///
    /// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
    @Test("頼まない作品を長く回しても、置き場が増えない")
    func aLongRunWithoutSavingDoesNotAllocate() throws {
        let sketch = PlotterSketch()
        sketch.onDraw = { sketch in
            sketch.background(20)
            sketch.stroke(255)
            for index in 0..<30 {
                sketch.line(Float(index), 0, Float(index) + 20, 70)
                sketch.rect(Float(index) * 3, 10, 6, 6)
            }
        }
        let runtime = try makeRuntime(sketch)
        for _ in 0..<24 { try runtime.advance() }
        let gpu = runtime.canvas.gpu
        let settled = gpu.residencySet.allocationCount
        for _ in 0..<120 { try runtime.advance() }
        #expect(gpu.residencySet.allocationCount == settled)
        #expect(runtime.recorderWarnings == nil)
        runtime.closePlugins()
    }
}

/// 撮る係の側 (ベクターを頼まれたときの書き方)。GPU を要さない。
@Suite("ベクターを書く撮る係")
struct VectorRecorderTests {
    @Test("控えた図形を頼まれた時点から後ろだけ書き、書き損じは静止画と同じ道で名乗る")
    func writesFromTheRequestAndNamesFailures() throws {
        try withTemporaryDirectory("mokume-svg-recorder") { directory in
            let capture = VectorCapture()
            func figure(_ x: Float) -> VectorFigure {
                VectorFigure(
                    subpaths: [VectorSubpath(points: [SIMD2(x, 0), SIMD2(x, 10)], isClosed: false)],
                    fill: nil,
                    stroke: VectorStroke(color: VectorColor(.display(red: 0, green: 0, blue: 0)), width: 1, cap: .round, join: .miter))
            }
            capture.figures = [figure(1), figure(2), figure(3)]
            capture.drops = [.text, .image, .image]
            let whole = directory.appendingPathComponent("whole.svg").path
            let tail = directory.appendingPathComponent("tail.svg").path
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let blocked = blocker.appendingPathComponent("blocked.svg").path
            capture.requests = [
                .init(path: whole, figureStart: 0, dropStart: 0, placedBefore: false),
                .init(path: tail, figureStart: 2, dropStart: 2, placedBefore: true),
                .init(path: blocked, figureStart: 0, dropStart: 0, placedBefore: false),
            ]

            let recorder = FrameRecorder()
            recorder.writeVectors(capture, width: 100, height: 80)
            recorder.close()

            let wholeElements = SVG.elements(try String(contentsOfFile: whole, encoding: .utf8))
            let tailElements = SVG.elements(try String(contentsOfFile: tail, encoding: .utf8))
            #expect(wholeElements.count == 3)
            #expect(tailElements.map { SVG.attribute("d", in: $0) } == ["M3 0L3 10"])
            // 頼まれた時点から後ろの種類だけを名指す
            let leftOutTail = try #require(
                recorder.warnings.message(for: .vectorLeftOut(destination: FrameWriter.destination(of: tail))))
            #expect(leftOutTail.contains("image x1") && !leftOutTail.contains("text"), "\(leftOutTail)")
            let leftOutWhole = try #require(
                recorder.warnings.message(for: .vectorLeftOut(destination: FrameWriter.destination(of: whole))))
            #expect(leftOutWhole.contains("text x1") && leftOutWhole.contains("image x2"), "\(leftOutWhole)")
            #expect(recorder.warnings.hasWarned(.vectorPlacedBefore(destination: FrameWriter.destination(of: tail))))
            #expect(!recorder.warnings.hasWarned(.vectorPlacedBefore(destination: FrameWriter.destination(of: whole))))
            // 書けなかった行き先は、静止画と同じ書き損じとして名乗り、穴が立つ
            #expect(recorder.imageFailureMessage(for: blocked)?.contains("blocked.svg") == true)
            #expect(recorder.hasFailedToWrite)
        }
    }

    @Test("同じ行き先を 2 回頼まれたら、先の頼みだけを書く。別の綴りでも同じ行き先と見る")
    func theFirstOfTwoRequestsForOneFileIsWritten() throws {
        try withTemporaryDirectory("mokume-svg-recorder-twice") { directory in
            func figure(_ x: Float) -> VectorFigure {
                VectorFigure(
                    subpaths: [VectorSubpath(points: [SIMD2(x, 0), SIMD2(x, 10)], isClosed: false)],
                    fill: nil,
                    stroke: VectorStroke(color: VectorColor(.display(red: 0, green: 0, blue: 0)), width: 1, cap: .round, join: .miter))
            }
            let capture = VectorCapture()
            capture.figures = [figure(1), figure(2), figure(3)]
            let path = directory.appendingPathComponent("plot.svg").path
            let spelled = directory.path + "/./plot.svg"
            let other = directory.appendingPathComponent("other.svg").path
            capture.requests = [
                .init(path: path, figureStart: 0, dropStart: 0, placedBefore: false),
                .init(path: spelled, figureStart: 2, dropStart: 0, placedBefore: true),
                .init(path: other, figureStart: 1, dropStart: 0, placedBefore: false),
            ]
            let recorder = FrameRecorder()
            recorder.writeVectors(capture, width: 100, height: 80)
            recorder.close()
            #expect(SVG.elements(try String(contentsOfFile: path, encoding: .utf8)).count == 3, "多い側 (先の頼み)")
            #expect(SVG.elements(try String(contentsOfFile: other, encoding: .utf8)).count == 2, "別の行き先は別")
            let destination = FrameWriter.destination(of: path)
            let said = try #require(recorder.warnings.message(for: .vectorAskedTwice(destination: destination)))
            #expect(said.contains(path) && said.contains(spelled), "\(said)")
            // 書かなかった頼みの「呼ぶ前に置いた」知らせは言わない
            #expect(!recorder.warnings.hasWarned(.vectorPlacedBefore(destination: destination)))
        }
    }

    @Test("ファイル名の上限 (255) ちょうどの SVG は書け、1 字越えれば断る")
    func aNameAtTheLimitIsWritten() throws {
        try withTemporaryDirectory("mokume-svg-limit") { directory in
            let capture = VectorCapture()
            capture.figures = [
                VectorFigure(
                    subpaths: [VectorSubpath(points: [SIMD2(0, 0), SIMD2(1, 1)], isClosed: false)], fill: nil,
                    stroke: VectorStroke(color: VectorColor(.display(red: 0, green: 0, blue: 0)), width: 1, cap: .round, join: .miter))
            ]
            func name(_ length: Int) -> String { String(repeating: "a", count: length - 4) + ".svg" }
            let atLimit = directory.appendingPathComponent(name(FileNameLength.limit)).path
            capture.requests = [.init(path: atLimit, figureStart: 0, dropStart: 0, placedBefore: false)]
            let recorder = FrameRecorder()
            #expect(recorder.acceptsVector(atLimit))
            recorder.writeVectors(capture, width: 10, height: 10)
            recorder.close()
            // `.atomic` の書き込みは一時ファイルを経由する。**上限ちょうどでも、書けたことと名乗りが揃う**
            #expect(!recorder.hasFailedToWrite, "名乗った書き損じ: \(recorder.imageFailureMessage(for: atLimit) ?? "")")
            #expect(FileManager.default.fileExists(atPath: atLimit), "255 字のファイル名が書かれていない")
            #expect(!recorder.acceptsVector(directory.appendingPathComponent(name(FileNameLength.limit + 1)).path))
        }
    }

    @Test(".svg の連番は撮り始めず、理由を言う")
    func anSVGSeriesIsNotStarted() {
        let recorder = FrameRecorder()
        recorder.beginRecord("out/frame-####.svg", at: 0)
        #expect(!recorder.isRecording)
        #expect(recorder.warnings.hasWarned(.vectorSeries))
        let said = recorder.warnings.message(for: .vectorSeries) ?? ""
        #expect(said.contains("save(\"plot.svg\")") && said.contains("Not starting"), "\(said)")
        recorder.close()
    }

    @Test("拡張子で振り分ける")
    func theExtensionDecides() {
        #expect(FrameRecorder.isVector("a.svg") && FrameRecorder.isVector("out/A.SVG"))
        #expect(!FrameRecorder.isVector("a.png") && !FrameRecorder.isVector("svg") && !FrameRecorder.isVector("a.svg.png"))
    }
}
