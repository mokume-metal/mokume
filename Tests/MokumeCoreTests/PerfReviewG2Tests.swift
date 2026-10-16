// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// PerfReview G2Frame — 性能レビュー (#1744 の 2026-10-12 分) の G2 の実測 (2026-10-16)。
//
// **使い捨ての Draft PR で専用機に流すためだけに置く。マージしない。** 1 本ずつ
// (`--filter "PerfReview G2Frame/<名前>"`) release で回す。GPU の検査を手元で回さない
// (#1999・#2052)。結果は `grep '^PERF'` で集める。
//
// 出力の形: PERF\t<Issue>\t<場面>\t<指標>\t<値>\t<単位>
//
// 対象: #2367 #2368 #2371 #2373 #2374 #2387 #2388 #2390 と、not planned の #1791 の記録。#2365 は
// 2026-10-14 に測り終えて閉じたので外した。測るのは前後の比較ではなく、**いまの費用の大きさ**である。

import AppKit
import Darwin
import Foundation
import IOSurface
import Metal
import QuartzCore
import Testing

@testable import MokumeCore

// MARK: - 共通の道具

/// 測った値の要約と出力。
enum Perf {
    /// 中央値・p90・最小。
    static func summary(_ samples: [Double]) -> (median: Double, p90: Double, min: Double) {
        guard !samples.isEmpty else { return (.nan, .nan, .nan) }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        return (median, p90, sorted[0])
    }

    static func line(_ issue: Int, _ scene: String, _ metric: String, _ value: Double, _ unit: String) {
        print("PERF\t\(issue)\t\(scene)\t\(metric)\t\(String(format: "%.4f", value))\t\(unit)")
    }

    /// 中央値・p90・最小と回数を出す。
    static func series(_ issue: Int, _ scene: String, _ metric: String, _ samples: [Double], _ unit: String) {
        let s = summary(samples)
        line(issue, scene, "\(metric).median", s.median, unit)
        line(issue, scene, "\(metric).p90", s.p90, unit)
        line(issue, scene, "\(metric).min", s.min, unit)
        line(issue, scene, "\(metric).n", Double(samples.count), "回")
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    /// 暖機してから `runs` 回測る (ミリ秒)。
    static func measure(warmup: Int = 3, runs: Int = 20, _ body: () throws -> Void) rethrows -> [Double] {
        for _ in 0..<warmup { try body() }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(runs)
        for _ in 0..<runs {
            let start = clock.now
            try body()
            samples.append(milliseconds(clock.now - start))
        }
        return samples
    }

    /// GPU を空にしてから `body` を走らせ、GPU が空になるまでの壁時計 (ミリ秒)。
    /// **GPU 時間の口が無いので、これが「組み立て + GPU の実行」の上限になる。**
    static func untilIdle(_ gpu: RenderDevice, _ body: () throws -> Void) throws -> Double {
        try gpu.settle()
        let clock = ContinuousClock()
        let start = clock.now
        try body()
        try gpu.settle()
        return milliseconds(clock.now - start)
    }
}

/// 種を固定した乱数 (SplitMix64)。合成した負荷を回ごとに揃える。
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// GPU の断片の仕事を作る場面。**全面の半透明の矩形を重ねる** (固定機能のブレンドの列)。
enum PerfScene {
    static let veil = LinearRGBA(premultipliedRed: 0.01, green: 0.012, blue: 0.015, alpha: 0.02)
    static let ink = LinearRGBA(premultipliedRed: 0.9, green: 0.3, blue: 0.2, alpha: 1)

    static func veils(_ canvas: Canvas, count: Int) {
        let width = Float(canvas.target.width)
        let height = Float(canvas.target.height)
        canvas.noStroke()
        canvas.fill(veil)
        for _ in 0..<count { canvas.rect(0, 0, width, height) }
    }

    /// 効果の入りに使う絵。縁と色の境目が要る (ぼかし・反転の差が出る所)。
    static func pattern(_ canvas: Canvas) {
        let width = Float(canvas.target.width)
        let height = Float(canvas.target.height)
        canvas.noStroke()
        for index in 0..<24 {
            let t = Float(index) / 24
            canvas.fill(LinearRGBA(premultipliedRed: t, green: 1 - t, blue: 0.5 * t, alpha: 1))
            canvas.circle(width * t, height * (0.5 + 0.4 * sin(t * 9)), height * 0.2)
        }
    }

    /// 2 枚の読み出しの、ビットで違う成分の数。
    static func differingComponents(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        zip(a.components, b.components).reduce(0) { $0 + ($1.0.bitPattern == $1.1.bitPattern ? 0 : 1) }
    }
}

/// プロセスの起床と CPU 時間 (`proc_pid_rusage`)。**プロセス全体の値**なので、検査の器の糸の分も
/// 入る。比べるのは同じ器の上の差だけにする。
enum ProcessUsage {
    struct Sample {
        let interruptWakeups: UInt64
        let idleWakeups: UInt64
        let cpuNanoseconds: UInt64
    }

    static func sample() -> Sample {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        precondition(result == 0, "proc_pid_rusage failed")
        // ri_user_time / ri_system_time は mach の時間単位 (Apple Silicon では 125/3 ns) — 要確認
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = usage.ri_user_time + usage.ri_system_time
        return Sample(
            interruptWakeups: usage.ri_interrupt_wkups, idleWakeups: usage.ri_pkg_idle_wkups,
            cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    /// `seconds` 秒、主の実行ループを回したときの、毎秒の起床と CPU。
    static func whileRunningMainLoop(seconds: Double) -> (wakeupsPerSecond: Double, cpuMsPerSecond: Double) {
        let before = sample()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        let after = sample()
        let wakeups = Double(after.interruptWakeups - before.interruptWakeups)
        let cpu = Double(after.cpuNanoseconds - before.cpuNanoseconds) / 1e6
        return (wakeups / seconds, cpu / seconds)
    }
}

/// 表示のリフレッシュを数える受け手 (CADisplayLink の target)。
final class LinkProbe: NSObject {
    struct Tick {
        let called: Double
        let timestamp: Double
        let target: Double
    }

    var ticks: [Tick] = []
    /// 呼ばれるたびに走らせるもの (予備のタイマーの張り直しなど)。
    var onTick: (() -> Void)?

    @objc func step(_ link: CADisplayLink) {
        ticks.append(Tick(called: CACurrentMediaTime(), timestamp: link.timestamp, target: link.targetTimestamp))
        onTick?()
    }
}

/// 駆動源の持ち主の代わり。進められた回数だけ数える。
final class AdvanceCounter: ScreenDisplayLinkOwner {
    var advances = 0
    func displayLinkFired() { advances += 1 }
}

/// 止めたまま回るスケッチ (#2367)。1 枚目だけ描く。
final class StillSketch: Sketch {
    var settings: SketchSettings { SketchSettings(width: 1280, height: 800) }
    init() {}
    func setup() { noLoop() }
    func draw() {
        background(235)
        fill(40, 80, 160)
        circle(640, 400, 300)
    }
}

/// 層を N 枚描いて置くスケッチ (#2387 の時計別の場面)。
final class LayeredSketch: Sketch {
    var clockMode = SketchSettings.ClockMode.wallClock
    var layerCount = 0
    var veilCount = 0
    var dotCount = 0
    var layers: [Canvas] = []
    var settings: SketchSettings { SketchSettings(width: 1280, height: 720, frameRate: 60, clock: clockMode) }
    init() {}
    convenience init(clock: SketchSettings.ClockMode, layers: Int, veils: Int, dots: Int) {
        self.init()
        clockMode = clock
        layerCount = layers
        veilCount = veils
        dotCount = dots
    }
    func setup() {
        layers = (0..<layerCount).compactMap { _ in try? createGraphics(1280, 720) }
    }
    func draw() {
        background(26, 26, 31)
        noStroke()
        fill(3, 3, 4, 5)
        for _ in 0..<veilCount { rect(0, 0, 1280, 720) }
        for layer in layers {
            layer.beginDraw()
            layer.background(LinearRGBA.transparent)
            PerfScene.veils(layer, count: veilCount)
            layer.fill(PerfScene.ink)
            for index in 0..<dotCount { layer.circle(Float(index % 1280), Float((index * 7) % 720), 3) }
            layer.endDraw()
            image(layer, 0, 0)
        }
    }
}

// MARK: - GPU を使う計測

@Suite(
    "PerfReview G2Frame", .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い"))
struct PerfReviewG2Frame {

    // MARK: #2367 止まっている間の差し出し

    /// 窓の経路の代わり: `SketchApplication.advanceAndPresent()` と同じ 2 手 (`runtime.advance()` →
    /// 差し出す 1 パス) を、窓の面と同じ大きさ・形式のテクスチャへ向けて回す。
    ///
    /// 窓・`nextDrawable()`・WindowServer の合成は入らない (それは Instruments の Metal System Trace と
    /// `powermetrics` が要る)。ここで分かるのは、**止まっている間も 1 リフレッシュごとに投入が 1 本・
    /// 全面のパスが 1 回走る**ことと、その GPU の壁時計の大きさ。
    @Test("#2367 noLoop・pause の間の 1 リフレッシュの投入と差し出しの費用", arguments: [false, true])
    func idlePresentPerRefresh(externallyPaused: Bool) throws {
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(
            sketch: StillSketch(), gpu: gpu, clock: nil, now: { CACurrentMediaTime() }, observer: nil)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        // Retina の窓 (1280×800 pt を 2 倍) の面
        let drawable = try RenderTarget(gpu: gpu, width: 2560, height: 1600)
        try runtime.advance()  // 1 枚目を描く
        try gpu.settle()
        if externallyPaused { runtime.pause() }
        let scene = externallyPaused ? "pause 中" : "noLoop 中"

        var advanceSubmissions = 0
        var presentSubmissions = 0
        let ticks = 120
        for _ in 0..<ticks {
            let a = gpu.submissionCount
            try runtime.advance()
            let b = gpu.submissionCount
            try presenter.draw(runtime.target, into: drawable.texture)
            advanceSubmissions += Int(b - a)
            presentSubmissions += Int(gpu.submissionCount - b)
        }
        Perf.line(2367, scene, "advance の投入 / リフレッシュ", Double(advanceSubmissions) / Double(ticks), "本")
        Perf.line(2367, scene, "差し出しの投入 / リフレッシュ", Double(presentSubmissions) / Double(ticks), "本")

        let advanceOnly = try Perf.measure(runs: 30) { _ = try Perf.untilIdle(gpu) { try runtime.advance() } }
        let withPresent = try Perf.measure(runs: 30) {
            _ = try Perf.untilIdle(gpu) {
                try runtime.advance()
                try presenter.draw(runtime.target, into: drawable.texture)
            }
        }
        Perf.series(2367, scene, "advance だけ (GPU が空くまで)", advanceOnly, "ms")
        Perf.series(2367, scene, "advance + 差し出し 2560×1600 (GPU が空くまで)", withPresent, "ms")
    }

    /// 共有面の経路: 止まっている間も `write` が枚数を繰り上げ、受け手 (道具) の `newest.frame != lastFrame`
    /// を毎回通してしまうか。
    @Test("#2367 noLoop の間も共有面の枚数が毎リフレッシュ進み、受け手の間引きが効かない")
    func idleSharedSurfacePerRefresh() throws {
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(
            sketch: StillSketch(), gpu: gpu, clock: nil, now: { CACurrentMediaTime() }, observer: nil)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-g2frame-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = try SharedFrameSurface(gpu: gpu, width: 2560, height: 1600, at: directory)
        try runtime.advance()

        var lastSeen = 0
        var receiverWouldPresent = 0
        var submissions = 0
        let ticks = 120
        let clock = ContinuousClock()
        var cpu: [Double] = []
        for _ in 0..<ticks {
            let before = gpu.submissionCount
            let start = clock.now
            try runtime.advance()
            try shared.write(runtime.target, using: presenter, numbers: runtime.frameNumbers)
            cpu.append(Perf.milliseconds(clock.now - start))
            submissions += Int(gpu.submissionCount - before)
            // 受け手 (`SharedFrameStage.displayLinkFired()`) の規則
            if let newest = SharedFrameSurface.newest(among: shared.ids), newest.frame != lastSeen {
                lastSeen = newest.frame
                receiverWouldPresent += 1
            }
        }
        try gpu.settle()
        Perf.line(2367, "共有面 noLoop 中", "投入 / リフレッシュ (作る側)", Double(submissions) / Double(ticks), "本")
        Perf.line(2367, "共有面 noLoop 中", "受け手が差し出す回 / リフレッシュ", Double(receiverWouldPresent) / Double(ticks), "回")
        Perf.series(2367, "共有面 noLoop 中", "作る側の 1 リフレッシュ (CPU)", cpu, "ms")
    }

    // MARK: #2368 共有面の属性の読み書き

    /// 受け手が毎リフレッシュ払う `newest(among:)` (面 4 枚に Lookup + CopyValue) と、新しい枚ごとの
    /// `pointerLockRequested(of:)` + `numbers(of:)`、作る側の SetValue。**面の参照を持ち続けたときの
    /// CopyValue だけ**の費用と並べる (完了条件 2 の得の上限)。
    @Test("#2368 IOSurface の Lookup / CopyValue / SetValue の 1 回あたり")
    func sharedSurfaceAttributeCosts() throws {
        let gpu = try RenderDevice()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-g2frame-attr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = try SharedFrameSurface(gpu: gpu, width: 1920, height: 1080, at: directory)
        let source = try RenderTarget(gpu: gpu, width: 1920, height: 1080)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let numbers = FrameNumbers(frameCount: 1, time: 0, frameRate: 60, frameTimeMs: 16.7)
        try shared.write(source, using: presenter, numbers: numbers)
        try shared.write(source, using: presenter, numbers: numbers)  // 1 枚目を名乗らせる
        try gpu.settle()
        let ids = shared.ids
        let held = ids.compactMap { IOSurfaceLookup($0) }
        try #require(held.count == ids.count)
        let iterations = 10_000

        var sink = 0
        let newest = Perf.measure(runs: 15) {
            for _ in 0..<iterations { sink &+= SharedFrameSurface.newest(among: ids)?.frame ?? 0 }
        }.map { $0 * 1000 / Double(iterations) }
        let heldCopy = Perf.measure(runs: 15) {
            for _ in 0..<iterations {
                for surface in held {
                    let value = IOSurfaceCopyValue(surface, SharedFrameSurface.frameAttribute as CFString) as? NSNumber
                    sink &+= value?.intValue ?? 0
                }
            }
        }.map { $0 * 1000 / Double(iterations) }
        let perNewFrame = Perf.measure(runs: 15) {
            for _ in 0..<iterations {
                sink &+= SharedFrameSurface.pointerLockRequested(of: ids[0]) ? 1 : 0
                sink &+= SharedFrameSurface.numbers(of: ids[0])?.frameCount ?? 0
            }
        }.map { $0 * 1000 / Double(iterations) }
        let producer = Perf.measure(runs: 15) {
            for index in 0..<iterations {
                let surface = held[index % held.count]
                // `publishPending()` が 1 枚ごとに出す 6 回 (frameCount・time・frameRate・frameTimeMs・捕まえ・枚数)。
                // 鍵の綴りは `TempoAttribute` の実物と違ってよい (費用は綴りに依らない前提)
                IOSurfaceSetValue(surface, "perf.frameCount" as CFString, NSNumber(value: index))
                IOSurfaceSetValue(surface, "perf.time" as CFString, NSNumber(value: Double(index)))
                IOSurfaceSetValue(surface, "perf.frameRate" as CFString, NSNumber(value: 60.0))
                IOSurfaceSetValue(surface, "perf.frameTimeMs" as CFString, NSNumber(value: 16.7))
                IOSurfaceRemoveValue(surface, SharedFrameSurface.pointerLockAttribute as CFString)
                IOSurfaceSetValue(surface, "perf.frame" as CFString, NSNumber(value: index))
            }
        }.map { $0 * 1000 / Double(iterations) }
        #expect(sink != 42)  // 最適化で消させない
        Perf.series(2368, "受け手 毎リフレッシュ", "newest(among: 4 枚)", newest, "µs/回")
        Perf.series(2368, "受け手 参照を持ったまま", "CopyValue × 4", heldCopy, "µs/回")
        Perf.series(2368, "受け手 新しい枚ごと", "pointerLockRequested + numbers", perNewFrame, "µs/回")
        Perf.series(2368, "作る側 1 枚ごと", "SetValue/RemoveValue × 6", producer, "µs/回")
    }

    // MARK: #2387 置き場 3 本と投入ごとの順序待ち

    private static func device(slotCount: Int) throws -> RenderDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        return try RenderDevice(device: device, slotCount: slotCount)
    }

    /// 層を N 枚描いて本体へ置き、差し出す (窓の代わりにテクスチャへ) フレーム。置き場の本数 3 (既定) と 8 で
    /// 比べる。**8 は案 B の代わりの量**で、データの環 (`FrameRing`) も同じ深さになる点に注意する。
    ///
    /// 負荷は 2 段: GPU 律速 (全面の幕が多い) と、釣り合い (幕が少なく CPU の組み立てが同程度)。
    @Test("#2387 層 N 枚のフレームの投入数・置き場待ち・フレーム時間", arguments: [3, 8])
    func layeredFrameSlotWaits(slotCount: Int) throws {
        let gpu = try Self.device(slotCount: slotCount)
        let main = try CanvasFixture.make(gpu: gpu, width: 1280, height: 720)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let drawable = try RenderTarget(gpu: gpu, width: 2560, height: 1440)
        let allLayers = try (0..<5).map { _ in try main.createGraphics(1280, 720) }

        for (load, veilsPerLayer, dotsPerLayer) in [("GPU 律速", 24, 50), ("釣り合い", 2, 3000)] {
            for layerCount in [0, 1, 3, 5] {
                let layers = Array(allLayers.prefix(layerCount))
                func frame() throws {
                    try main.draw {
                        main.background(LinearRGBA.linear(red: 0.1, green: 0.1, blue: 0.12))
                        PerfScene.veils(main, count: veilsPerLayer)
                        for layer in layers {
                            layer.beginDraw()
                            layer.background(LinearRGBA.transparent)
                            PerfScene.veils(layer, count: veilsPerLayer)
                            layer.fill(PerfScene.ink)
                            for index in 0..<dotsPerLayer {
                                layer.circle(Float(index % 1280), Float((index * 7) % 720), 3)
                            }
                            layer.endDraw()
                            main.image(layer, 0, 0)
                        }
                    }
                    try presenter.draw(main.output, into: drawable.texture)
                }
                for _ in 0..<5 { try frame() }
                try gpu.settle()
                let s0 = gpu.submissionCount, w0 = gpu.slotWaits, r0 = gpu.ringWaits, b0 = gpu.blockingWaits
                let frames = 40
                let clock = ContinuousClock()
                let start = clock.now
                var perFrame: [Double] = []
                for _ in 0..<frames {
                    let t = clock.now
                    try frame()
                    perFrame.append(Perf.milliseconds(clock.now - t))
                }
                try gpu.settle()
                let total = Perf.milliseconds(clock.now - start)
                let scene = "\(load) 層 \(layerCount) 枚 置き場 \(slotCount) 本"
                Perf.line(2387, scene, "投入 / フレーム", Double(gpu.submissionCount - s0) / Double(frames), "本")
                Perf.line(2387, scene, "slotWaits / フレーム", Double(gpu.slotWaits - w0) / Double(frames), "回")
                Perf.line(2387, scene, "ringWaits / フレーム", Double(gpu.ringWaits - r0) / Double(frames), "回")
                Perf.line(2387, scene, "blockingWaits / フレーム", Double(gpu.blockingWaits - b0) / Double(frames), "回")
                Perf.line(2387, scene, "平均フレーム時間 (完了まで)", total / Double(frames), "ms")
                Perf.series(2387, scene, "フレームの CPU 時間", perFrame, "ms")
            }
        }
    }

    /// `Sketches/EffectsAndCustom.swift` と同じ形 (1 枚の描き場所を 1 フレームに 6 回描き直し、効果を掛けて
    /// 置く)。置いた絵の写し (#1656) と描き直しで、投入がどれだけ増えるか。
    @Test("#2387 EffectsAndCustom 型のフレームの投入数と置き場待ち", arguments: [3, 8])
    func effectsAndCustomShape(slotCount: Int) throws {
        let gpu = try Self.device(slotCount: slotCount)
        let main = try CanvasFixture.make(gpu: gpu, width: 960, height: 540)
        let stage = try main.createGraphics(288, 200)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let drawable = try RenderTarget(gpu: gpu, width: 1920, height: 1080)
        let looks: [[Effect]] = [
            [], [.blur(radius: 6)], [.invert()], [.monochrome()], [.vignette(amount: 0.6)],
            [.adjust(brightness: 0.12, contrast: 0.6, saturation: 0.8)],
        ]
        func frame() throws {
            try main.draw {
                main.background(LinearRGBA.linear(red: 0.03, green: 0.04, blue: 0.06))
                for (index, look) in looks.enumerated() {
                    stage.beginDraw()
                    stage.background(LinearRGBA.linear(red: 0.9, green: 0.9, blue: 0.85))
                    PerfScene.pattern(stage)
                    stage.effects(look)
                    stage.endDraw()
                    main.image(stage, Float(24 + (index % 3) * 312), Float(24 + (index / 3) * 260))
                }
            }
            try presenter.draw(main.output, into: drawable.texture)
        }
        for _ in 0..<5 { try frame() }
        try gpu.settle()
        let s0 = gpu.submissionCount, w0 = gpu.slotWaits, b0 = gpu.blockingWaits
        let limit0 = main.placedPictureCopyLimitReached
        let samples = try Perf.measure(warmup: 0, runs: 40) { try frame() }
        try gpu.settle()
        let scene = "EffectsAndCustom 型 置き場 \(slotCount) 本"
        Perf.line(2387, scene, "投入 / フレーム", Double(gpu.submissionCount - s0) / 40, "本")
        Perf.line(2387, scene, "slotWaits / フレーム", Double(gpu.slotWaits - w0) / 40, "回")
        Perf.line(2387, scene, "blockingWaits / フレーム", Double(gpu.blockingWaits - b0) / 40, "回")
        Perf.line(2387, scene, "写しの上限に達した回 / フレーム", Double(main.placedPictureCopyLimitReached - limit0) / 40, "回")
        Perf.series(2387, scene, "フレームの CPU 時間", samples, "ms")
    }

    /// 窓の経路と同じ組み立て (`onScreen: true`・時計は設定から) で、層を N 枚描くスケッチを 60 Hz の
    /// 刻みで回す。表示のリフレッシュの代わりに 1/60 秒の締め切りで次の枚を始め、遅れた枚は次の刻みへ
    /// 送る (display link が刻みを飛ばすのと同じ)。**時計 (`clock: .frames` と既定の実時間) で GPU と
    /// CPU の仕事は変わらない**ので、比べるのは、予算 (1/60 秒) を越えた枚の数 (`overBudgetFrames`) と、
    /// 作品の時刻が実時間からどれだけ遅れたか (フレームの時計では越えた枚がそのまま処理落ちになる)。
    @Test(
        "#2387 層 N 枚のスケッチを 60 Hz で回したときの予算超過と時刻の遅れ (clock 別)",
        arguments: [SketchSettings.ClockMode.wallClock, .frames])
    func layeredSketchByClock(mode: SketchSettings.ClockMode) throws {
        let gpu = try RenderDevice()
        let modeName = mode == .frames ? "clock: .frames" : "clock: .wallClock"
        for (load, veils, dots) in [("GPU 律速", 24, 50), ("釣り合い", 2, 3000)] {
            for layerCount in [0, 3, 5] {
                let sketch = LayeredSketch(clock: mode, layers: layerCount, veils: veils, dots: dots)
                let runtime = try SketchRuntime(
                    sketch: sketch, gpu: gpu, clock: nil, now: { CACurrentMediaTime() }, onScreen: true)
                let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
                let drawable = try RenderTarget(gpu: gpu, width: 2560, height: 1440)
                for _ in 0..<5 {
                    try runtime.advance()
                    try presenter.draw(runtime.target, into: drawable.texture)
                }
                try gpu.settle()
                let budget0 = runtime.frameNumbers.overBudgetFrames
                let time0 = runtime.frameNumbers.time
                let w0 = gpu.slotWaits, b0 = gpu.blockingWaits
                let frames = 120
                let interval = 1.0 / 60
                let begin = CACurrentMediaTime()
                var tick = 0
                var skipped = 0
                var works: [Double] = []
                for _ in 0..<frames {
                    let deadline = begin + Double(tick) * interval
                    while CACurrentMediaTime() < deadline { usleep(200) }
                    let start = CACurrentMediaTime()
                    try runtime.advance()
                    try presenter.draw(runtime.target, into: drawable.texture)
                    works.append((CACurrentMediaTime() - start) * 1000)
                    // 次に始められる刻み (間に合わなかった刻みは飛ばす)
                    let next = Int(((CACurrentMediaTime() - begin) / interval).rounded(.up))
                    skipped += max(0, next - tick - 1)
                    tick = max(tick + 1, next)
                }
                try gpu.settle()
                let wall = CACurrentMediaTime() - begin
                let numbers = runtime.frameNumbers
                let scene = "\(load) 層 \(layerCount) 枚 \(modeName)"
                Perf.line(2387, scene, "予算超過の枚 / 120 枚", Double(numbers.overBudgetFrames - budget0), "枚")
                Perf.line(2387, scene, "飛ばした刻み / 120 枚", Double(skipped), "刻み")
                Perf.line(2387, scene, "作品の時刻の進み", (numbers.time - time0) * 1000, "ms")
                Perf.line(2387, scene, "実時間の進み", wall * 1000, "ms")
                Perf.line(2387, scene, "slotWaits / フレーム", Double(gpu.slotWaits - w0) / Double(frames), "回")
                Perf.line(2387, scene, "blockingWaits / フレーム", Double(gpu.blockingWaits - b0) / Double(frames), "回")
                Perf.series(2387, scene, "1 枚の仕事 (advance + 差し出し・CPU)", works, "ms")
            }
        }
    }

    // MARK: #2388 効果のフレームの控えの写し

    /// 1 枚の GPU の壁時計を 4 つの場面で測り、差から写し 1 回の費用を出す。
    ///
    /// - a: 効果なし・毎フレーム塗る
    /// - b: `.invert()`・毎フレーム塗る (控えへの写し 1 回 + 段 1 つ)
    /// - c: `.invert()`・塗らない (b + 戻しの写し 1 回)
    /// - d: `.invert()` 2 段・毎フレーム塗る (b + 段 1 つ)
    ///
    /// 戻しの写し 1 回 ≈ c − b、段 1 つ ≈ d − b、控えへの写し 1 回 ≈ b − a − (d − b)。
    @Test("#2388 控えへの写しと戻しの費用", arguments: [1080, 2160])
    func effectCarryCopies(height: Int) throws {
        let gpu = try RenderDevice()
        let width = height * 16 / 9
        let scene = "\(width)×\(height)"
        func run(effects: [Effect], clears: Bool) throws -> (samples: [Double], carries: Double, restores: Double) {
            let canvas = try CanvasFixture.make(gpu: gpu, width: width, height: height)
            var first = true
            func frame() throws {
                try canvas.draw {
                    if clears || first { canvas.background(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.25)) }
                    first = false
                    canvas.fill(PerfScene.ink)
                    canvas.circle(Float(width) / 2, Float(height) / 2, 40)
                    canvas.effects(effects)
                }
            }
            try frame()
            let c0 = canvas.effectCarriesEncoded, r0 = canvas.effectCarryRestoresEncoded
            var samples: [Double] = []
            for index in 0..<23 {
                let ms = try Perf.untilIdle(gpu) { try frame() }
                if index >= 3 { samples.append(ms) }
            }
            return (samples, Double(canvas.effectCarriesEncoded - c0) / 23, Double(canvas.effectCarryRestoresEncoded - r0) / 23)
        }
        let a = try run(effects: [], clears: true)
        let b = try run(effects: [.invert()], clears: true)
        let c = try run(effects: [.invert()], clears: false)
        let d = try run(effects: [.invert(), .invert()], clears: true)
        Perf.series(2388, scene, "a 効果なし", a.samples, "ms")
        Perf.series(2388, scene, "b invert・塗る", b.samples, "ms")
        Perf.series(2388, scene, "c invert・塗らない", c.samples, "ms")
        Perf.series(2388, scene, "d invert×2・塗る", d.samples, "ms")
        Perf.line(2388, scene, "b 写し / フレーム", b.carries, "回")
        Perf.line(2388, scene, "b 戻し / フレーム", b.restores, "回")
        Perf.line(2388, scene, "c 写し / フレーム", c.carries, "回")
        Perf.line(2388, scene, "c 戻し / フレーム", c.restores, "回")
        let m = { (s: [Double]) in Perf.summary(s).median }
        Perf.line(2388, scene, "戻しの写し 1 回 ≈ c−b", m(c.samples) - m(b.samples), "ms")
        Perf.line(2388, scene, "段 1 つ ≈ d−b", m(d.samples) - m(b.samples), "ms")
        Perf.line(2388, scene, "控えへの写し 1 回 ≈ (b−a)−(d−b)", (m(b.samples) - m(a.samples)) - (m(d.samples) - m(b.samples)), "ms")
    }

    // MARK: #2371 組み込みの効果の uber shader・融合・ぼかしの重み

    private static let invertOnly = """
        float4 effect(Pixel in, Values values) {
            return float4(mix(in.color.rgb, in.color.a - in.color.rgb, 1.0), in.color.a);
        }
        """

    /// 反転・単色化・周辺減光・明るさを 1 段で。組み込みの式をそのまま並べる (adjust は明るさだけ)。
    private static let fusedPerPixel = """
        float4 effect(Pixel in, Values values) {
            float4 c = in.color;
            c = float4(mix(c.rgb, c.a - c.rgb, 1.0), c.a);
            float grey = dot(c.rgb, float3(0.228975, 0.691739, 0.079287));
            c = float4(mix(c.rgb, float3(grey), 1.0), c.a);
            float2 fromCentre = (in.place - 0.5) * 2.0;
            c = float4(c.rgb * (1.0 - 0.6 * smoothstep(0.4, 1.45, length(fromCentre))), c.a);
            if (c.a > 0.0) {
                float3 straight = c.rgb / c.a;
                straight = max(straight + 0.1, min(straight, 0.0));
                straight = max((straight - 0.5) * (1.0 + 0.0) + 0.5, min(straight, 0.0));
                straight = max(mix(float3(dot(straight, float3(0.228975, 0.691739, 0.079287))), straight, 1.0 + 0.0), min(straight, 0.0));
                c = float4(straight * c.a, c.a);
            }
            return c;
        }
        """

    /// 組み込みのぼかしと同じ 17 タップ・同じ足し順で、重みだけ定数の表から引く。
    /// 表は exp(−i²/32) (i = 0…8) — 本文の式の主張どおりなら、組み込みと同じ重み。
    private static func constantWeightBlur() -> String {
        let table = (0...8).map { i in String(format: "%.9g", exp(-Double(i * i) / 32)) }
            .joined(separator: ", ")
        return """
            constant float kPerfWeights[9] = { \(table) };
            float4 effect(Pixel in, Values values) {
                float radius = values.radius;
                if (radius <= 0.0) { return in.color; }
                float2 texels = float2(in.source.get_width(), in.source.get_height());
                float2 step = values.direction / texels;
                float total = 0.0;
                float4 sum = float4(0.0);
                for (int i = -8; i <= 8; i++) {
                    float offset = float(i) * radius / 8.0;
                    float weight = kPerfWeights[abs(i)];
                    sum += mokume_at(in, in.place + step * offset) * weight;
                    total += weight;
                }
                return sum / max(total, 1e-6);
            }
            """
    }

    /// 4K で、組み込み (1 本のシェーダ・種別で分岐) と、同じ式を 1 種別だけ持つ利用者の効果を並べる。
    /// 差は「走らない枝も居るだけで払う」費用 (レジスタ・占有率) の上限の見積もりになる。
    @Test("#2371 組み込みの段と、特化・融合・定数の重みの段の GPU の壁時計 (4K)")
    func builtinVersusSpecialized() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 3840, height: 2160)
        let invert = try canvas.makeEffect(Self.invertOnly, name: "perfInvert")
        let fused = try canvas.makeEffect(Self.fusedPerPixel, name: "perfFused")
        let blurX = try canvas.makeEffect(
            Self.constantWeightBlur(), name: "perfBlurX", values: ["radius": 4, "direction": .pair(1, 0)])
        let blurY = try canvas.makeEffect(
            Self.constantWeightBlur(), name: "perfBlurY", values: ["radius": 4, "direction": .pair(0, 1)])

        func frameTime(_ effects: [Effect]) throws -> (samples: [Double], pixels: PixelBuffer) {
            func frame() throws {
                try canvas.draw {
                    canvas.background(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.25))
                    PerfScene.pattern(canvas)
                    canvas.effects(effects)
                }
            }
            for _ in 0..<3 { try frame() }
            var samples: [Double] = []
            for _ in 0..<20 { samples.append(try Perf.untilIdle(gpu) { try frame() }) }
            return (samples, try canvas.target.readPixels())
        }

        let none = try frameTime([])
        let builtinInvert = try frameTime([.invert()])
        let customInvert = try frameTime([.custom(invert)])
        let builtinChain = try frameTime([.invert(), .monochrome(), .vignette(amount: 0.6), .adjust(brightness: 0.1)])
        let fusedChain = try frameTime([.custom(fused)])
        let builtinBlur = try frameTime([.blur(radius: 4)])
        let tableBlur = try frameTime([.custom(blurX), .custom(blurY)])

        Perf.series(2371, "4K", "効果なし", none.samples, "ms")
        Perf.series(2371, "4K", "組み込み invert", builtinInvert.samples, "ms")
        Perf.series(2371, "4K", "特化 invert (利用者の効果)", customInvert.samples, "ms")
        Perf.series(2371, "4K", "組み込み 4 段 (invert/monochrome/vignette/adjust)", builtinChain.samples, "ms")
        Perf.series(2371, "4K", "融合 1 段 (同じ式)", fusedChain.samples, "ms")
        Perf.series(2371, "4K", "組み込み blur r=4 (2 段・毎画素 exp)", builtinBlur.samples, "ms")
        Perf.series(2371, "4K", "定数の重みの blur r=4 (2 段)", tableBlur.samples, "ms")
        Perf.line(2371, "4K", "blur 組み込みと定数の重みのビット違いの成分", Double(PerfScene.differingComponents(builtinBlur.pixels, tableBlur.pixels)), "個")
        Perf.line(2371, "4K", "成分の総数", Double(builtinBlur.pixels.components.count), "個")
        Perf.line(2371, "4K", "invert 組み込みと特化のビット違いの成分", Double(PerfScene.differingComponents(builtinInvert.pixels, customInvert.pixels)), "個")
        Perf.line(2371, "4K", "4 段と融合のビット違いの成分", Double(PerfScene.differingComponents(builtinChain.pixels, fusedChain.pixels)), "個")
    }

    // MARK: #2374 createGraphics

    /// 作る所要を、GPU が空いているときと、重いフレームが走っているときで測り、内訳を出す。
    /// 二度目の塗り (`target.fill(with: .transparent)` の `commitAndWait`) の得の上限は「全体 − 塗りを
    /// 除いた組み立て」で、GPU が走っているときほど大きくなるはず (全完了を待つため)。
    @Test("#2374 createGraphics の所要と内訳 (空いている GPU・走っている GPU)", arguments: [256, 1080])
    func createGraphicsBreakdown(height: Int) throws {
        let gpu = try RenderDevice()
        let main = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
        let width = height == 256 ? 256 : 1920
        let scene = "\(width)×\(height)"
        var keep: [Canvas] = []

        let b0 = gpu.blockingWaits
        let whole = try Perf.measure(runs: 15) { keep.append(try main.createGraphics(width, height)) }
        Perf.series(2374, "\(scene) 空いている GPU", "createGraphics", whole, "ms")
        Perf.line(2374, "\(scene) 空いている GPU", "blockingWaits / 回", Double(gpu.blockingWaits - b0) / 18, "回")
        keep.removeAll()
        let target = try Perf.measure(runs: 15) { _ = try RenderTarget(gpu: gpu, width: width, height: height) }
        let fill = try Perf.measure(runs: 15) {
            let fresh = try RenderTarget(gpu: gpu, width: width, height: height)
            try fresh.fill(with: .transparent)
        }
        let canvasOnly = try Perf.measure(runs: 15) {
            _ = try Canvas(target: try RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu)
        }
        let shapePipeline = try Perf.measure(runs: 15) {
            _ = try ShapePipeline(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        }
        Perf.series(2374, "\(scene) 空いている GPU", "RenderTarget.init", target, "ms")
        Perf.series(2374, "\(scene) 空いている GPU", "RenderTarget.init + fill(.transparent)", fill, "ms")
        Perf.series(2374, "\(scene) 空いている GPU", "RenderTarget.init + Canvas.init (塗りなし)", canvasOnly, "ms")
        Perf.series(2374, "\(scene) 空いている GPU", "うち ShapePipeline.init", shapePipeline, "ms")

        // 走っている GPU: 重いフレームを投入した直後 (待たない) に作る
        func busy() throws {
            try main.draw {
                main.background(LinearRGBA.linear(red: 0.1, green: 0.1, blue: 0.1))
                PerfScene.veils(main, count: 48)
            }
        }
        let clock = ContinuousClock()
        var busyWhole: [Double] = []
        var busyNoFill: [Double] = []
        for index in 0..<18 {
            try gpu.settle()
            try busy()
            var start = clock.now
            keep.append(try main.createGraphics(width, height))
            if index >= 3 { busyWhole.append(Perf.milliseconds(clock.now - start)) }
            try gpu.settle()
            try busy()
            start = clock.now
            keep.append(try Canvas(target: try RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu))
            if index >= 3 { busyNoFill.append(Perf.milliseconds(clock.now - start)) }
            keep.removeAll()
        }
        try gpu.settle()
        Perf.series(2374, "\(scene) 走っている GPU (幕 48 枚 1080p)", "createGraphics", busyWhole, "ms")
        Perf.series(2374, "\(scene) 走っている GPU (幕 48 枚 1080p)", "RenderTarget + Canvas (塗りなし)", busyNoFill, "ms")
    }

    // MARK: #2373 read(numbers)

    private static let tick = """
        kernel void tick(device float *out [[buffer(0)]],
                         uint id [[thread_position_in_grid]])
        {
            out[id] = out[id] + 1.0;
        }
        """

    enum ReadMode: String, CaseIterable {
        /// 読まない (CPU と GPU が重なる基準)
        case none
        /// 毎フレーム読む (いまの形)
        case everyFrame
        /// 読む前に自分で全完了を待つ (`read` の所要から「前のフレームの残り」を除いた往復だけ)
        case settledFirst
    }

    @Test("#2373 重い描画と read を毎フレーム並べたフレーム時間・待ちの数", arguments: ReadMode.allCases)
    func readEveryFrame(mode: ReadMode) throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
        let numbers = try canvas.makeNumbers(count: 1)
        let tick = try canvas.makeComputation(Self.tick, name: "tick")
        let clock = ContinuousClock()
        var readTimes: [Double] = []
        func frame(record: Bool) throws {
            try canvas.draw {
                canvas.background(LinearRGBA.linear(red: 0.1, green: 0.1, blue: 0.1))
                PerfScene.veils(canvas, count: 32)
                canvas.compute(tick, over: 1, writes: [numbers])
                switch mode {
                case .none:
                    break
                case .everyFrame:
                    let start = clock.now
                    _ = canvas.read(numbers)
                    if record { readTimes.append(Perf.milliseconds(clock.now - start)) }
                case .settledFirst:
                    try? gpu.settle()
                    let start = clock.now
                    _ = canvas.read(numbers)
                    if record { readTimes.append(Perf.milliseconds(clock.now - start)) }
                }
            }
        }
        for _ in 0..<5 { try frame(record: false) }
        let b0 = gpu.blockingWaits, s0 = gpu.settleCalls, n0 = gpu.submissionCount
        let frames = 30
        let start = clock.now
        var perFrame: [Double] = []
        for _ in 0..<frames {
            let t = clock.now
            try frame(record: true)
            perFrame.append(Perf.milliseconds(clock.now - t))
        }
        try gpu.settle()
        let total = Perf.milliseconds(clock.now - start)
        let scene = "1080p 幕 32 枚 read=\(mode.rawValue)"
        Perf.line(2373, scene, "平均フレーム時間 (完了まで)", total / Double(frames), "ms")
        Perf.series(2373, scene, "フレームの CPU 時間", perFrame, "ms")
        if !readTimes.isEmpty { Perf.series(2373, scene, "read の所要", readTimes, "ms") }
        Perf.line(2373, scene, "blockingWaits / フレーム", Double(gpu.blockingWaits - b0) / Double(frames), "回")
        Perf.line(2373, scene, "settleCalls / フレーム", Double(gpu.settleCalls - s0) / Double(frames), "回")
        Perf.line(2373, scene, "投入 / フレーム", Double(gpu.submissionCount - n0) / Double(frames), "本")
    }

    // MARK: #1791 置き場が伸びる瞬間の止まり (not planned の記録)

    /// GPU 律速の描き場所で、図形の数を倍々に増やし、置き場が伸びるフレームの描き切りの所要を測る。
    /// **場面の見張り**: 伸びるフレームで `blockingWaits` が 1 増えなければ GPU 律速になっていない。
    @Test("#1791 GrowableBuffer を伸ばすフレームの描き切りの止まり (記録)")
    func growthStall() throws {
        let gpu = try RenderDevice()
        let counts = [300, 600, 1200, 2400, 4800, 9600]
        var growth: [Double] = []
        var steady: [Double] = []
        var growthBlocking: [Double] = []
        var growthSettles: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<3 {
            // 伸びるのは面ごとに 1 度なので、回ごとに新しい面を作る
            let canvas = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
            func frame(dots: Int) throws -> (ms: Double, blocking: Int, settles: Int) {
                let b0 = gpu.blockingWaits, s0 = gpu.settleCalls
                let start = clock.now
                try canvas.draw {
                    canvas.background(LinearRGBA.linear(red: 0.1, green: 0.1, blue: 0.1))
                    PerfScene.veils(canvas, count: 40)
                    canvas.fill(PerfScene.ink)
                    for index in 0..<dots { canvas.rect(Float(index % 1920), Float((index * 13) % 1080), 2, 2) }
                }
                return (Perf.milliseconds(clock.now - start), gpu.blockingWaits - b0, gpu.settleCalls - s0)
            }
            for _ in 0..<10 { _ = try frame(dots: 150) }
            for count in counts {
                let grown = try frame(dots: count)
                growth.append(grown.ms)
                growthBlocking.append(Double(grown.blocking))
                growthSettles.append(Double(grown.settles))
                for _ in 0..<5 { steady.append(try frame(dots: count).ms) }
            }
            try gpu.settle()
        }
        let scene = "1080p 幕 40 枚 + 小さな矩形 倍々"
        Perf.series(1791, scene, "伸びるフレームの draw", growth, "ms")
        Perf.series(1791, scene, "伸びないフレームの draw", steady, "ms")
        Perf.line(1791, scene, "伸びるフレームの blockingWaits 平均", growthBlocking.reduce(0, +) / Double(growthBlocking.count), "回")
        Perf.line(1791, scene, "伸びるフレームの settleCalls 平均", growthSettles.reduce(0, +) / Double(growthSettles.count), "回")
    }
}

// MARK: - GPU を使わない計測 (画面は要るものがある)

@Suite("PerfReview G2Frame (GPU なし)", .serialized)
struct PerfReviewG2FrameWithoutGPU {

    // MARK: #2371 ぼかしの重みが半径に依らないこと (式の確かめ)

    /// 組み込みの式 (`Builtin.metal` の `mokume_blurAlong`) を Float でなぞり、exp(−i²/32) と比べる。
    @Test("#2371 ぼかしの重みは半径に依らない (Float でなぞる)")
    func blurWeightsDoNotDependOnRadius() {
        var worst: Float = 0
        for radius: Float in [0.0002, 0.5, 1, 2, 4, 6, 8, 12.5, 64, 131_072] {
            let sigma = max(radius, 1e-4) * 0.5
            for i in -8...8 {
                let offset = Float(i) * radius / 8.0
                let weight = exp(-0.5 * (offset * offset) / (sigma * sigma))
                let table = Float(exp(-Double(i * i) / 32))
                worst = max(worst, abs(weight - table) / table)
            }
        }
        Perf.line(2371, "CPU の Float", "重みの最大の相対差 (半径 0.0002〜131072)", Double(worst), "比")
        #expect(worst < 1e-5)
    }

    // MARK: #2368 予備の駆動タイマー

    /// 起床と CPU を、次の構成で 3 秒ずつ比べる。画面が無ければタイマーだけの比較になる。
    ///
    /// - 何も無し / タイマーだけ (tolerance 0) / タイマーだけ (tolerance 半分)
    /// - 画面があれば: 素の display link (60) / `ScreenDisplayLink(frameRate: 60)` (= link + 予備) /
    ///   link + tolerance 半分の予備 / link + 張り直す見張り (止まりの閾値で 1 度だけ)
    /// - 道具の link (速さを据えない) と 60 に据えた link (ProMotion でだけ違うはず)
    @Test("#2368 予備の駆動タイマーが足す起床と CPU")
    func fallbackTimerWakeups() {
        let interval = FrameDriver.fallbackInterval(frameRate: 60)
        let seconds = 3.0
        final class Count { var fires = 0 }
        func timer(tolerance: Double, count: Count) -> Timer {
            let made = Timer(timeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { count.fires += 1 }
            }
            made.tolerance = tolerance
            RunLoop.main.add(made, forMode: .common)
            return made
        }
        func report(_ scene: String, _ usage: (wakeupsPerSecond: Double, cpuMsPerSecond: Double), fires: Int? = nil) {
            Perf.line(2368, scene, "起床 / 秒 (プロセス)", usage.wakeupsPerSecond, "回")
            Perf.line(2368, scene, "CPU / 秒 (プロセス)", usage.cpuMsPerSecond, "ms")
            if let fires { Perf.line(2368, scene, "発火 / 秒", Double(fires) / seconds, "回") }
        }

        report("何も無し", ProcessUsage.whileRunningMainLoop(seconds: seconds))
        for tolerance in [0.0, interval * 0.5] {
            let count = Count()
            let made = timer(tolerance: tolerance, count: count)
            report("タイマーだけ tolerance=\(tolerance)", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: count.fires)
            made.invalidate()
        }

        guard let screen = NSScreen.main else {
            Perf.line(2368, "画面なし", "display link の比較を飛ばした", 0, "-")
            return
        }
        Perf.line(2368, "画面", "maximumFramesPerSecond", Double(screen.maximumFramesPerSecond), "Hz")
        func bareLink(_ probe: LinkProbe, rate: Float?) -> CADisplayLink {
            let link = screen.displayLink(target: probe, selector: #selector(LinkProbe.step(_:)))
            if let rate { link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate) }
            link.add(to: .main, forMode: .common)
            return link
        }

        do {
            let probe = LinkProbe()
            let link = bareLink(probe, rate: 60)
            report("素の display link 60", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: probe.ticks.count)
            link.invalidate()
        }
        do {
            let counter = AdvanceCounter()
            let link = ScreenDisplayLink(frameRate: 60)
            link.owner = counter
            link.attach(to: screen)
            report("ScreenDisplayLink(60) = link + 予備 (いま)", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: counter.advances)
            link.invalidate()
        }
        do {
            let probe = LinkProbe()
            let link = bareLink(probe, rate: 60)
            let count = Count()
            let made = timer(tolerance: interval * 0.5, count: count)
            report("link 60 + 予備 tolerance 半分", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: count.fires)
            made.invalidate()
            link.invalidate()
        }
        do {
            // 完了条件 1 の形: 健全な間は「最後に進めた時刻 + 止まりの閾値」へ張り直すだけの見張り
            let probe = LinkProbe()
            let count = Count()
            let threshold = FrameDriver.stallThreshold(frameRate: 60)
            let watchdog = Timer(timeInterval: threshold, repeats: true) { _ in
                MainActor.assumeIsolated { count.fires += 1 }
            }
            RunLoop.main.add(watchdog, forMode: .common)
            probe.onTick = { watchdog.fireDate = Date(timeIntervalSinceNow: threshold) }
            let link = bareLink(probe, rate: 60)
            report("link 60 + 張り直す見張り (閾値 4 枚)", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: count.fires)
            watchdog.invalidate()
            link.invalidate()
        }
        for rate: Float? in [nil, 60] {
            let probe = LinkProbe()
            let link = bareLink(probe, rate: rate)
            report("道具の link 速さ=\(rate.map { "\($0)" } ?? "据えない")", ProcessUsage.whileRunningMainLoop(seconds: seconds), fires: probe.ticks.count)
            link.invalidate()
        }
    }

    // MARK: #2390 フレームの時刻の揺れ

    /// main に合成した負荷 (5 ms ごとに 0〜3 ms 塞ぐ) を混ぜ、display link のコールバックの時点の
    /// `CACurrentMediaTime()` と `targetTimestamp` の間隔の揺れを比べる。さらに記録した時刻を
    /// `FrameTiming` (実時計) に通し、作者に見える `deltaTime` の揺れを 2 つの取り方で出す。
    ///
    /// **いまの実装の `now()` はコールバックより後** (`pollStopSignal`・`updatePresence`・観測の処理の後、
    /// `drawSketchFrame` の頭) なので、実際の揺れはここで測るコールバックの時点より大きいか等しい。
    @Test("#2390 コールバックの時刻と表示予定の時刻の deltaTime の揺れ", arguments: [false, true])
    func frameTimeJitter(loaded: Bool) {
        guard let screen = NSScreen.main else {
            Perf.line(2390, "画面なし", "飛ばした", 0, "-")
            return
        }
        let probe = LinkProbe()
        let link = screen.displayLink(target: probe, selector: #selector(LinkProbe.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        var load: Timer?
        if loaded {
            final class Generator { var random = SeededRandom(seed: 2390) }
            let generator = Generator()
            let made = Timer(timeInterval: 0.005, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let busy = Double.random(in: 0...0.003, using: &generator.random)
                    let until = CACurrentMediaTime() + busy
                    while CACurrentMediaTime() < until {}
                }
            }
            RunLoop.main.add(made, forMode: .common)
            load = made
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))
        link.invalidate()
        load?.invalidate()

        let ticks = Array(probe.ticks.dropFirst(10))
        let scene = loaded ? "main に 0〜3 ms の負荷" : "負荷なし"
        guard ticks.count > 30 else {
            Perf.line(2390, scene, "コールバックが来なかった (窓の無いプロセスで回らない?)", Double(ticks.count), "回")
            return
        }
        func deltas(_ values: [Double]) -> [Double] { zip(values.dropFirst(), values).map { ($0 - $1) * 1000 } }
        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        let called = deltas(ticks.map(\.called))
        let target = deltas(ticks.map(\.target))
        let nominal = 1000.0 / 60
        Perf.line(2390, scene, "コールバックの時点の間隔 標準偏差", deviation(called), "ms")
        Perf.line(2390, scene, "targetTimestamp の間隔 標準偏差", deviation(target), "ms")
        Perf.line(2390, scene, "コールバックの時点の間隔 最大の外れ", called.map { abs($0 - nominal) }.max() ?? .nan, "ms")
        Perf.line(2390, scene, "targetTimestamp が 1.5 枚以上飛んだ回", Double(target.filter { $0 > nominal * 1.5 }.count), "回")
        Perf.line(2390, scene, "コールバック - timestamp の遅れ 中央値", Perf.summary(ticks.map { ($0.called - $0.timestamp) * 1000 }).median, "ms")

        // 作者に見える deltaTime (FrameTiming に通す)
        final class Cursor { var index = 0 }
        let runs: [(String, [Double], Clock)] = [
            ("いま (コールバックの時点)", ticks.map(\.called), .wallClock),
            ("案 B (targetTimestamp)", ticks.map(\.target), .wallClock),
            ("clock: .frames (#2744)", ticks.map(\.called), .frameIndex(frameRate: 60)),
        ]
        for (name, times, clock) in runs {
            let cursor = Cursor()
            let timing = FrameTiming(clock: clock, frameRate: 60, now: { times[cursor.index] })
            var seen: [Double] = []
            for index in 1..<times.count {
                cursor.index = index
                timing.advance()
                seen.append(Double(timing.deltaTime) * 1000)
            }
            Perf.line(2390, scene, "deltaTime 標準偏差 \(name)", deviation(seen), "ms")
            Perf.line(2390, scene, "deltaTime 最大の外れ \(name)", seen.map { abs($0 - nominal) }.max() ?? .nan, "ms")
            // 作品の時刻が実時間 (表示予定の時刻) からどれだけ遅れたか。フレームの時計は刻みを飛ばした
            // ぶんだけ遅れる (処理落ち)
            let shown = ticks.last!.target - ticks[1].target
            Perf.line(2390, scene, "time の遅れ (表示の時刻との差・\(ticks.count) 枚) \(name)", (shown - Double(timing.time)) * 1000, "ms")
        }
    }
}
