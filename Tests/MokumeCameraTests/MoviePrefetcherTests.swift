// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 実時間の時計の先読みの係 (#2523)。GPU は要らない。動画は検査の中で作る。
///
/// 係は main actor の外で読むので、検査は係が列を埋め終えるのを ``MoviePrefetcher/isSettled`` で
/// 待ってから見る (待つ側が期限を持ち、越えたら落とす)。
@Suite(
    "動画の先読みの係",
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MoviePrefetcherTests {
    /// 3 秒・30 fps・鍵のコマ 30 枚ごとの動画。
    private func movie() async throws -> URL {
        try await TestMovie.write(frames: 90, width: 128, height: 96, keyFrameInterval: 30, paint: TestMovie.stripe)
    }

    private func source(_ url: URL, width: Int = 128, height: Int = 96) -> MovieSource {
        MovieSource(
            url: url, path: url.lastPathComponent, indexesKeyFrames: true, width: width, height: height,
            orientation: .identity)
    }

    /// 係が列を埋め終えるまで待つ。期限 (60 秒) を越えたら落とす。期限は、係が最初のコマで面の色の表を作る (debug で数秒・#2962) 間を含む。
    private func settle(_ prefetcher: MoviePrefetcher) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !prefetcher.isSettled {
            try #require(ContinuousClock.now < deadline, "係が 60 秒で列を埋め終えない")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("埋まった列から、頼んだ位置のコマを待たずに選ぶ")
    func picksFromTheQueueWithoutWaiting() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let prefetcher = MoviePrefetcher(source: source(url))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 0, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        for frame in 0..<89 {
            let picture = try prefetcher.picture(at: Double(frame) / 30, generation: 0, lap: 0, looping: false)?.picture
            #expect(picture == expected[frame].picture, "\(frame) 枚目")
            try await settle(prefetcher)
        }
        #expect(prefetcher.restarts == 0, "流している間は読み直さない")
    }

    @Test("飛んだそのフレームは nil で、係が届けた後のフレームで飛び先のコマになる")
    func jumpGivesNothingUntilTheWorkerDelivers() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let prefetcher = MoviePrefetcher(source: source(url))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 0.5, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        #expect(try prefetcher.picture(at: 0.5, generation: 0, lap: 0, looping: false)?.picture == expected[15].picture)
        // 世代が進んだ頼みは、前の世代の列から選ばない (頼みと選びが同じ錠の中なので、係は割り込めない)
        #expect(try prefetcher.picture(at: 2.5, generation: 1, lap: 0, looping: false)?.picture == nil)
        try await settle(prefetcher)
        #expect(try prefetcher.picture(at: 2.5, generation: 1, lap: 0, looping: false)?.picture == expected[75].picture)
        #expect(try prefetcher.picture(at: 2.5 + 1.0 / 30, generation: 1, lap: 0, looping: false)?.picture == expected[76].picture)
    }

    @Test("ループで流すと、継ぎ目の先のコマは継ぎ目に着く前に列に入っている")
    func loopSeamIsReadyBeforeTheSeam() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let prefetcher = MoviePrefetcher(source: source(url))
        defer { prefetcher.close() }
        // 終わりの手前まで流す
        _ = try prefetcher.picture(at: 2.5, generation: 0, lap: 0, looping: true)
        try await settle(prefetcher)
        for frame in 76..<90 {
            _ = try prefetcher.picture(at: Double(frame) / 30, generation: 0, lap: 0, looping: true)
            try await settle(prefetcher)
        }
        // 継ぎ目のフレームで、待たずに頭のコマが出る
        #expect(try prefetcher.picture(at: 0, generation: 0, lap: 1, looping: true)?.picture == expected[0].picture)
        #expect(try prefetcher.picture(at: 1.0 / 30, generation: 0, lap: 1, looping: true)?.picture == expected[1].picture)
    }

    @Test("ループでなければ終わりのコマで止まり、列を埋めようとしない")
    func endStopsWithoutLooping() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await TestMovie.reference(url)
        let prefetcher = MoviePrefetcher(source: source(url))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 2.9, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        _ = try prefetcher.picture(at: 2.9, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        #expect(try prefetcher.picture(at: 3, generation: 0, lap: 0, looping: false)?.picture == expected[89].picture)
        try await settle(prefetcher)
        #expect(try prefetcher.picture(at: 3.5, generation: 0, lap: 0, looping: false)?.picture == nil, "同じ終わりのコマは渡さない")
    }

    @Test("閉じると係が止まり、期限の内に返る")
    func closeStopsTheWorkerInTime() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let prefetcher = MoviePrefetcher(source: source(url))
        _ = try prefetcher.picture(at: 0, generation: 0, lap: 0, looping: true)
        try await settle(prefetcher)
        let started = ContinuousClock.now
        prefetcher.close()
        #expect(!prefetcher.stopTimedOut)
        #expect(ContinuousClock.now - started < .seconds(MoviePrefetcher.stopLimit))
        prefetcher.close()  // 2 度目は何もしない
    }

    @Test("係が塞がっていても、閉じる側は期限で返り、係は塞ぎが解けた後に自分で抜ける")
    func closeGivesUpAtTheLimit() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = DispatchSemaphore(value: 0)
        let blocking = Switch()
        let prefetcher = MoviePrefetcher(source: source(url)) {
            if blocking.isOn { gate.wait() }
        }
        _ = try prefetcher.picture(at: 0, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        blocking.isOn = true
        // 飛んで係を起こし、1 枚目の手前で塞がせる
        _ = try prefetcher.picture(at: 2, generation: 1, lap: 0, looping: false)
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        prefetcher.close()
        let waited = ContinuousClock.now - started
        #expect(prefetcher.stopTimedOut)
        #expect(waited >= .seconds(MoviePrefetcher.stopLimit) && waited < .seconds(MoviePrefetcher.stopLimit + 1))
        gate.signal()
        #expect(prefetcher.waitUntilStopped(5), "塞ぎが解けた後、係が抜けない")
    }

    @Test("途中が壊れた動画は、読めなくなった後は渡せるコマが無いかぎり毎フレーム投げ、手前へ飛べば戻る")
    func damagedMiddleKeepsFailingUntilJumpBack() async throws {
        let url = try await TestMovie.write(frames: 60, width: 64, height: 48, pixel: TestMovie.noise)
        let broken = try TestMovie.damaged(url, from: 0.3, to: 0.6)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: broken)
        }
        let expected = try await TestMovie.reference(url)
        let prefetcher = MoviePrefetcher(source: source(broken, width: 64, height: 48))
        defer { prefetcher.close() }
        var failedAt: Int?
        for frame in 0..<60 {
            do {
                _ = try prefetcher.picture(at: Double(frame) / 30, generation: 0, lap: 0, looping: false)
            } catch {
                failedAt = frame
                break
            }
            try await settle(prefetcher)
        }
        let failed = try #require(failedAt, "壊した範囲を読んでも投げなかった")
        try await settle(prefetcher)
        // 少し先へ進んでも投げ続ける (読めたふりをしない)
        #expect(throws: MovieFrames.Failure.self) {
            try prefetcher.picture(at: Double(failed + 2) / 30, generation: 0, lap: 0, looping: false)
        }
        // 頭へ飛べば (新しい世代) 読み直して戻る
        _ = try? prefetcher.picture(at: 0, generation: 1, lap: 0, looping: false)
        try await settle(prefetcher)
        #expect(try prefetcher.picture(at: 0, generation: 1, lap: 0, looping: false)?.picture == expected[0].picture)
    }

    // MARK: - 世代と何周目か

    @Test("飛ぶと世代が進み、ループの継ぎ目では何周目かが進み、ループでないのに戻ると世代が進む")
    func continuityCountsGenerationsAndLaps() {
        var continuity = PlaybackContinuity()
        continuity.note(position: 0, jumped: false, looping: true)
        continuity.note(position: 1.5, jumped: false, looping: true)
        #expect(continuity.generation == 0 && continuity.lap == 0)
        continuity.note(position: 0.1, jumped: false, looping: true)
        #expect(continuity.generation == 0 && continuity.lap == 1, "継ぎ目")
        continuity.note(position: 2.5, jumped: true, looping: true)
        #expect(continuity.generation == 1 && continuity.lap == 0, "飛んだ")
        continuity.note(position: 0.2, jumped: false, looping: false)
        #expect(continuity.generation == 2 && continuity.lap == 0, "ループでないのに戻った")
        continuity.note(position: 0.2, jumped: false, looping: false)
        #expect(continuity.generation == 2, "止まっている")
        continuity.cut()
        continuity.note(position: 1, jumped: false, looping: false)
        #expect(continuity.generation == 3 && continuity.lap == 0, "続きを切った")
    }
}

/// 係と検査の間で渡す旗。
nonisolated private final class Switch: Sendable {
    private let state = Mutex(false)
    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

extension VideoFrame {
    /// 比べるための 8 bit の絵。面なら表を CPU で引く (GPU で引いた結果と bit が同じ — #2962)。
    var picture: DisplayImage {
        switch self {
        case .converted(let picture): picture
        case .surface(let surface): surface.converted()
        }
    }
}
