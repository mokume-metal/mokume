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

    /// このフレームに頼まれた 1 枚ものの行き先。
    private var oneShots: [String] = []
    /// 撮っている連番。撮っていなければ `nil`。
    private var sequence: FrameSequence?
    /// 撮っている動画。撮っていなければ `nil`。
    private var movie: MovieWriter?

    private(set) var failure: String?

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

    /// 連番か動画を撮っている最中か。
    var isRecording: Bool { sequence != nil || movie != nil }

    /// 撮った枚数 (この録りの中での通し)。
    var recordedCount: Int { sequence?.index ?? movie?.acceptedFrames ?? 0 }

    /// 撮っている動画 (検査から中を見るため)。
    var recordingMovie: MovieWriter? { movie }

    // MARK: - 頼まれる

    /// このフレームの絵を 1 枚だけ頼む。
    func save(_ path: String) { oneShots.append(path) }

    /// 連番か動画を始める。**行き先の綴りが形を決める。**
    ///
    /// `.mov` なら動画、`#` を含むなら連番。どちらでもない名前は断る — 番号の入る
    /// 場所が無い連番を受けてしまうと全部が同じ名前になり、最後の 1 枚しか残らない。
    func beginRecord(_ pattern: String) {
        guard !isRecording else {
            warnOnce(.alreadyRecording, "beginRecord(): すでに撮っています。いまの録りを続けます")
            return
        }
        if pattern.lowercased().hasSuffix(".mov") {
            movie = MovieWriter(path: pattern, frameRate: frameRate)
            forgetWarnings()
            return
        }
        guard let sequence = FrameSequence(pattern: pattern) else {
            warnOnce(
                .patternWithoutNumber,
                "beginRecord(\"\(pattern)\"): 連番なら番号の入る場所が要ります "
                    + "(\"out/frame-####.png\" のように # を並べる)。"
                    + "動きは \"out/motion.mov\" のように .mov で書きます。撮り始めません")
            return
        }
        self.sequence = sequence
        forgetWarnings()
    }

    /// 連番か動画を止める。**頼んだ全部がファイルになってから返る。**
    func endRecord() {
        guard isRecording else {
            warnOnce(.notRecording, "endRecord(): 撮っていません")
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
    /// [#789]: https://github.com/mokume-metal/mokume/issues/789
    private func finishMovie() {
        guard let movie else { return }
        self.movie = nil
        movie.finish()
        report(movie)
        if let failure = movie.takeFailure() { warnOnce(.movieFailure, failure) }
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
            "\(movie.path): \(movie.acceptedFrames) 枚を書きました。"
                + "\(movie.droppedFrames) 枚は描けなかったので入っていません "
                + "(残った絵の時刻はずれていません)")
    }

    // MARK: - 差込口

    func receive(_ frame: OutputFrame) {
        // 書き込みは隔離の外で走るので、転んだことが分かるのは頼んだフレームより後になる。
        // 受け取ったときに載せ替えて、続けて転んだら外れる形へつなぐ (ADR-0024 決定 7)
        failure = takeFailures()
        guard !isIdle else { return }

        // **1 フレームに 1 回だけ読み戻す。** 行き先が何個あっても同じ 1 枚を配る
        let image = frame.bytes()
        for path in oneShots { writer.write(image, to: path) }
        oneShots.removeAll(keepingCapacity: true)
        if sequence != nil { writer.write(image, to: sequence!.next()) }
        movie?.write(image, frame: frame.frame, time: frame.time)
    }

    /// 溜まっている書き損じを**両方から**取り出して 1 つにまとめる。取り出したら消える。
    ///
    /// **`??` で繋がない** ([#789])。左が非 nil なら右を評価しないので、静止画が
    /// 転んだフレームでは動画の書き損じを取り出さない。取り出さなかったものは
    /// `lastFailure` に残って次のフレームで拾われる — が、**最終フレームだと拾う機会が
    /// 無い**。短絡を選んだ理由は履歴にもコメントにも無く (#488 が 1 行で足したもの)、
    /// 捨ててよい根拠が見つからないので、両方あるときは並べて 1 つの理由にする。
    /// 差込口が持てる理由は 1 つだが、``SeamHealth`` が見るのは `nil` かどうかだけ
    /// なので、繋いでも数え方は変わらない。
    ///
    /// [#789]: https://github.com/mokume-metal/mokume/issues/789
    func takeFailures() -> String? {
        let reasons = [writer.takeFailure(), movie.flatMap { $0.takeFailure() }]
            .compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: " / ")
    }

    /// 終わるときに、頼んだ全部がファイルになるまで待つ。
    ///
    /// 2 度呼んでも安全なので、並びから外れた後に呼ばれても構わない。
    func close() {
        writer.drain()
        finishMovie()
        // **ここが最後の読み手である** ([#789])。`receive(_:)` はもう来ないので、
        // 待っている間に判明した静止画・連番の書き損じは、ここで言わなければ
        // 誰も取りに来ない。``endRecord()`` の側では取らない — あちらは同じフレームの
        // `receive(_:)` がまだ来るので、取ると ``SeamHealth`` から 1 回ぶん数えを奪う
        if let failure = writer.takeFailure() { warnOnce(.imageFailure, failure) }
    }
}
