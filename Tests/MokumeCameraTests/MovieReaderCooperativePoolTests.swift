// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Testing

@testable import MokumeCamera

/// 作品が協調プール (Swift の `Task` を走らせるスレッド群) を埋めていても、動画を開くときの
/// トラックの読み込み (`MovieReader.inspect`) は返る (#3240)。
///
/// `inspect` は読み込みを待つ間だけ呼んだスレッドを塞ぐ。読み込みが協調プールの空きを要ると、作品が
/// `Task.detached` で同期の重い仕事を回している間は、`createVideo(_:)` が返らない。
///
/// **見るのは `inspect` までで、`MovieReader` の `init` 全体ではない。** 協調プールの全部を既定の
/// 優先度で塞ぐと、AVFoundation が内部で使う GCD の既定の優先度のキューも動かなくなり (実測: 塞ぐ数が
/// コア数 - 1 以上で `DispatchQueue.global()` の仕事が走らない)、`init` の後ろの最初のコマの読み込み
/// (`copyNextSampleBuffer`) が、`inspect` の外で止まる。それはこの口の読み込みの形とは別の話。
///
/// **協調プールを埋めると、同じプロセスで並んで走る他の suite も止まる** (#3199 で踏んだ形)。なので
/// 待つ側が期限を持つ: 期限は専用のスレッドが持ち (協調プールも GCD の worker も要らない)、越えたら
/// 埋めた仕事を解いて「期限超過」を記録する。解けば止まっていた仕事が進むので、変更前のコードでも
/// 検査は終わり、赤になる。`.timeLimit` は使わない (main actor 上で検査全体の秒数を縛る)。
@Suite(.serialized)
nonisolated struct MovieReaderCooperativePoolTests {
    /// 協調プールのスレッドを全部、同期の待ちで塞ぐ。
    final class PoolFill: @unchecked Sendable {
        let width = ProcessInfo.processInfo.activeProcessorCount
        private let started = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var released = false

        /// 起きたことを知らせて、解かれるまで同期に待つ (協調プールのスレッドを 1 本塞ぐ)。
        /// `async` の文脈から `wait()` は呼べないので、同期の関数に包む。
        private func park() {
            started.signal()
            gate.wait()
        }

        /// 全部が起きて止まるまで (`timeout` 秒) 待つ。起きなかった数を返す。
        func fill(timeout: TimeInterval) -> Int {
            for _ in 0..<width {
                Task.detached { [self] in park() }
            }
            let deadline = DispatchTime.now() + timeout
            var missing = width
            while missing > 0, started.wait(timeout: deadline) == .success { missing -= 1 }
            return missing
        }

        /// 塞いだ仕事を解く。何度呼んでもよい。
        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            for _ in 0..<width { gate.signal() }
        }
    }

    /// `inspect` の結果。
    final class Outcome: @unchecked Sendable {
        var duration: Double?
        var failure: (any Error)?
        var timedOut = false
        /// `inspect` が返るまでの秒。
        var seconds = 0.0
        /// 起きなかった (塞げなかった) 仕事の数。0 でなければ前提が崩れている。
        var missing = 0
    }

    /// 協調プールを塞ぐ待ちの上限 (秒)。**並走する他の suite が協調プールを使っていて塞ぎきれないとき、
    /// 起きた分を抱えたまま待つのはこの間だけ** — 越えたらすぐ解いて、検査は「塞げなかった」と名乗って赤になる。
    private static let fillBudget = 5.0

    /// 協調プールを塞いだ状態で、専用のスレッドから `inspect` を呼ぶ。
    ///
    /// **期限の見張りは、塞ぐ前に起こす** (塞ぐ待ちも期限に含める)。見張りは専用のスレッドで、塞ぐ待ちと
    /// `inspect` の待ちの合計 (``fillBudget`` + `deadline`) を越えたら、塞ぎを解いて `timedOut` を立てる。
    private func inspectWhileFilled(_ url: URL, deadline: TimeInterval) async -> Outcome {
        let fill = PoolFill()
        let outcome = Outcome()
        return await withCheckedContinuation { continuation in
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                if finished.wait(timeout: .now() + Self.fillBudget + deadline) == .timedOut {
                    outcome.timedOut = true
                    fill.release()
                }
            }
            Thread.detachNewThread {
                defer {
                    finished.signal()
                    fill.release()
                    continuation.resume(returning: outcome)
                }
                outcome.missing = fill.fill(timeout: Self.fillBudget)
                // 塞ぎきれなければ、すぐ解いて抜ける (`defer`)。他の suite の仕事を待たせない
                guard outcome.missing == 0 else { return }
                let begin = DispatchTime.now()
                do {
                    let asset = AVURLAsset(url: url)
                    let (_, range, _, _) = try MovieReader.inspect(asset, path: url.lastPathComponent)
                    outcome.duration = range.duration.seconds
                } catch {
                    outcome.failure = error
                }
                outcome.seconds = Double(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds) / 1e9
            }
        }
    }

    @Test(
        "協調プールを全部塞いでいても、動画のトラックの読み込みは期限内に返り、長さが動画のものになる",
        .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い"))
    func inspectReturnsWhileTheCooperativePoolIsFull() async throws {
        let url = try await TestMovie.write(frames: 30, width: 32, height: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await inspectWhileFilled(url, deadline: 10)
        #expect(outcome.missing == 0, "前提: 協調プールの全部が塞がった。他の suite が協調プールを使っていて塞ぎきれなかった (起きなかった仕事 \(outcome.missing) 本)")
        #expect(!outcome.timedOut && outcome.seconds < 10, "10 秒以内に返らなかった (協調プールの空きを待っている)")
        #expect(outcome.failure == nil, "読めなかった: \(String(describing: outcome.failure))")
        #expect(outcome.duration.map { abs($0 - 1) < 1e-9 } == true)
    }

    @Test("協調プールを全部塞いでいても、映像の無いファイルは映像が無い、読めないファイルは読めない、と名乗る")
    func failuresAreNamedWhileTheCooperativePoolIsFull() async throws {
        let garbage = try TestMovie.garbage()
        let sound = try TestMovie.soundOnly()
        defer {
            try? FileManager.default.removeItem(at: garbage)
            try? FileManager.default.removeItem(at: sound)
        }
        let garbled = await inspectWhileFilled(garbage, deadline: 10)
        let silent = await inspectWhileFilled(sound, deadline: 10)
        #expect(garbled.missing == 0 && silent.missing == 0, "前提: 協調プールの全部が塞がった")
        #expect(
            !garbled.timedOut && !silent.timedOut && garbled.seconds < 10 && silent.seconds < 10,
            "10 秒以内に返らなかった")
        #expect(garbled.failure as? MovieFailure == .unreadable(path: garbage.lastPathComponent))
        #expect(silent.failure as? MovieFailure == .noVideo(path: sound.lastPathComponent))
    }
}
