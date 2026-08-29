// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
/// | `slots` | **背圧**。抱える枚数が上限を超えない → 長く撮ってもメモリが伸びない |
/// | `closed` | **終わりを待つ形**。``finish()`` はファイルが閉じてから返る |
///
/// 待つ側が semaphore なのは、完了を待つのが main actor の上で `await` が使えない
/// ためである (同 決定 4。`DispatchQueue` は足さない)。
///
/// ## 落ちたフレームは数えない
///
/// 出口へ届かなかったフレームは**番号の穴**として残る。落ちた数は最初と最後の番号の
/// 幅から導けるので ([ADR-0025] 決定 2)、数える機構を別に持たない。時刻はフレーム
/// 自身のものを使うので、落ちても残りの絵の時刻は動かない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
final class MovieWriter {
    /// 同時に抱える枚数の既定の上限。
    static let defaultLimit = 4

    /// 符号化へ渡す 1 枚。
    private struct Job: Sendable {
        let image: DisplayImage
        let time: Double
    }

    /// 空いている枠。**取れなければ待つ** — これが背圧そのものである。
    private let slots: DispatchSemaphore
    /// 符号化し終わった枚数。抱えている枚数を数え直すのに使う。
    private let finished = DispatchSemaphore(value: 0)
    /// ファイルが閉じた合図。
    private let closed = DispatchSemaphore(value: 0)
    /// 直近の書き損じ。**隔離の外から書かれる**ので錠で守る。
    private let lastFailure = FailureSlot()
    private let continuation: AsyncStream<Job>.Continuation

    /// 書き出し先。
    let path: String
    /// 抱えている枚数の上限。
    let limit: Int
    /// いま抱えている枚数。
    private(set) var outstanding = 0
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    private(set) var peakOutstanding = 0
    /// 受け取った枚数。
    private(set) var acceptedFrames = 0

    private var firstFrame: Int?
    private var lastFrame = 0
    private var hasFinished = false

    init(path: String, frameRate: Int, limit: Int = MovieWriter.defaultLimit) {
        self.path = path
        self.limit = max(1, limit)
        slots = DispatchSemaphore(value: self.limit)

        let (stream, continuation) = AsyncStream<Job>.makeStream()
        self.continuation = continuation

        let slots = self.slots
        let finished = self.finished
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
                    failure.set("\(path) を書けませんでした: \(error)")
                }
                // **終わりの合図を先に出す。** 枠を先に返すと、待っていた側が起きた
                // 時点でまだ合図が出ておらず、抱えている枚数を数え損なう
                finished.signal()
                slots.signal()
            }
            if let file {
                do {
                    try await file.finish(lastFrameAt: lastTime)
                } catch {
                    failure.set("\(path) を閉じられませんでした: \(error)")
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
        guard !hasFinished else { return }
        harvest()
        slots.wait()
        harvest()

        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        acceptedFrames += 1
        if firstFrame == nil { firstFrame = frame }
        lastFrame = frame
        continuation.yield(Job(image: image, time: time))
    }

    /// 書き終える。**ファイルが閉じてから返る。**
    ///
    /// 「呼んだら出来ている」ように見える面が「あとで出来る」実装だと、止めた直後に
    /// プロセスを終えた人は動画そのものを失う。2 度呼んでも安全。
    func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        continuation.finish()
        closed.wait()
        outstanding = 0
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

    /// 終わっているものを取り込む。**待たない。**
    private func harvest() {
        while outstanding > 0, finished.wait(timeout: .now()) == .success {
            outstanding -= 1
        }
    }
}
