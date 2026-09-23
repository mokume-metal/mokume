// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Testing

@testable import MokumeCore

/// 撮る係の刻みは、**起動のときに読んだ `settings.frameRate`** である ([#1457])。
///
/// 各枚の時刻は時計が決め、時計の刻みは起動のときに決まる。動画の最後の 1 枚の長さは撮る係が
/// 足す「1 フレームぶん」で、これだけが別の時点の値を読むと、`var settings` と持って走っている
/// 最中に代入したスケッチでは、各枚の間隔は起動のときのまま最後の 1 枚だけが伸び縮みする。
/// 測るのは読み戻した `.mov` の「終わり − 最後の枚の時刻」で、各枚の間隔と揃うことも見る。
///
/// [#1457]: https://github.com/mokume-metal/mokume/issues/1457
@Suite(
    "撮る係の刻みは起動のときの frameRate",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct RecordingFrameRateTests {

    /// 設定を `var` で持つスケッチ。**`draw()` の中から代入できる。**
    final class RetimedSketch: Sketch {
        nonisolated(unsafe) static var launchFrameRate = 60
        nonisolated(unsafe) static var body: (RetimedSketch) -> Void = { _ in }

        var settings: SketchSettings

        init() {
            settings = SketchSettings(width: 64, height: 48, frameRate: Self.launchFrameRate)
        }

        func draw() {
            background(.display(red: 0.06, green: 0.06, blue: 0.09))
            Self.body(self)
        }
    }

    /// 起動のときの刻みを決めて組み、`frames` 回進めてから差込口を閉じる。
    ///
    /// 時計は渡さない — フレーム番号から導く既定の時計になり、各枚の時刻が
    /// `(frameCount - 1) / 起動のときの frameRate` に決まる。
    private func run(
        launchFrameRate: Int, frames: Int, _ body: @escaping (RetimedSketch) -> Void
    ) throws {
        RetimedSketch.launchFrameRate = launchFrameRate
        RetimedSketch.body = body
        let runtime = try SketchRuntime(sketch: RetimedSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
        runtime.closePlugins()
    }

    @Test("代入しなければ、最後の 1 枚は起動のときの 1 フレームぶんで、各枚の間隔と揃う")
    func theLastFrameLastsOneLaunchFrame() async throws {
        try await withTemporaryDirectory("mokume-rate-untouched") { directory in
            let path = directory.appendingPathComponent("untouched.mov").path
            // **撮る係の既定 (60) と違う値で起動する。** 60 のままだと、起動のときの値を
            // 渡し忘れて既定に落ちても緑になる
            try run(launchFrameRate: 30, frames: 11) { sketch in
                if sketch.frameCount == 1 { sketch.beginRecord(path) }
                if sketch.frameCount == 11 { sketch.endRecord() }
            }

            let movie = try await readTiming(path)
            #expect(movie.times.count == 10)
            expectEveryFrameLasts(movie, 1.0 / 30)
        }
    }

    @Test("最初の beginRecord の前に frameRate を代入しても、最後の 1 枚は起動のときの 1 フレームぶん")
    func anAssignmentBeforeTheFirstRecordingDoesNotStretchTheLastFrame() async throws {
        try await withTemporaryDirectory("mokume-rate-assigned") { directory in
            let path = directory.appendingPathComponent("assigned.mov").path
            try run(launchFrameRate: 60, frames: 11) { sketch in
                if sketch.frameCount == 1 {
                    // 読み返せば 5 が返るが、時計は起動のときの 60 で刻み続ける
                    sketch.settings.frameRate = 5
                    sketch.beginRecord(path)
                }
                if sketch.frameCount == 11 { sketch.endRecord() }
            }

            let movie = try await readTiming(path)
            #expect(movie.times.count == 10)
            expectEveryFrameLasts(movie, 1.0 / 60)
        }
    }

    /// **撮る係を作るのが `save` でも同じ。** 係は `save` と `beginRecord` のどちらか先に
    /// 頼まれたほうで作られ、以後の録りへ持ち回られる。
    ///
    /// 枚数は数えない — `save` の次の `beginRecord` の 1 枚目は別の事象で、#1456 が扱う。
    @Test("save で撮る係ができた後に動画を撮っても、最後の 1 枚は起動のときの 1 フレームぶん")
    func anAssignmentBeforeTheFirstSaveDoesNotReachTheMovie() async throws {
        try await withTemporaryDirectory("mokume-rate-saved-first") { directory in
            let still = directory.appendingPathComponent("still.png").path
            let path = directory.appendingPathComponent("after-save.mov").path
            // 起動のときより**速い**値を代入する — 最後の 1 枚が縮む側も見る
            try run(launchFrameRate: 30, frames: 11) { sketch in
                if sketch.frameCount == 1 {
                    sketch.settings.frameRate = 120
                    sketch.save(still)
                }
                if sketch.frameCount == 2 { sketch.beginRecord(path) }
                if sketch.frameCount == 11 { sketch.endRecord() }
            }

            let movie = try await readTiming(path)
            try #require(movie.times.count >= 2, "動画に 2 枚以上入っていない")
            expectEveryFrameLasts(movie, 1.0 / 30)
        }
    }

    /// **2 本目も、2 本目を始めたときの値ではなく起動のときの値に従う。** 1 本目を撮ってから
    /// 代入し、2 本目を撮る。
    @Test("1 本目の後に frameRate を代入しても、2 本目の最後の 1 枚は起動のときの 1 フレームぶん")
    func theSecondMovieKeepsTheLaunchFrameRate() async throws {
        try await withTemporaryDirectory("mokume-rate-second-movie") { directory in
            let first = directory.appendingPathComponent("first.mov").path
            let second = directory.appendingPathComponent("second.mov").path
            try run(launchFrameRate: 60, frames: 14) { sketch in
                switch sketch.frameCount {
                case 1: sketch.beginRecord(first)
                case 6: sketch.endRecord()
                case 7: sketch.settings.frameRate = 5
                case 8: sketch.beginRecord(second)
                case 14: sketch.endRecord()
                default: break
                }
            }

            let a = try await readTiming(first)
            let b = try await readTiming(second)
            #expect(a.times.count == 5)
            #expect(b.times.count == 6)
            expectEveryFrameLasts(a, 1.0 / 60)
            expectEveryFrameLasts(b, 1.0 / 60)
        }
    }
}

// MARK: - 共通の道具

/// 読み戻した動画の時刻。**絵は読まない** — 見るのは各枚の時刻と動画の終わりだけである。
private struct MovieTiming {
    /// 各枚の表示時刻 (秒)。
    let times: [Double]
    /// 動画の終わり (秒)。最後の枚の時刻に、書き出す係が足した 1 フレームぶんを加えたところ。
    let end: Double

    /// 最後の 1 枚の長さ。
    var lastFrameDuration: Double? { times.last.map { end - $0 } }
    /// 隣り合う枚の間隔。
    var intervals: [Double] { zip(times.dropFirst(), times).map { $0 - $1 } }
}

/// 最後の 1 枚の長さも各枚の間隔も `duration` であることを見る。
///
/// 動画の時刻の刻み (90000 分の 1 秒) と、`Float` の時刻を丸めたぶんを許す。
private func expectEveryFrameLasts(
    _ movie: MovieTiming, _ duration: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let tolerance = 1e-4
    guard let last = movie.lastFrameDuration else {
        Issue.record("動画に 1 枚も入っていない", sourceLocation: sourceLocation)
        return
    }
    #expect(
        abs(last - duration) < tolerance,
        "最後の 1 枚の長さが \(last) 秒 (\(duration) 秒のはず)", sourceLocation: sourceLocation)
    for interval in movie.intervals {
        #expect(
            abs(interval - duration) < tolerance,
            "枚の間隔が \(interval) 秒 (\(duration) 秒のはず)", sourceLocation: sourceLocation)
    }
}

/// 書き出した動画の時刻を読む。**符号化を通った実物を見る。**
private func readTiming(_ path: String) async throws -> MovieTiming {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let duration = try await asset.load(.duration)

    let reader = try AVAssetReader(asset: asset)
    // 絵を解かずに試料のまま受け取る。時刻は試料が持っている
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()

    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
    }
    return MovieTiming(times: times, end: CMTimeGetSeconds(duration))
}

/// 検査のあいだだけ使う一時ディレクトリ。
private func withTemporaryDirectory(
    _ name: String, _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
