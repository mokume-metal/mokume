// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Testing

@testable import MokumeCore

/// 決まった時間で回す — 時刻がフレーム番号から決まること。GPU を要さない。
@Suite("決まった時間で回す")
struct FixedTimestepTests {

    @Test("フレーム番号から時刻が一意に決まる")
    func theFrameNumberDecidesTheTime() {
        // 実時間はでたらめに飛ぶ。それでも時刻が動かないことを見る
        var jumps = [0.0, 3.0, 3.001, 90.0, 91.5, 400.0].makeIterator()
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { jumps.next() ?? 0 })

        var times: [Float] = []
        for _ in 0..<5 {
            timing.advance()
            times.append(timing.time)
        }
        let expected: [Float] = (0..<5).map { Float($0) / 60 }
        #expect(times == expected)
        #expect(timing.deltaTime == Float(1) / 60)
    }

    @Test("実時間の時計を選ぶと、同じ番号でも時刻が変わる")
    func theWallClockMakesTheSameNumberDifferentTimes() {
        var jumps = [0.0, 3.0, 3.001].makeIterator()
        let timing = FrameTiming(clock: .wallClock, now: { jumps.next() ?? 0 })
        timing.advance()
        timing.advance()
        // 同じ 2 枚目でも、フレーム番号から導けば 1/60 秒。実時間なら流れたぶん
        #expect(timing.time == 3.001)
        #expect(timing.deltaTime == Float(0.001))
    }
}

/// 動きをファイルにする係。**GPU を要さない** — 出口が受け取る絵を直接渡して測る。
@Suite(
    "動きの書き出し",
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct MovieWriterTests {

    /// 一色で塗った 1 枚。
    private func image(_ level: UInt8, width: Int = 64, height: Int = 48) -> DisplayImage {
        DisplayImage(
            width: width, height: height,
            bytes: [UInt8](repeating: level, count: width * height * 4))
    }

    @Test("落ちたフレームは番号の穴として残り、残った絵の時刻は動かない")
    func aMissingFrameLeavesAHoleRatherThanShiftingTheRest() async throws {
        try await withTemporaryDirectory("mokume-movie-hole") { directory in
            let path = directory.appendingPathComponent("holes.mov").path
            let writer = MovieWriter(path: path, frameRate: 60)
            // 4 枚目と 5 枚目が描けなかったフレーム。出口へは届かない
            for frame in [1, 2, 3, 6, 7] {
                writer.write(
                    image(UInt8(frame * 20)), frame: frame, time: Double(frame - 1) / 60)
            }
            writer.finish()

            #expect(writer.acceptedFrames == 5)
            // 数える機構を持たず、最初と最後の番号の幅から導く
            #expect(writer.droppedFrames == 2)

            let movie = try await decodeMovie(path)
            #expect(movie.times.count == 5)
            // **詰めていない。** 詰めると 4 枚目以降が 2 コマぶん早く映る
            let expected = [0, 1, 2, 5, 6].map { Double($0) / 60 }
            for (got, want) in zip(movie.times, expected) {
                #expect(abs(got - want) < 1e-6)
            }
        }
    }

    @Test("長く撮っても、抱える枚数が上限を超えない")
    func theQueueNeverGrowsBeyondTheLimit() async throws {
        try await withTemporaryDirectory("mokume-movie-backpressure") { directory in
            let path = directory.appendingPathComponent("long.mov").path
            let writer = MovieWriter(path: path, frameRate: 60, limit: 2)
            for frame in 1...180 {
                writer.write(
                    image(UInt8(frame % 256), width: 256, height: 192),
                    frame: frame, time: Double(frame - 1) / 60)
                // 頼んだ時点で上限を超えていない = 待たされている
                #expect(writer.outstanding <= writer.limit)
            }
            writer.finish()
            // 上限まで抱えた = 背圧が実際に効いた (効かないなら 180 枚が積まれる)
            #expect(writer.peakOutstanding == writer.limit)
            #expect(writer.acceptedFrames == 180)
        }
    }

    @Test("止めた時点で、ファイルは閉じていて全部入っている")
    func finishReturnsOnlyAfterTheFileIsClosed() async throws {
        try await withTemporaryDirectory("mokume-movie-drain") { directory in
            let path = directory.appendingPathComponent("closed.mov").path
            let writer = MovieWriter(path: path, frameRate: 60)
            for frame in 1...12 {
                writer.write(image(UInt8(frame * 8)), frame: frame, time: Double(frame - 1) / 60)
            }
            writer.finish()

            // **待っていない。** ここで揃っていなければ、止めた直後にプロセスを
            // 終えた人は動画そのものを失う
            let movie = try await decodeMovie(path)
            #expect(movie.frames.count == 12)
        }
    }

    @Test("作業空間と同じ色を名乗る")
    func theMovieDeclaresTheWorkingColourSpace() async throws {
        try await withTemporaryDirectory("mokume-movie-colour") { directory in
            let path = directory.appendingPathComponent("colour.mov").path
            let writer = MovieWriter(path: path, frameRate: 60)
            writer.write(image(200), frame: 1, time: 0)
            writer.finish()

            let movie = try await decodeMovie(path)
            #expect(movie.colorPrimaries == (AVVideoColorPrimaries_P3_D65 as String))
        }
    }
}

/// 撮り終わりに分かった失敗が、人へ届くか ([#789])。**GPU を要さない。**
///
/// 見ているのは 4 つ — 閉じられなかったことを ``FrameRecorder/endRecord()`` が言う・
/// 書き込み先が読み取り専用でも黙らない・静止画と動画の**両方**の理由が載る・
/// 2 本目の録りが 1 本目のせいで黙らない。
///
/// **どれも撮り終わりでしか見られない。** 動画は閉じた時点で手放すので、そこで
/// 読まなかった書き損じは ``FrameRecorder/receive(_:)`` からも読めない。
///
/// [#789]: https://github.com/mokume-metal/mokume/issues/789
@Suite(
    "撮り終わりの失敗",
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct RecordingFailureTests {

    /// 一色で塗った 1 枚。
    private func image(_ level: UInt8, width: Int = 64, height: Int = 48) -> DisplayImage {
        DisplayImage(
            width: width, height: height,
            bytes: [UInt8](repeating: level, count: width * height * 4))
    }

    @Test("閉じられなかったことを、endRecord() の後に言う")
    func endRecordSpeaksWhenTheMovieCouldNotBeClosed() async throws {
        try await withTemporaryDirectory("mokume-movie-close-failure") { directory in
            let path = directory.appendingPathComponent("broken.mov").path
            let recorder = FrameRecorder(frameRate: 60)
            recorder.beginRecord(path)
            let movie = try #require(recorder.recordingMovie)

            movie.write(image(80), frame: 1, time: 0)
            movie.write(image(120), frame: 2, time: 1.0 / 60)
            // **時刻が戻るフレーム。** 符号化器はこれを受けた時点で失敗状態に入り、
            // 閉じるところまで立ち直らない (手元で実測)。読み取り専用の書き込み先は
            // ここでは効かない — 開いた後の fd への書き込みは権限に縛られないので、
            // 閉じるほうは成功してしまう
            movie.write(image(160), frame: 3, time: -1)

            recorder.endRecord()

            // 動画はもう手放されているので、ここで言わなければ誰も読まない
            let said = try #require(
                recorder.warnings.message(for: .movieFailure),
                "閉じられなかったことが誰にも読まれていない")
            #expect(said.contains(path))
            #expect(said.contains("閉じられませんでした"))
        }
    }

    @Test("書き込み先が読み取り専用でも、endRecord() は黙らない")
    func endRecordSpeaksWhenTheDestinationIsReadOnly() async throws {
        try await withTemporaryDirectory("mokume-movie-readonly") { directory in
            let locked = directory.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: locked.path)
            // **戻してから抜ける。** 読み取り専用のまま残すと、この検査の後片付けも
            // 同じ場所を使う後続の検査も転ぶ
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: locked.path)
            }

            let path = locked.appendingPathComponent("still.mov").path
            let recorder = FrameRecorder(frameRate: 60)
            recorder.beginRecord(path)
            try #require(recorder.recordingMovie).write(image(120), frame: 1, time: 0)

            recorder.endRecord()

            let said = try #require(
                recorder.warnings.message(for: .movieFailure),
                "書き込み先が開けなかったことが誰にも読まれていない")
            #expect(said.contains(path))
        }
    }

    @Test("静止画と動画が同じフレームで転んだら、理由は両方載る")
    func bothReasonsSurviveTheSameFrame() async throws {
        try await withTemporaryDirectory("mokume-both-failures") { directory in
            // 書き先の親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder(frameRate: 60)
            recorder.writer.write(
                image(10, width: 8, height: 8),
                to: blocker.appendingPathComponent("still.png").path)
            recorder.writer.drain()

            recorder.beginRecord(blocker.appendingPathComponent("motion.mov").path)
            let movie = try #require(recorder.recordingMovie)
            // **背圧を使って待つ。** 抱える枚数の上限を超えて頼めば、頼んだ側は空くまで
            // 返らない = 少なくとも 2 枚は符号化の側を通っていて、書き損じは置かれている
            for frame in 1...(movie.limit + 2) {
                movie.write(image(20), frame: frame, time: Double(frame - 1) / 60)
            }

            // **`??` で繋ぐと、ここで動画の理由が落ちる。** 左が非 nil なら右を評価しない
            let both = try #require(recorder.takeFailures())
            #expect(both.contains("still.png"))
            #expect(both.contains("motion.mov"), "動画の書き損じが落ちている")

            recorder.close()
        }
    }

    @Test("2 本目の録りが転んでも、1 本目で言ったからと黙らない")
    func aSecondRecordingIsNotSilencedByTheFirst() async throws {
        try await withTemporaryDirectory("mokume-second-recording") { directory in
            // 書き先の親をファイルにしておく。どちらの録りも開けない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)

            let recorder = FrameRecorder(frameRate: 60)
            for name in ["first.mov", "second.mov"] {
                recorder.beginRecord(blocker.appendingPathComponent(name).path)
                try #require(recorder.recordingMovie).write(image(60), frame: 1, time: 0)
                recorder.endRecord()

                // 控えを録りごとに戻さないと、2 周目はここで 1 本目の名前を返す
                let said = try #require(recorder.warnings.message(for: .movieFailure))
                #expect(said.contains(name))
            }
        }
    }
}

/// スケッチから動きをファイルにする経路。GPU を要する。
@Suite(
    "動きをファイルにする",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct RecordMovieTests {

    final class MovingSketch: Sketch {
        nonisolated(unsafe) static var body: (MovingSketch) -> Void = { _ in }

        var settings: SketchSettings { SketchSettings(width: 64, height: 48, frameRate: 60) }
        func draw() { Self.body(self) }
    }

    private func makeRuntime(
        _ body: @escaping (MovingSketch) -> Void
    ) throws -> SketchRuntime {
        MovingSketch.body = body
        return try SketchRuntime(sketch: MovingSketch(), gpu: try RenderDevice())
    }

    /// 動きのあるスケッチを 1 本撮って、量子化点の絵も一緒に持ち帰る。
    ///
    /// **止めたフレームは入らない。** `endRecord()` を呼ぶ時点でそのフレームはまだ
    /// 描き終えておらず、出口へは渡らないためである (連番と同じ)。
    private func record(to path: String, frames: Int) throws -> [DisplayImage] {
        let runtime = try makeRuntime { sketch in
            sketch.background(.display(red: 0.06, green: 0.06, blue: 0.09))
            sketch.noStroke()
            sketch.fill(.display(red: 1, green: 0.45, blue: 0.15))
            sketch.circle(Float(sketch.frameCount) * 4, 24, 20)
            if sketch.frameCount == 1 { sketch.beginRecord(path) }
            if sketch.frameCount == frames + 1 { sketch.endRecord() }
        }
        var fromTheRoad: [DisplayImage] = []
        for _ in 0..<frames {
            try runtime.advance()
            fromTheRoad.append(try runtime.target.encodeToImage().read())
        }
        try runtime.advance()
        runtime.closePlugins()
        return fromTheRoad
    }

    @Test("同じ入力から 2 回書き出した動きが一致する")
    func theSameInputWritesTheSameMotionTwice() async throws {
        try await withTemporaryDirectory("mokume-movie-twice") { directory in
            let first = directory.appendingPathComponent("first.mov").path
            let second = directory.appendingPathComponent("second.mov").path
            _ = try record(to: first, frames: 10)
            _ = try record(to: second, frames: 10)

            let a = try await decodeMovie(first)
            let b = try await decodeMovie(second)
            #expect(a.frames.count == 10)
            #expect(a.frames == b.frames)
            #expect(a.times == b.times)
        }
    }

    @Test("書き出した動きが、出力段の量子化点を通った絵と一致する")
    func theMovieHoldsWhatCameThroughTheQuantisationPoint() async throws {
        try await withTemporaryDirectory("mokume-movie-matches") { directory in
            let path = directory.appendingPathComponent("motion.mov").path
            let fromTheRoad = try record(to: path, frames: 6)

            let movie = try await decodeMovie(path)
            #expect(movie.frames.count == fromTheRoad.count)
            // 符号化は可逆ではないので、差が残るなら**測って名乗る** (ADR-0025 決定 3)。
            // 縁がくっきりしていた頃は最大 1 階調だった。基本図形の縁が滑らかになって
            // (#752) 中間の値を持つ画素が並ぶようになり、ProRes 4444 の差は最大 2 階調 (実測)
            var worst = 0
            for (written, expected) in zip(movie.frames, fromTheRoad) {
                #expect(written.width == expected.width)
                #expect(written.height == expected.height)
                for index in written.bytes.indices {
                    worst = max(worst, abs(Int(written.bytes[index]) - Int(expected.bytes[index])))
                }
            }
            #expect(worst <= 2)
        }
    }

    @Test(
        "透けたところは、動きにも透けたまま残る",
        .enabled(
            if: MovieFile.keepsStraightAlpha,
            "この機械の符号化器は乗算前のアルファを受けない"))
    func transparencySurvivesTheTripToTheMovie() async throws {
        try await withTemporaryDirectory("mokume-movie-alpha") { directory in
            let path = directory.appendingPathComponent("clear.mov").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.transparent)
                sketch.noStroke()
                // **半分だけ透ける白。** 乗算して渡していないことは、透明な下地では
                // 見えない (どちらでも 0 になる) ので、半透明の色で見る
                sketch.fill(.display(red: 1, green: 1, blue: 1, alpha: 0.5))
                sketch.circle(32, 24, 24)
                if sketch.frameCount == 1 { sketch.beginRecord(path) }
                if sketch.frameCount == 5 { sketch.endRecord() }
            }
            for _ in 0..<5 { try runtime.advance() }
            runtime.closePlugins()

            let movie = try await decodeMovie(path)
            let frame = try #require(movie.frames.first)
            let expected = try runtime.target.encodeToImage().read()
            #expect(frame[0, 0].alpha == 0)
            #expect(frame[63, 47].alpha == 0)
            // 半透明のまま残る。**乗算して渡していれば色が黒へ寄る** (255 → 128)
            let middle = frame[32, 24]
            #expect(middle.alpha == expected[32, 24].alpha)
            #expect(abs(Int(middle.red) - Int(expected[32, 24].red)) <= 1)
            #expect(middle.red >= 250)
        }
    }

    @Test("動画でも連番でもない名前は撮り始めない")
    func aNameThatIsNeitherMovieNorSequenceNeverStarts() async throws {
        try await withTemporaryDirectory("mokume-movie-refused") { directory in
            let path = directory.appendingPathComponent("motion.mp4").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(path) }
            }
            for _ in 0..<4 { try runtime.advance() }
            runtime.closePlugins()

            #expect(!FileManager.default.fileExists(atPath: path))
            // 撮っていないので、絵を取り出す道も 1 回も通らない (ADR-0023 決定 5)
            #expect(runtime.target.encodePassCount == 0)
        }
    }
}

// MARK: - 共通の道具

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

/// 読み戻した動画。
private struct DecodedMovie {
    let frames: [DisplayImage]
    let times: [Double]
    let colorPrimaries: String?
}

/// 書き出した動画を読み戻す。**符号化を通った実物を見る** — 渡した絵ではなく。
private func decodeMovie(_ path: String) async throws -> DecodedMovie {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let descriptions = try await track.load(.formatDescriptions)
    let primaries = descriptions.first.flatMap {
        CMFormatDescriptionGetExtension(
            $0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()

    var frames: [DisplayImage] = []
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        frames.append(read(buffer))
    }
    return DecodedMovie(frames: frames, times: times, colorPrimaries: primaries)
}

/// 符号化器が返す並び (BGRA) を、表示できる形 (RGBA) へ直す。
private func read(_ buffer: CVPixelBuffer) -> DisplayImage {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let from = y * stride + x * 4
            let to = (y * width + x) * 4
            bytes[to] = base[from + 2]
            bytes[to + 1] = base[from + 1]
            bytes[to + 2] = base[from]
            bytes[to + 3] = base[from + 3]
        }
    }
    return DisplayImage(width: width, height: height, bytes: bytes)
}
