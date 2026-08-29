// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

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
            Diagnostics.warn("beginRecord(): すでに撮っています。いまの録りを続けます")
            return
        }
        if pattern.lowercased().hasSuffix(".mov") {
            movie = MovieWriter(path: pattern, frameRate: frameRate)
            return
        }
        guard let sequence = FrameSequence(pattern: pattern) else {
            Diagnostics.warn(
                "beginRecord(\"\(pattern)\"): 連番なら番号の入る場所が要ります "
                    + "(\"out/frame-####.png\" のように # を並べる)。"
                    + "動きは \"out/motion.mov\" のように .mov で書きます。撮り始めません")
            return
        }
        self.sequence = sequence
    }

    /// 連番か動画を止める。**頼んだ全部がファイルになってから返る。**
    func endRecord() {
        guard isRecording else {
            Diagnostics.warn("endRecord(): 撮っていません")
            return
        }
        sequence = nil
        if let movie {
            self.movie = nil
            movie.finish()
            report(movie)
        }
        writer.drain()
    }

    /// 撮り終えた動画のことを 1 行で言う。
    ///
    /// **落ちたフレームは黙って飲まない。** 出口へ届かなかったフレームがあると動きは
    /// カクつくが、時刻はずれないので**再生しても気付きにくい** ([ADR-0025] 決定 2)。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    private func report(_ movie: MovieWriter) {
        guard movie.droppedFrames > 0 else { return }
        Diagnostics.warn(
            "\(movie.path): \(movie.acceptedFrames) 枚を書きました。"
                + "\(movie.droppedFrames) 枚は描けなかったので入っていません "
                + "(残った絵の時刻はずれていません)")
    }

    // MARK: - 差込口

    func receive(_ frame: OutputFrame) {
        // 書き込みは隔離の外で走るので、転んだことが分かるのは頼んだフレームより後になる。
        // 受け取ったときに載せ替えて、続けて転んだら外れる形へつなぐ (ADR-0024 決定 7)
        failure = writer.takeFailure() ?? movie.flatMap { $0.takeFailure() }
        guard !isIdle else { return }

        // **1 フレームに 1 回だけ読み戻す。** 行き先が何個あっても同じ 1 枚を配る
        let image = frame.bytes()
        for path in oneShots { writer.write(image, to: path) }
        oneShots.removeAll(keepingCapacity: true)
        if sequence != nil { writer.write(image, to: sequence!.next()) }
        movie?.write(image, frame: frame.frame, time: frame.time)
    }

    /// 終わるときに、頼んだ全部がファイルになるまで待つ。
    ///
    /// 2 度呼んでも安全なので、並びから外れた後に呼ばれても構わない。
    func close() {
        writer.drain()
        if let movie {
            self.movie = nil
            movie.finish()
            report(movie)
        }
    }
}
