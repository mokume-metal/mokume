// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 効果を通したフレームの後、止まっている間のコールバックで描く先を変えたとき ([#1524])。
///
/// **止まっている間に変えたものは、次のフレームでは効果を通す前の絵の上に載る。** フレームの外で
/// 読む画素は効果を通した絵 (出口と同じ 1 枚) なので、変える前の効果を通した絵を控え、次の
/// フレームの頭で**違う画素だけ**を効果を通す前の絵へ重ねてから戻す (甲-1)。直す前は、書いた画素が
/// 写しの全面 (効果を通した絵) ごと書き戻されて効果が焼き込まれるか、次のフレームの頭が効果を
/// 通す前の絵で上書きして、変えた分が消えていた。
///
/// 止まっている間のコールバックは、面の上では持ち越しの区間 (``Canvas/carriesOver``) である。
/// ここではその印を立てて模す。ランタイムを通す形は、下の「ランタイムを通す」が見る。
///
/// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
@Suite(
    "止まっている間に変えた描く先と効果",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectStoppedChangeTests {
    /// 効果を通す面。描き場所は止まっている間のコールバックを持たない (区間は
    /// `beginDraw()`〜`endDraw()` だけ・#1672) ので入れない。
    enum Surface: CaseIterable, CustomTestStringConvertible {
        /// 本体の面。細かさ 1 なので、描く先と出す先が同じ 1 枚である。
        case main
        /// 細かさを下げた面。効果は描く先に書かれ、拡大がそこから出す先へ広げる。
        case halfDensity

        var testDescription: String {
            switch self {
            case .main: "本体の面"
            case .halfDensity: "細かさ 0.5 の面"
            }
        }

        /// 出す大きさ 160×160 の面を 1 つ作る。
        func make() throws -> Canvas {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
            switch self {
            case .main: return try Canvas(target: output, gpu: gpu)
            case .halfDensity:
                return try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
            }
        }
    }

    /// 再現手順の下地 (`background(235)`) と効果。
    private static func paper(_ canvas: Canvas) { canvas.background(235) }
    private static let darkening: [Effect] = [.vignette(amount: 0.6)]
    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    /// 1 枚目: 下地に効果を通す。
    private static func firstFrame(_ canvas: Canvas) throws {
        try canvas.draw {
            paper(canvas)
            canvas.effects(darkening)
        }
    }

    /// 止まっている間のコールバックを模す (持ち越しの区間の印を立てる)。
    private static func whileStopped(_ canvas: Canvas, _ body: () -> Void) {
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        body()
    }

    /// 2 枚目: 効果を頼まず、何も置かない。**描く先を読む** — 細かさを下げた面でも、書いた画素が
    /// 拡大でにじまないところで見る。
    private static func secondFrame(_ canvas: Canvas) throws -> PixelBuffer {
        try canvas.draw {}
        return try canvas.target.readPixels()
    }

    /// 描く先の中央 (描く画素)。
    private static func centre(of canvas: Canvas) -> (x: Int, y: Int) {
        (canvas.pixelWidth / 2, canvas.pixelHeight / 2)
    }

    /// 止まっている間に何も変えなかったときの 2 枚目。
    private static func untouchedSecondFrame(_ surface: Surface) throws -> PixelBuffer {
        let canvas = try surface.make()
        try firstFrame(canvas)
        return try secondFrame(canvas)
    }

    private static func isRed(_ color: LinearRGBA) -> Bool {
        color.red > 0.99 && color.green < 0.01 && color.blue < 0.01
    }

    /// 画素を書く口。
    enum Writer: CaseIterable, CustomTestStringConvertible {
        case set
        case subscripted
        case fill

        var testDescription: String {
            switch self {
            case .set: "set"
            case .subscripted: "pixels[x, y] ="
            case .fill: "pixels.fill"
            }
        }

        func write(_ color: LinearRGBA, at point: (x: Int, y: Int), on canvas: Canvas) {
            switch self {
            case .set: canvas.set(point.x, point.y, color)
            case .subscripted: canvas.pixels[point.x, point.y] = color
            case .fill: canvas.pixels.fill(color)
            }
        }
    }

    /// 完了条件 1 — 止まっている間に書いた画素は残り、効果は焼き込まれない。
    ///
    /// 隅 (3, 3) は周辺減光がいちばん効くところで、書いていない。2 枚目は効果を頼まないので、
    /// 隅は下地だけの値に戻るはずである。直す前は、写しの全面 (効果を通した絵) が書き戻されて、
    /// 隅に周辺減光が残った。`fill` は全面を書くので、隅も書いた色になる。
    @Test(
        "止まっている間に書いた画素は残り、効果は次のフレームへ焼き込まれない",
        arguments: Surface.allCases, Writer.allCases)
    func writtenPixelsStayWithoutBakingTheEffect(surface: Surface, writer: Writer) throws {
        let canvas = try surface.make()
        let centre = Self.centre(of: canvas)
        try Self.firstFrame(canvas)
        Self.whileStopped(canvas) { writer.write(Self.red, at: centre, on: canvas) }
        let second = try Self.secondFrame(canvas)

        #expect(Self.isRed(second[centre.x, centre.y]), "書いた画素が 2 枚目に残っていない")
        if writer == .fill {
            #expect(Self.isRed(second[3, 3]), "全面を書いたのに、隅が書いた色でない")
        } else {
            let untouched = try Self.untouchedSecondFrame(surface)
            #expect(
                second[3, 3] == untouched[3, 3],
                "隅に効果が焼き込まれた: \(second[3, 3].red) (書かなければ \(untouched[3, 3].red))")
        }
    }

    /// 完了条件 2 — 読んだ値をそのまま書き戻しても、絵は変わらない (`pixels[x, y] = pixels[x, y]`)。
    ///
    /// フレームの外で読む値は効果を通した絵なので、直す前はその全面が次のフレームの入りになった。
    @Test(
        "止まっている間に全画素を読んで書き戻しても、2 枚目は書かなかったときと同じ",
        arguments: Surface.allCases)
    func rewritingWhatWasReadChangesNothing(surface: Surface) throws {
        let canvas = try surface.make()
        try Self.firstFrame(canvas)
        Self.whileStopped(canvas) {
            let pixels = canvas.pixels
            for y in 0..<pixels.height {
                for x in 0..<pixels.width { pixels[x, y] = pixels[x, y] }
            }
        }
        let second = try Self.secondFrame(canvas)
        let untouched = try Self.untouchedSecondFrame(surface)

        var differing = 0
        for y in 0..<second.height {
            for x in 0..<second.width where second[x, y] != untouched[x, y] { differing += 1 }
        }
        #expect(differing == 0, "書き戻しただけで \(differing) 画素が変わった")
    }

    /// 完了条件 3 — 書いた後、2 枚目より前に出力段を通っても、書いた画素は消えない。
    ///
    /// 出力段は写しを描く先へ書き戻して「戻した」ことにする。直す前は、次のフレームの頭が効果を
    /// 通す前の絵を戻すだけになり、書いた画素が消えた (細かさ 1 の面。細かさを下げた面の出力段は
    /// 出す先を読むので、描く先の写しには触らない)。
    @Test(
        "止まっている間に書いて出力段を通しても、書いた画素は次のフレームに残る",
        arguments: Surface.allCases)
    func writtenPixelsSurviveTheOutputStage(surface: Surface) throws {
        let canvas = try surface.make()
        let centre = Self.centre(of: canvas)
        try Self.firstFrame(canvas)
        Self.whileStopped(canvas) { canvas.set(centre.x, centre.y, Self.red) }
        let shown = try canvas.output.encodeToImage().read()
        let second = try Self.secondFrame(canvas)

        if surface == .main {
            let point = shown[centre.x, centre.y]
            #expect(point.red == 255 && point.green == 0, "出力段に書いた画素が出ていない")
        }
        #expect(Self.isRed(second[centre.x, centre.y]), "出力段を通した後、書いた画素が消えた")
        let untouched = try Self.untouchedSecondFrame(surface)
        #expect(second[3, 3] == untouched[3, 3], "隅に効果が焼き込まれた: \(second[3, 3].red)")
    }

    /// 止まっている間に置いて、その場で描き切らせるもの。
    enum Placement: CaseIterable, CustomTestStringConvertible {
        /// 図形を置いて、画素を読む口で描き切らせる。
        case shapeThenRead
        /// 描き場所を置いて、その描き場所を描き直す (置いた面が変わる直前の描き切り)。
        case graphicsThenRedrawn
        /// 背景を塗って、画素を読む口で描き切らせる。
        case backgroundThenRead

        var testDescription: String {
            switch self {
            case .shapeThenRead: "図形を置いて読む"
            case .graphicsThenRedrawn: "描き場所を置いて描き直す"
            case .backgroundThenRead: "背景を塗って読む"
            }
        }
    }

    /// 完了条件 4 — 止まっている間に置いて描き切らせたものは、次のフレームで消えない。
    ///
    /// 直す前は、フレームの外の描き切りが効果を通した絵の上に描き、次のフレームの頭が効果を
    /// 通す前の絵を戻して上書きしていた。
    @Test(
        "止まっている間に置いて描き切らせたものは、次のフレームで消えない",
        arguments: Surface.allCases, Placement.allCases)
    func placedAndSettledThingsStay(surface: Surface, placement: Placement) throws {
        let canvas = try surface.make()
        let centre = Self.centre(of: canvas)
        let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
        let layer = try canvas.createGraphics(40, 40)
        layer.beginDraw()
        layer.background(green)
        layer.endDraw()
        try Self.firstFrame(canvas)

        Self.whileStopped(canvas) {
            switch placement {
            case .shapeThenRead:
                canvas.noStroke()
                canvas.fill(Self.red)
                canvas.circle(80, 80, 40)
                _ = canvas.get(0, 0)
            case .graphicsThenRedrawn:
                canvas.image(layer, 60, 60)
                layer.beginDraw()
                layer.background(Self.red)
                layer.endDraw()
            case .backgroundThenRead:
                canvas.background(0)
                _ = canvas.get(0, 0)
            }
        }
        let second = try Self.secondFrame(canvas)

        let point = second[centre.x, centre.y]
        switch placement {
        case .shapeThenRead:
            #expect(Self.isRed(point), "描き切った図形が 2 枚目で消えた: \(point)")
        case .graphicsThenRedrawn:
            // 置いた時点の絵 (描き直す前の緑) が残る
            #expect(point.green > 0.99 && point.red < 0.01, "描き切った絵が 2 枚目で消えた: \(point)")
        case .backgroundThenRead:
            for (x, y) in [(3, 3), (centre.x, centre.y)] {
                #expect(second[x, y].red < 0.01, "塗った背景が (\(x), \(y)) で消えた: \(second[x, y])")
            }
        }
    }

    // MARK: - 払うのは変えたときだけ

    /// 完了条件 6 — 効果を頼まない面と、効果を頼んでも止まっている間に描く先を変えない面は、
    /// 変える前の絵の控えを作らず、重ねる段も積まない。
    ///
    /// 読むだけのコールバック (色を拾う `get()`) も変えないうちに入る。細かさを下げた面は拡大の
    /// ために段のパイプラインが立つので、パイプラインの有無ではなく控えを作った回数で見る。
    @Test(
        "止まっている間に描く先を変えない面は、変える前の絵を控えず、重ねる段も積まない",
        arguments: Surface.allCases)
    func paysNothingWithoutAChange(surface: Surface) throws {
        // 効果を頼まずに、止まっている間に書く
        let plain = try surface.make()
        let centre = Self.centre(of: plain)
        try plain.draw { Self.paper(plain) }
        Self.whileStopped(plain) { plain.set(centre.x, centre.y, Self.red) }
        _ = try Self.secondFrame(plain)
        #expect((plain.effectPipelineStorage?.picturesBeforeChangeBuilt ?? 0) == 0)
        #expect(plain.effectChangesKeptEncoded == 0)

        // 効果を頼んで、止まっている間は読むだけ
        let reading = try surface.make()
        for _ in 0..<3 {
            try Self.firstFrame(reading)
            Self.whileStopped(reading) { _ = reading.get(centre.x, centre.y) }
            _ = try Self.secondFrame(reading)
        }
        #expect(reading.effectPipelineStorage?.picturesBeforeChangeBuilt == 0, "読んだだけで控えを作った")
        #expect(reading.effectChangesKeptEncoded == 0, "変えていないのに重ねる段を積んだ")
    }

    /// 完了条件 6 — 変えるたびに控えを作り直さない。長く回しても、置き場の確保が積み上がらない。
    @Test(
        "止まっている間に変えるのを繰り返しても、控えもテーブルも作り直さない",
        arguments: Surface.allCases)
    func keepsNothingGrowingWhileItRuns(surface: Surface) throws {
        let canvas = try surface.make()
        let centre = Self.centre(of: canvas)
        func cycle(_ index: Int) throws {
            try Self.firstFrame(canvas)
            Self.whileStopped(canvas) {
                canvas.set(centre.x + index % 8, centre.y, Self.red)
                if index.isMultiple(of: 2) {
                    canvas.circle(40, 40, 10)
                    _ = canvas.get(0, 0)
                }
            }
            _ = try Self.secondFrame(canvas)
        }
        try cycle(0)
        let pipeline = try #require(canvas.effectPipelineStorage)
        let tables = pipeline.tablesBuilt
        let buffers = pipeline.buffersBuilt
        let kept = canvas.effectChangesKeptEncoded
        for index in 1..<60 { try cycle(index) }

        #expect(pipeline.picturesBeforeChangeBuilt == 1, "変える前の絵の控えを作り直した")
        #expect(pipeline.carriesBuilt == 1)
        #expect(pipeline.tablesBuilt == tables)
        #expect(pipeline.buffersBuilt == buffers)
        // 変えたのは毎回なので、重ねる段も毎回 1 つ
        #expect(canvas.effectChangesKeptEncoded - kept == 59)
    }

    // MARK: - ランタイムを通す

    /// 1 枚目に下地と効果を置いて止まり、キーを押されるたびに頼まれたことをするスケッチ。
    final class StoppedPainter: Sketch {
        let density: Float
        /// 押されたキーの文字ごとに、コールバックの中ですること。
        var onKey: [String: (StoppedPainter) -> Void] = [:]
        init(density: Float) { self.density = density }
        convenience init() { self.init(density: 1) }
        var settings: SketchSettings {
            SketchSettings(width: 160, height: 160, pixelDensity: density)
        }
        func setup() { noLoop() }
        func draw() {
            guard frameCount == 1 else { return }
            background(235)
            effects([.vignette(amount: 0.6)])
        }
        func keyPressed() { onKey[key]?(self) }
    }

    /// 完了条件 1・3 をランタイムの経路で — `noLoop()` の後に配ったコールバックの中で書き、別の
    /// コールバックで `save()` を通してから (止まっている間の出力段)、さらに別のコールバックで
    /// `redraw()` する。2 枚目の中央は書いた赤、隅は下地だけの値である。
    @Test(
        "止まっている間のコールバックで書き、save() を通してから描き直しても、書いた画素が残り効果は焼き込まれない",
        arguments: [Float(1), 0.5])
    func aStoppedSketchKeepsWhatItsCallbackWrote(density: Float) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stopped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = directory.appendingPathComponent("facet", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        func run(_ sketch: StoppedPainter, keys: [String]) throws -> DisplayImage {
            let runtime = try SketchRuntime(
                sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
                inbox: InputInbox(directory: facet))
            try runtime.advance()
            for (index, key) in keys.enumerated() {
                try AtomicFile.write(
                    Data(
                        #"{"id":"k\#(index)","events":[{"type":"keyDown","code":0,"characters":"\#(key)","isRepeat":false},{"type":"keyUp","code":0}]}"#
                            .utf8),
                    to: facet.appendingPathComponent("request.json"))
                try runtime.advance()
            }
            return try runtime.target.encodeToImage().read()
        }

        let written = StoppedPainter(density: density)
        // 中央に 4×4 の赤を書く。**位置は描く画素で数える** (細かさ 0.5 なら中央は (40, 40))。
        // 1 画素でなく塊にするのは、細かさを下げた面で拡大を通っても中央が赤のまま出るため
        written.onKey["w"] = { sketch in
            let centre = sketch.pixelWidth / 2
            for y in centre - 2..<centre + 2 {
                for x in centre - 2..<centre + 2 { sketch.set(x, y, Self.red) }
            }
        }
        written.onKey["s"] = { sketch in sketch.save(directory.appendingPathComponent("stopped.png").path) }
        written.onKey["r"] = { sketch in sketch.redraw() }
        let second = try run(written, keys: ["w", "s", "r"])

        let untouched = StoppedPainter(density: density)
        untouched.onKey["r"] = { sketch in sketch.redraw() }
        let plain = try run(untouched, keys: ["r"])

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped.png").path))
        #expect(second[80, 80].red > 200 && second[80, 80].green < 30, "書いた画素が 2 枚目に残っていない")
        #expect(
            second[3, 3] == plain[3, 3],
            "隅に効果が焼き込まれた: \(second[3, 3]) (書かなければ \(plain[3, 3]))")
    }
}
