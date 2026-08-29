// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

/// 絵をファイルにする、組み込みの出口。
///
/// **外から足す出口とまったく同じ差込口を通る** ([ADR-0024] 決定 10) — 同じ `Outlet`、
/// 同じ並び、同じ `SeamHealth`。組み込みだけの近道を持たないので、「組み込みにはできて
/// 外にはできないこと」が増えない。
///
/// ## 読み戻しは 1 フレームに 1 回
///
/// 同じフレームに何枚頼まれても、受け取った 1 枚から配る。予約ごとに読み戻すと、
/// 2 つ頼んだフレームだけが 2 倍遅くなる。
///
/// ## 頼まれている間だけ差込口に居る
///
/// 遊んでいる間は ``SketchRuntime`` が並びから外す。付けっぱなしにすると、1 枚だけ
/// 撮ったスケッチが以後ずっと毎フレーム道を通ることになる ([ADR-0023] 決定 5)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
final class FrameRecorder: Outlet {
    /// 書き出す係。
    let writer: FrameWriter

    /// このフレームに頼まれた 1 枚ものの行き先。
    private var oneShots: [String] = []
    /// 撮っている連番。撮っていなければ `nil`。
    private var sequence: FrameSequence?

    private(set) var failure: String?

    init(writer: FrameWriter = FrameWriter()) { self.writer = writer }

    /// 頼まれているものが何も無いか。
    var isIdle: Bool { oneShots.isEmpty && sequence == nil }

    /// 連番を撮っている最中か。
    var isRecording: Bool { sequence != nil }

    /// 撮った枚数 (この録りの中での通し)。
    var recordedCount: Int { sequence?.index ?? 0 }

    // MARK: - 頼まれる

    /// このフレームの絵を 1 枚だけ頼む。
    func save(_ path: String) { oneShots.append(path) }

    /// 連番を始める。
    ///
    /// **番号の入る場所が無い名前は断る。** 受けてしまうと全部が同じ名前になり、
    /// 最後の 1 枚しか残らない。
    func beginRecord(_ pattern: String) {
        guard !isRecording else {
            Diagnostics.warn("beginRecord(): すでに撮っています。いまの録りを続けます")
            return
        }
        guard let sequence = FrameSequence(pattern: pattern) else {
            Diagnostics.warn(
                "beginRecord(\"\(pattern)\"): 番号の入る場所がありません。"
                    + "\"out/frame-####.png\" のように # を並べてください。撮り始めません")
            return
        }
        self.sequence = sequence
    }

    /// 連番を止める。**頼んだ全部がファイルになってから返る。**
    func endRecord() {
        guard isRecording else {
            Diagnostics.warn("endRecord(): 撮っていません")
            return
        }
        sequence = nil
        writer.drain()
    }

    // MARK: - 差込口

    func receive(_ frame: OutputFrame) {
        // 書き込みは隔離の外で走るので、転んだことが分かるのは頼んだフレームより後になる。
        // 受け取ったときに載せ替えて、続けて転んだら外れる形へつなぐ (ADR-0024 決定 7)
        failure = writer.takeFailure()
        guard !isIdle else { return }

        // **1 フレームに 1 回だけ読み戻す。** 行き先が何個あっても同じ 1 枚を配る
        let image = frame.bytes()
        for path in oneShots { writer.write(image, to: path) }
        oneShots.removeAll(keepingCapacity: true)
        if sequence != nil { writer.write(image, to: sequence!.next()) }
    }

    /// 終わるときに、頼んだ全部がファイルになるまで待つ。
    ///
    /// 2 度呼んでも安全なので、並びから外れた後に呼ばれても構わない。
    func close() { writer.drain() }
}
