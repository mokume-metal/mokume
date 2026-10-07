// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 動画のどこを映すか。**時計にも AVFoundation にも触れない**純粋な型で、検査が直に回す。
///
/// ## 位置はスケッチの時刻から決める
///
/// 再生中の位置は「再生を始めた位置 + (いまのフレームの時刻 − 始めたフレームの時刻)」で、
/// 実時間の再生時計を持たない。だから固定の時計で書き出すと、位置はフレーム番号だけで決まる
/// ([ADR-0025] の水準 2・[ADR-0028] 決定 7)。前身のライブラリは再生時計でコマを選んでいたので、
/// 書き出しと揃わなかった (#1960)。
///
/// ## 操作は次のフレームで効く
///
/// ``play()``・``loop()``・``jump(to:)`` は、次の ``advance(to:)`` で始めた位置・飛んだ先を
/// 映す (`Sketch.jumpTime(_:)` と同じ向き)。`draw()` の中で頼んだ操作の時刻を、そのフレームの
/// 時刻にすると、次のフレームでは 1 枚ぶん先へ進んでしまい、頼んだ位置のコマが 1 度も出ない。
/// ``pause()`` だけはすぐ効く — いま映している位置で止める。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated struct Playhead: Equatable {
    /// コマの境目の余裕 (秒)。**境目の手前この長さまでは、次のコマとみなす。**
    ///
    /// スケッチの時刻は単精度なので、フレームの時刻がちょうどコマの境目に乗ると、半分ほどが
    /// 手前へ丸まる (30 fps の動画を 30 fps で回すと、17・19・21… 枚目の時刻が境目をわずかに
    /// 割り、前のコマを取り違える)。単精度の丸めは数千秒まで 1 ms を越えないので、これで吸収する。
    static let tolerance = 0.001

    /// 再生を始めたフレームの時刻と、そのときの位置。
    private struct Anchor: Equatable {
        let time: Double
        let position: Double
    }

    /// 長さ (秒)。正の数。
    let duration: Double
    /// いま映している位置 (秒)。0 から ``duration`` まで。
    private(set) var position: Double = 0
    /// 進んでいるか。
    private(set) var isPlaying = false
    /// 終わりまで行ったら頭へ戻るか。
    private(set) var isLooping = false
    /// 始めたフレーム。再生中で、まだ始めたフレームを迎えていなければ `nil`。
    private var anchor: Anchor?
    /// 次のフレームで飛ぶ先 (秒)。
    private var pendingJump: Double?
    /// 最後に進めたフレームの時刻。
    private var lastTime: Double?

    init(duration: Double) {
        self.duration = duration
    }

    /// 外へ見せる位置 (秒)。飛ぶよう頼まれていれば、その飛び先。
    var reported: Double { pendingJump ?? position }

    /// 終わりまで映したか (ループしていないとき)。
    private var hasEnded: Bool { pendingJump == nil && position >= duration }

    /// 1 度だけ流す。終わりまで映していたら頭から。ループしていたなら、今回の終わりで止まる。
    mutating func play() {
        if isPlaying, isLooping, let lastTime {
            // 起点を今回の頭へ寄せる。寄せないと、何周目かの生の位置が長さを越えていて、
            // 次のフレームですぐ終わる
            anchor = Anchor(time: lastTime, position: position)
        }
        isLooping = false
        start()
    }

    /// 繰り返し流す。終わりまで映していたら頭から。
    mutating func loop() {
        isLooping = true
        start()
    }

    private mutating func start() {
        guard !isPlaying else { return }
        if hasEnded { position = 0 }
        isPlaying = true
        anchor = nil
    }

    /// いま映している位置で止める。
    mutating func pause() {
        isPlaying = false
        anchor = nil
    }

    /// 次のフレームで `seconds` 秒の位置を映す。範囲の外は 0 か長さへ寄せる。
    ///
    /// - Returns: 受け取ったか。数でない値・無限は受け取らない (位置は変わらない)。
    mutating func jump(to seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        pendingJump = min(max(seconds, 0), duration)
        anchor = nil
        return true
    }

    /// フレームの時刻 `time` (秒) まで進め、映す位置を返す。
    mutating func advance(to time: Double) -> Double {
        lastTime = time
        if let target = pendingJump {
            position = target
            pendingJump = nil
            anchor = nil
        }
        guard isPlaying else { return position }
        guard let anchor else {
            // 始めたフレーム。位置は動かさず、ここから数える
            anchor = Anchor(time: time, position: position)
            if isLooping { position = wrapped(position) }
            return position
        }
        let raw = anchor.position + (time - anchor.time)
        if isLooping {
            position = wrapped(raw)
        } else if raw >= duration {
            // 終わりのコマで止まる (Processing の `Movie.play()` と同じ)
            position = duration
            isPlaying = false
            self.anchor = nil
        } else {
            // スケッチの時刻が後ろへ飛んだ (`jumpTime`) ときに頭より前へ行かない
            position = max(0, raw)
        }
        return position
    }

    /// 長さで折り返した位置。**継ぎ目の手前 ``tolerance`` までは頭とみなす** — 単精度の丸めで
    /// ちょうど長さに乗るはずの時刻がわずかに割っても、終わりのコマを 1 枚余計に映さない。
    private func wrapped(_ raw: Double) -> Double {
        var folded = raw.truncatingRemainder(dividingBy: duration)
        if folded < 0 { folded += duration }
        return duration - folded <= Self.tolerance ? 0 : folded
    }
}
