// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

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
        var onKey: [String: (StoppedPainter) -> Void] = [:]
        init(density: Float, vignette: Bool) {
            self.density = density
            self.vignette = vignette
        }
        convenience init() { self.init(density: 1, vignette: false) }
        var settings: SketchSettings {
            SketchSettings(width: 160, height: 160, pixelDensity: density)
        }
        func setup() { noLoop() }
        func draw() {
            guard frameCount == 1 else { return }
            background(235)
            if vignette { effects([.vignette(amount: 0.6)]) }
        }
        func keyPressed() { onKey[key]?(self) }
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
        density: Float, vignette: Bool = false,
        _ body: (SketchRuntime, RenderDevice, (String) throws -> Void) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stopped-outlets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = directory.appendingPathComponent("facet", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        let sketch = StoppedPainter(density: density, vignette: vignette)
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
