// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 絵と動きをファイルにする、組み込みの出口。
///
/// **外から足す出口とまったく同じ差込口を通る** ([ADR-0024] 決定 10) — 同じ `Outlet`、
/// 同じ並び、同じ `SeamHealth`。組み込みだけの近道を持たないので、「組み込みにはできて
/// 外にはできないこと」が増えない。
///
/// ## 読み戻しは 1 フレームに 1 回
///
/// 同じフレームに何枚頼まれても、受け取った 1 枚から配る。静止画・連番・動画が同時に
/// 頼まれていても読み戻しは 1 回で、**3 つとも同じ絵になる**。
///
/// ## 頼まれている間だけ差込口に居る
///
/// 遊んでいる間は ``SketchRuntime`` が並びから外す。付けっぱなしにすると、1 枚だけ
/// 撮ったスケッチが以後ずっと毎フレーム道を通ることになる ([ADR-0023] 決定 5)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
final class FrameRecorder: Outlet {
    /// 静止画と連番を書き出す係。
    let writer: FrameWriter
    /// 宣言されたフレームレート。**動画の時刻の刻みになる。**
    private let frameRate: Int

    /// まだ書いていない 1 枚ものの行き先と、**頼まれたフレーム**。
    ///
    /// 番号を憶えるのは、絵が 1 枚遅れて届くためである ([#927])。届いた絵より後の
    /// フレームで頼まれたものは、その絵では書かずに持ち越す — `save()` が書くのは
    /// **それを呼んだフレームの絵**である。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    private var oneShots: [(frame: Int, path: String)] = []
    /// 撮っている連番。撮っていなければ `nil`。
    private var sequence: FrameSequence?
    /// 撮っている動画。撮っていなければ `nil`。
    private var movie: MovieWriter?
    /// 撮っている連番か動画を**頼まれたフレーム**。これより前のフレームの絵は録らない。
    ///
    /// 番号を憶える理由は ``oneShots`` と同じで、絵が 1 枚遅れて届くためである ([#927])。
    /// 撮る係が前のフレームから並びに居ると (直前の `save()` の予約・外から足した出口)、
    /// 撮り始めたフレームで**前のフレームの絵**が届く。それを録ると 1 枚多くなり、全体が
    /// 1 フレーム前へずれる ([#1456])。
    ///
    /// 連番と動画を同時には撮らない (``beginRecord(_:at:)``) ので、1 つで足りる。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    /// [#1456]: https://github.com/mokume-metal/mokume/issues/1456
    private var recordingFrom = 0

    /// 静止画・連番の、最後に決着した書き込みの書き損じ。**知らせの無いフレームでは前の値を保つ。**
    private var imageFailure: String?
    /// 動画の、最後に決着した書き込みの書き損じ。**知らせの無いフレームでは前の値を保つ。**
    ///
    /// 動画を手放すときに消す — 閉じ際に分かったことは ``finishMovie(_:)`` が言うので、
    /// 手放した動画の失敗を次の録りへ持ち越す理由が無い。
    private var movieFailure: String?

    /// 最後に決着した書き込みの書き損じ。**まだ何も決着していないフレームでは前の値を保つ**
    /// ([#1272])。
    ///
    /// 書き込みは隔離の外で走るので、知らせが次のフレームに間に合わないことがある。そこで
    /// `nil` を載せると ``SeamHealth`` は「順調」と読んで数えを 0 に戻し、転び続ける出口が
    /// 負荷の下で外れなくなる。`nil` に戻すのは**書けたことが決着したとき**だけである。
    ///
    /// 両方あるときは並べて 1 つの理由にする (#789)。差込口が持てる理由は 1 つだが、
    /// ``SeamHealth`` が見るのは `nil` かどうかだけなので、繋いでも数え方は変わらない。
    ///
    /// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
    var failure: String? {
        let reasons = [imageFailure, movieFailure].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: " / ")
    }

    /// 閉じている途中で、静止画の待ちが決着したか。
    ///
    /// **同じ閉じの中で待ち直さないための印である。** 塞がずに見に来る閉じ方
    /// (``close(_:)`` に ``Patience/peek``) は何度も呼ばれるので、決着した待ちへもう一度
    /// 入ると期限が測り直され、諦めた警告も二重に出る。
    private var imagesSettled = false

    init(frameRate: Int = 60, writer: FrameWriter = FrameWriter()) {
        self.frameRate = frameRate
        self.writer = writer
    }

    // MARK: - 初回だけ言う注意

    /// 1 度だけ言う注意の種類。仕組みは ``WarningLog`` が持つ ([#734])。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
        /// 撮っている最中に撮り始めようとした。
        case alreadyRecording
        /// 番号の入る場所が無い名前で撮り始めようとした。
        case patternWithoutNumber
        /// 撮っていないのに止めようとした。
        case notRecording
        /// 出口へ届かなかったフレームがあった。
        case droppedFrames
        /// 動画を書けなかった・閉じられなかった。
        case movieFailure
        /// 静止画・連番を書けなかった。
        case imageFailure
        /// 絵を貰えないまま終わった `save()` の予約が残っていた。
        case unwrittenShots
    }

    /// 言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    private func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    /// 控えを空に戻す。**録りが始まるたびに呼ぶ。**
    ///
    /// 畳む理由は「毎フレーム起きうることを繰り返さない」であって、**録りをまたいで
    /// 黙ること**ではない。2 本目の動画が閉じられなかったのに 1 本目で言ったからと
    /// 黙れば、[#789] が塞いだ穴をそのまま作り直す。
    ///
    /// [#789]: https://github.com/mokume-metal/mokume/issues/789
    private func forgetWarnings() { warnings = WarningLog<Warning>() }

    /// 頼まれているものが何も無いか。
    var isIdle: Bool { oneShots.isEmpty && !isRecording }

    /// いまの絵で果たせる `save()` の予約が残っているか。
    ///
    /// **``isIdle`` ではなく予約だけを見る。** 止まっているスケッチの抱えものを決着させるか
    /// の判定に使うので、連番や動画まで数えると、止めている間じゅう同じ絵を押し込み続ける
    /// ことになる ([#1300])。描かないフレームは録らない、が連番と動画の側の正しさである。
    ///
    /// - Parameter frame: 配れる絵のフレーム番号。これより後で頼まれたものは宛先の絵が
    ///   まだ描かれていないので数えない (``receive(_:)`` と同じ境目)。
    ///
    /// [#1300]: https://github.com/mokume-metal/mokume/issues/1300
    func hasUnwrittenShots(upTo frame: Int) -> Bool { oneShots.contains { $0.frame <= frame } }

    /// 連番か動画を撮っている最中か。
    var isRecording: Bool { sequence != nil || movie != nil }

    /// 撮っている動画 (検査から中を見るため)。
    var recordingMovie: MovieWriter? { movie }

    // MARK: - 頼まれる

    /// このフレームの絵を 1 枚だけ頼む。
    ///
    /// - Parameter frame: 頼まれたフレームの番号。**この番号の絵が届いたときに書く。**
    func save(_ path: String, at frame: Int) {
        startAfreshIfIdle()
        oneShots.append((frame, path))
    }

    /// 連番か動画を始める。**行き先の綴りが形を決める。**
    ///
    /// `.mov` なら動画、`#` を含むなら連番。どちらでもない名前は断る — 番号の入る
    /// 場所が無い連番を受けてしまうと全部が同じ名前になり、最後の 1 枚しか残らない。
    ///
    /// - Parameter frame: 頼まれたフレームの番号。**録りの 1 枚目はこの番号の絵になる**
    ///   (``recordingFrom``)。
    func beginRecord(_ pattern: String, at frame: Int) {
        guard !isRecording else {
            warnOnce(.alreadyRecording, "beginRecord(): already recording. Carrying on with the current one")
            return
        }
        if pattern.lowercased().hasSuffix(".mov") {
            startAfreshIfIdle()
            movie = MovieWriter(path: pattern, frameRate: frameRate)
            recordingFrom = frame
            forgetWarnings()
            return
        }
        guard let sequence = FrameSequence(pattern: pattern) else {
            warnOnce(
                .patternWithoutNumber,
                "beginRecord(\"\(pattern)\"): a numbered series needs somewhere for the number "
                    + "to go (a run of # characters, as in \"out/frame-####.png\"). "
                    + "Motion is written as .mov, as in \"out/motion.mov\". Not starting")
            return
        }
        startAfreshIfIdle()
        self.sequence = sequence
        recordingFrom = frame
        forgetWarnings()
    }

    /// 暇だったなら、前に頼まれた分の書き損じを持ち越さない。**頼まれ始める直前に呼ぶ。**
    ///
    /// 暇になった出口は並びから外れ、次に頼まれたときに健康状態ごと作り直される
    /// (``SketchRuntime``)。持ち越した失敗や、外れている間に決着した前の書き込みの知らせが
    /// 残っていると、仕切り直したはずの最初のフレームで 1 回ぶん数えられてしまう。
    /// 動画の側は手放すときに消えている (``movieFailure``)。
    private func startAfreshIfIdle() {
        guard isIdle else { return }
        imageFailure = nil
        _ = writer.takeOutcome()
    }

    /// 連番か動画を止める。**頼んだ全部がファイルになってから返る。**
    func endRecord() {
        guard isRecording else {
            warnOnce(.notRecording, "endRecord(): nothing is being recorded")
            return
        }
        sequence = nil
        finishMovie()
        writer.drain()
    }

    /// 撮っている動画を閉じ、**閉じ際に分かったことをここで言う。**
    ///
    /// ``endRecord()`` と ``close()`` の両方が通る 1 本にしてある。同文を 2 か所に
    /// 置くと、片方だけが直った状態を誰も見つけられない。
    ///
    /// ここが**動画の書き損じの最後の読み手**である ([#789])。閉じた時点で動画を
    /// 手放すので、この後に ``receive(_:)`` が来ても `takeFailure()` は何も返さない —
    /// 「\(path) を閉じられませんでした」がいちばん起きてほしくない場面 (撮り終わり)
    /// で誰にも読まれなかったのがこれである。
    ///
    /// **手放すのは閉じ終えてから**である。塞がずに見に来る閉じ方ではまだ閉じていない
    /// 呼び出しが挟まるので、先に手放すと続きを見に来る先が無くなる。
    ///
    /// - Parameter patience: まだ閉じていないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (撮っていない・閉じた・諦めた)。``Patience/block`` なら必ず `true`。
    ///
    /// [#789]: https://github.com/mokume-metal/mokume/issues/789
    @discardableResult
    private func finishMovie(_ patience: Patience = .block) -> Bool {
        guard let movie else { return true }
        guard movie.finish(patience) else { return false }
        self.movie = nil
        movieFailure = nil
        report(movie)
        if let failure = movie.takeFailure() { warnOnce(.movieFailure, failure) }
        return true
    }

    /// 撮り終えた動画のことを 1 行で言う。
    ///
    /// **落ちたフレームは黙って飲まない。** 出口へ届かなかったフレームがあると動きは
    /// カクつくが、時刻はずれないので**再生しても気付きにくい** ([ADR-0025] 決定 2)。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    private func report(_ movie: MovieWriter) {
        guard movie.droppedFrames > 0 else { return }
        warnOnce(
            .droppedFrames,
            "\(movie.path): wrote \(movie.acceptedFrames) frames. \(movie.droppedFrames) could not "
                + "be drawn and are not in it (the times of the frames that remain are not shifted)")
    }

    // MARK: - 差込口

    func receive(_ frame: OutputFrame) {
        // 書き込みは隔離の外で走るので、転んだことが分かるのは頼んだフレームより後になる。
        // 受け取ったときに載せ替えて、続けて転んだら外れる形へつなぐ (ADR-0024 決定 7)
        absorbOutcomes()
        guard !isIdle else { return }

        // **1 フレームに 1 回だけ読み戻す。** 行き先が何個あっても同じ 1 枚を配る
        let image = frame.bytes()
        // **届いた絵より後で頼まれたものは持ち越す。** 絵は 1 枚遅れて届くので、
        // ここで全部書くと `save()` が 1 つ前のフレームの絵を書くことになる (#927)
        for shot in oneShots where shot.frame <= frame.frame {
            writer.write(image, to: shot.path)
        }
        oneShots.removeAll { $0.frame <= frame.frame }
        // **撮り始めたフレームより前の絵は録らない。** これも 1 枚遅れのためで、撮る係が
        // 前のフレームから並びに居ると、撮り始めたフレームで前の絵が届く (#1456)
        guard frame.frame >= recordingFrom else { return }
        if sequence != nil { writer.write(image, to: sequence!.next()) }
        movie?.write(image, frame: frame.frame, time: frame.time)
    }

    /// 決着した書き込みの知らせを**両方から**取り出して、``failure`` を更新する。
    ///
    /// **知らせがあった口だけを更新する** ([#1272])。片方の口の「まだ決着していない」で
    /// もう片方の書き損じまで消すと、数えがそこで 0 に戻る。
    ///
    /// **`??` で繋がない** ([#789])。左が非 nil なら右を評価しないので、静止画が
    /// 転んだフレームでは動画の知らせを取り出さず、最終フレームだと拾う機会が無い。
    ///
    /// [#789]: https://github.com/mokume-metal/mokume/issues/789
    /// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
    func absorbOutcomes() {
        if let outcome = writer.takeOutcome() { imageFailure = outcome.failure }
        if let outcome = movie?.takeOutcome() { movieFailure = outcome.failure }
    }

    /// 終わるときに、頼んだ全部がファイルになるまで待つ。
    ///
    /// 2 度呼んでも安全なので、並びから外れた後に呼ばれても構わない。
    ///
    /// **この 1 行を消さない。** `Outlet` の拡張が空の `close()` を持っているので、消しても
    /// コンパイルは通り、差込口として閉じられたときに何も待たない実装が黙って選ばれる。
    func close() { close(.block) }

    /// 終わるときに、頼んだ全部がファイルになるのを選んだ待ち方で待つ。
    ///
    /// 終わりの経路は塞がずに見に来る (``Patience/peek``・[#978])。**呼び直せば続きから
    /// 見る** — 静止画の待ちが決着していれば、次は動画だけを見る。
    ///
    /// - Parameter patience: まだ済んでいないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (全部済んだ・諦めた)。``Patience/block`` なら必ず `true`。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @discardableResult
    func close(_ patience: Patience) -> Bool {
        if !imagesSettled {
            guard writer.drain(patience) else { return false }
            imagesSettled = true
        }
        guard finishMovie(patience) else { return false }
        imagesSettled = false
        // **ここが最後の読み手である** ([#789])。`receive(_:)` はもう来ないので、
        // 待っている間に判明した静止画・連番の書き損じは、ここで言わなければ
        // 誰も取りに来ない。``endRecord()`` の側では取らない — あちらは同じフレームの
        // `receive(_:)` がまだ来るので、取ると ``SeamHealth`` から 1 回ぶん数えを奪う。
        // 読むのは**閉じ終えた呼び出しだけ**で、まだ待っている呼び出しは取らない
        //
        // [#789]: https://github.com/mokume-metal/mokume/issues/789
        if let failure = writer.takeFailure() { warnOnce(.imageFailure, failure) }
        // **果たせなかった予約を黙って捨てない** ([#1300])。`receive(_:)` はもう来ないので、
        // ここに残っているものは 1 枚もファイルにならない。頼んだのに何の音も立てずに
        // 消えるのが、いちばん分かりにくい壊れ方である
        if !oneShots.isEmpty {
            let paths = oneShots.map { "\"\($0.path)\"" }.joined(separator: ", ")
            warnOnce(
                .unwrittenShots,
                "save(\(paths)): the sketch ended before the picture reached this outlet, "
                    + "so nothing was written")
            oneShots.removeAll()
        }
        return true
    }
}
