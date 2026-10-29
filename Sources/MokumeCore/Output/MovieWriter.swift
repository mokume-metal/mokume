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
/// 出口へ届かなかったフレームは**番号の穴**として残る。落ちた数は、最初に受け取った番号
/// から止めたところまでの幅から導けるので ([ADR-0025] 決定 2・``droppedFrames``)、数える
/// 機構を別に持たない。時刻はフレーム
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

    /// 符号化へ渡す 1 つ。絵と音の窓は同じ 1 本の列に、頼んだ順に並ぶ。窓は 1 フレームぶんで、`draw()` の後に積まれ、
    /// 絵は少し遅れて届くので、**列の上では窓のほうが先に来る**。書き手は窓を控えて、絵に合わせた順で書く
    /// (``soundLead``)。
    private enum Job: Sendable {
        case picture(DisplayImage, frame: Int, time: Double)
        case sound(SoundWindow)
    }

    /// 音の窓を、書けた絵より何フレームぶん先まで書いてよいか。
    ///
    /// フレーム `N` の絵 (番号 `N`) と同じ時刻の窓は、番号 `N - 1` である。絵が `N` まで書けたら、窓は
    /// `N - 1 + soundLead` まで書く。**音声の先行は、測って止まらないと分かった 0〜2 フレームに抑える**
    /// ([#3125] の測定)。絵は窓より遅れて届き、遅れの幅は決まっていない (書き出しの背圧しだい) ので、窓を届いた
    /// 順にそのまま書くと、先行がこれを越えて、映像を待つ音声の入力が用意を待ち続けうる。窓を控えて、絵が書けるたびに
    /// ここまでを書く。
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    nonisolated static let soundLead = 2

    /// 抱える枚数の上限と、終わったものの数え方。
    private let pressure: Backpressure
    /// ファイルが閉じた合図。
    private let closed = DispatchSemaphore(value: 0)
    /// 最後に決着した書き込みの結果。**隔離の外から書かれる**ので錠で守る。
    private let lastOutcome = OutcomeSlot()
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
    var acceptedFrames: Int { span.accepted }
    /// 録りが覆う番号の幅。落ちた数はここから導く (``droppedFrames``)。
    private var span: RecordedSpan

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

    /// 書くファイルの形。**元にする形 (ProRes 4444 の `.mov`) と、配る形 (H.264 の MP4・GIF)** ([#2440])。
    ///
    /// 配る形は `mokume render --out` だけが頼む。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    nonisolated enum Format: Sendable, Equatable {
        case proRes4444
        case h264
        case gif
    }

    /// - Parameters:
    ///   - from: 録りを頼まれたフレーム。1 枚も届かなかったときの、落ちた数の幅の
    ///     始まりになる (``RecordedSpan``)。
    ///   - format: 書くファイルの形。
    ///   - open: 最初の絵でファイルを開く手の差し替え (検査)。空なら本物を開く。絵と最初の窓の先頭の標本 (音声トラックを
    ///     付けるとき) を受ける。
    init(
        path: String, frameRate: Int, limit: Int = MovieWriter.defaultLimit, from: Int = 1,
        format: Format = .proRes4444,
        open: (@Sendable (_ image: DisplayImage, _ soundStart: Int?) throws -> any MovieOutput)? = nil
    ) {
        self.path = path
        pressure = Backpressure(limit: limit)
        span = RecordedSpan(from: from)

        let (stream, continuation) = AsyncStream<Job>.makeStream()
        self.continuation = continuation

        let release = pressure.release
        let closed = self.closed
        let outcome = lastOutcome
        // 閉じるときに言う警告 (縦横が変わったとき・#3379) が、頼んだ側の溜め場へ入るように控える。
        // 差してなければ `nil` で、プロセスの溜め場へ入る (タスクローカル値は `Task.detached` に届かない)
        let digest = Diagnostics.digest
        // **優先度は待つ側 (main) に揃える** (#2372)。main は `Backpressure.take()` で semaphore を
        // 待つが、semaphore は優先度を寄付しない。`.utility` だと CPU が混んだ機械で符号化だけが
        // 後回しにされ、main がその遅れを待つ形になる (ProRes のソフトの符号化器の内部のスレッドは
        // 呼んだ側の QoS を継ぐ)
        Task.detached(priority: .userInitiated) {
            // **ファイルは最初の 1 枚が来てから開く。** 絵の大きさは受け取るまで
            // 分からず、開いた後は変えられない
            var file: (any MovieOutput)?
            var lastTime = 0.0
            // 最初の絵を書けたか。**音の窓は、これが立つまで書かない** (区間は最初の絵で始まる)
            var started = false
            // 書き手へ渡す順を待っている音の窓 (番号の順)。**書けた分だけ消す**
            var waiting: [SoundWindow] = []
            // 音声トラックの書き込みを止めたか。書き損じた後や、最初の絵が書けなかったとき立つ
            var soundStopped = false
            // 書けた絵のうち、最も新しいフレームの番号
            var newest = 0

            /// 控えの窓のうち、番号が `limit` 以下のものを順に書く。**書き損じたら音声トラックを止める**
            /// (映像と同じ道で名乗る)。書き損じた窓を控えに残すと、次の絵のときに同じ窓を二重に書くか、飛ばして
            /// 後の窓を先に書いて順序が乱れる。
            func drainSound(through limit: Int) async {
                guard started, !soundStopped, let file else { return }
                while let window = waiting.first, window.frame <= limit {
                    do {
                        try await file.appendSound(window)
                        waiting.removeFirst()
                    } catch {
                        outcome.fail("Could not write \(path): \(error)", at: path)
                        soundStopped = true
                        waiting.removeAll()
                        return
                    }
                }
            }

            for await job in stream {
                switch job {
                case .sound(let window):
                    guard !soundStopped else { continue }
                    waiting.append(window)
                    await drainSound(through: newest - 1 + Self.soundLead)
                case .picture(let image, let frame, let time):
                    do {
                        let opened: any MovieOutput
                        if let file {
                            opened = file
                        } else {
                            let soundStart = format == .proRes4444 && !soundStopped ? waiting.first?.start : nil
                            if let open {
                                opened = try open(image, soundStart)
                            } else {
                                switch format {
                                case .proRes4444, .h264:
                                    opened = try MovieFile(
                                        path: path, width: image.width, height: image.height,
                                        frameRate: frameRate, format: format == .h264 ? .h264 : .proRes4444,
                                        soundStart: soundStart)
                                case .gif:
                                    opened = try GIFFile(path: path, frameRate: frameRate)
                                }
                            }
                            file = opened
                        }
                        try await opened.append(image, at: time)
                        lastTime = time
                        started = true
                        newest = max(newest, frame)
                        outcome.succeed()
                        await drainSound(through: newest - 1 + Self.soundLead)
                    } catch {
                        outcome.fail("Could not write \(path): \(error)", at: path)
                        // **最初の絵が書けなかったら、音声は書かない。** 書けなかった絵の分の窓を控えたまま
                        // 後の絵で書くと、窓が欠けたり順序が乱れたりする。書き損じは絵の側が名乗っている
                        if !started {
                            soundStopped = true
                            waiting.removeAll()
                        }
                    }
                    release()
                }
            }
            if let file {
                // 残りの窓 (最後の絵より先の分) を書いてから閉じる
                await drainSound(through: .max)
                do {
                    try await Diagnostics.$digest.withValue(digest) {
                        try await file.finish(lastFrameAt: lastTime)
                    }
                } catch {
                    outcome.fail("Could not close \(path): \(error)", at: path)
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
        span.accept(frame)
        continuation.yield(.picture(image, frame: frame, time: time))
    }

    /// 音の 1 窓を書き足すよう頼む ([#3125])。**背圧は掛けない** — 窓は 1 フレームに 1 つで、絵の背圧が間接に
    /// 抑える。絵より先に積んでよく、最初の絵の前の窓は、ファイルを開くまで控える。
    ///
    /// 配る形 (MP4・GIF) は音声トラックを持たないので、窓は書かれない (呼ばないのは呼ぶ側の仕事)。
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    func writeSound(_ window: SoundWindow) {
        guard case .recording = stage else { return }
        continuation.yield(.sound(window))
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

    /// 録りが覆うはずだったのは、このフレームまでだと教える。**閉じる前に、止めた側が呼ぶ。**
    ///
    /// 受け取った最後の番号だけでは、**届かなくなった後の末尾**が番号の幅の外に出る。
    /// 撮る係が録りの途中で差込口から外れると (続けて転んだとき・[ADR-0024] 決定 7)、
    /// 以後の絵は 1 枚も届かないまま止められるので、末尾の欠けは穴として残らない ([#1626])。
    ///
    /// 受け取った番号より手前を教えられても、幅は縮めない。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func expectFrames(through frame: Int) { span.expect(through: frame) }

    /// 出口へ届かなかったフレームの数。
    ///
    /// **番号の穴から導く** ([ADR-0025] 決定 2 の「番号の幅 − 入った枚数」)。描けなかった
    /// フレームは出口を通らないので、受け取った枚数と番号の幅が食い違う。幅の終わりは、
    /// 受け取った最後の番号と ``expectFrames(through:)`` で教えられた番号の遅いほうで、
    /// 1 枚も受け取っていなければ録りを頼まれた番号から数える (``RecordedSpan``)。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    var droppedFrames: Int { span.dropped }

    /// 前に取り出してから決着した書き込みの結果を取り出す (転んだものがあれば書き損じ・``OutcomeSlot``)。
    /// **取り出したら消える。**
    ///
    /// `nil` は「順調」ではなく「まだ何も決着していない」である
    /// (``FrameWriter/takeOutcome()``・[#1272])。
    ///
    /// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
    func takeOutcome() -> WriteOutcome? { lastOutcome.take() }

    /// 最後の結果が書き損じなら、その理由を取り出す。**取り出したら消える。**
    func takeFailure() -> String? { takeOutcome()?.failure }
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
