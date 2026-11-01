// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 4K の動画 4 本を流す複合場面で、実時間の時計では復号の待ちが main を止めないことを測る (#2961 の
/// 完了条件 1)。**検査ではなく計測で、既定では走らない。**
///
/// `MOKUME_MOVIE_DECODE_WAIT` で開き、release でだけ走る。場面ごとに別のプロセスで専有して測る (値は
/// `normal` か `speed4`。それ以外なら両方を続けて測る):
///
/// ```sh
/// MOKUME_MOVIE_DECODE_WAIT=normal python3 scripts/gpu-slot.py --exclusive -- \
///   make test-release TEST_RELEASE_ARGS='--filter MovieDecodeWaitMeasurement'
/// MOKUME_MOVIE_DECODE_WAIT=speed4 python3 scripts/gpu-slot.py --exclusive -- \
///   make test-release TEST_RELEASE_ARGS='--filter MovieDecodeWaitMeasurement'
/// ```
///
/// 場面は ``MovieSurfaceMeasurement`` と同じ複合場面 (``SurfaceScene/composite(_:)``) で、(i) 通常再生
/// (各 30 fps を 120 Hz で描く) と (ii) 4 本とも `speed(4)` (描画ごとに 1 コマ進む。4K を毎秒 480 枚) を流す。
/// 1,200 フレームのうち、立ち上がりの 2 秒を除いた 960 フレームを数える。
///
/// フレームごとに、4 本の `Movie.supply()` の main の時間 (4 本の入り口の前後に ``Stopwatch`` を置いた差)・
/// `draw()` の時間・`advance()` の時間を取り、中央値 / p90 / 最大と 1 フレーム (8.33 ms) を越えた回数を出す。
/// 新しいコマが出た回数 (`isNewFrame`) を 4 本で足し、素材の速さから求めた期待の回数と並べる (足りない分が、
/// 前のコマのまま映ったフレーム)。値は `PERF\t2961\t<場面>\t<指標>\t<値>\t<単位>` の行で出す。
@Suite(
    "動画の復号の待ちが main を止めないか (計測)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUME_MOVIE_DECODE_WAIT"] != nil, "MOKUME_MOVIE_DECODE_WAIT で開く"),
    .enabled(if: !MovieStall.isDebugBuild, "性能は release で測る"),
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い"),
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MovieDecodeWaitMeasurement {
    /// 120 Hz の 1 フレーム (ms)。
    static let budget = 1000.0 / 120

    @Test("2961 4K 4 本の複合場面 — 通常再生と 4 倍速の main の待ち")
    func fourMovies() async throws {
        var urls: [URL] = []
        for _ in 0..<4 {
            urls.append(
                try await TestMovie.write(
                    frames: 90, width: 3840, height: 2160, keyFrameInterval: 30, hardware: true,
                    bitRate: 3840 * 2160 * 4, paint: MovieStall.busy))
        }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let chosen = ProcessInfo.processInfo.environment["MOKUME_MOVIE_DECODE_WAIT"]
        if chosen != "speed4" { try measure(urls, rate: 1) }
        if chosen != "normal" { try measure(urls, rate: 4) }
    }

    private func measure(_ urls: [URL], rate: Float) throws {
        let scene = rate == 1 ? "normal" : "speed\(Int(rate))"
        let before = Stopwatch()
        let after = Stopwatch()
        var movies: [Movie] = []
        var drawn: [Double] = []
        SurfaceScene.onSetup = { sketch in
            sketch.attach(before)
            movies = try urls.map { url in
                let movie = try sketch.createVideo(url.path)
                movie.loop()
                movie.speed(rate)
                return movie
            }
            sketch.attach(after)
        }
        SurfaceScene.onDraw = { sketch in
            let started = ContinuousClock.now
            sketch.composite(movies)
            drawn.append(MovieStall.ms(ContinuousClock.now - started))
        }
        let origin = ContinuousClock.now
        let runtime = try SketchRuntime(
            sketch: SurfaceScene(), gpu: try RenderDevice(), clock: .wallClock,
            now: { MovieStall.seconds(ContinuousClock.now - origin) })
        defer {
            runtime.closePlugins()
            SurfaceScene.onSetup = { _ in }
            SurfaceScene.onDraw = { _ in }
        }
        var supply: [Double] = []
        var advance: [Double] = []
        var draw: [Double] = []
        var newFrames = 0
        let warmUp = 240
        let counted = 960
        for tick in 0..<(warmUp + counted) {
            let due = origin + .microseconds(Int64(Double(tick + 1) * 1_000_000 / 120))
            let wait = due - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: MovieStall.seconds(wait)) }
            let started = ContinuousClock.now
            try runtime.advance()
            // 最初のフレームは `setup()` が入り口を足すので、supply の前後がまだ揃わない
            guard tick >= warmUp else { continue }
            advance.append(MovieStall.ms(ContinuousClock.now - started))
            supply.append(MovieStall.ms(after.last - before.last))
            draw.append(drawn.last ?? 0)
            newFrames += movies.count { $0.isNewFrame }
        }
        // 素材は 30 fps。描画 1 回で進むコマは 30 × 速さ / 120 で、1 を越えても新しいコマは 1 回と数える
        let expected = Int(Double(counted * movies.count) * min(1, 30 * Double(rate) / 120))
        for (metric, values) in [("supply", supply), ("draw", draw), ("advance", advance)] {
            MovieStall.report("2961", scene, metric, values)
            MovieStall.line(
                "2961", scene, "\(metric).p95", String(format: "%.2f", MovieSurfaceMeasurement.percentile(values, 0.95)),
                "ms")
            MovieStall.line("2961", scene, "\(metric).overBudget", "\(values.count { $0 > Self.budget })", "frames")
        }
        MovieStall.line("2961", scene, "newFrames", "\(newFrames)", "frames")
        MovieStall.line("2961", scene, "expectedNewFrames", "\(expected)", "frames")
        MovieStall.line("2961", scene, "staleFrames", "\(max(0, expected - newFrames))", "frames")
    }
}
