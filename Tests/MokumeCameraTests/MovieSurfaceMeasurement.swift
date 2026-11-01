// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 4K の動画 4 本を流す複合場面で、面の道と CPU の道 (変更前) を並べて測る (#2962 の完了条件 1)。
/// **検査ではなく計測で、既定では走らない。**
///
/// `MOKUME_MOVIE_SURFACES` で開き、release でだけ走る。最大の記憶が前の回の残りを拾わないよう、
/// 道ごとに別のプロセスで専有して測る (値は `cpu` か `surface`。それ以外なら両方を続けて測る):
///
/// ```sh
/// MOKUME_MOVIE_SURFACES=cpu python3 scripts/gpu-slot.py --exclusive -- \
///   make test-release TEST_RELEASE_ARGS='--filter MovieSurfaceMeasurement'
/// MOKUME_MOVIE_SURFACES=surface python3 scripts/gpu-slot.py --exclusive -- \
///   make test-release TEST_RELEASE_ARGS='--filter MovieSurfaceMeasurement'
/// ```
///
/// 場面: 1920×1080 の面に、4K・30 fps・H.264 の動画 4 本 (同じ大きさ・不透明・ループ) を 4 分割で貼り、
/// 200 個の半透明の矩形と照らして回る立方体を重ね、全体にぼかしの効果を掛ける (2D・3D・GPU の効果。
/// 音の FFT はこの検査の束から音のモジュールを引けないので入れない)。実時間の時計で 120 Hz の刻みまで
/// 眠りながら回す (通常再生: 各 30 fps の動画を 120 Hz で描く)。立ち上がりの 2 秒を除いた 6 秒
/// (720 フレーム) を数える。値は `PERF\t2962\t<道>\t<指標>\t<値>\t<単位>` の行で出す。
///
/// 再発検出 (#2962 の完了条件 6) の値も出す: GPU が打ち切った数 (command buffer の失敗) と、投入した数と
/// 結末が届いた数。
@Suite(
    "動画を面のまま渡す道の費用 (計測)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUME_MOVIE_SURFACES"] != nil, "MOKUME_MOVIE_SURFACES で開く"),
    .enabled(if: !MovieStall.isDebugBuild, "性能は release で測る"),
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い"),
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MovieSurfaceMeasurement {
    @Test("2962 4K 4 本の複合場面 — 面の道と CPU の道 (変更前)")
    func fourMovies() async throws {
        var urls: [URL] = []
        for _ in 0..<4 {
            urls.append(
                try await TestMovie.write(
                    frames: 90, width: 3840, height: 2160, keyFrameInterval: 30, hardware: true,
                    bitRate: 3840 * 2160 * 4, paint: MovieStall.busy))
        }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        // 表を作る費用 (1 度だけ・先読みの係の上) は立ち上がりの 2 秒に入る
        let chosen = ProcessInfo.processInfo.environment["MOKUME_MOVIE_SURFACES"]
        if chosen != "surface" { try measure(urls, surfaces: false) }
        if chosen != "cpu" { try measure(urls, surfaces: true) }
        SurfaceRoute.isEnabled.store(true, ordering: .relaxed)
    }

    private func measure(_ urls: [URL], surfaces: Bool) throws {
        SurfaceRoute.isEnabled.store(surfaces, ordering: .relaxed)
        let path = surfaces ? "surface" : "cpu"
        var movies: [Movie] = []
        SurfaceScene.onSetup = { sketch in
            movies = try urls.map { url in
                let movie = try sketch.createVideo(url.path)
                movie.loop()
                return movie
            }
        }
        SurfaceScene.onDraw = { sketch in
            sketch.background(20, 20, 30)
            for (index, movie) in movies.enumerated() {
                sketch.image(movie.image, Float(index % 2) * 960, Float(index / 2) * 540, 960, 540)
            }
            sketch.noStroke()
            for index in 0..<200 {
                sketch.fill(Float(index % 255), 120, 200, 90)
                sketch.rect(Float(index * 37 % 1880), Float(index * 53 % 1040), 40, 40)
            }
            sketch.lights()
            sketch.fill(230, 160, 60)
            sketch.translate(960, 540, 0)
            sketch.rotateX(Float(sketch.frameCount) * 0.01)
            sketch.rotateY(Float(sketch.frameCount) * 0.013)
            sketch.box(300)
            sketch.filter([.blur(radius: 2)])
        }
        let origin = ContinuousClock.now
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(
            sketch: SurfaceScene(), gpu: gpu, clock: .wallClock, now: { MovieStall.seconds(ContinuousClock.now - origin) })
        defer { runtime.closePlugins() }
        var main: [Double] = []
        var footprint = 0.0
        var leases = 0
        var conversionsAtStart = 0
        let warmUp = 240
        let counted = 720
        for tick in 0..<(warmUp + counted) {
            let due = origin + .microseconds(Int64(Double(tick + 1) * 1_000_000 / 120))
            let wait = due - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: MovieStall.seconds(wait)) }
            if tick == warmUp { conversionsAtStart = FrameConverter.conversions.load(ordering: .relaxed) }
            let started = ContinuousClock.now
            try runtime.advance()
            if tick >= warmUp {
                main.append(MovieStall.ms(ContinuousClock.now - started))
                footprint = max(footprint, Self.footprintMB())
                leases = max(leases, SurfaceLease.live.load(ordering: .relaxed))
            }
        }
        try gpu.settle()
        let conversions = FrameConverter.conversions.load(ordering: .relaxed) - conversionsAtStart
        let gpuTimes = gpu.completedGPUFrameTimes.map(\.milliseconds)
        MovieStall.report("2962", path, "main.advance", main)
        MovieStall.line("2962", path, "main.advance.p95", String(format: "%.2f", Self.percentile(main, 0.95)), "ms")
        MovieStall.report("2962", path, "gpu.span", gpuTimes)
        MovieStall.line("2962", path, "cpuConversions", "\(conversions)", "frames")
        MovieStall.line("2962", path, "footprint.max", String(format: "%.0f", footprint), "MiB")
        MovieStall.line("2962", path, "leases.max", "\(leases)", "surfaces")
        MovieStall.line("2962", path, "gpu.faults", "\(gpu.commandFaultCount)", "commands")
        MovieStall.line("2962", path, "submitted", "\(gpu.submissionCount)", "commands")
        MovieStall.line("2962", path, "delivered", "\(gpu.arrivedNoticeCount)", "commands")
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    /// アクティビティモニタの「メモリ」に当たる値 (MiB)。
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / (1024 * 1024) : 0
    }
}

/// 計測の場面。`setup()` と `draw()` で、計測が渡した手続きを走らせる。
final class SurfaceScene: Sketch {
    nonisolated(unsafe) static var onSetup: (SurfaceScene) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (SurfaceScene) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 1920, height: 1080, frameRate: 120) }
    func setup() throws { try Self.onSetup(self) }
    func draw() { Self.onDraw(self) }
}
