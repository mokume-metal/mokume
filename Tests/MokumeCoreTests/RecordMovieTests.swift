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

    /// **塞がずに見に来る閉じ方も、閉じ終えたと答えた時点で全部入っている** ([#978])。
    ///
    /// 終わりの経路はこの答えを見て AppKit へ「終わってよい」と返す。閉じる前に `true` を
    /// 返せば、返事の直後にプロセスが消えて、再生できないファイルが残る。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("塞がずに見に来て閉じ終えたと答えた時点で、ファイルは閉じていて全部入っている")
    func peekingReportsClosedOnlyAfterTheFileIsClosed() async throws {
        try await withTemporaryDirectory("mokume-movie-peek") { directory in
            let path = directory.appendingPathComponent("peeked.mov").path
            let writer = MovieWriter(path: path, frameRate: 60)
            for frame in 1...12 {
                writer.write(image(UInt8(frame * 8)), frame: frame, time: Double(frame - 1) / 60)
            }
            // **符号化を済ませてから閉じ始める。** 見に来る間隔 (2 ms) の間に残りの符号化と
            // 最終化 (手元で最短約 3 ms) が両方済むと、閉じた合図を見ずに答えていても閉じ終えて
            // 見える (実測)。符号化が済んでいれば、最初に見に来た同じ呼び出しの中で閉じる段へ
            // 進むので、合図を見ずに答えれば最終化より前になる
            try await Task.sleep(for: .milliseconds(300))

            // **答えた瞬間に見る。** 読み戻し (`decodeMovie`) は `await` を挟むので、その間に
            // 最終化が追いつき、閉じる前に答えていても揃って見える
            var closedWhenAnswered: Bool?
            try #require(
                pollUntilSettled(within: MovieWriter.closeLimitSeconds + 10) {
                    guard writer.finish(.peek) else { return false }
                    closedWhenAnswered = movieHasClosed(path)
                    return true
                },
                "閉じる期限を過ぎても決着しない")
            #expect(closedWhenAnswered == true, "閉じ終える前に、閉じ終えたと答えた")

            let movie = try await decodeMovie(path)
            #expect(movie.frames.count == 12)
            // 決着した後に呼んでも、もう一度閉じようとしない
            #expect(writer.finish(.peek))
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

    /// **転んだ符号化器へ書き足した枚は、符号化器の言った理由で書き損じになる** ([#1299])。
    ///
    /// 転んだ writer は画素の器を手放す (macOS 27 で実測)。`status` を見ずに器を借りに行くと
    /// 「器を借りられない」(`bufferUnavailable`) として決着し、ディスクが埋まった (`Disk Full`)
    /// のような本当の理由が落ちる。差込口を外すときに名乗るのは最後に決着した枚の理由なので、
    /// 落ちた理由はどこにも出ない。
    ///
    /// 決着は隔離の外で走るので、**待つ側が期限を持って**、1 枚ずつ決着を見てから次を書く
    /// (``writeAndSettle(_:_:frame:time:)``)。
    ///
    /// [#1299]: https://github.com/mokume-metal/mokume/issues/1299
    @Test("転んだ符号化器へ書き足した枚は、1 枚ずつ符号化器の理由で書き損じになる")
    func framesWrittenToAFailedEncoderCarryItsReason() async throws {
        try await withTemporaryDirectory("mokume-movie-reason-after-failure") { directory in
            let path = directory.appendingPathComponent("broken.mov").path
            let writer = MovieWriter(path: path, frameRate: 60)
            defer { writer.finish() }

            #expect(try writeAndSettle(writer, image(80), frame: 1, time: 0) == .succeeded)
            #expect(try writeAndSettle(writer, image(120), frame: 2, time: 1.0 / 60) == .succeeded)
            // 時刻が戻るフレーム。この 1 枚は受け付けられ、符号化器は後から転ぶ (実測)。
            // どちらに決着するかは見ない
            _ = try writeAndSettle(writer, image(160), frame: 3, time: -1)

            // **転ぶ前に受け付けられた枚は数えない** — 直後の枚は、符号化器が転ぶ前に受け付け
            // られることがある (実測)。転んだ後に書けたことになる枚は無い
            var frame = 3
            var reasons: [String] = []
            while reasons.count < 3, frame < 8 {
                frame += 1
                let outcome = try writeAndSettle(
                    writer, image(200), frame: frame, time: Double(frame - 1) / 60)
                if let reason = outcome.failure {
                    reasons.append(reason)
                } else {
                    #expect(reasons.isEmpty, "\(frame) 枚目: 転んだ後に書けたことになった")
                }
            }
            try #require(reasons.count == 3, "5 枚書き足しても、3 枚転ばない — この入り方が効いていない")
            for reason in reasons {
                #expect(reason.contains("writeFailed"), "\(reason)")
                #expect(!reason.contains("bufferUnavailable"), "符号化器の理由を落とした: \(reason)")
            }
        }
    }
}

/// 撮り終わりに分かった失敗が、人へ届くか ([#789])。**GPU を要さない。**
///
/// 見ているのは 5 つ — 閉じられなかったことを ``FrameRecorder/endRecord()`` が言う・
/// 転んだ符号化器へ書き足しても抱えものを残さずに返る・書き込み先が読み取り専用でも
/// 黙らない・静止画と動画の**両方**の理由が載る・2 本目の録りが 1 本目のせいで黙らない。
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
            recorder.beginRecord(path, at: 1)
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
            #expect(said.contains("Could not close"))
        }
    }

    /// **転んだ符号化器へ書き足しても、待ちが固まらない** ([#1299])。
    ///
    /// 起票時の見立ては「転んだ writer の用意が戻らず、書き足した 1 枚が永久に待つ」だった。
    /// macOS 27 では用意が戻るので、`status` を見ない姿でもこの検査は緑になる — 見張って
    /// いるのは、用意のフラグがどう振る舞っても `endRecord()` が抱えものを残さずに返ることで
    /// ある。固まる姿では、転んだ後に書き足した 1 枚が決着しない (決着を見る枚なら 10 秒で、
    /// 見ない最後の 1 枚なら `endRecord()` が閉じる側の期限まで待ち切って、赤になる)。
    ///
    /// [#1299]: https://github.com/mokume-metal/mokume/issues/1299
    @Test("転んだ符号化器へ書き足しても、endRecord() が抱えものを残さずに返る")
    func endRecordLeavesNothingBehindAfterWritingToAFailedEncoder() async throws {
        try await withTemporaryDirectory("mokume-movie-write-after-failure") { directory in
            let path = directory.appendingPathComponent("broken.mov").path
            let recorder = FrameRecorder(frameRate: 60)
            recorder.beginRecord(path, at: 1)
            let movie = try #require(recorder.recordingMovie)

            // 時刻が戻るフレームで転ばせる (上の検査と同じ入り方)
            _ = try writeAndSettle(movie, image(80), frame: 1, time: 0)
            _ = try writeAndSettle(movie, image(120), frame: 2, time: 1.0 / 60)
            _ = try writeAndSettle(movie, image(160), frame: 3, time: -1)
            // **転んだと分かってから書き足す。** 時刻が戻る 1 枚の直後の枚は、符号化器が転ぶ前に
            // 受け付けられることがある (実測) ので、書き損じが決着するまで 1 枚ずつ見る
            var frame = 3
            var failed = false
            while !failed, frame < 6 {
                frame += 1
                let outcome = try writeAndSettle(
                    movie, image(200), frame: frame, time: Double(frame - 1) / 60)
                failed = outcome.failure != nil
            }
            try #require(failed, "3 枚書き足しても符号化器が転ばない — この入り方が効いていない")

            // 転んだ符号化器へもう 1 枚。**この決着は待たない** — 待つのは endRecord() の期限である
            frame += 1
            movie.write(image(220), frame: frame, time: Double(frame - 1) / 60)
            recorder.endRecord()

            #expect(movie.outstanding == 0, "書き足した 1 枚が決着しないまま、待つのを諦めた")
            let said = try #require(
                recorder.warnings.message(for: .movieFailure),
                "転んだことが誰にも読まれていない")
            #expect(said.contains(path))
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
            recorder.beginRecord(path, at: 1)
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
            // **撮り始めてから転ばせる。** 暇なうちに決着した知らせは、頼まれ始めた時点で
            // 仕切り直しとして捨てられる (#1272)
            recorder.beginRecord(blocker.appendingPathComponent("motion.mov").path, at: 1)
            let movie = try #require(recorder.recordingMovie)
            recorder.writer.write(
                image(10, width: 8, height: 8),
                to: blocker.appendingPathComponent("still.png").path)
            recorder.writer.drain()
            // **背圧を使って待つ。** 抱える枚数の上限を超えて頼めば、頼んだ側は空くまで
            // 返らない = 少なくとも 2 枚は符号化の側を通っていて、書き損じは置かれている
            for frame in 1...(movie.limit + 2) {
                movie.write(image(20), frame: frame, time: Double(frame - 1) / 60)
            }

            // **`??` で繋ぐと、ここで動画の理由が落ちる。** 左が非 nil なら右を評価しない
            recorder.absorbOutcomes()
            let both = try #require(recorder.failure)
            #expect(both.contains("still.png"))
            #expect(both.contains("motion.mov"), "動画の書き損じが落ちている")

            // どちらの口にも新しい知らせが無いフレーム。片方の「まだ決着していない」で
            // 理由を消すと、数えがそこで 0 に戻る (#1272)
            recorder.absorbOutcomes()
            let stillBoth = try #require(recorder.failure, "知らせが無いだけで直ったことになっている")
            #expect(stillBoth.contains("still.png"))
            #expect(stillBoth.contains("motion.mov"))

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
                recorder.beginRecord(blocker.appendingPathComponent(name).path, at: 1)
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

    /// **撮っている最中に終わっても、最後の 1 枚まで入る** ([#978])。
    ///
    /// 終わりの経路は `endRecord()` を通らず、差込口を閉じながら塞がずに見に来る。控えの
    /// 1 枚 (#927) を配る前に撮る係を閉じたり、閉じ終える前に手放したりすると、枚数が
    /// 欠けるかファイルが開けなくなる。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("撮っている最中に塞がずに閉じても、最後の 1 枚まで入っている")
    func closingWithoutBlockingKeepsEveryFrame() async throws {
        try await withTemporaryDirectory("mokume-movie-quit") { directory in
            let path = directory.appendingPathComponent("quit.mov").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.06, green: 0.06, blue: 0.09))
                sketch.circle(Float(sketch.frameCount) * 4, 24, 20)
                if sketch.frameCount == 1 { sketch.beginRecord(path) }
            }
            for _ in 0..<10 { try runtime.advance() }

            try #require(
                pollUntilSettled(within: MovieWriter.closeLimitSeconds + 10) {
                    runtime.closePlugins(.peek)
                },
                "閉じる期限を過ぎても決着しない")

            // 撮り始めたフレームから 10 枚目まで。10 枚目は閉じるときに配られる (#927)
            let movie = try await decodeMovie(path)
            #expect(movie.frames.count == 10)
        }
    }

    /// **閉じ終えるのを待っている間は、フレームを進めない** ([#978])。
    ///
    /// 待ちは塞がずに見に来る形なので、その間も駆動源は `advance()` を呼んでくる。進めると
    /// `draw()` が新しい録りを始め、それは誰にも閉じられないまま終わる。
    ///
    /// **最初に見に来た時点で「まだ」になることに寄りかかっている。** 見に来るのは
    /// `continuation.finish()` と同じ呼び出しの中で、その間は数 µs しかない。対して閉じた
    /// 合図までは、配ったばかりの 1 枚の符号化に加えて最終化が要る — 符号化を済ませた
    /// 64x48 の動画でも最終化だけで最短約 3 ms かかり、この検査の経路では閉じ終えるまで
    /// 0.13 秒前後だった (手元でそれぞれ 5 回)。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("閉じ終えるのを待っている間は、advance() してもスケッチが描かれない")
    func framesDoNotAdvanceWhileClosing() async throws {
        try await withTemporaryDirectory("mokume-movie-quit-frozen") { directory in
            let path = directory.appendingPathComponent("frozen.mov").path
            var draws = 0
            let runtime = try makeRuntime { sketch in
                draws += 1
                sketch.background(.display(red: 0.06, green: 0.06, blue: 0.09))
                if sketch.frameCount == 1 { sketch.beginRecord(path) }
            }
            for _ in 0..<3 { try runtime.advance() }

            try #require(!runtime.closePlugins(.peek), "最初に見に来た時点で閉じ終えていた")
            let drawsBeforeWaiting = draws
            try runtime.advance()
            #expect(draws == drawsBeforeWaiting, "閉じ終えるのを待っている間にスケッチが描かれた")

            try #require(
                pollUntilSettled(within: MovieWriter.closeLimitSeconds + 10) {
                    runtime.closePlugins(.peek)
                },
                "閉じる期限を過ぎても決着しない")
            // 閉じ終えたら、また進む
            try runtime.advance()
            #expect(draws == drawsBeforeWaiting + 1)
        }
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

/// 1 枚を書き、その決着を待って取り出す。**待つ側が期限を持つ** (`.timeLimit` は使わない)。
///
/// 決着を見てから次を書く理由は 2 つある。知らせの器は最後の 1 つしか持たない
/// (``MovieWriter/takeOutcome()``) ので、続けて書くとどの枚の決着か分からない。もう 1 つは、
/// 時刻が戻る 1 枚の直後に続けて書くと、次の枚は符号化器が転ぶ前に受け付けられ、転んだ後の
/// 待ちを通らないことである (手元で実測 — 待ちを固まる姿にしても検査が緑のままだった)。
@MainActor
private func writeAndSettle(
    _ writer: MovieWriter, _ image: DisplayImage, frame: Int, time: Double
) throws -> WriteOutcome {
    writer.write(image, frame: frame, time: time)
    var outcome: WriteOutcome?
    try #require(
        pollUntilSettled(within: 10) {
            outcome = writer.takeOutcome()
            return outcome != nil
        },
        "\(frame) 枚目が 10 秒待っても決着しない")
    return try #require(outcome)
}

/// 動画が閉じ終えているか。**末尾のメタデータ (`moov`) が書かれているかで見る。**
///
/// `AVAssetWriter` の .mov は、最終化を終えるまで `moov` を書かない (書いている途中・
/// `finishWriting` を呼んだ直後・終えた後で手元で確かめた)。「閉じ終えた」と答えた瞬間に
/// 同期で見たいときに使う — 読み戻し (``decodeMovie(_:)``) は `await` を挟むので、その間に
/// 最終化が追いついてしまう。
func movieHasClosed(_ path: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path) else { return false }
    return data.range(of: Data("moov".utf8)) != nil
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
