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
/// 細かさ 1 で `set()` した画素は、まだ窓に出ない (出力段を通すまで写しがテクスチャへ戻らない)。
/// 効果と関係の無い別の根で、[#1906] が扱うので、ここでは見ない。
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

    /// 止まっている間に変える口。
    enum Change: CaseIterable, CustomTestStringConvertible {
        /// 中央に 4×4 の赤を `set` する。
        case writeBlock
        /// 赤い円を置いて、画素を読む口で描き切らせる。
        case circleThenRead

        var testDescription: String {
            switch self {
            case .writeBlock: "画素を書く"
            case .circleThenRead: "円を置いて読む"
            }
        }

        var key: String {
            switch self {
            case .writeBlock: "w"
            case .circleThenRead: "c"
            }
        }
    }

    /// 細かさ × 周辺減光の有無 × 変え方 の 1 通り。
    ///
    /// 細かさ 1 の `set()` は含まない (窓に出ないのは #1906)。
    struct Scenario: CustomTestStringConvertible {
        let density: Float
        let vignette: Bool
        let change: Change

        var testDescription: String {
            "細かさ \(density)・\(vignette ? "周辺減光あり" : "効果なし")・\(change.testDescription)"
        }

        nonisolated static var all: [Scenario] {
            [false, true].flatMap { vignette in
                var rows = Change.allCases.map {
                    Scenario(density: 0.5, vignette: vignette, change: $0)
                }
                // 細かさ 1 でも、円は窓に出る (対照)
                rows.append(Scenario(density: 1, vignette: vignette, change: .circleThenRead))
                return rows
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
        sketch.onKey["c"] = { sketch in
            sketch.noStroke()
            sketch.fill(red)
            sketch.circle(80, 80, 40)
            _ = sketch.get(0, 0)
        }
        // 読むだけ (描く先を変えない)
        sketch.onKey["g"] = { sketch in _ = sketch.get(40, 40) }

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

    private static func isRed(_ red: Float, _ green: Float, _ blue: Float) -> Bool {
        red > 0.9 && green < 0.1 && blue < 0.1
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

            let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
            let window = try RenderTarget(gpu: gpu, width: 160, height: 160)
            try presenter.draw(runtime.target, into: window.texture)
            let point = try window.readPixels()[80, 80]

            #expect(Self.isRed(point.red, point.green, point.blue), "窓が読む絵に出ていない: \(point)")
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

    /// 配った直後の追い付きは、変えたときだけ積む。読むだけ・何も無いリフレッシュは積まない。
    @Test("コールバックが描く先を変えなければ、配った直後に拡大を積まない", arguments: [false, true])
    func theRuntimePaysOnlyForAChange(vignette: Bool) throws {
        try Self.withStoppedSketch(density: 0.5, vignette: vignette) { runtime, _, press in
            let canvas = runtime.canvas
            let afterFirstFrame = canvas.effectPassesEncoded

            try press("g")
            try runtime.advance()
            try runtime.advance()
            #expect(canvas.effectPassesEncoded == afterFirstFrame, "変えていないのに拡大を積んだ")

            try press("w")
            #expect(canvas.effectPassesEncoded - afterFirstFrame == 1, "変えたのに、配った直後に 1 度だけ積んでいない")
            #expect(!canvas.needsOutputEnlargement, "追い付いたのに、まだ追い付いていないことになっている")

            // 追い付いた後は、リフレッシュを重ねても出力段を通しても積み足さない
            try runtime.advance()
            _ = try runtime.target.encodeToImage()
            #expect(canvas.effectPassesEncoded - afterFirstFrame == 1, "追い付いた後に積み足した")
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
}
