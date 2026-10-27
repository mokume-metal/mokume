// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MokumeCamera
import MokumeCore

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
