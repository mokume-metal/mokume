// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 書き出した `.mov` の時刻の刻み ([#2307])。**GPU を要さない** — 出口が受け取る絵と時刻を
/// ``MovieWriter`` へ直接渡し、書き上がったファイルの箱 (`mvhd`・`mdhd`・`stts`) を読む。
///
/// 刻みを書き手へ渡さないと、`CMTime` を 90 000 で作っても、トラックは AVFoundation の既定の
/// 600 で書かれる。600 を割り切らない fps では 1 枚の長さが揃わず (48 fps で 12 と 13 が交互)、
/// 600 を越える fps では隣の枚が同じ時刻へ丸まって枚が消えた (1000 fps で 20 枚が 12 枚)。
/// それまでの動画の検査の fps (5・24・30・60・120) はどれも 600 を割り切るので、刻みが 600 の
/// ままでも緑だった。ここでは 600 を割り切らない fps と、600 を越える fps を撮る。
///
/// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
@Suite(
    "動画の時刻の刻み",
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct MovieTimescaleTests {

    /// `frames` 枚を n/fps の時刻で書いて閉じ、書き上がったファイルの時刻の箱を読む。
    ///
    /// 時刻は、フレーム番号の時計が作る値と同じ `Double(n) / Double(fps)` で渡す
    /// (``FrameTiming`` の `timeline`)。
    private func record(fps: Int, frames: Int, in directory: URL) throws -> MovieBoxes.Timing {
        let path = directory.appendingPathComponent("rate-\(fps).mov").path
        let writer = MovieWriter(path: path, frameRate: fps)
        for index in 0..<frames {
            writer.write(
                DisplayImage(
                    width: 32, height: 18,
                    bytes: [UInt8](repeating: UInt8(index * 10 % 256), count: 32 * 18 * 4)),
                frame: index + 1, time: Double(index) / Double(fps))
        }
        writer.finish()
        #expect(writer.takeFailure() == nil, "書き損じた")
        return try #require(
            MovieBoxes.timing(of: try Data(contentsOf: URL(fileURLWithPath: path))),
            "mvhd・mdhd・stts を読めない")
    }

    @Test("48 fps で 24 枚撮ると、刻みは 90 000 で、24 枚とも 1875 刻み")
    func fortyEightFramesASecondLastTheSame() throws {
        try withTemporaryDirectory("mokume-timescale-48") { directory in
            let movie = try record(fps: 48, frames: 24, in: directory)
            #expect(movie.mediaTimescale == Int(MovieFile.timescale))
            #expect(movie.movieTimescale == Int(MovieFile.timescale))
            #expect(movie.durations == Array(repeating: 1875, count: 24))
        }
    }

    /// **600 を越える fps でも枚が消えず、1 枚の長さも揃う。** 刻みが 600 だと 1/1000 秒ずつの
    /// 時刻が隣と同じ 1/600 秒へ丸まる。起票の機械 (macOS 26.6) では 20 枚が 12 枚になり、手元の
    /// macOS 27.0 では 20 枚とも 1/600 秒の長さで並んだ (動画の長さが 0.02 秒でなく 0.033 秒)。
    @Test("1000 fps で 20 枚撮ると、20 枚とも入り、どれも 90 刻み")
    func aThousandFramesASecondAreAllKept() throws {
        try withTemporaryDirectory("mokume-timescale-1000") { directory in
            let movie = try record(fps: 1000, frames: 20, in: directory)
            #expect(movie.mediaTimescale == Int(MovieFile.timescale))
            #expect(movie.durations == Array(repeating: 90, count: 20))
        }
    }

    /// 境目: **刻みちょうどの fps** は 1 枚 1 刻みで、まだ隣の枚と同じ時刻にならない。
    /// これを越える fps は、撮り始める前に断る (``FrameRateLimitTests``)。
    @Test("90 000 fps で 3 枚撮ると、3 枚とも入り、どれも 1 刻み")
    func theTimescaleItselfIsTheFastestRate() throws {
        try withTemporaryDirectory("mokume-timescale-limit") { directory in
            let movie = try record(fps: FrameRecorder.movieFrameRateLimit, frames: 3, in: directory)
            #expect(movie.mediaTimescale == Int(MovieFile.timescale))
            #expect(movie.durations == [1, 1, 1])
            // 容れ物も同じ刻みで 3 刻みの長さを名乗る (刻みが 600 だと長さ 0 の動画になった)
            #expect(movie.movieTimescale == Int(MovieFile.timescale))
            #expect(movie.movieDuration == 3)
        }
    }

    /// **90 000 を割り切らない fps は、1 刻み (約 11 µs) の揺れが残る** (#2307 の判断)。
    /// 揺れても、各枚の時刻と動画の終わりは n/fps から半刻み以内に収まる。刻みが 600 なら
    /// 1/1200 秒 (= 75 刻み) までずれる。
    @Test("90 000 を割り切らない 7 fps でも、各枚の時刻と終わりは n/7 秒から半刻み以内")
    func aRateThatDoesNotDivideTheTimescaleStaysWithinHalfATick() throws {
        try withTemporaryDirectory("mokume-timescale-7") { directory in
            let movie = try record(fps: 7, frames: 10, in: directory)
            try #require(movie.durations.count == 10)
            let scale = Double(MovieFile.timescale)
            // 各枚の始まり (0…9 枚目) と、最後の枚の終わり (10 枚目の位置)
            let edges = movie.durations.reduce(into: [0]) { $0.append($0.last! + $1) }
            for (index, edge) in edges.enumerated() {
                let want = Double(index) / 7
                #expect(
                    abs(Double(edge) / Double(movie.mediaTimescale) - want) <= 0.5 / scale + 1e-12,
                    "\(index) 枚目の位置が \(edge)/\(movie.mediaTimescale) 秒 (\(want) 秒のはず)")
            }
            // 容れ物の長さも同じ刻みで数える。容れ物の刻みが 600 なら、ここが 1/1200 秒ずれうる
            #expect(
                abs(Double(movie.movieDuration) / Double(movie.movieTimescale) - 10.0 / 7)
                    <= 0.5 / scale + 1e-12,
                "動画の長さが \(movie.movieDuration)/\(movie.movieTimescale) 秒 (10/7 秒のはず)")
        }
    }
}

/// 動画として書ける fps の上限 ([#2307])。**GPU も符号化器も要さない** — 撮り始めるかどうかは、
/// 最初の 1 枚が届く前 (ファイルを開く前) に決まる。
///
/// 上限を越える fps では、刻みを直しても隣の枚が同じ時刻へ丸まる。撮ると枚が消えるか、開けない
/// `.mov` が残るだけなので、番号の入る場所が無い連番と同じく撮り始めない。
///
/// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
@Suite("動画として書ける fps の上限")
struct FrameRateLimitTests {
    @Test("上限は時刻の刻みそのもの (90 000)")
    func theLimitIsTheTimescale() {
        #expect(FrameRecorder.movieFrameRateLimit == Int(MovieFile.timescale))
        #expect(FrameRecorder.movieFrameRateLimit == 90_000)
    }

    @Test("上限を越える fps で .mov を撮り始めると、撮らずに上限を名乗って 1 度知らせる")
    func aMovieFasterThanTheTimescaleIsRefused() throws {
        let recorder = FrameRecorder(frameRate: FrameRecorder.movieFrameRateLimit + 1)
        recorder.beginRecord("/tmp/mokume-too-fast.mov", at: 1)
        #expect(!recorder.isRecording)
        let said = try #require(
            recorder.warnings.message(for: .movieFrameRateTooHigh), "断ったことを知らせていない")
        #expect(said.contains("90000"))
        #expect(said.contains("90001"))
        #expect(said.contains("/tmp/mokume-too-fast.mov"))

        // 頼み直しても撮らず、知らせは増えない (控えは撮り始めたときにだけ空に戻る)
        recorder.beginRecord("/tmp/mokume-too-fast.mov", at: 2)
        #expect(!recorder.isRecording)
        #expect(recorder.warnings.count { $0 == .movieFrameRateTooHigh } == 1)
    }

    /// 境目: 上限ちょうどは撮る。連番は時刻を書かないので、上限を越えても撮る。
    @Test("上限ちょうどの .mov と、上限を越える連番は撮り始める")
    func theLimitItselfAndSeriesAreTaken() {
        let atTheLimit = FrameRecorder(frameRate: FrameRecorder.movieFrameRateLimit)
        atTheLimit.beginRecord("/tmp/mokume-at-limit.mov", at: 1)
        #expect(atTheLimit.isRecording)
        #expect(!atTheLimit.warnings.hasWarned(.movieFrameRateTooHigh))
        atTheLimit.endRecord()

        let series = FrameRecorder(frameRate: FrameRecorder.movieFrameRateLimit + 1)
        series.beginRecord("/tmp/mokume-fast-series/f-####.png", at: 1)
        #expect(series.isRecording)
        #expect(!series.warnings.hasWarned(.movieFrameRateTooHigh))
        series.endRecord()
    }

    /// 走らせる前に確かめる口 (`mokume render`) も、撮る係と同じ規則で見る。
    @Test("行き先と fps の組を受けるかは、.mov のときだけ上限で決まる")
    func acceptsLooksAtTheRateOnlyForMovies() {
        let limit = FrameRecorder.movieFrameRateLimit
        #expect(FrameRecorder.accepts("/tmp/a.mov", frameRate: limit))
        #expect(!FrameRecorder.accepts("/tmp/a.mov", frameRate: limit + 1))
        #expect(!FrameRecorder.accepts("/tmp/A.MOV", frameRate: limit + 1))
        #expect(FrameRecorder.accepts("/tmp/f-####.png", frameRate: limit + 1))
        #expect(!FrameRecorder.accepts("/tmp/still.png", frameRate: 30))
    }
}

/// `.mov` の箱を読む道具 (#2307 の再現から持ち込んだ)。**絵は読まない** — 見るのは刻みと、
/// 1 枚ごとの長さだけである。`AVAsset` を通すと秒へ直した値になり、刻みそのものが見えない。
enum MovieBoxes {
    /// 読んだ時刻の箱。
    struct Timing {
        /// 容れ物 (`mvhd`) の刻み。
        let movieTimescale: Int
        /// 容れ物 (`mvhd`) が名乗る動画の長さ (容れ物の刻みで)。
        let movieDuration: Int
        /// 動画のトラック (`mdhd`) の刻み。
        let mediaTimescale: Int
        /// 1 枚ごとの長さ (`stts` を広げたもの・トラックの刻みで)。
        let durations: [Int]
    }

    /// 書き上がった `.mov` のバイトから、刻みと 1 枚ごとの長さを読む。読めなければ `nil`。
    static func timing(of data: Data) -> Timing? {
        guard let movie = find(["moov", "mvhd"], in: data),
            let media = find(["moov", "trak", "mdia", "mdhd"], in: data),
            let table = find(["moov", "trak", "mdia", "minf", "stbl", "stts"], in: data)
        else { return nil }
        let (movieScale, movieDuration) = scaleAndDuration(data, header: movie)
        let entries = word(data, table + 4)
        let durations = (0..<entries).flatMap { index in
            Array(
                repeating: word(data, table + 12 + index * 8),
                count: word(data, table + 8 + index * 8))
        }
        return Timing(
            movieTimescale: movieScale, movieDuration: movieDuration,
            mediaTimescale: scaleAndDuration(data, header: media).scale, durations: durations)
    }

    /// `mvhd` / `mdhd` の刻みと長さ。版 0 は作成・更新が 4 バイトずつ、版 1 は 8 バイトずつ。
    private static func scaleAndDuration(_ data: Data, header: Int) -> (scale: Int, duration: Int) {
        if data[header] == 1 {
            return (word(data, header + 20), word(data, header + 24) << 32 | word(data, header + 28))
        }
        return (word(data, header + 12), word(data, header + 16))
    }

    /// 箱の道 (`moov/trak/…`) を降りて、最後の箱の中身の頭の位置を返す。
    private static func find(_ path: [String], in data: Data) -> Int? {
        var (offset, end) = (data.startIndex, data.endIndex)
        var rest = path[...]
        while offset + 8 <= end, let wanted = rest.first {
            var size = word(data, offset)
            var header = 8
            if size == 1 {  // 64 ビットの大きさ
                size = word(data, offset + 8) << 32 | word(data, offset + 12)
                header = 16
            }
            guard size >= header else { return nil }
            if String(decoding: data[offset + 4..<offset + 8], as: UTF8.self) == wanted {
                rest = rest.dropFirst()
                if rest.isEmpty { return offset + header }
                (offset, end) = (offset + header, offset + size)
            } else {
                offset += size
            }
        }
        return nil
    }

    /// 大きい側から並んだ 4 バイトの符号なし整数。
    private static func word(_ data: Data, _ at: Int) -> Int {
        data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
    }
}

/// 検査のあいだだけ使う一時ディレクトリ。
private func withTemporaryDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
