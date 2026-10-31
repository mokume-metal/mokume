// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 動画の読み手の止まりを測る (#2523・#2764)。**検査ではなく計測で、既定では走らない。**
///
/// `MOKUME_MOVIE_STALLS=1` で開き、release でだけ走る (debug の数字を根拠にしない)。専有して測る:
///
/// ```sh
/// MOKUME_MOVIE_STALLS=1 python3 scripts/gpu-slot.py --exclusive -- \
///   make test-release TEST_RELEASE_ARGS='--filter MovieStallMeasurement'
/// ```
///
/// 動画は #2523 の「実測」と同じ形 — 3 秒・30 fps・1080p と 4K・H.264 の鍵のコマ 30 / 90 枚ごとと
/// HEVC の 30 枚ごと。ハードの符号化器に並べ替えも任せ (普通の動画に近い)、行ごとの縞と跳ぶ帯で
/// 符号化に手応えを与える。値は `PERF\t<Issue>\t<動画>\t<場面.指標>\t<値>\t<単位>` の行で出す。
@Suite(
    "動画の読み手の止まり (計測)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUME_MOVIE_STALLS"] != nil, "MOKUME_MOVIE_STALLS で開く"),
    .enabled(if: !MovieStall.isDebugBuild, "性能は release で測る"),
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MovieStallMeasurement {
    /// 測る動画の大きさ。
    static let sizes: [(width: Int, height: Int)] = [(1920, 1080), (3840, 2160)]

    @Test(
        "2764 MovieReader.picture(at:) の止まり — 鍵のコマで決める読み方と、1 秒で分ける読み方 (変更前)",
        arguments: ["h264.gop30", "h264.gop90"])
    func pictureStalls(variant: String) async throws {
        try await measurePictureStalls(variant: variant)
    }

    /// HEVC の符号化器が無い機械では、H.264 の側を巻き込まずに、この 1 本だけを理由つきで飛ばす。
    @Test(
        "2764 MovieReader.picture(at:) の止まり — 鍵のコマで決める読み方と、1 秒で分ける読み方 (変更前・HEVC)",
        .enabled(if: TestMovie.canWriteHEVC, "この機械には HEVC の符号化器が無い"))
    func pictureStallsHEVC() async throws {
        try await measurePictureStalls(variant: "hevc.gop30")
    }

    private func measurePictureStalls(variant: String) async throws {
        let hevc = variant.hasPrefix("hevc")
        for (width, height) in Self.sizes {
            let url = try await TestMovie.write(
                frames: 90, width: width, height: height, codec: hevc ? .hevc : .h264,
                keyFrameInterval: variant.hasSuffix("gop90") ? 90 : 30, hardware: true, bitRate: width * height * 4,
                paint: MovieStall.busy)
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = try await TestMovie.keyFrameTimes(url).map { Int(($0 * 30).rounded()) }
            MovieStall.line("2764", "\(width)x\(height).\(variant)", "keyFrames", "\(keys)")
            for lookup in [MovieReader.KeyFrameLookup.track, .unavailable] {
                let scene = "\(width)x\(height).\(variant).\(lookup == .track ? "keyFrames" : "oneSecond")"
                try measure(url: url, lookup: lookup, scene: scene)
            }
        }
    }

    /// 1 本の動画を、`lookup` の読み方で測る。
    private func measure(url: URL, lookup: MovieReader.KeyFrameLookup, scene: String) throws {
        let clock = ContinuousClock()
        let reader = try MovieReader(url: url, path: url.path, keyFrames: lookup)
        defer { reader.close() }
        // 暖機 (最初の読み直しは仕組みの立ち上げを含む)
        for position in [0.0, 2.5, 0, 1.4, 0] { _ = try reader.picture(at: position) }

        var steady: [Double] = []
        for frame in 0..<89 {
            let position = Double(frame) / 30
            steady.append(MovieStall.ms(try clock.measure { _ = try reader.picture(at: position) }))
        }
        MovieStall.report("2764", scene, "steady", steady)

        /// `from` に置いてから `to` へ飛ぶ時間 (`runs` 回) と、その飛びで読み直したか。
        func stall(_ name: String, from: Double, to: Double, runs: Int = 8) throws {
            var values: [Double] = []
            var restarted = 0
            for _ in 0..<runs {
                _ = try reader.picture(at: from)
                let before = reader.restarts
                values.append(MovieStall.ms(try clock.measure { _ = try reader.picture(at: to) }))
                restarted += reader.restarts - before
            }
            MovieStall.report("2764", scene, name, values)
            MovieStall.line("2764", scene, "\(name).restartsPerJump", "\(Double(restarted) / Double(runs))")
        }
        try stall("loopSeam(2.95->0)", from: 2.95, to: 0)
        try stall("jumpBack(2.9->2.5)", from: 2.9, to: 2.5)
        try stall("jumpAhead(0->2.5)", from: 0, to: 2.5)
        try stall("jumpAheadWithin1s(0->0.9)", from: 0, to: 0.9)
        try stall("crossKey(0.5->1.4)", from: 0.5, to: 1.4)
        try stall("nearKey(0.9->1.15)", from: 0.9, to: 1.15)
        try stall("afterKey(1.0->1.3)", from: 1.0, to: 1.3)
    }
}

/// 実時間の時計で、`Movie.supply()` 1 回の main の時間を測る (#2523 完了条件 1)。**検査ではなく計測で、
/// 既定では走らない** (開き方は ``MovieStallMeasurement`` と同じ)。`Movie` を走るスケッチに足すので GPU が要る。
///
/// 動画の入り口の前後に時刻を読む入り口を足し (``Stopwatch``)、その差を supply 1 回の時間とする
/// (入り口は足した順に回る)。画面の更新の代わりに、1 フレームごとに 1/60 秒の刻みまで眠る。
/// 先読みを止めた回 (`allowsPrefetch = false` = 変更前の同期の読み) を同じ実行で並べる。
@Suite(
    "動画の supply の止まり (計測)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUME_MOVIE_STALLS"] != nil, "MOKUME_MOVIE_STALLS で開く"),
    .enabled(if: !MovieStall.isDebugBuild, "性能は release で測る"),
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い"),
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MovieSupplyStallMeasurement {
    @Test(
        "2523 Movie.supply() の main の時間 — 実時間の時計の先読みと、同期の読み (変更前)",
        arguments: ["h264.gop30", "h264.gop90", "hevc.gop30"])
    func supplyStalls(variant: String) async throws {
        let hevc = variant.hasPrefix("hevc")
        try #require(!hevc || TestMovie.canWriteHEVC, "この機械には HEVC の符号化器が無い")
        for (width, height) in MovieStallMeasurement.sizes {
            let url = try await TestMovie.write(
                frames: 90, width: width, height: height, codec: hevc ? .hevc : .h264,
                keyFrameInterval: variant.hasSuffix("gop90") ? 90 : 30, hardware: true, bitRate: width * height * 4,
                paint: MovieStall.busy)
            defer { try? FileManager.default.removeItem(at: url) }
            for prefetch in [true, false] {
                let scene = "\(width)x\(height).\(variant).\(prefetch ? "prefetch" : "sync")"
                try measureSupply(url: url, prefetch: prefetch, scene: scene)
            }
        }
    }

    /// 1 本の動画を、先読みあり / なしで流して測る。
    private func measureSupply(url: URL, prefetch: Bool, scene: String) throws {
        let before = Stopwatch()
        let after = Stopwatch()
        var movie: Movie?
        MovieSketch.frameRate = 60
        MovieSketch.onSetup = { sketch in
            sketch.attach(before)
            let made = try sketch.createVideo(url.path)
            made.allowsPrefetch = prefetch
            sketch.attach(after)
            movie = made
        }
        MovieSketch.onDraw = { _ in }
        let origin = ContinuousClock.now
        let now = { MovieStall.seconds(ContinuousClock.now - origin) }
        let runtime = try SketchRuntime(sketch: MovieSketch(), gpu: try RenderDevice(), clock: .wallClock, now: now)
        defer { runtime.closePlugins() }
        try runtime.advance()  // `setup()` は最初のフレームで走る
        let movieRef = try #require(movie)
        var tick = 1

        /// 1 フレーム進め、supply の時間 (ms) と新しいコマが出たかを返す。1/60 秒の刻みまで眠る。
        func frame() throws -> (ms: Double, isNew: Bool) {
            tick += 1
            let due = origin + .microseconds(Int64(Double(tick) * 1_000_000 / 60))
            let wait = due - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: MovieStall.seconds(wait)) }
            try runtime.advance()
            return (MovieStall.ms(after.last - before.last), movieRef.isNewFrame)
        }
        /// `count` フレーム進める。
        func frames(_ count: Int) throws -> [(ms: Double, isNew: Bool)] { try (0..<count).map { _ in try frame() } }

        // 継ぎ目: ループで 8 秒 (継ぎ目 2 つ) 流し、継ぎ目の前後 3 フレームとそれ以外を分けて集める
        movieRef.loop()
        let laps = try frames(60 * 8)
        var seam: [Double] = []
        var steady: [Double] = []
        for (index, row) in laps.enumerated() {
            // 流し始めてからの位置 (1/60 秒の刻みで進めているので、フレームの数から読める)
            let phase = (Double(index) / 60).truncatingRemainder(dividingBy: 3)
            let nearSeam = phase < 0.06 || phase > 2.94
            // 最初の 1 秒は係の立ち上がりを含むので数えない
            if index > 60 { nearSeam ? seam.append(row.ms) : steady.append(row.ms) }
        }
        MovieStall.report("2523", scene, "steady.supply", steady)
        MovieStall.report("2523", scene, "loopSeam.supply", seam)
        // フレームごとの列 (図にする。1 行に、supply の ms と新しいコマが出たかを並べる)
        MovieStall.line(
            "2523", scene, "loop.series",
            laps.map { String(format: "%.2f%@", $0.ms, $0.isNew ? "" : "*") }.joined(separator: ","))

        // 速さ 2 倍・4 倍 (#2451): 1 フレームに進むコマが増える。継ぎ目を含めて 6 秒ずつ流す。最初の 0.5 秒は
        // 速さを変えた直後を含むので数えない。前のコマのまま (`isNewFrame == false`) だったフレームも数える
        for rate: Float in [2, 4] {
            movieRef.speed(rate)
            let rows = try frames(60 * 6).dropFirst(30)
            let name = "speed\(Int(rate))x"
            MovieStall.report("2523", scene, "\(name).supply", rows.map(\.ms))
            MovieStall.line("2523", scene, "\(name).staleFrames", "\(rows.count { !$0.isNew })", "frames")
        }
        movieRef.speed(1)

        /// 止めて `from` に置き、落ち着いてから `to` へ飛ぶ。飛んだフレームから 30 フレームの supply と、
        /// 新しいコマが出るまでのフレーム数を 8 回集める。
        func jump(_ name: String, from: Float, to: Float) throws {
            var worst: [Double] = []
            var arrival: [Double] = []
            movieRef.pause()
            for _ in 0..<8 {
                movieRef.jump(from)
                _ = try frames(30)
                movieRef.jump(to)
                let rows = try frames(30)
                worst.append(rows.map(\.ms).max() ?? 0)
                arrival.append(Double(rows.firstIndex(where: \.isNew) ?? rows.count))
            }
            MovieStall.report("2523", scene, "\(name).supplyMax", worst)
            MovieStall.line("2523", scene, "\(name).framesToArrive", "\(arrival.sorted()[arrival.count / 2])", "frames")
        }
        try jump("jumpBack(2.9->2.5)", from: 2.9, to: 2.5)
        try jump("jumpAhead(0->2.5)", from: 0, to: 2.5)
        try jump("jumpAheadWithin1s(0->0.9)", from: 0, to: 0.9)
    }
}

/// 回るたびに時刻を控える入り口。
final class Stopwatch: Inlet {
    private(set) var last = ContinuousClock.now
    func supply() { last = ContinuousClock.now }
    func close() {}
    var failure: String? { nil }
    var report: SourceReport? { nil }
}

/// 計測の道具。
nonisolated enum MovieStall {
    /// 最適化していない実行ファイルか (`assert` は最適化すると消える)。
    static let isDebugBuild: Bool = {
        var debug = false
        assert(
            {
                debug = true
                return true
            }())
        return debug
    }()

    /// 行ごとに一色で塗り、枚ごとに 37 画素跳ぶ白い帯を置く (#2523 の「実測」の動画と同じ柄)。
    static func busy(_ buffer: CVPixelBuffer, _ index: Int) {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bar = min(64, width)
        let barX = (index * 37) % max(1, width - bar)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            let level = UInt32(truncatingIfNeeded: (y + index * 3) & 0xff)
            row.update(
                repeating: 0xff00_0000 | level << 16 | UInt32((y >> 2) & 0xff) << 8 | UInt32((index * 5) & 0xff),
                count: width)
            (row + barX).update(repeating: 0xffff_ffff, count: bar)
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1e3 + Double(parts.attoseconds) / 1e15
    }

    /// 中央値・p90・最大・回数を出す。
    static func report(_ id: String, _ scene: String, _ metric: String, _ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return }
        let p90 = sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1))]
        line(id, scene, "\(metric).median", String(format: "%.2f", sorted[sorted.count / 2]), "ms")
        line(id, scene, "\(metric).p90", String(format: "%.2f", p90), "ms")
        line(id, scene, "\(metric).max", String(format: "%.2f", sorted[sorted.count - 1]), "ms")
    }

    static func line(_ id: String, _ scene: String, _ metric: String, _ value: String, _ unit: String = "") {
        print("PERF\t\(id)\t\(scene)\t\(metric)\t\(value)\t\(unit)")
    }
}
