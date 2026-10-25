// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera
import MokumeCore

/// 動画ファイルから位置でコマを読む (#1960)。GPU は要らない。動画は検査の中で作る (主に H.264)。
///
/// 鍵のコマの位置を見る検査は、動く帯の柄 (`TestMovie.stripe`) で作る — 枚ごとに絵が丸ごと変わる柄
/// (`noise`) は、符号化器が場面の変わり目と見て鍵のコマを足す。
@Suite(
    "動画のコマを位置で読む",
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MovieReaderTests {
    /// 固定の時計 (`fps` 枚/秒) の `frame` 枚目の時刻。スケッチが渡すのと同じく単精度を通す。
    private func time(_ frame: Int, fps: Int = 30) -> Double {
        Double(Float(Double(frame - 1) / Double(fps)))
    }

    @Test("各コマの表示時刻ちょうどの位置で、そのコマが出る (単精度で境目を割る時刻を含む)")
    func eachFrameAtItsOwnTime() async throws {
        let url = try await TestMovie.write(frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        #expect(expected.count == 30)
        let reader = try MovieReader(url: url, path: url.path)
        #expect(reader.width == 32 && reader.height == 16)
        #expect(abs(reader.duration - 1) < 1e-9)
        for frame in 1...30 {
            let picture = try reader.picture(at: time(frame))
            // 17・19・21… 枚目の時刻は単精度で境目をわずかに割る。それでも前のコマに戻らない
            #expect(picture == expected[frame - 1].picture, "\(frame) 枚目")
        }
    }

    @Test("同じコマの間は 2 度渡さない")
    func samePictureIsNotHandedTwice() async throws {
        let url = try await TestMovie.write(frames: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path)
        #expect(try reader.picture(at: 0) != nil)
        // 60 fps の時計なら、30 fps のコマ 1 枚が 2 フレームに映る
        #expect(try reader.picture(at: time(2, fps: 60)) == nil)
        #expect(try reader.picture(at: time(3, fps: 60)) != nil)
        #expect(try reader.picture(at: time(4, fps: 60)) == nil)
    }

    @Test("頭へ戻ると (ループの継ぎ目)、読み直して頭のコマが出る")
    func goingBackRereads() async throws {
        let url = try await TestMovie.write(frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let reader = try MovieReader(url: url, path: url.path)
        for frame in 1...30 { _ = try reader.picture(at: time(frame)) }
        #expect(try reader.picture(at: 0) == expected[0].picture)
        #expect(try reader.picture(at: time(2)) == expected[1].picture)
        // 途中へ戻っても同じ
        _ = try reader.picture(at: time(20))
        #expect(try reader.picture(at: time(5)) == expected[4].picture)
    }

    @Test("先へ大きく飛んでも (読み直し)、読み進めたときと同じコマが出る")
    func farJumpMatchesSequentialReading() async throws {
        let url = try await TestMovie.write(frames: 90)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let reader = try MovieReader(url: url, path: url.path)
        _ = try reader.picture(at: 0)
        // 間に鍵のコマがあれば読み直し、無ければ読み進める (#2764)。どちらでも同じコマが出る
        #expect(try reader.picture(at: time(70)) == expected[69].picture)
        #expect(try reader.picture(at: time(71)) == expected[70].picture)
        // コマの途中の位置は、そのとき映っているコマ
        #expect(try reader.picture(at: (Double(80) + 0.5) / 30) == expected[80].picture)
    }

    @Test("範囲の外は端のコマ — 終わりより後は終わりのコマ、頭より前は頭のコマ")
    func outOfRangeGivesTheEdgeFrames() async throws {
        let url = try await TestMovie.write(frames: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let reader = try MovieReader(url: url, path: url.path)
        _ = try reader.picture(at: 0)
        // 終わりちょうど (再生が終わりで止まった位置) と、その先
        #expect(try reader.picture(at: reader.duration) == expected[11].picture)
        #expect(try reader.picture(at: reader.duration + 5) == nil, "同じ終わりのコマなので渡さない")
        #expect(try reader.picture(at: -3) == expected[0].picture)
    }

    @Test("同じ位置の並びで 2 度読むと、同じコマの並びになる")
    func samePositionsSamePictures() async throws {
        let url = try await TestMovie.write(frames: 30, pixel: TestMovie.noise)
        defer { try? FileManager.default.removeItem(at: url) }
        // 進む・止まる・戻る・飛ぶを混ぜた位置の並び
        let positions: [Double] = [0, 0.1, 0.2, 0.2, 0.9, 0.05, 0.3, 0.999, 1, 0.5, 0.51]
        func read() throws -> [DisplayImage?] {
            let reader = try MovieReader(url: url, path: url.path)
            return try positions.map { try reader.picture(at: $0) }
        }
        let first = try read()
        #expect(first.compactMap { $0 }.count > 5)
        #expect(try read() == first)
    }

    // MARK: - 作れないとき・読めなくなったとき

    @Test("中身が動画でないファイルは読めない、音声だけのファイルは映像が無い、として作るときに投げる")
    func creationFailures() throws {
        let garbage = try TestMovie.garbage()
        let sound = try TestMovie.soundOnly()
        defer {
            try? FileManager.default.removeItem(at: garbage)
            try? FileManager.default.removeItem(at: sound)
        }
        #expect(throws: MovieFailure.unreadable(path: "garbage.mov")) {
            try MovieReader(url: garbage, path: "garbage.mov")
        }
        #expect(throws: MovieFailure.noVideo(path: "sound.wav")) {
            try MovieReader(url: sound, path: "sound.wav")
        }
    }

    @Test("途中が壊れた動画は、作れて、読めなくなったところで投げ、手前へ戻れば読み直せる")
    func damagedMiddleThrowsWhileReading() async throws {
        let url = try await TestMovie.write(frames: 60, width: 64, height: 48, pixel: TestMovie.noise)
        let broken = try TestMovie.damaged(url, from: 0.3, to: 0.6)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: broken)
        }
        let reader = try MovieReader(url: broken, path: "broken.mov")
        var failedAt: Int?
        var failure: MovieReader.Failure?
        for frame in 1...60 {
            do {
                _ = try reader.picture(at: time(frame))
            } catch {
                failedAt = frame
                failure = error
                break
            }
        }
        let failed = try #require(failedAt, "壊した範囲を読んでも投げなかった")
        #expect(failed > 1)
        #expect(failure?.reason.isEmpty == false)
        // 止まった後、少し先へ進んでも試し直さない (毎フレーム読み直して重くならない)
        #expect(try reader.picture(at: time(failed + 1)) == nil)
        // 頭へ戻れば読み直して、頭のコマが出る
        let expected = try await TestMovie.reference(url)
        #expect(try reader.picture(at: 0) == expected[0].picture)
    }

    @Test("読めなくなった後は、1 秒より先へ進むまで読み直しを試さない (鍵のコマの位置に依らない)")
    func retryWaitsASecondAfterFailing() async throws {
        let url = try await TestMovie.write(frames: 90, width: 64, height: 48, pixel: TestMovie.noise)
        let broken = try TestMovie.damaged(url, from: 0.3, to: 0.6)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: broken)
        }
        let reader = try MovieReader(url: broken, path: "broken.mov")
        var failedAt: Double?
        for frame in 1...90 {
            do {
                _ = try reader.picture(at: time(frame))
            } catch {
                failedAt = time(frame)
                break
            }
        }
        let failed = try #require(failedAt, "壊した範囲を読んでも投げなかった")
        let restarts = reader.restarts
        // 投げた直後も、試さずに待っている間も、待ちを名乗る (``Movie`` が running に戻さない根拠、#2908)
        #expect(reader.isWaitingToRetry, "投げた後は待ちを名乗る")
        _ = try? reader.picture(at: failed + 0.5)
        #expect(reader.restarts == restarts, "0.5 秒先では試さない")
        #expect(reader.isWaitingToRetry, "試さずに nil を返す間は待ちを名乗る")
        // 1 秒より先では試し、待ちの印は試した結果に従う。壊れた所の先から読み直して読めるかは
        // 機械 (OS の復号器) に依る — 手元では読めず、専用機では読めた (PR #3214 の queue)
        var retryThrew = false
        do {
            _ = try reader.picture(at: failed + MovieReader.retryDistance + 0.1)
        } catch {
            retryThrew = true
        }
        #expect(reader.restarts == restarts + 1, "1 秒より先では試す")
        #expect(reader.isWaitingToRetry == retryThrew, "読み直しても読めなければ待ちのまま、読めたら下りる")
        // 頭へ戻って読み直し、読めたら下りる
        _ = try reader.picture(at: 0)
        #expect(!reader.isWaitingToRetry, "読み直して読めたら待ちを下ろす")
        // 読めなくなって待っている動画を閉じると、待ちも戻る (#3122 の retryAfter と揃う)
        _ = try? reader.picture(at: failed + 0.01)
        _ = try? reader.picture(at: failed + 0.5)
        #expect(reader.isWaitingToRetry, "閉じる前は待っている — 比べる前提")
        reader.close()
        #expect(!reader.isWaitingToRetry)
    }

    // MARK: - 鍵のコマで読み進めるか読み直すかを決める (#2764)

    /// `fps` 枚/秒の動画で `seconds` 秒に映るコマの番号。
    private func frame(at seconds: Double, fps: Double = 30, count: Int) -> Int {
        min(count - 1, max(0, Int((seconds * fps + 0.03).rounded(.down))))
    }

    @Test("検査の動画は、頼んだ間隔ちょうどに鍵のコマを持つ (以下の検査の前提)")
    func testMoviesHaveKeyFramesWhereAsked() async throws {
        let gop30 = try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 30, paint: TestMovie.stripe)
        let gop90 = try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 90, paint: TestMovie.stripe)
        defer {
            try? FileManager.default.removeItem(at: gop30)
            try? FileManager.default.removeItem(at: gop90)
        }
        let every30 = try await TestMovie.keyFrameTimes(gop30)
        let every90 = try await TestMovie.keyFrameTimes(gop90)
        #expect(every30 == [0, 1, 2])
        #expect(every90 == [0])
    }

    @Test("鍵のコマが頭にしか無い動画でも、0 から 2.5 秒へ飛ぶと読み直す (読み進めるより速い)")
    func farJumpWithoutKeyFrameStillRestarts() async throws {
        let url = try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 90, paint: TestMovie.stripe)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let reader = try MovieReader(url: url, path: url.path)
        _ = try reader.picture(at: 0)
        #expect(try reader.picture(at: 2.5) == expected[75].picture)
        // 読み直しても 0 の鍵のコマから復号するが、2.5 より前のコマは変換しないので速い (#2764 の実測)
        #expect(reader.restarts == 1, "鍵のコマを引いても、遠い先の読み直しは減らさない")

        // 鍵のコマを引かない読み方 (変更前と同じ) も、1 秒より先なので読み直す
        let unindexed = try MovieReader(url: url, path: url.path, keyFrames: .unavailable)
        _ = try unindexed.picture(at: 0)
        #expect(try unindexed.picture(at: 2.5) == expected[75].picture)
        #expect(unindexed.restarts == 1)
    }

    @Test("1 秒ごとに鍵のコマがある動画で 0.5 から 1.4 秒へ進むと、1.0 の鍵のコマから読み直す")
    func nearJumpAcrossKeyFrameRestarts() async throws {
        let url = try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 30, paint: TestMovie.stripe)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let reader = try MovieReader(url: url, path: url.path)
        _ = try reader.picture(at: 0.5)
        #expect(reader.restarts == 0, "0 → 0.5 の間に鍵のコマは無い")
        #expect(try reader.picture(at: 1.4) == expected[42].picture)
        #expect(reader.restarts == 1)

        // 鍵のコマを引かない読み方は、1 秒以内なので 27 コマを読み進める
        let unindexed = try MovieReader(url: url, path: url.path, keyFrames: .unavailable)
        _ = try unindexed.picture(at: 0.5)
        #expect(try unindexed.picture(at: 1.4) == expected[42].picture)
        #expect(unindexed.restarts == 0)
    }

    @Test(
        "どの読み方でも、ループ・後ろ・前・1 秒以内の飛びを混ぜた位置の並びに同じコマが出る",
        arguments: ["h264.gop30", "h264.gop90", "h264.gop30.reordered", "hevc.gop30"])
    func sameFramesWhicheverWayItReads(variant: String) async throws {
        let hevc = variant.hasPrefix("hevc")
        try #require(!hevc || TestMovie.canWriteHEVC, "この機械には HEVC の符号化器が無い")
        let url = try await TestMovie.write(
            frames: 90, width: 128, height: 96, codec: hevc ? .hevc : .h264,
            keyFrameInterval: variant.contains("gop90") ? 90 : 30, reordersFrames: variant.hasSuffix("reordered"),
            paint: TestMovie.stripe)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        #expect(expected.count == 90)
        // 普通に流す・継ぎ目・後ろへ・前へ・1 秒以内の前・鍵のコマを跨ぐ・鍵のコマのすぐ後
        var positions = (0..<88).map { Double($0) / 30 }
        positions += [2.95, 0, 0.0333, 2.9, 2.5, 2.5333, 0, 2.5, 0, 0.9, 0.5, 1.4, 0.95, 1.05, 1.8, 2.99, 3, 0.2]
        let indexed = try MovieReader(url: url, path: url.path)
        let unindexed = try MovieReader(url: url, path: url.path, keyFrames: .unavailable)
        var shownIndexed: DisplayImage?
        var shownUnindexed: DisplayImage?
        for position in positions {
            shownIndexed = try indexed.picture(at: position) ?? shownIndexed
            shownUnindexed = try unindexed.picture(at: position) ?? shownUnindexed
            let index = frame(at: position, count: expected.count)
            #expect(shownIndexed == expected[index].picture, "\(position) 秒")
            #expect(shownUnindexed == expected[index].picture, "\(position) 秒 (鍵のコマを引かない)")
        }
        #expect(indexed.restarts >= unindexed.restarts, "鍵のコマは読み直しを足すほうにだけ使う")
    }

    @Test(
        "全部が鍵のコマの動画を 1 コマ飛ばしで読んでも、毎回は読み直さない",
        .enabled(if: TestMovie.canWriteTransparent, "この機械には ProRes 4444 の符号化器が無い"))
    func allKeyFramesDoNotRestartEveryFrame() async throws {
        let url = try await TestMovie.writeTransparent(frames: 120, fps: 60) { index, x, y in
            (UInt8(truncatingIfNeeded: index * 2), UInt8(truncatingIfNeeded: x * 30), UInt8(truncatingIfNeeded: y * 60), 255)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await TestMovie.keyFrameTimes(url).count == 120, "前提: 全部が鍵のコマ")
        let reader = try MovieReader(url: url, path: url.path)
        // 60 fps の動画を 30 fps と 10 fps で進める
        for step in 0..<60 { _ = try reader.picture(at: Double(step) / 30) }
        for step in 0..<20 { _ = try reader.picture(at: Double(step) / 10) }
        // 10 fps の 2 本目の頭 (1.9 → 0) で後ろへ戻る 1 回だけ
        #expect(reader.restarts == 1)
    }

    @Test("鍵のコマを引かない読み方は、1 秒より先へ飛ぶときだけ読み直す (目録を引けない動画と同じ)")
    func unindexedSplitsAtOneSecond() async throws {
        let url = try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 30, paint: TestMovie.stripe)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path, keyFrames: .unavailable)
        _ = try reader.picture(at: 0)
        _ = try reader.picture(at: 0.9)
        #expect(reader.restarts == 0, "0 → 0.9 は 1 秒以内")
        _ = try reader.picture(at: 2.5)
        #expect(reader.restarts == 1, "0.9 → 2.5 は 1 秒より先")
    }
}
