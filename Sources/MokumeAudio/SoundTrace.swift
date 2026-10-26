// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 音源が区間の列から引き出す、**波形と拍**の状態 ([#3137])。``AudioIn``・``SoundFile``・``SynthSound`` が
/// 同じこの型を通す (値の遅延は音源ごとに違うが、波形と拍の決まりは 1 か所)。
///
/// ## 波形
///
/// 置いた最新の区間の終わりの ``AudioAnalysis/windowSize`` 標本。空の区間は置かないので、標本が進まなかった
/// フレームは前のまま。時刻を指定した観測の枚 (``show(_:)``) は、指定の秒で終わる区間のものを見せ、通常の続きの
/// 波形は動かさない。
///
/// ## 拍
///
/// 状態 (``BeatTracker``) は**最初の区間を置いたとき**に作り、以後は区間を置くたびに必ず進める。読まれたかどうかに
/// 依らない — 読み始めたフレームによって、それまでの履歴の有無が変わることはない。1 区間は標本あたり二乗和 1 回
/// なので、読まない音源にも払える量である。
///
/// - 流れが切れたか (標本を落とした・飛んだ・鳴らし直した) は、``BeatTracker`` が区間の番号の連続だけで判断する。
///   持ち主は流れを切る操作を知らせなくてよい。番号を付け直しても流れが続くときだけ ``rebase(to:)`` で伝える
/// - 1 フレームに区間を置く回数は 1 回とは限らない (``SoundFile`` が飛ぶフレームは、飛ぶ前の区間と飛び先の
///   区間)。``beginFrame()`` でフレームの頭に拍を消し、``hold(_:)`` はそのフレームの拍を足していく —
///   **飛ぶ前の区間で見つけた拍は、そのフレームの結果として残る**
/// - 時刻を指定した観測の枚は、指定の秒で終わる区間に終わりが入るブロックの拍を、覚えている拍から読む。通常の枚が同じ
///   区間に返す答えと同じ決まりで、続きの状態は動かさない。まだ処理していない先の区間の拍は分からない
///
/// [#3137]: https://github.com/mokume-metal/mokume/issues/3137
struct SoundTrace {
    /// 置かれた最新の (空でない) 区間。
    private var latest: AudioSpan?
    /// 時刻を指定した観測の枚の区間。通常の枚では `nil`。
    private var shown: AudioSpan?
    private var waveformCache: [Float]?
    /// 拍の状態。最初の区間を置くまで `nil`。
    private var beat: BeatTracker?
    /// このフレームの区間に拍があったか。
    private var beatNow = false
    /// 観測の枚の区間に拍があったか。
    private var beatShown = false
    /// 鳴り始める前が無音と分かっている音源か (合成音)。そうなら最初の区間の始まりが標本 0 でなくても、最初の
    /// 立ち上がりを拍にする。
    var beginsSilent = false

    /// 拍の状態が区間を処理した回数。**検査が読む。**
    var beatSteps: Int { beat?.calls ?? 0 }

    /// フレームの頭。このフレームの拍と観測の区間を消す。
    mutating func beginFrame() {
        beatNow = false
        beatShown = false
        if shown != nil {
            shown = nil
            waveformCache = nil
        }
    }

    /// このフレームの区間を置く。空の区間は何も変えない (標本が進まなかったフレームは、波形が前のまま)。
    mutating func hold(_ span: AudioSpan) {
        guard !span.isEmpty else { return }
        latest = span
        waveformCache = nil
        if beat == nil { beat = BeatTracker(fresh: beginsSilent || span.from == 0) }
        if beat?.process(span) == true { beatNow = true }
    }

    /// 時刻を指定した観測の枚が見せる区間。通常の続きは動かさない。観測の枚でなければ `nil` を渡す (何もしない)。
    mutating func show(_ observation: AudioSpan.Observation?) {
        guard let observation else { return }
        let span = observation.span
        shown = span
        waveformCache = nil
        beatShown = beat?.hasBeat(from: span.from, to: span.to) ?? false
    }

    /// 標本の流れが終わった (一発音の終わり・ループしないファイルの終わり)。閉じていない端数のブロックを閉じる。
    mutating func end() {
        if beat?.finish() == true { beatNow = true }
    }

    /// 区間の番号の付け直しで流れが続くとき、続きの番号を伝える (``BeatTracker/rebase(to:)``)。
    mutating func rebase(to position: Int) {
        beat?.rebase(to: position)
    }

    /// 何も鳴っていない状態にする。波形は 0 になるが、**拍の履歴は残す** — 止めた位置から続けるとき、履歴は続く。
    mutating func clear() {
        latest = nil
        shown = nil
        waveformCache = nil
        beatNow = false
        beatShown = false
    }

    /// 流れを忘れる (閉じた・外した・音が来なくなった)。次に鳴り始めるのは、流れの最初から。
    mutating func forget() {
        clear()
        beat = nil
    }

    /// 区間の終わりの ``AudioAnalysis/windowSize`` 標本 (古い順)。何も鳴っていなければ全部 0。
    mutating func waveform() -> [Float] {
        if let waveformCache { return waveformCache }
        let tail = (shown ?? latest)?.tail(AudioAnalysis.windowSize)
            ?? [Float](repeating: 0, count: AudioAnalysis.windowSize)
        waveformCache = tail
        return tail
    }

    /// このフレームの区間 (観測の枚なら、指定の秒で終わる区間) に拍があったか。
    var isBeat: Bool { shown != nil ? beatShown : beatNow }
}
