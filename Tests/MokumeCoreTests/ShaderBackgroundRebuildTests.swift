// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 窓の経路では、利用者の断片の保存を裏で組む ([#2365])。
///
/// 冷えた状態では組み立てに 1 回 0.2 秒ほどかかり、その場で組むと保存のたびに窓が止まる。裏で
/// 組む間は前の断片で描き、組み上がった後の最初のフレームの頭で差し替える (``ShaderBox`` の
/// 「裏で組む」)。ここで確かめる約束:
///
/// - **組み上がりの受け取りを main actor の継続に頼らない** — 譲らずにフレームを回しても届く
///   ([#1830] と同じ穴を開けない)
/// - 差し替えはフレームの頭だけで、1 つのフレームの中で断片が混ざらない
/// - 組むのは 1 本までで、組み上がったときにファイルが変わっていればその結果は捨てる
/// - 観測のフレームでは待つ
///
/// 断片には毎回新しい定数を書く。同じ中身は Metal のシステムの控えに当たり、すぐ組み上がる。
///
/// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
/// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
@Suite(
    "窓の経路では、保存した断片を裏で組む (#2365)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderBackgroundRebuildTests {
    /// 黒の上に、渡された塗りで面を覆うスケッチ。`draw` の中で走らせる手続きも持てる。
    final class Cover: Sketch {
        var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
        var duringDraw: (() -> Void)?
        var paint: Shader?

        init() {}
        func draw() {
            duringDraw?()
            background(.linear(red: 0, green: 0, blue: 0))
            guard let paint else { return }
            noStroke()
            shader(paint)
            rect(0, 0, 8, 8)
            resetShader()
        }
    }

    /// 緑の成分が `green` の塗り。**定数を毎回変えるので、毎回冷えた状態で組む。**
    private static func paintBody(_ green: Double) -> String {
        "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
    }
    /// 組めない塗り。
    private static func brokenBody(_ mark: Int) -> String {
        "float4 paint(Fragment in, Values values) { return undeclared\(mark); }"
    }
    private static func effectBody(_ scale: Double) -> String {
        "float4 effect(Pixel in, Values values) { return in.color * \(scale); }"
    }
    private static func computationBody(_ value: Double) -> String {
        """
        kernel void fill(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]])
        {
            out[id] = \(value);
        }
        """
    }

    /// 新しい作業場所に断片を書いて返す。
    private static func write(_ body: String, named name: String, in directory: URL? = nil) throws -> URL {
        let directory =
            directory
            ?? TestScratch.path("mokume-background-shader", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 書き換えて、**譲らずに**事象が見張りに届くのを待つ。
    private static func save(_ body: String, to url: URL, watchedBy watcher: FileWatcher?) throws {
        let watcher = try #require(watcher, "検査の前提: 断片を見張っていない")
        let before = watcher.arrivedEventCount
        try body.write(to: url, atomically: true, encoding: .utf8)
        let deadline = DispatchTime.now() + 5
        while watcher.arrivedEventCount == before, DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(
            watcher.arrivedEventCount > before, "検査の前提: 書き換えた事象が 5 秒待っても見張りに届いていない")
    }

    /// `done` が満たされるまで、**譲らずに**フレームを回す。期限を越えたら `false`。
    private static func advance(
        _ runtime: SketchRuntime, until done: () -> Bool, seconds: Double = 30
    ) throws -> Bool {
        let deadline = DispatchTime.now() + seconds
        while !done() {
            guard DispatchTime.now() < deadline else { return false }
            try runtime.advance()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// 裏で組む設定の土台で、塗りを読み込んだランタイム。
    private static func runtime(
        painting body: String, observer: FrameObserver? = nil
    ) throws -> (runtime: SketchRuntime, sketch: Cover, shader: Shader, url: URL) {
        let gpu = try RenderDevice()
        gpu.rebuildsShadersInBackground = true
        let sketch = Cover()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: gpu, clock: nil, now: { 0 }, observer: observer)
        try runtime.advance()
        let url = try write(body, named: "paint.metal")
        let shader = try runtime.canvas.loadShader(url.path)
        sketch.paint = shader
        try runtime.advance()
        return (runtime, sketch, shader, url)
    }

    private static func green(_ runtime: SketchRuntime) throws -> Float {
        try runtime.target.readPixels()[4, 4].green
    }

    @Test("保存しても、そのフレームは前の断片で描き、譲らずに回すうちに組み上がって差し替わる")
    func aSaveIsBuiltInTheBackgroundAndAdoptedAtAFrameHead() throws {
        let (runtime, _, shader, url) = try Self.runtime(painting: Self.paintBody(0.25))
        let before = try Self.green(runtime)

        try Self.save(Self.paintBody(Double.random(in: 0.6...0.9)), to: url, watchedBy: shader.watcher)
        try runtime.advance()
        // 組み立てはこのフレームの頭で始まったので、このフレームではまだ差し替わらない
        #expect(shader.isBuildingInBackground, "保存を拾ったフレームで、裏で組み始めていない")
        #expect(shader.generation == 0, "保存を拾ったフレームの中で、その場で組んで差し替えた")
        #expect(try Self.green(runtime) == before, "組み上がる前のフレームが、前の断片で描かれていない")

        let adopted = try Self.advance(runtime, until: { shader.generation == 1 })
        #expect(
            adopted,
            """
            譲らずに 30 秒フレームを回しても、裏で組んだ断片が差し替わらない。組み上がりの受け取りが \
            main actor の継続に頼っている (#1830 と同じ穴)
            """)
        #expect(!shader.isBuildingInBackground)
        #expect(shader.backgroundBuildsStarted == 1)
        #expect(try Self.green(runtime) > before + 0.1, "差し替えた後のフレームが、新しい断片で描かれていない")
    }

    @Test("組み上がりを描いている最中に待っても、差し替わるのは次のフレームの頭")
    func adoptionWaitsForTheFrameBoundary() throws {
        let (runtime, sketch, shader, url) = try Self.runtime(painting: Self.paintBody(0.25))
        try Self.save(Self.paintBody(Double.random(in: 0.6...0.9)), to: url, watchedBy: shader.watcher)
        try runtime.advance()
        try #require(shader.isBuildingInBackground)

        var atStart = -1
        var atEnd = -1
        var finishedInsideTheFrame = false
        sketch.duringDraw = {
            atStart = shader.generation
            let deadline = DispatchTime.now() + 30
            while !shader.backgroundBuildFinished, DispatchTime.now() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            finishedInsideTheFrame = shader.backgroundBuildFinished
            atEnd = shader.generation
        }
        try runtime.advance()
        sketch.duringDraw = nil
        try #require(finishedInsideTheFrame, "検査の前提: 30 秒待っても裏の組み立てが終わらない")
        #expect(atStart == 0)
        #expect(atEnd == 0, "組み上がりが、描いている最中のフレームの中で差し替わった")

        try runtime.advance()
        #expect(shader.generation == 1, "組み上がった後の最初のフレームの頭で差し替わっていない")
    }

    @Test("組んでいる間に続けて保存すると、最後の中身だけが効き、途中の失敗は名乗らない")
    func onlyTheLatestSaveIsAdopted() throws {
        let (runtime, _, shader, url) = try Self.runtime(painting: Self.paintBody(0.25))
        let latest = Double.random(in: 0.6...0.9)

        try Self.save(Self.paintBody(Double.random(in: 0.3...0.5)), to: url, watchedBy: shader.watcher)
        try runtime.advance()  // A を組み始める
        try #require(shader.isBuildingInBackground)
        try Self.save(Self.brokenBody(Int.random(in: 0...999_999)), to: url, watchedBy: shader.watcher)  // B
        try Self.save(Self.paintBody(latest), to: url, watchedBy: shader.watcher)  // C

        let adopted = try Self.advance(runtime, until: { shader.generation >= 1 && !shader.isBuildingInBackground })
        #expect(adopted, "30 秒回しても、最後に保存した中身が差し替わらない")
        #expect(shader.generation == 1, "途中の保存 (A) の結果まで差し替えた")
        #expect(shader.backgroundBuildsStarted == 2, "組んでいる間の保存で、組み立てを並べた (A と C の 2 本のはず)")
        #expect(shader.failure == nil)
        #expect(shader.failureReports == 0, "途中の保存 (B) の失敗を名乗った")
        #expect(abs(try Self.green(runtime) - Float(latest)) < 0.05, "最後に保存した中身で描かれていない")
    }

    @Test("組めない中身は、組み終えた後の頭で 1 度だけ名乗り、前の断片のまま描き続ける")
    func aFailureIsReportedOnceAtAFrameHead() throws {
        let (runtime, _, shader, url) = try Self.runtime(painting: Self.paintBody(0.75))
        let before = try Self.green(runtime)

        try Self.save(Self.brokenBody(Int.random(in: 0...999_999)), to: url, watchedBy: shader.watcher)
        try runtime.advance()
        #expect(shader.failure == nil, "組み終える前に、失敗を名乗った")

        let reported = try Self.advance(runtime, until: { shader.failure != nil })
        #expect(reported, "30 秒回しても、組めない中身の失敗を名乗らない")
        for _ in 0..<5 { try runtime.advance() }
        #expect(shader.failureReports == 1, "同じ失敗を言い直した")
        #expect(shader.generation == 0)
        #expect(try Self.green(runtime) == before, "組めなかった後に、前の断片で描いていない")
    }

    @Test("観測のフレームでは、組んでいる仕事を待たずにその場で組み、保存した中身で描く")
    func anObservedFrameBuildsInPlace() throws {
        let facet = try TestScratch.directory("mokume-background-observe")
        let (runtime, _, shader, url) = try Self.runtime(
            painting: Self.paintBody(0.25), observer: FrameObserver(directory: facet))
        let saved = Double.random(in: 0.6...0.9)

        try Self.save(Self.paintBody(saved), to: url, watchedBy: shader.watcher)
        try runtime.advance()
        try #require(shader.isBuildingInBackground)
        try #require(shader.generation == 0)

        try AtomicFile.write(
            Data(#"{"id":"wait-2365"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        #expect(shader.generation == 1, "観測のフレームで、保存した断片の組み上がりを待っていない")
        #expect(!shader.isBuildingInBackground, "観測のフレームの後も、裏の仕事が残っている")
        #expect(abs(try Self.green(runtime) - Float(saved)) < 0.05, "観測のフレームが、保存した中身で描かれていない")
        #expect(!runtime.canvas.gpu.waitsForShaderRebuilds, "観測のフレームの後も、待つ旗が下りていない")
    }

    @Test("効果と計算も、裏で組んでフレームの頭で差し替わる")
    func effectsAndComputationsAreBuiltInTheBackground() throws {
        let (runtime, _, _, _) = try Self.runtime(painting: Self.paintBody(0.25))
        let directory = TestScratch.path("mokume-background-others", isDirectory: true)
        let tint = try Self.write(Self.effectBody(0.5), named: "tint.metal", in: directory)
        let fill = try Self.write(Self.computationBody(0.5), named: "fill.metal", in: directory)
        let effect = try runtime.canvas.loadEffect(tint.path)
        let computation = try runtime.canvas.loadComputation(fill.path)

        try Self.save(Self.effectBody(Double.random(in: 0.6...0.9)), to: tint, watchedBy: effect.watcher)
        try Self.save(Self.computationBody(Double.random(in: 0.6...0.9)), to: fill, watchedBy: computation.watcher)
        try runtime.advance()
        #expect(effect.generation == 0, "効果を、保存を拾ったフレームの中でその場で組んだ")
        #expect(computation.generation == 0, "計算を、保存を拾ったフレームの中でその場で組んだ")

        let adopted = try Self.advance(runtime, until: { effect.generation == 1 && computation.generation == 1 })
        #expect(adopted, "30 秒回しても、裏で組んだ効果と計算が差し替わらない")
        #expect(effect.failure == nil)
        #expect(computation.failure == nil)
    }
}
