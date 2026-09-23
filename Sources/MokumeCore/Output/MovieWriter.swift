// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 動きをファイルにする係。**符号化をフレームの外で行う。**
///
/// フレームの中で払うのは読み戻しだけという点は静止画の ``FrameWriter`` と同じで、
/// 違うのは **順番が意味を持つ**ことである。動画は詰めた順にそのまま並ぶので、
/// 受け取る側は 1 本でなければならない。
///
/// ## 待ち方
///
/// | 使うもの | 役目 |
/// | --- | --- |
/// | `AsyncStream` と 1 本の仕事 | **順番**。詰めた順に届く ([ADR-0010] 決定 4) |
/// | ``Backpressure`` | **背圧**。抱える枚数が上限を超えない → 長く撮ってもメモリが伸びない |
/// | ``MovieFile`` の読み直し | **符号化器の用意**。受け取れるようになるまで 1 本の仕事が待つ。待つあいだ枠が返らないので、``Backpressure`` を通じて頼む側まで待たされる |
/// | `closed` | **終わりを待つ形**。``finish(_:)`` はファイルが閉じてから返る (塞ぐかは待ち方による) |
///
/// 待つ側が semaphore なのは、完了を待つのが main actor の上で `await` が使えない
/// ためである (同 決定 4。`DispatchQueue` は足さない)。
///
/// **塞いで待つのは `endRecord()` の経路だけである。** 終わりの経路は同じ合図を塞がずに
/// 見に来る (``Patience/peek``)。`AVAssetWriter.finishWriting` は main を塞いだまま走らせると
/// 失敗しうると Apple が書いている相手で、終わりはいちばん起きやすい場面だった ([#978])。
///
/// ## 落ちたフレームは数えない
///
/// 出口へ届かなかったフレームは**番号の穴**として残る。落ちた数は最初と最後の番号の
/// 幅から導けるので ([ADR-0025] 決定 2)、数える機構を別に持たない。時刻はフレーム
/// 自身のものを使うので、落ちても残りの絵の時刻は動かない。
///
/// [#978]: https://github.com/mokume-metal/mokume/issues/978
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
final class MovieWriter {
    /// 同時に抱える枚数の既定の上限。
    static let defaultLimit = Backpressure.defaultLimit

    /// ファイルを閉じるのを待つ上限 (秒)。
    ///
    /// **進捗では測れないので平らな数である。** 閉じる合図 (`closed`) は 1 回きりで、その間に
    /// 何枚進んだかを外から見る手が無い。だから「1 つも進まない」ではなく「全体で何秒」で
    /// 測るしかなく、長い動画の最終化を途中で諦めないだけの幅を取ってある。
    ///
    /// **越えても殺さない。** mp4 は末尾のメタデータが要るので、途中で止めると再生できない
    /// ファイルになる。待つのをやめても符号化は走り続けるので、失うのは「返ってきた時点で
    /// 出来ている」という保証だけである。
    nonisolated static let closeLimitSeconds = 30.0

    /// 符号化へ渡す 1 枚。
    private struct Job: Sendable {
        let image: DisplayImage
        let time: Double
    }

    /// 抱える枚数の上限と、終わったものの数え方。
    private let pressure: Backpressure
    /// ファイルが閉じた合図。
    private let closed = DispatchSemaphore(value: 0)
    /// 直近の書き損じ。**隔離の外から書かれる**ので錠で守る。
    private let lastFailure = FailureSlot()
    private let continuation: AsyncStream<Job>.Continuation

    /// 書き出し先。
    let path: String
    /// 抱えている枚数の上限。
    var limit: Int { pressure.limit }
    /// いま抱えている枚数。
    var outstanding: Int { pressure.outstanding }
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    var peakOutstanding: Int { pressure.peak }
    /// 受け取った枚数。
    private(set) var acceptedFrames = 0

    private var firstFrame: Int?
    private var lastFrame = 0

    /// 書き終えるまでのどこに居るか。
    ///
    /// **段を憶えるのは、塞がずに見に来る呼び出しが続きから再開するためである**
    /// (``finish(_:)``)。見に来るたびに頭からやり直すと、諦めた警告が何度も出て、閉じる
    /// 期限も測り直される。
    private enum Stage {
        /// 受け取っている。
        case recording
        /// 積んだぶんを符号化しきるのを待っている。
        case encoding
        /// ファイルが閉じるのを待っている。**期限はこの段に入った時刻から測る。**
        case closing(deadline: DispatchTime)
        /// 閉じた (諦めたときも)。
        case closed
    }
    private var stage = Stage.recording

    init(path: String, frameRate: Int, limit: Int = MovieWriter.defaultLimit) {
        self.path = path
        pressure = Backpressure(limit: limit)

        let (stream, continuation) = AsyncStream<Job>.makeStream()
        self.continuation = continuation

        let release = pressure.release
        let closed = self.closed
        let failure = lastFailure
        Task.detached(priority: .utility) {
            // **ファイルは最初の 1 枚が来てから開く。** 絵の大きさは受け取るまで
            // 分からず、開いた後は変えられない
            var file: MovieFile?
            var lastTime = 0.0
            for await job in stream {
                do {
                    let opened: MovieFile
                    if let file {
                        opened = file
                    } else {
                        opened = try MovieFile(
                            path: path, width: job.image.width, height: job.image.height,
                            frameRate: frameRate)
                        file = opened
                    }
                    try await opened.append(job.image, at: job.time)
                    lastTime = job.time
                } catch {
                    failure.set("Could not write \(path): \(error)")
                }
                release()
            }
            if let file {
                do {
                    try await file.finish(lastFrameAt: lastTime)
                } catch {
                    failure.set("Could not close \(path): \(error)")
                }
            }
            closed.signal()
        }
    }

    /// 1 枚を書き足すよう頼む。**上限に達していたら、空くまで返らない。**
    ///
    /// - Parameters:
    ///   - image: 出力段を通った絵。
    ///   - frame: 何枚目か。落ちたフレームを数えるのに使う。
    ///   - time: このフレームの時刻 (秒)。**そのまま動画の時刻になる。**
    func write(_ image: DisplayImage, frame: Int, time: Double) {
        guard case .recording = stage else { return }
        pressure.take()
        acceptedFrames += 1
        if firstFrame == nil { firstFrame = frame }
        lastFrame = frame
        continuation.yield(Job(image: image, time: time))
    }

    /// 書き終える。**ファイルが閉じてから返る。**
    ///
    /// 「呼んだら出来ている」ように見える面が「あとで出来る」実装だと、止めた直後に
    /// プロセスを終えた人は動画そのものを失う。2 度呼んでも安全。
    ///
    /// **待ちは 2 段で、期限の測り方が違う。** 積んだぶんを符号化しきる段は 1 枚ごとに
    /// 合図が来るので進捗で測れる (``Backpressure/drain()``)。ファイルを閉じる段は合図が
    /// 1 回きりなので、平らな ``closeLimitSeconds`` で測るしかない。
    ///
    /// どちらも**越えても殺さない** — 名乗って窓を返すだけである。
    ///
    /// **期限は待ち方によらず同じ。** 塞がずに見に来る呼び出し (``Patience/peek``) も同じ段を
    /// 通るので、終わりの経路にも同じ 2 段の期限が効く ([#978])。
    ///
    /// - Parameter patience: まだ閉じていないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (閉じた・諦めた)。``Patience/block`` なら必ず `true`。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @discardableResult
    func finish(_ patience: Patience = .block) -> Bool {
        if case .recording = stage {
            continuation.finish()
            stage = .encoding
        }
        if case .encoding = stage {
            guard pressure.drain(patience) else { return false }
            if pressure.outstanding > 0 {
                Diagnostics.warn(
                    "\(path): encoding has not moved for \(Int(pressure.stallLimitSeconds)) seconds "
                        + "(\(pressure.outstanding) frames are still waiting) — no longer waiting for it")
            }
            stage = .closing(deadline: .now() + Self.closeLimitSeconds)
        }
        if case .closing(let deadline) = stage {
            let answered: Bool
            switch patience {
            case .block: answered = closed.wait(timeout: deadline) == .success
            case .peek:
                answered = closed.wait(timeout: .now()) == .success
                guard answered || DispatchTime.now() >= deadline else { return false }
            }
            if !answered {
                Diagnostics.warn(
                    "\(path): waited \(Int(Self.closeLimitSeconds)) seconds to close the movie with no "
                        + "answer — no longer waiting. Quitting now leaves a file that will not "
                        + "play (writing is still going, so waiting a little may still close it)")
            }
            stage = .closed
        }
        return true
    }

    /// 出口へ届かなかったフレームの数。
    ///
    /// **番号の穴から導く。** 描けなかったフレームは出口を通らないので、受け取った
    /// 枚数と番号の幅が食い違う。
    var droppedFrames: Int {
        guard let firstFrame else { return 0 }
        return max(0, (lastFrame - firstFrame + 1) - acceptedFrames)
    }

    /// 直近の書き損じを取り出す。**取り出したら消える。**
    func takeFailure() -> String? { lastFailure.take() }
}

/// 動画を閉じ終えるまでに、外から待つ側が見込むべき長さ。
///
/// **足し算をここ 1 箇所に置く。** 待ちは 2 段 (``MovieWriter/finish(_:)``) で、積んだぶんを
/// 符号化しきる段が進捗の途切れ (``Backpressure/defaultStallLimitSeconds``) で諦め、閉じる段が
/// 平らな ``MovieWriter/closeLimitSeconds`` で諦める。プロセスの外から待つ側 (見張りが子を
/// 終わらせる猶予・[#1219]) が数字を写すと、片方が動いたときに黙って割れる。
///
/// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
package nonisolated enum RecordingDeadline {
    /// 止まってしまったときに、諦めるまでの秒数。
    ///
    /// **上限ではない。** 符号化が少しずつでも進む限り 1 段目は待ち続けるので、ここが覆うのは
    /// 「止まってしまったとき」の長さだけである。
    package static let longestFinishSeconds =
        Backpressure.defaultStallLimitSeconds + MovieWriter.closeLimitSeconds
}
