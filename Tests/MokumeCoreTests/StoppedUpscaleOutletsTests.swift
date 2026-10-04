// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 止まっている間に変えた描く先が、**出す先を読むどの口にも**出る ([#1882])。
///
/// 出す先を読む口は複数ある — 出力段 (`save()`・観測)・窓 (`FramePresenter`)・共有の面
/// (`SharedFrameSurface`)・CPU の読み出し。どれも同じ 1 枚を受け取る (ADR-0023 決定 2)。止まっている
/// 間のコールバックを配る場所は `SketchRuntime.advance()` の 1 か所だけなので、**配った直後にそこで
/// 追い付けば、どの口も同時に直る**。ここでは実ランタイムに止まっている間のキーを配り、窓と共有の面が
/// 読む出す先のテクスチャを、窓を開かずに読む (`FramePresenter.draw(_:into:)`・`SharedFrameSurface`)。
///
/// 細かさ 1 の面も同じ 1 点で追い付く ([#1906])。描く先が出す先そのものなので広げ直す手は無いが、
/// 書いた画素は CPU の写しに載ったままで、窓と共有の面はテクスチャを直に読む。配った直後に写しを
/// 書き戻さないと、次に描くフレームか出力段を通すまで、書く前の絵が出たままになる。
///
/// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
/// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
@Suite(
    "止まっている間に変えた描く先と、出す先を読む口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct StoppedUpscaleOutletsTests {
    /// 1 枚目に下地 (と、頼めば周辺減光) を置いて止まり、押されたキーごとに頼まれたことをするスケッチ。
    final class StoppedPainter: Sketch {
        let density: Float
        let vignette: Bool
        let upscale: Upscale
        var onKey: [String: (StoppedPainter) -> Void] = [:]
        /// `setup()` の終わりにすること。
        var onSetup: ((StoppedPainter) -> Void)?
        /// 2 枚目以降のフレームの中ですること (1 枚目は下地だけ)。
        var onLaterFrame: ((StoppedPainter) -> Void)?
        init(density: Float, vignette: Bool, upscale: Upscale = .spatial) {
            self.density = density
            self.vignette = vignette
            self.upscale = upscale
        }
        convenience init() { self.init(density: 1, vignette: false) }
        var settings: SketchSettings {
            SketchSettings(width: 160, height: 160, pixelDensity: density, upscale: upscale)
        }
        func setup() {
            noLoop()
            onSetup?(self)
        }
        func draw() {
            guard frameCount == 1 else {
                onLaterFrame?(self)
                return
            }
            background(235)
            if vignette { effects([.vignette(amount: 0.6)]) }
        }
        func keyPressed() { onKey[key]?(self) }
    }

    /// キーのコールバックが開いた描き場所を、検査へ渡す入れ物。
    final class LayerBox {
        var canvas: Canvas?
    }

    /// 止まっている間に変える口。画素を書く口は 3 つとも CPU の写しへ書く ([#1906])。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    enum Change: CaseIterable, CustomTestStringConvertible {
        /// 中央に 4×4 の赤を `set` する。
        case writeBlock
        /// 中央に 4×4 の赤を `pixels[x, y] =` で書く。
        case subscriptBlock
        /// 全面を `pixels.fill` で赤にする。
        case fillPixels
        /// 赤い円を置いて、画素を読む口で描き切らせる。
        case circleThenRead

        var testDescription: String {
            switch self {
            case .writeBlock: "set で画素を書く"
            case .subscriptBlock: "pixels[x, y] = で画素を書く"
            case .fillPixels: "pixels.fill で埋める"
            case .circleThenRead: "円を置いて読む"
            }
        }

        var key: String {
            switch self {
            case .writeBlock: "w"
            case .subscriptBlock: "p"
            case .fillPixels: "f"
            case .circleThenRead: "c"
            }
        }
    }

    /// 細かさ × 周辺減光の有無 × 変え方 の 1 通り。
    struct Scenario: CustomTestStringConvertible {
        let density: Float
        let vignette: Bool
        let change: Change

        var testDescription: String {
            "細かさ \(density)・\(vignette ? "周辺減光あり" : "効果なし")・\(change.testDescription)"
        }

        nonisolated static var all: [Scenario] {
            [Float(0.5), 1].flatMap { density in
                [false, true].flatMap { vignette in
                    Change.allCases.map { Scenario(density: density, vignette: vignette, change: $0) }
                }
            }
        }
    }

    /// 実ランタイムに、止まっている間のキーを配る場を作って渡す。後片付けまで面倒を見る。
    private static func withStoppedSketch(
        density: Float, vignette: Bool = false, upscale: Upscale = .spatial, layer: LayerBox? = nil,
        configure: (StoppedPainter) -> Void = { _ in },
        _ body: (SketchRuntime, RenderDevice, (String) throws -> Void) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stopped-outlets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = directory.appendingPathComponent("facet", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        let sketch = StoppedPainter(density: density, vignette: vignette, upscale: upscale)
        sketch.onKey["w"] = { sketch in
            let centre = sketch.pixelWidth / 2
            for y in centre - 2..<centre + 2 {
                for x in centre - 2..<centre + 2 { sketch.set(x, y, red) }
            }
        }
        sketch.onKey["p"] = { sketch in
            let centre = sketch.pixelWidth / 2
            let pixels = sketch.pixels
            for y in centre - 2..<centre + 2 {
                for x in centre - 2..<centre + 2 { pixels[x, y] = red }
            }
        }
        sketch.onKey["f"] = { sketch in sketch.pixels.fill(red) }
        sketch.onKey["c"] = { sketch in
            sketch.noStroke()
            sketch.fill(red)
            sketch.circle(80, 80, 40)
            _ = sketch.get(0, 0)
        }
        // 描き場所を開き、本体を置いて、本体の画素を書く。**描き場所は開いたままコールバックを終える**
        // (閉じるのは次のコールバック "e")。本体の画素は読み込み済みにしてから置く — 書く前に読み込む
        // 描き切りを挟むと、そこで置いた側へ写させてしまう
        sketch.onKey["a"] = { sketch in
            _ = sketch.get(0, 0)
            guard let opened = try? sketch.createGraphics(160, 160) else { return }
            layer?.canvas = opened
            opened.beginDraw()
            opened.image(sketch.canvas, 0, 0)
            sketch.onKey["w"]?(sketch)
        }
        sketch.onKey["e"] = { _ in layer?.canvas?.endDraw() }
        // 読むだけ (描く先を変えない)
        sketch.onKey["g"] = { sketch in _ = sketch.get(40, 40) }
        sketch.onKey["r"] = { sketch in sketch.redraw() }
        // 緑の円を置いて描き直す (円は描き直すフレームへ持ち越す)
        sketch.onKey["b"] = { sketch in
            sketch.noStroke()
            sketch.fill(green)
            sketch.circle(30, 30, 20)
            sketch.redraw()
        }
        // 同じコールバックで書いて描き直す
        sketch.onKey["x"] = { sketch in
            sketch.onKey["w"]?(sketch)
            sketch.redraw()
        }
        configure(sketch)

        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: gpu, clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()

        var pressed = 0
        func press(_ key: String) throws {
            try AtomicFile.write(
                Data(
                    #"{"id":"k\#(pressed)","events":[{"type":"keyDown","code":0,"characters":"\#(key)","isRepeat":false},{"type":"keyUp","code":0}]}"#
                        .utf8),
                to: facet.appendingPathComponent("request.json"))
            pressed += 1
            try runtime.advance()
        }
        try body(runtime, gpu, press)
    }

    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private static let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)

    private static func isRed(_ red: Float, _ green: Float, _ blue: Float) -> Bool {
        red > 0.9 && green < 0.1 && blue < 0.1
    }

    /// 窓が読む絵。窓を開かずに、差し出す経路を渡したテクスチャへ描いて読む。
    private static func windowPicture(of runtime: SketchRuntime, gpu: RenderDevice) throws -> PixelBuffer {
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let window = try RenderTarget(gpu: gpu, width: 160, height: 160)
        try presenter.draw(runtime.target, into: window.texture)
        return try window.readPixels()
    }

    // MARK: - 窓・共有の面・CPU

    /// 窓が読む出す先のテクスチャ。窓を開かずに、差し出す経路を渡したテクスチャへ描いて読む。
    @Test(
        "止まっている間に変えたものは、窓が読む出す先に出る",
        arguments: Scenario.all)
    func theWindowShowsIt(scenario: Scenario) throws {
        try Self.withStoppedSketch(density: scenario.density, vignette: scenario.vignette) {
            runtime, gpu, press in
            try press(scenario.change.key)

            let point = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]

            #expect(Self.isRed(point.red, point.green, point.blue), "窓が読む絵に出ていない: \(point)")
        }
    }

    /// 窓に出した後に描き直しても、書いた画素は残り、効果は次のフレームへ焼き込まれない ([#1906]
    /// 完了条件 3)。
    ///
    /// 配った直後の書き戻しは、効果を通す前の絵 (次のフレームの入り) へも同じ画素を写す。写さずに
    /// 書き戻すと、次のフレームの頭が効果を通す前の絵を戻して書いた画素が消える。2 枚目は効果を
    /// 頼まないので、隅 (3, 3) は書かなかったスケッチと同じ下地だけの値に戻るはずである。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    @Test(
        "窓に出した後に描き直しても、書いた画素は残り効果は焼き込まれない",
        arguments: [Float(1), 0.5])
    func writtenPixelsSurviveTheWindow(density: Float) throws {
        var plain: PixelBuffer?
        try Self.withStoppedSketch(density: density, vignette: true) { runtime, gpu, press in
            try press("r")
            plain = try Self.windowPicture(of: runtime, gpu: gpu)
        }
        let untouched = try #require(plain)

        try Self.withStoppedSketch(density: density, vignette: true) { runtime, gpu, press in
            try press("w")
            let shown = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]
            #expect(Self.isRed(shown.red, shown.green, shown.blue), "窓が読む絵に出ていない: \(shown)")

            try press("r")
            let second = try Self.windowPicture(of: runtime, gpu: gpu)
            let point = second[80, 80]
            #expect(Self.isRed(point.red, point.green, point.blue), "描き直したら書いた画素が消えた: \(point)")
            #expect(
                second[3, 3] == untouched[3, 3],
                "隅に効果が焼き込まれた: \(second[3, 3]) (書かなければ \(untouched[3, 3]))")
        }
    }

    /// 共有の面 (別のプロセスが読む面) へ差し出す絵。
    @Test(
        "止まっている間に変えたものは、共有の面へ差し出す絵に出る",
        arguments: Scenario.all)
    func theSharedSurfaceShowsIt(scenario: Scenario) throws {
        try Self.withStoppedSketch(density: scenario.density, vignette: scenario.vignette) {
            runtime, gpu, press in
            try press(scenario.change.key)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-stopped-shared-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
            let shared = try SharedFrameSurface(gpu: gpu, width: 160, height: 160, at: directory)
            try shared.publishManifest()
            try shared.write(
                runtime.target, using: presenter,
                numbers: FrameNumbers(frameCount: 1, time: 0, frameRate: 60, frameTimeMs: 16.7))
            // 公開は 1 枚遅れるので、控えも名乗らせてから読む (#748)
            try shared.publishPending()
            let point = try #require(SharedSurfaceReader.pixel(id: shared.ids[0], x: 80, y: 80))

            #expect(Self.isRed(point.red, point.green, point.blue), "共有の面に出ていない: \(point)")
        }
    }

    // MARK: - 払うのは変えたときだけ

    /// 配った直後の追い付きは、変えたときだけ積む。読むだけ・何も無いリフレッシュは積まない
    /// (ADR-0023 決定 5)。
    ///
    /// 数えるのは書き戻し (描く先の ``RenderTarget/pixelWriteBacksEncoded``) と拡大 (段の数)。細かさ 1
    /// の面は拡大の段を持たないので、段の数は動かない ([#1906])。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    @Test(
        "コールバックが描く先を変えなければ、配った直後に書き戻しも拡大も積まない",
        arguments: [Float(0.5), 1], [false, true])
    func theRuntimePaysOnlyForAChange(density: Float, vignette: Bool) throws {
        try Self.withStoppedSketch(density: density, vignette: vignette) { runtime, gpu, press in
            let canvas = runtime.canvas
            let enlargements = density < 1 ? 1 : 0
            let passesAfterFirstFrame = canvas.effectPassesEncoded
            let writeBacksAfterFirstFrame = canvas.target.pixelWriteBacksEncoded

            try press("g")
            // 読むだけのコールバックの後のリフレッシュは、空のコマンドも投入しない
            let submissionsAfterReading = gpu.submissionCount
            try runtime.advance()
            try runtime.advance()
            #expect(gpu.submissionCount == submissionsAfterReading, "変えていないのにコマンドを投入した")
            #expect(canvas.effectPassesEncoded == passesAfterFirstFrame, "変えていないのに拡大を積んだ")
            #expect(
                canvas.target.pixelWriteBacksEncoded == writeBacksAfterFirstFrame,
                "変えていないのに書き戻しを積んだ")

            try press("w")
            #expect(
                canvas.effectPassesEncoded - passesAfterFirstFrame == enlargements,
                "変えたのに、配った直後に 1 度だけ広げていない")
            #expect(
                canvas.target.pixelWriteBacksEncoded - writeBacksAfterFirstFrame == 1,
                "書いたのに、配った直後に 1 度だけ書き戻していない")
            #expect(!canvas.target.hasPendingPixelWrites, "書き戻したのに、まだ書き込み待ちが残っている")
            #expect(!canvas.needsOutputEnlargement, "追い付いたのに、まだ追い付いていないことになっている")

            // 追い付いた後は、リフレッシュを重ねても出力段を通しても積み足さない
            try runtime.advance()
            _ = try runtime.target.encodeToImage()
            #expect(
                canvas.effectPassesEncoded - passesAfterFirstFrame == enlargements, "追い付いた後に広げ足した")
            #expect(
                canvas.target.pixelWriteBacksEncoded - writeBacksAfterFirstFrame == 1, "追い付いた後に書き戻し足した")
        }
    }

    // MARK: - 置いた側の絵 (#1942)

    /// 配った直後の追い付きは、出す先を書く前に、置いた側へ置いた時点の絵を写させる ([#1942])。
    ///
    /// 描き場所がコールバックをまたいで開いたままで、本体を置いた後に本体の画素を書くと、追い付きは
    /// 描き場所が閉じる前に本体の出す先を書く。写させないと、次のコールバックで閉じた描き場所に、
    /// 置いた時点ではなく書いた後の絵が出る。細かさを下げた面は ``Canvas/catchUpOutput()``、細かさ 1
    /// の面は ``Canvas/writeBackPendingPixels()`` を通る。
    ///
    /// [#1942]: https://github.com/mokume-metal/mokume/issues/1942
    @Test(
        "配った直後の追い付きの後に描き場所を閉じても、置いた側には置いた時点の本体の絵が出る",
        arguments: [Float(0.5), 1])
    func aPlacerKeepsThePictureAcrossTheCatchUp(density: Float) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, layer: box) { runtime, gpu, press in
            try press("a")
            // 追い付いた後の本体の出す先には、書いた画素が出ている
            let body = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]
            #expect(Self.isRed(body.red, body.green, body.blue), "本体の出す先に書いた画素が出ていない: \(body)")

            try press("e")
            let layer = try #require(box.canvas)
            let placed = try layer.output.encodeForDisplay()[80, 80]
            // 置いた時点の本体は下地 (235) だけで、書いた画素は載っていない
            #expect(
                placed.red > 200 && placed.green > 200 && placed.blue > 200,
                "置いた時点の絵が出ていない (書いた後の絵が出た): \(placed)")
        }
    }

    // MARK: - 描き切らせてから置いた本体 (#2042)

    /// 本体を描き場所へ置く口。`rg -n 'note\(placing:' Sources` の口を、利用者が触る 3 つの形で通す。
    ///
    /// どれも本体の全面を、描き場所の (`x`, `y`) から 80×80 へ縮めて置く。本体の中央 (80, 80) は
    /// 描き場所の (`x` + 40, `y` + 40) に出る。
    enum Door: CaseIterable, CustomTestStringConvertible {
        /// `image(canvas, x, y, 80, 80)`。
        case image
        /// `texture(canvas)` を貼った `rect(x, y, 80, 80)`。
        case texture
        /// 断片の面 (`ShaderSurface.graphics(canvas)`) を読む塗りの `rect(x, y, 80, 80)`。
        case shader

        var testDescription: String {
            switch self {
            case .image: "image で置く"
            case .texture: "texture で貼る"
            case .shader: "断片の面で読む"
            }
        }

        func place(_ body: Canvas, into layer: Canvas, at x: Float, _ y: Float) {
            layer.noStroke()
            switch self {
            case .image:
                layer.image(body, x, y, 80, 80)
            case .texture:
                layer.texture(body)
                layer.rect(x, y, 80, 80)
                layer.noTexture()
            case .shader:
                // 4 つの象限のどれに置いても、その象限が本体の全面を読む
                guard
                    let shader = try? layer.makeShader(
                        """
                        float4 paint(Fragment in, Values values, Surfaces surfaces) {
                            return mokume_sample(surfaces.body, fract(in.place * 2.0));
                        }
                        """,
                        surfaces: ["body": .graphics(body)])
                else { return }
                layer.shader(shader)
                layer.rect(x, y, 80, 80)
                layer.resetShader()
            }
        }
    }

    /// 本体を描き切らせる形。どちらも本体の描く先を変え、細かさ 1 では出す先がそのまま変わる。
    enum DrawOut: CaseIterable, CustomTestStringConvertible {
        /// 四角を置いて `get()` で描き切らせる。
        case rectThenGet
        /// 中央に 4×4 を `set` して `loadPixels()` で描き切らせる (書き戻しが描く先に載る)。
        case setThenLoadPixels

        var testDescription: String {
            switch self {
            case .rectThenGet: "四角を置いて get"
            case .setThenLoadPixels: "set して loadPixels"
            }
        }

        func apply(to sketch: StoppedPainter, colour: LinearRGBA? = nil) {
            let colour = colour ?? StoppedUpscaleOutletsTests.red
            switch self {
            case .rectThenGet:
                sketch.noStroke()
                sketch.fill(colour)
                sketch.rect(60, 60, 40, 40)
                _ = sketch.get(0, 0)
            case .setThenLoadPixels:
                let centre = sketch.pixelWidth / 2
                for y in centre - 2..<centre + 2 {
                    for x in centre - 2..<centre + 2 { sketch.set(x, y, colour) }
                }
                sketch.loadPixels()
            }
        }
    }

    /// 細かさ × 置く口 × 描き切らせ方 の 1 通り。
    struct Placing: CustomTestStringConvertible {
        let density: Float
        let door: Door
        let drawOut: DrawOut

        var testDescription: String {
            "細かさ \(density)・\(door.testDescription)・\(drawOut.testDescription)"
        }

        nonisolated static var all: [Placing] {
            [Float(0.5), 1].flatMap { density in
                Door.allCases.flatMap { door in
                    DrawOut.allCases.map { Placing(density: density, door: door, drawOut: $0) }
                }
            }
        }
    }

    private static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private static func isBlue(_ red: Float, _ green: Float, _ blue: Float) -> Bool {
        red < 0.1 && green < 0.1 && blue > 0.9
    }

    private static func isBackdrop(_ point: LinearRGBA) -> Bool {
        point.red > 0.7 && point.green > 0.7 && point.blue > 0.7
    }

    /// 本体を描き切らせてから、新しい描き場所へ置いて閉じる。描き場所は `box` へ渡す。
    private static func placeIntoNewLayer(
        _ sketch: StoppedPainter, by door: Door, box: LayerBox,
        between: (Canvas) -> Void = { _ in }
    ) {
        guard let layer = try? sketch.createGraphics(160, 160) else { return }
        box.canvas = layer
        layer.beginDraw()
        door.place(sketch.canvas, into: layer, at: 0, 0)
        between(layer)
        layer.endDraw()
    }

    /// 止まっている間に本体を描き切らせてから置くと、描き場所には描き切った絵が出る ([#2042])。
    ///
    /// 細かさを下げた本体は、途中の描き切りで描く先だけが変わり、出す先は追い付くまで最後のフレームの
    /// 絵のままである。ランタイムの追い付きはコールバックを返した後なので、同じコールバックの中で置いて
    /// 閉じた描き場所は、置く口が自分で追い付かせないと古い出す先を読む。細かさ 1 の本体は描く先が
    /// 出す先そのものなので、もとから描き切った絵が出る。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "止まっている間に描き切らせた本体を置くと、どの口・どの細かさでも描き切った絵が出る",
        arguments: Placing.all)
    func aDrawnOutBodyIsPlacedAsDrawn(placing: Placing) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: placing.density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                placing.drawOut.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: placing.door, box: box)
            }
        }) { _, _, press in
            try press("k")
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.isRed(point.red, point.green, point.blue), "置いた先に描き切った絵が出ていない: \(point)")
        }
    }

    /// `setup()` の中で描き切らせて置いても同じ ([#2042] 完了条件 2)。`setup()` も本体の持ち越しの区間で、
    /// 出す先は最初のフレームまで追い付かない。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "setup() で描き切らせた本体を置いても、描き切った絵が出る",
        arguments: [Float(0.5), 1], Door.allCases)
    func aBodyDrawnOutInSetupIsPlacedAsDrawn(density: Float, door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onSetup = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: door, box: box)
            }
        }) { _, _, _ in
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.isRed(point.red, point.green, point.blue), "置いた先に描き切った絵が出ていない: \(point)")
        }
    }

    /// 時間方向の拡大でも、描き切らせた本体を置けば描き切った絵が出る ([#2042] 完了条件 6)。見るのは
    /// 中央の色だけで、縁の位置 (揺らしの戻し) は #1913 の範囲である。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test("時間方向の拡大でも、止まっている間に描き切らせた本体を置くと描き切った絵が出る", arguments: Door.allCases)
    func aTemporalBodyIsPlacedAsDrawn(door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: 0.5, upscale: .temporal, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: door, box: box)
            }
        }) { _, _, press in
            try press("k")
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.isRed(point.red, point.green, point.blue), "置いた先に描き切った絵が出ていない: \(point)")
        }
    }

    /// 追い付くのは置いた時点で、描き場所の描き切りの時点ではない ([#2042] 完了条件 3・[#1656])。
    ///
    /// 置いた後に本体を描き換えて描き切らせても、先に置いた分は置いた時点の赤のまま、後に置いた分は
    /// 描き換えた青になる。描き場所の描き切りで追い付くと、先に置いた分まで青になる。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "置いた後に本体を描き換えても、先に置いた分は置いた時点の絵、後に置いた分は描き換えた絵が出る",
        arguments: [Float(0.5), 1], Door.allCases)
    func eachPlacementKeepsItsOwnPicture(density: Float, door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: door, box: box) { layer in
                    DrawOut.rectThenGet.apply(to: sketch, colour: StoppedUpscaleOutletsTests.blue)
                    door.place(sketch.canvas, into: layer, at: 80, 80)
                }
            }
        }) { _, _, press in
            try press("k")
            let picture = try #require(box.canvas).output.readPixels()
            let first = picture[40, 40]
            #expect(Self.isRed(first.red, first.green, first.blue), "先に置いた分が置いた時点の赤でない: \(first)")
            let second = picture[120, 120]
            #expect(Self.isBlue(second.red, second.green, second.blue), "後に置いた分が描き換えた青でない: \(second)")
        }
    }

    /// 同じ断片を当てたまま、本体を描き換えてもう一度塗っても、後に塗った分は描き換えた絵を読む
    /// ([#2042] 完了条件 3)。
    ///
    /// 断片の面は、記録済みなら図形を積むたびの記録を飛ばす。細かさを下げた本体の途中の描き切りは
    /// 出す先を変えないので、そこで置いた側へ写させて記録を落とさないと、後に塗った分が追い付きを
    /// 通らず追い付く前の出す先を読む。断片を作り直すと記録も取り直すので、ここでは 1 つの断片を
    /// 当て続ける。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "同じ断片のまま本体を描き換えて塗り直しても、先に塗った分は赤、後に塗った分は青が出る",
        arguments: [Float(0.5), 1])
    func aKeptShaderReadsTheRedrawnBody(density: Float) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                guard let layer = try? sketch.createGraphics(160, 160),
                    let shader = try? layer.makeShader(
                        """
                        float4 paint(Fragment in, Values values, Surfaces surfaces) {
                            return mokume_sample(surfaces.body, fract(in.place * 2.0));
                        }
                        """,
                        surfaces: ["body": .graphics(sketch.canvas)])
                else { return }
                box.canvas = layer
                layer.beginDraw()
                layer.noStroke()
                layer.shader(shader)
                layer.rect(0, 0, 80, 80)
                DrawOut.rectThenGet.apply(to: sketch, colour: StoppedUpscaleOutletsTests.blue)
                layer.rect(80, 80, 80, 80)
                layer.endDraw()
            }
        }) { _, _, press in
            try press("k")
            let picture = try #require(box.canvas).output.readPixels()
            let first = picture[40, 40]
            #expect(Self.isRed(first.red, first.green, first.blue), "先に塗った分が置いた時点の赤でない: \(first)")
            let second = picture[120, 120]
            #expect(Self.isBlue(second.red, second.green, second.blue), "後に塗った分が描き換えた青でない: \(second)")
        }
    }

    /// 置いた後に本体を描き換えて描き切らせ、それから描き場所を閉じても、置いた時点の絵が出る
    /// ([#2042] 完了条件 3)。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "置いた後に本体を描き換えてから描き場所を閉じても、置いた時点の絵が出る",
        arguments: [Float(0.5), 1], Door.allCases)
    func aPlacementOutlivesALaterDrawOut(density: Float, door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: door, box: box) { _ in
                    DrawOut.rectThenGet.apply(to: sketch, colour: StoppedUpscaleOutletsTests.blue)
                }
            }
        }) { _, _, press in
            try press("k")
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.isRed(point.red, point.green, point.blue), "置いた時点の赤でない: \(point)")
        }
    }

    /// 書いただけ (描き切らせていない) の画素は、どちらの細かさでも置いた先に出ない ([#2042] 完了条件 4)。
    ///
    /// 置くのは「そのとき描き切れている絵」で、書いた画素は CPU の写しに載ったままである。置く口が
    /// 追い付くときに書き込み待ちまで書き戻すと、細かさを下げた本体だけ書いた画素が出てしまう。先に
    /// 隅の四角を描き切らせて出す先を遅らせておき、置く口が追い付く形で見る。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "書いただけの画素は、どの口・どの細かさでも置いた先に出ない",
        arguments: [Float(0.5), 1], Door.allCases)
    func writtenOnlyPixelsAreNotPlaced(density: Float, door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                sketch.noStroke()
                sketch.fill(StoppedUpscaleOutletsTests.green)
                sketch.rect(0, 0, 20, 20)
                _ = sketch.get(0, 0)
                let centre = sketch.pixelWidth / 2
                for y in centre - 2..<centre + 2 {
                    for x in centre - 2..<centre + 2 { sketch.set(x, y, StoppedUpscaleOutletsTests.red) }
                }
                Self.placeIntoNewLayer(sketch, by: door, box: box)
            }
        }) { _, _, press in
            try press("k")
            let picture = try #require(box.canvas).output.readPixels()
            // 書く前の本体の中央は下地 (235) だけ
            #expect(Self.isBackdrop(picture[40, 40]), "書いただけの画素が置いた先に出た: \(picture[40, 40])")
            // 描き切らせた隅の四角は出る (置く口が追い付いた)
            let corner = picture[3, 3]
            #expect(corner.green > 0.9 && corner.red < 0.1, "描き切らせた隅の四角が出ていない: \(corner)")
        }
    }

    /// 置く口の追い付きは、本体を描き切らせたときだけ積む ([#2042] 完了条件 5・ADR-0023 決定 5)。
    ///
    /// 変えていない本体を置いても、拡大も書き戻しも積まない。描き切らせてから何度置いても、広げるのは
    /// 最初に置いた 1 度だけで、配った直後のランタイムも積み足さない。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "置く口は、本体を描き切らせたときだけ 1 度広げ、変えていなければ何も積まない",
        arguments: [Float(0.5), 1])
    func placingPaysOnlyForADrawnOutBody(density: Float) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            let placeTwice: (StoppedPainter) -> Void = { sketch in
                Self.placeIntoNewLayer(sketch, by: .image, box: box) { layer in
                    Door.texture.place(sketch.canvas, into: layer, at: 80, 80)
                }
                Self.placeIntoNewLayer(sketch, by: .shader, box: box)
            }
            sketch.onKey["u"] = placeTwice
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                placeTwice(sketch)
            }
        }) { runtime, _, press in
            let canvas = runtime.canvas
            let passes = canvas.effectPassesEncoded
            let writeBacks = canvas.target.pixelWriteBacksEncoded

            try press("u")
            #expect(canvas.effectPassesEncoded == passes, "変えていない本体を置いて拡大を積んだ")
            #expect(canvas.target.pixelWriteBacksEncoded == writeBacks, "変えていない本体を置いて書き戻しを積んだ")

            try press("k")
            #expect(
                canvas.effectPassesEncoded - passes == (density < 1 ? 1 : 0),
                "描き切らせた本体を何度も置いて、広げたのが 1 度でない")
            #expect(canvas.target.pixelWriteBacksEncoded == writeBacks, "描き切らせただけで書き戻しを積んだ")
        }
    }

    /// 畳む口の外で本体を置く経路。`Door` の 3 口は `rect` がどれも畳む口に入るので、ここで残りを通す
    /// ([#2042] の反証 8)。どれも本体の全面を、描き場所の (0, 0) から 80×80 へ置く。
    enum Route: CaseIterable, CustomTestStringConvertible {
        /// `createShape` で `texture(canvas)` を貼った `rect` を記録し、`shape()` で置き直す
        /// (`replaying` → `useTexture`)。
        case heldFlat
        /// `createShape` で `texture(canvas)` を貼った `box` を記録し、`shape()` で置き直す
        /// (`replaying` の立体の区間 → `beginSolids` → `useTexture`。粒の板も同じ口を通る)。
        case heldSolid
        /// 断片の面を読む塗りの `rect` を記録し、`shape()` で置き直す (記録した塗りの面)。
        case heldPaint
        /// `texture(canvas)` を貼った `box` (その場の立体)。
        case box
        /// `texture(canvas)` を貼った `beginShape` / `vertex(x, y, u, v)` (畳まない平面)。
        case vertices

        var testDescription: String {
            switch self {
            case .heldFlat: "保持した平面を置き直す"
            case .heldSolid: "保持した立体を置き直す"
            case .heldPaint: "断片の面で塗った保持した形を置き直す"
            case .box: "その場の立体"
            case .vertices: "beginShape と vertex"
            }
        }

        func place(_ body: Canvas, into layer: Canvas) {
            layer.noStroke()
            layer.fill(.linear(red: 1, green: 1, blue: 1))
            switch self {
            case .heldFlat:
                let shape = layer.createShape {
                    layer.texture(body)
                    layer.rect(0, 0, 80, 80)
                }
                layer.noTexture()
                layer.shape(shape)
            case .heldSolid:
                let shape = layer.createShape {
                    layer.texture(body)
                    layer.box(80, 80, 2)
                }
                layer.noTexture()
                layer.push()
                layer.translate(40, 40)
                layer.shape(shape)
                layer.pop()
            case .heldPaint:
                guard
                    let shader = try? layer.makeShader(
                        """
                        float4 paint(Fragment in, Values values, Surfaces surfaces) {
                            return mokume_sample(surfaces.body, fract(in.place * 2.0));
                        }
                        """,
                        surfaces: ["body": .graphics(body)])
                else { return }
                let shape = layer.createShape {
                    layer.shader(shader)
                    layer.rect(0, 0, 80, 80)
                    layer.resetShader()
                }
                layer.shape(shape)
            case .box:
                layer.texture(body)
                layer.push()
                layer.translate(40, 40)
                layer.box(80, 80, 2)
                layer.pop()
                layer.noTexture()
            case .vertices:
                layer.texture(body)
                layer.beginShape()
                layer.vertex(0, 0, 0, 0)
                layer.vertex(80, 0, 160, 0)
                layer.vertex(80, 80, 160, 160)
                layer.vertex(0, 80, 0, 160)
                layer.endShape(.close)
                layer.noTexture()
            }
        }
    }

    /// 赤が勝っているか。立体は陰りを受けうるので、色の向きだけを見る (下地は 235 の灰)。
    private static func leansRed(_ point: LinearRGBA) -> Bool {
        point.red > 0.5 && point.green < 0.2 && point.blue < 0.2
    }

    /// 畳む口の外の経路でも、止まっている間に描き切らせた本体を置くと、どの細かさでも描き切った絵が
    /// 出る ([#2042] の反証 8)。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "保持した形・立体・畳まない平面で置いても、止まっている間に描き切らせた本体の絵が出る",
        arguments: [Float(0.5), 1], Route.allCases)
    func everyRoutePlacesTheDrawnOutBody(density: Float, route: Route) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                guard let layer = try? sketch.createGraphics(160, 160) else { return }
                box.canvas = layer
                layer.beginDraw()
                route.place(sketch.canvas, into: layer)
                layer.endDraw()
            }
        }) { _, _, press in
            try press("k")
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.leansRed(point), "置いた先に描き切った絵が出ていない: \(point)")
        }
    }

    /// 置く口の追い付きに失敗したら、本体が次に描き切るまで見送り、描き切らせてから置けばやり直す
    /// ([#2042] の反証 2・2 回目の反証 3)。
    ///
    /// 失敗した回と、見送っている間に置いた分は古い絵 (下地) のまま、本体を描き切らせた後に置いた分は
    /// 描き切った赤になる。断片の面は記録済みなら記録を飛ばすので、控えが外れないと描き切らせた後も
    /// 追い付かない。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "置く口の追い付きに失敗したら本体が次に描き切るまで見送り、描き切らせてから置けばやり直す",
        arguments: [Door.image, Door.shader])
    func aFailedPlacingCatchUpIsRetried(door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: 0.5, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                guard let layer = try? sketch.createGraphics(160, 160),
                    let shader = try? layer.makeShader(
                        """
                        float4 paint(Fragment in, Values values, Surfaces surfaces) {
                            return mokume_sample(surfaces.body, fract(in.place * 2.0));
                        }
                        """,
                        surfaces: ["body": .graphics(sketch.canvas)])
                else { return }
                box.canvas = layer
                let place: (Float, Float) -> Void = { x, y in
                    switch door {
                    case .shader: layer.rect(x, y, 80, 80)
                    default: layer.image(sketch.canvas, x, y, 80, 80)
                    }
                }
                layer.beginDraw()
                layer.noStroke()
                if door == .shader { layer.shader(shader) }
                sketch.canvas.failEffectPassForTesting = 0
                place(0, 0)
                sketch.canvas.failEffectPassForTesting = nil
                // 本体がまだ描き切っていないので見送る
                place(80, 0)
                DrawOut.rectThenGet.apply(to: sketch)
                place(80, 80)
                layer.endDraw()
            }
        }) { runtime, _, press in
            try press("k")
            #expect(runtime.canvas.warnings.hasWarned(.upscaleFailed), "検査の前提: 追い付きが失敗していない")
            let picture = try #require(box.canvas).output.readPixels()
            #expect(Self.isBackdrop(picture[40, 40]), "失敗した回に置いた分が古い絵でない: \(picture[40, 40])")
            #expect(Self.isBackdrop(picture[120, 40]), "見送っている間に置いた分が古い絵でない: \(picture[120, 40])")
            let retried = picture[120, 120]
            #expect(
                Self.isRed(retried.red, retried.green, retried.blue),
                "描き切らせた後に置いた分が追い付いていない: \(retried)")
        }
    }

    /// 追い付きが失敗し続けても、断片の面を読む線をいくら引いても、やり直すのは本体が次に描き切るまでに
    /// 1 度だけ ([#2042] の 2 回目の反証 3)。線は三角形ごとに記録の口を通るので、見送らないと三角形ごとに
    /// 環を進めてコマンドを組み直す (組みかけて捨てたコマンドの数で見る)。置く側の写しの上限の数も
    /// 三角形ごとには増えない (2 回目の反証 2)。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test("追い付きが失敗し続けても、断片の面を読む線ごとにはやり直さない")
    func aFailingPlacingCatchUpIsNotRetriedPerTriangle() throws {
        final class Counts { var abandoned = -1; var limitReached = -1 }
        let counts = Counts()
        try Self.withStoppedSketch(density: 0.5, configure: { sketch in
            sketch.onKey["k"] = { sketch in
                DrawOut.rectThenGet.apply(to: sketch)
                guard let layer = try? sketch.createGraphics(160, 160),
                    let shader = try? layer.makeShader(
                        """
                        float4 paint(Fragment in, Values values, Surfaces surfaces) {
                            return mokume_sample(surfaces.body, in.place);
                        }
                        """,
                        surfaces: ["body": .graphics(sketch.canvas)])
                else { return }
                let gpu = sketch.canvas.gpu
                layer.beginDraw()
                layer.shader(shader)
                layer.stroke(.linear(red: 1, green: 1, blue: 1))
                layer.strokeWeight(3)
                sketch.canvas.failEffectPassForTesting = 0
                let abandoned = gpu.abandonedCommands
                let limitReached = layer.placedPictureCopyLimitReached
                for index in 0..<40 {
                    let y = Float(index * 4)
                    layer.line(0, y, 160, y + 2)
                }
                counts.abandoned = gpu.abandonedCommands - abandoned
                counts.limitReached = layer.placedPictureCopyLimitReached - limitReached
                sketch.canvas.failEffectPassForTesting = nil
                layer.endDraw()
            }
        }) { _, _, press in
            try press("k")
            #expect(counts.abandoned == 1, "失敗した追い付きを線ごとにやり直した: \(counts.abandoned) 回")
            #expect(counts.limitReached == 0, "写しの上限の数が線ごとに増えた: \(counts.limitReached)")
        }
    }


    /// 写しの上限を越えてくり返し置く形の、置き方 ([#2042] の反証 3)。保持した形は前置き (記録した面・
    /// 塗り・立体の区間) を済ませてから記録の口へ来るので、置く口の内側で置いた側が描き切られると壊れる。
    enum Repeated: CaseIterable, CustomTestStringConvertible {
        /// `image(canvas, x, y, 40, 40)`。
        case image
        /// 当て続けた 1 つの断片で `rect(x, y, 40, 40)`。
        case keptShader
        /// `texture(canvas)` を貼った `rect` を記録した形を、`shape()` で置き直す。
        case heldFlat
        /// 断片の面で塗った `rect` を記録した形を、`shape()` で置き直す (記録した塗りの面)。
        case heldPaint
        /// `texture(canvas)` を貼った `box` を記録した形を、`shape()` で置き直す (立体の区間)。
        case heldSolid

        var testDescription: String {
            switch self {
            case .image: "image で置く"
            case .keptShader: "当て続けた断片で塗る"
            case .heldFlat: "保持した平面を置き直す"
            case .heldPaint: "断片の面で塗った保持した形を置き直す"
            case .heldSolid: "保持した立体を置き直す"
            }
        }
    }

    /// 本体を描き換えて描き切らせては置く、を写しの上限 (``Canvas/placedPictureCopyLimit``) を越えて
    /// くり返しても、どの細かさでも置いた分ごとに置いた時点の絵が出る ([#2042] の反証 3)。
    ///
    /// 上限を越えると、置いた側は写しの代わりに描き切られる (フレームの途中で区切られる)。細かさ 1 では
    /// 本体の描き切りがそれを起こし、細かさを下げた本体も同じ時点 (本体の描き切り) で起こす — 置く口の
    /// 内側では起こさない。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    @Test(
        "描き切らせては置くを写しの上限を越えてくり返しても、置いた分ごとに置いた時点の絵が出る",
        arguments: [Float(0.5), 1], Repeated.allCases)
    func placingPastTheCopyLimitKeepsEachPicture(density: Float, kind: Repeated) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: density, configure: { sketch in
            sketch.onKey["k"] = { sketch in Self.placeRepeatedly(sketch, kind: kind, box: box) }
        }) { _, _, press in
            try press("k")
            try Self.expectEachPlacedPicture(in: try #require(box.canvas))
        }
    }

    /// 写しの上限を越えて描き切らせては置く回数。
    private static var repeatedRounds: Int { Canvas.placedPictureCopyLimit + 2 }

    /// 本体を赤と青へ交互に描き換えて描き切らせては、新しい描き場所の 40×40 の升へ順に置いて閉じる。
    private static func placeRepeatedly(_ sketch: StoppedPainter, kind: Repeated, box: LayerBox) {
        let body = sketch.canvas
        guard let layer = try? sketch.createGraphics(160, 160),
            let shader = try? layer.makeShader(
                """
                float4 paint(Fragment in, Values values, Surfaces surfaces) {
                    return mokume_sample(surfaces.body, fract(in.place * 4.0));
                }
                """,
                surfaces: ["body": .graphics(body)])
        else { return }
        box.canvas = layer
        layer.beginDraw()
        layer.noStroke()
        layer.fill(.linear(red: 1, green: 1, blue: 1))
        // 形は 1 度だけ記録する (記録の中では置いた記録を取らない)
        let held: Shape? =
            switch kind {
            case .heldFlat:
                layer.createShape {
                    layer.texture(body)
                    layer.rect(0, 0, 40, 40)
                    layer.noTexture()
                }
            case .heldPaint:
                layer.createShape {
                    layer.shader(shader)
                    layer.rect(0, 0, 40, 40)
                    layer.resetShader()
                }
            case .heldSolid:
                layer.createShape {
                    layer.texture(body)
                    layer.box(40, 40, 2)
                    layer.noTexture()
                }
            case .image, .keptShader: nil
            }
        // 断片は 1 つを当て続ける (記録の控えが効く形)
        if kind == .keptShader { layer.shader(shader) }
        for round in 0..<repeatedRounds {
            DrawOut.rectThenGet.apply(
                to: sketch,
                colour: round.isMultiple(of: 2)
                    ? StoppedUpscaleOutletsTests.red : StoppedUpscaleOutletsTests.blue)
            let x = Float(round % 4) * 40
            let y = Float(round / 4) * 40
            switch kind {
            case .image: layer.image(body, x, y, 40, 40)
            case .keptShader: layer.rect(x, y, 40, 40)
            case .heldFlat, .heldPaint: layer.shape(held!, x, y)
            case .heldSolid: layer.shape(held!, x + 20, y + 20)
            }
        }
        layer.endDraw()
    }

    /// ``placeRepeatedly(_:kind:box:)`` が置いた升ごとに、置いた時点の色 (赤と青の交互) が出ているか。
    private static func expectEachPlacedPicture(in layer: Canvas) throws {
        #expect(layer.placedPictureCopyLimitReached > 0, "検査の前提: 写しの上限に達していない")
        let picture = try layer.output.readPixels()
        for round in 0..<repeatedRounds {
            let point = picture[(round % 4) * 40 + 20, (round / 4) * 40 + 20]
            if round.isMultiple(of: 2) {
                #expect(Self.leansRed(point), "\(round) 回目に置いた分が赤でない: \(point)")
            } else {
                #expect(
                    point.blue > 0.5 && point.red < 0.2 && point.green < 0.2,
                    "\(round) 回目に置いた分が青でない: \(point)")
            }
        }
    }

    // MARK: - フレームの中で置く本体 (#2103)

    /// フレームの中で本体を描き切らせる口。
    enum InFrameDrawOut: CaseIterable, CustomTestStringConvertible {
        /// 四角を置いて `get()` で描き切らせる。
        case get
        /// 四角を置いて `loadPixels()` で描き切らせる。
        case loadPixels

        var testDescription: String {
            switch self {
            case .get: "四角を置いて get"
            case .loadPixels: "四角を置いて loadPixels"
            }
        }

        func apply(to sketch: StoppedPainter, colour: LinearRGBA = StoppedUpscaleOutletsTests.red) {
            sketch.noStroke()
            sketch.fill(colour)
            sketch.rect(60, 60, 40, 40)
            switch self {
            case .get: _ = sketch.get(0, 0)
            case .loadPixels: sketch.loadPixels()
            }
        }
    }

    /// 本体の細かさ × 拡大の 1 通り。細かさ 1 には拡大の段が無いので、拡大を分けるのは 0.5 だけ。
    struct Body: CustomTestStringConvertible {
        let density: Float
        let upscale: Upscale

        var testDescription: String {
            "細かさ \(density)" + (density < 1 ? (upscale == .temporal ? "・時間方向" : "・空間方向") : "")
        }

        nonisolated static var all: [Body] {
            [
                Body(density: 1, upscale: .spatial), Body(density: 0.5, upscale: .spatial),
                Body(density: 0.5, upscale: .temporal),
            ]
        }

        nonisolated static var reduced: [Body] { all.filter { $0.density < 1 } }
    }

    /// 自分の `draw()` の中で途中まで描き切らせた本体を描き場所へ置くと、どの細かさ・拡大でも途中まで
    /// 描いた絵が出る ([#2103] 完了条件 1)。
    ///
    /// 置くのは「そのとき描き切れている絵」で、フレームの中でも外でも同じである。細かさを下げた本体は
    /// 途中の描き切りで描く先だけが変わるので、置く口がフレームの中でも出す先を追い付かせる。追い付かせ
    /// ないと、細かさ 1 は途中の絵・0.5 は前のフレームの絵に分かれる (#2042 の時点の形)。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test(
        "フレームの中で描き切らせた本体を置くと、どの細かさ・拡大でも途中まで描いた絵が出る",
        arguments: Body.all, InFrameDrawOut.allCases)
    func placingInsideTheBodysFrameShowsTheDrawnOutPicture(body: Body, drawOut: InFrameDrawOut) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                drawOut.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: .image, box: box)
            }
        }) { _, _, press in
            try press("r")
            let point = try #require(box.canvas).output.readPixels()[40, 40]
            #expect(Self.isRed(point.red, point.green, point.blue), "置いた先に途中まで描いた絵が出ていない: \(point)")
        }
    }

    /// 区切り (途中の描き切り) なしで描いている最中の本体を置くと、どの細かさでも前のフレームの絵が出て、
    /// 描き切る前に置いたと警告する ([#2103] 完了条件 2)。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test(
        "区切りなしで描いている最中の本体を置くと、どの細かさでも前のフレームの絵が出て警告が出る",
        arguments: Body.all)
    func placingTheBodyWithoutABreakShowsThePreviousFrame(body: Body) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                sketch.noStroke()
                sketch.fill(StoppedUpscaleOutletsTests.red)
                sketch.rect(60, 60, 40, 40)
                Self.placeIntoNewLayer(sketch, by: .image, box: box)
            }
        }) { _, _, press in
            try press("r")
            let layer = try #require(box.canvas)
            let point = try layer.output.readPixels()[40, 40]
            #expect(Self.isBackdrop(point), "区切りなしで置いた先に前のフレームの絵が出ていない: \(point)")
            // 警告は置いた側 (描き場所) が出す
            #expect(layer.warnings.hasWarned(.placingWhileDrawing), "描き切る前に置いたと警告していない")
        }
    }

    /// 置いた後に本体を描き換えて描き切らせ、同じ描き場所へもう一度置くと、先に置いた分は置いた時点の
    /// 絵、後に置いた分は描き換えた絵が出る ([#2103]・[#1656])。フレームの中で追い付くときも、出す先を
    /// 書く前に先に置いた分を写しへ差し替える。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test(
        "フレームの中で置いた後に本体を描き換えて置き直しても、置いた分ごとに置いた時点の絵が出る",
        arguments: Body.all, Door.allCases)
    func eachPlacementInsideTheBodysFrameKeepsItsOwnPicture(body: Body, door: Door) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                InFrameDrawOut.get.apply(to: sketch)
                Self.placeIntoNewLayer(sketch, by: door, box: box) { layer in
                    InFrameDrawOut.get.apply(to: sketch, colour: StoppedUpscaleOutletsTests.blue)
                    door.place(sketch.canvas, into: layer, at: 80, 80)
                }
            }
        }) { _, _, press in
            try press("r")
            let picture = try #require(box.canvas).output.readPixels()
            let first = picture[40, 40]
            #expect(Self.isRed(first.red, first.green, first.blue), "先に置いた分が置いた時点の赤でない: \(first)")
            let second = picture[120, 120]
            #expect(Self.isBlue(second.red, second.green, second.blue), "後に置いた分が描き換えた青でない: \(second)")
        }
    }

    /// フレームの中で写しの上限を越えて描き切らせては置いても、置いた分ごとに置いた時点の絵が出る
    /// ([#2103]・[#2042] の反証 3)。
    ///
    /// 置いた側の写しの代わりの描き切りは、置く口の内側では起こさない
    /// (``Canvas/keepPictureWithoutFlushing(placedFrom:)``)。だから細かさを下げた本体のフレームの中の
    /// 途中の描き切りも、細かさ 1 と同じくその時点で置いた側へ写させる。写させないと、上限に達した後は
    /// 置く口が追い付きを見送り、前に追い付いた絵が出る。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test(
        "フレームの中で描き切らせては置くを写しの上限を越えてくり返しても、置いた分ごとに置いた時点の絵が出る",
        arguments: Body.all, Repeated.allCases)
    func placingInsideTheBodysFramePastTheCopyLimitKeepsEachPicture(body: Body, kind: Repeated) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in Self.placeRepeatedly(sketch, kind: kind, box: box) }
        }) { _, _, press in
            try press("r")
            try Self.expectEachPlacedPicture(in: try #require(box.canvas))
        }
    }

    /// 細かさを下げた本体で、フレームの中で出す先を読む (`canvas.output.readPixels()`) のを挟んでも
    /// 挟まなくても、続けて置いた絵は同じになる ([#2103] 完了条件 3)。読む口と置く口は、同じ時点で
    /// 同じ揺らしの追い付きを通る。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test(
        "フレームの中で出す先を読むのを挟んでも挟まなくても、続けて置いた絵は同じになる",
        arguments: Body.reduced)
    func readingTheOutputInsideTheFrameDoesNotChangeThePlacement(body: Body) throws {
        func placedPicture(readingFirst: Bool) throws -> PixelBuffer {
            let box = LayerBox()
            try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
                sketch.onLaterFrame = { sketch in
                    InFrameDrawOut.get.apply(to: sketch)
                    if readingFirst { _ = try? sketch.canvas.output.readPixels() }
                    Self.placeIntoNewLayer(sketch, by: .image, box: box)
                }
            }) { _, _, press in try press("r") }
            return try #require(box.canvas).output.readPixels()
        }
        let placed = try placedPicture(readingFirst: false)
        let placedAfterReading = try placedPicture(readingFirst: true)
        #expect(
            placed == placedAfterReading,
            "出す先を読むのを挟むと、置いた絵が変わった: 中央 \(placed[40, 40]) / \(placedAfterReading[40, 40])")
        let centre = placed[40, 40]
        #expect(Self.isRed(centre.red, centre.green, centre.blue), "置いた先に途中まで描いた絵が出ていない: \(centre)")
    }

    /// 時間方向・細かさ 0.5 で、フレームの中で追い付いた出す先の図形は、そのフレームの終わりの拡大と同じ
    /// 位置に出る ([#2103] 完了条件 4)。
    ///
    /// フレームの中の描く先は、このフレームの揺らし (``UpscaleStage/jitter``) で描いてあり、フレームの
    /// 終わりの拡大はそれを戻す。フレームの中の追い付きが最後のフレームの揺らし
    /// (``UpscaleStage/lastJitterInSource``) を戻すと、2 つの揺らしの差だけずれる。比べるのは下地からの
    /// 変わり方の重心で、フレームの終わりの絵は前の結果と混ぜてある (重み 0.2) が、前の結果は一様な
    /// 下地なので重心は変わらない。揺らしの差が描く画素 0.5 個を越える 3 枚目で見る。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test("時間方向で、フレームの中で追い付いた出す先の図形は、フレームの終わりの拡大と同じ位置に出る")
    func aTemporalCatchUpInsideTheFrameMatchesTheFramesEnd() throws {
        var caughtUp: PixelBuffer?
        var jitters: (now: SIMD2<Float>, last: SIMD2<Float>)?
        try Self.withStoppedSketch(density: 0.5, upscale: .temporal, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                guard sketch.frameCount == 3 else { return }
                if let stage = sketch.canvas.upscaleStage { jitters = (stage.jitter, stage.lastJitter) }
                InFrameDrawOut.get.apply(to: sketch)
                caughtUp = try? sketch.canvas.output.readPixels()
            }
        }) { runtime, _, press in
            try press("r")
            try press("r")
            let (now, last) = try #require(jitters)
            #expect(simd_length(now - last) > 0.5, "検査の前提: 2 つの揺らしの差が描く画素 0.5 個を越えていない")
            let inFrame = Self.centroidOfChange(in: try #require(caughtUp))
            let framesEnd = Self.centroidOfChange(in: try runtime.canvas.output.readPixels())
            // 出す画素 2 個が描く画素 1 個 (細かさ 0.5)
            let gap = simd_length(inFrame - framesEnd) / 2
            #expect(gap < 0.5, "フレームの中の追い付きが、フレームの終わりと描く画素 \(gap) 個ずれた")
        }
    }

    /// 下地 (左上の隅の画素) からの緑の減り方で重みを付けた重心 (出す画素)。赤い図形の位置を、補間の
    /// ぼけによらず画素より細かく読む。
    private static func centroidOfChange(in picture: PixelBuffer) -> SIMD2<Double> {
        let backdrop = picture[0, 0].green
        var sum = SIMD2<Double>.zero
        var total = 0.0
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                let weight = Double(backdrop - picture[x, y].green)
                sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5) * weight
                total += weight
            }
        }
        return sum / total
    }

    /// 置く口のフレームの中の追い付きも書き戻さない ([#2103] 完了条件 5)。書いただけの画素は置いた先に
    /// 出ず、先に描き切らせた隅の四角は出る。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test("フレームの中で置いても、書いただけの画素は置いた先に出ない", arguments: Body.all)
    func writtenOnlyPixelsAreNotPlacedInsideTheFrame(body: Body) throws {
        let box = LayerBox()
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                sketch.noStroke()
                sketch.fill(StoppedUpscaleOutletsTests.green)
                sketch.rect(0, 0, 20, 20)
                _ = sketch.get(0, 0)
                let centre = sketch.pixelWidth / 2
                for y in centre - 2..<centre + 2 {
                    for x in centre - 2..<centre + 2 { sketch.set(x, y, StoppedUpscaleOutletsTests.red) }
                }
                Self.placeIntoNewLayer(sketch, by: .image, box: box)
            }
        }) { _, _, press in
            try press("r")
            let picture = try #require(box.canvas).output.readPixels()
            #expect(Self.isBackdrop(picture[40, 40]), "書いただけの画素が置いた先に出た: \(picture[40, 40])")
            let corner = picture[3, 3]
            #expect(corner.green > 0.9 && corner.red < 0.1, "描き切らせた隅の四角が出ていない: \(corner)")
        }
    }

    /// 出す先を読む口はフレームの中でも書き戻す ([#2103] 完了条件 5)。書いただけの画素も、読んだ絵には
    /// 出る。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    @Test("フレームの中で出す先を読むと、書いただけの画素も出る", arguments: Body.all)
    func readingTheOutputInsideTheFrameWritesBack(body: Body) throws {
        var read: PixelBuffer?
        try Self.withStoppedSketch(density: body.density, upscale: body.upscale, configure: { sketch in
            sketch.onLaterFrame = { sketch in
                let centre = sketch.pixelWidth / 2
                for y in centre - 2..<centre + 2 {
                    for x in centre - 2..<centre + 2 { sketch.set(x, y, StoppedUpscaleOutletsTests.red) }
                }
                read = try? sketch.canvas.output.readPixels()
            }
        }) { _, _, press in
            try press("r")
            let point = try #require(read)[80, 80]
            #expect(Self.isRed(point.red, point.green, point.blue), "読んだ絵に書いた画素が出ていない: \(point)")
        }
    }

    // MARK: - 失敗

    /// 配った直後の追い付きが失敗しても `advance()` は投げない (観測に応える前に投げると、失敗した
    /// 瞬間から観測が黙る)。書き込み待ちと印は残り、次に出力段が読むときにやり直す。
    @Test("配った直後の追い付きが失敗しても、advance() は投げず、次の出力段がやり直す")
    func aFailedCatchUpDoesNotThrowFromAdvance() throws {
        try Self.withStoppedSketch(density: 0.5) { runtime, _, press in
            let canvas = runtime.canvas
            canvas.failEffectPassForTesting = 0
            try press("w")
            #expect(canvas.needsOutputEnlargement, "失敗したのに、追い付いたことになった")

            canvas.failEffectPassForTesting = nil
            let point = try runtime.target.encodeToImage().read()[80, 80]
            #expect(point.red > 200 && point.green < 30 && point.blue < 30, "やり直しに書いた画素が出ていない: \(point)")
            #expect(!canvas.needsOutputEnlargement)
        }
    }

    /// 細かさ 1 の面で、配った直後の書き戻しが失敗しても `advance()` は投げない ([#1906])。書き込み待ちは
    /// 残り、**出力段は古い絵を黙って返さず投げる**。直れば、次のリフレッシュが書き戻して窓に出る。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    @Test(
        "細かさ 1 で配った直後の書き戻しが失敗しても、advance() は投げず、次のリフレッシュがやり直す",
        arguments: [false, true])
    func aFailedWriteBackDoesNotThrowFromAdvance(vignette: Bool) throws {
        try Self.withStoppedSketch(density: 1, vignette: vignette) { runtime, gpu, press in
            let canvas = runtime.canvas
            canvas.target.failPixelWriteBackForTesting = .encoderUnavailable
            try press("w")
            #expect(canvas.target.hasPendingPixelWrites, "失敗したのに、書き戻したことになった")
            #expect(canvas.warnings.hasWarned(.pixelWriteBackFailed), "失敗を言っていない")
            #expect(throws: RenderFailure.self) { _ = try runtime.target.encodeToImage() }

            canvas.target.failPixelWriteBackForTesting = nil
            try runtime.advance()
            #expect(!canvas.target.hasPendingPixelWrites, "直った後のリフレッシュが書き戻していない")
            let point = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]
            #expect(Self.isRed(point.red, point.green, point.blue), "やり直しで窓に出ていない: \(point)")
        }
    }

    /// 配った直後の追い付きが失敗した後に外から止められても、止めている間のリフレッシュがやり直す
    /// ([#1906])。注意の文面 (「次のリフレッシュでもう一度試す」) のとおりで、止めが解けるまで待たない。
    /// 細かさを下げた面の広げ直しも同じ 1 点を通る。追い付いた後の止めている間のリフレッシュは、
    /// 何も投入しない。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    @Test(
        "配った直後の追い付きが失敗した後に外から止めても、止めている間のリフレッシュがやり直す",
        arguments: [Float(1), 0.5])
    func aFailedCatchUpIsRetriedWhilePaused(density: Float) throws {
        try Self.withStoppedSketch(density: density) { runtime, gpu, press in
            let canvas = runtime.canvas
            canvas.target.failPixelWriteBackForTesting = .encoderUnavailable
            try press("w")
            #expect(canvas.target.hasPendingPixelWrites, "失敗したのに、書き戻したことになった")

            runtime.pause()
            canvas.target.failPixelWriteBackForTesting = nil
            try runtime.advance()
            #expect(!canvas.target.hasPendingPixelWrites, "止めている間のリフレッシュが書き戻していない")
            #expect(!canvas.needsOutputEnlargement, "止めている間のリフレッシュが広げ直していない")
            let point = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]
            #expect(Self.isRed(point.red, point.green, point.blue), "止めている間に窓に出ていない: \(point)")

            let submissions = gpu.submissionCount
            try runtime.advance()
            try runtime.advance()
            #expect(gpu.submissionCount == submissions, "追い付いた後も、止めている間にコマンドを投入した")
        }
    }

    // MARK: - 後で描くフレームの描き切りが失敗したとき

    /// 止まっている間のコールバックで書いた画素は、配った直後に面へ戻したもので、後で描くフレームの
    /// 描き切りが失敗しても消えない ([#1906]・ADR-0021 決定 4 の追補 (2026-10-02))。窓に一度出した
    /// 絵が、描けなかったフレームの後で消えないためである。捨てるのは、そのフレームへ持ち越した
    /// 図形だけ (緑の円)。**同じコールバックで書いて `redraw()` したときは、そのフレームの一部として
    /// 載るので、描き切りが失敗すれば一緒に捨てる。**
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    @Test(
        "止まっている間に書いた画素は、後で描くフレームの描き切りが失敗しても残り、持ち越した図形は捨てる",
        arguments: [Float(1), 0.5])
    func writtenPixelsOutliveALaterFailedFrame(density: Float) throws {
        // 検査の前提: 描けたフレームなら、持ち越した円は (30, 30) に出る
        try Self.withStoppedSketch(density: density) { runtime, gpu, press in
            try press("b")
            let circle = try Self.windowPicture(of: runtime, gpu: gpu)[30, 30]
            #expect(circle.green > 0.9 && circle.red < 0.1, "検査の前提: 円が (30, 30) に出ていない: \(circle)")
        }

        // 書くコールバックと描き直すコールバックが別
        try Self.withStoppedSketch(density: density) { runtime, gpu, press in
            try press("w")
            runtime.canvas.failureForTesting = .encoderUnavailable
            #expect(throws: RenderFailure.self) { try press("b") }
            runtime.canvas.failureForTesting = nil
            try runtime.advance()

            let shown = try Self.windowPicture(of: runtime, gpu: gpu)
            let written = shown[80, 80]
            #expect(
                Self.isRed(written.red, written.green, written.blue),
                "描けなかったフレームの後で、前のコールバックで書いた画素が消えた: \(written)")
            let circle = shown[30, 30]
            #expect(circle.red > 0.5, "描けなかったフレームへ持ち越した円が残った: \(circle)")
        }

        // 同じコールバックで書いて描き直す
        try Self.withStoppedSketch(density: density) { runtime, gpu, press in
            runtime.canvas.failureForTesting = .encoderUnavailable
            #expect(throws: RenderFailure.self) { try press("x") }
            runtime.canvas.failureForTesting = nil
            try runtime.advance()

            let point = try Self.windowPicture(of: runtime, gpu: gpu)[80, 80]
            #expect(point.green > 0.5, "描けなかったフレームで書いた画素が残った: \(point)")
            #expect(!runtime.canvas.target.hasPendingPixelWrites, "描けなかったフレームの書き込みが待ちに残った")
        }
    }
}
