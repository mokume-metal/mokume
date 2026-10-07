// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera
import MokumeCore

/// 動画ファイルから位置でコマを読む (#1960)。GPU は要らない。動画は検査の中で H.264 で作る。
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
        // 1 秒 (seekAhead) より先なので読み直す
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
}
