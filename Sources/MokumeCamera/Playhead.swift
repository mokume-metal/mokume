// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 動画のどこを映すか。**時計にも AVFoundation にも触れない**純粋な型で、検査が直に回す。
///
/// ## 位置はスケッチの時刻から決める
///
/// 再生中の位置は「再生を始めた位置 + (いまのフレームの時刻 − 始めたフレームの時刻) × 速さ」で、
/// 実時間の再生時計を持たない。だから固定の時計で書き出すと、位置はフレーム番号だけで決まる
/// ([ADR-0025] の水準 2・[ADR-0028] 決定 7)。前身のライブラリは再生時計でコマを選んでいたので、
/// 書き出しと揃わなかった (#1960)。速さも位置の決まり方の一部で、時計には触れない — 同じ速さを同じ
/// フレームで渡せば、同じ位置になる。
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

    /// 再生を始めたフレームの時刻と、そのときの位置、そこから数える速さ。
    ///
    /// 速さを起点に持たせるのは、起点から数える ``position(at:)`` (観測の枚の覗き) が、その起点を
    /// 作った ``advance(to:)`` と同じ速さで数えるため。
    private struct Anchor: Equatable {
        let time: Double
        let position: Double
        let speed: Double
    }

    /// 長さ (秒)。正の数。
    let duration: Double
    /// いま映している位置 (秒)。0 から ``duration`` まで。
    private(set) var position: Double = 0
    /// 進んでいるか。
    private(set) var isPlaying = false
    /// 終わりまで行ったら頭へ戻るか。
    private(set) var isLooping = false
    /// 流す速さ (1 が等倍)。0 以上の有限の数。
    private(set) var speed = 1.0
    /// 始めたフレーム。再生中で、まだ始めたフレームを迎えていなければ `nil`。
    private var anchor: Anchor?
    /// 次のフレームで飛ぶ先 (秒)。
    private var pendingJump: Double?
    /// 最後に進めたフレームの時刻。
    private var lastTime: Double?
    /// 最後の ``advance(to:)`` が数えた起点 (再生中だったフレームだけ)。**終わりに達したフレームでも
    /// 残る** — ``position(at:)`` が、そのフレームを別の時刻で覗くのに要る (#2357)。再生を変える
    /// 操作 (``play()``・``loop()``・``pause()``・``jump(to:)``) が空にする。
    private var projection: Anchor?

    init(duration: Double) {
        self.duration = duration
    }

    /// 外へ見せる位置 (秒)。飛ぶよう頼まれていれば、その飛び先。
    var reported: Double { pendingJump ?? position }

    /// 終わりまで映したか (ループしていないとき)。飛ぶよう頼まれていれば、飛び先が終わりか
    /// (同じフレームの ``jump(to:)`` → ``play()`` でも、終わりから流すので頭から。#3303)。
    private var hasEnded: Bool { reported >= duration }

    /// 1 度だけ流す。終わりまで映していたら頭から。ループしていたなら、今回の終わりで止まる。
    mutating func play() {
        if isPlaying, isLooping, let lastTime {
            // 起点を今回の頭へ寄せる。寄せないと、何周目かの生の位置が長さを越えていて、
            // 次のフレームですぐ終わる
            anchor = Anchor(time: lastTime, position: position, speed: speed)
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
        projection = nil
        guard !isPlaying else { return }
        if hasEnded {
            // 頭から。飛び先を残すと、次のフレームで飛び先の終わりが当たり直す
            position = 0
            pendingJump = nil
        }
        isPlaying = true
        anchor = nil
    }

    /// いま映している位置で止める。
    mutating func pause() {
        isPlaying = false
        anchor = nil
        projection = nil
    }

    /// 流す速さを `rate` に変える。
    ///
    /// 流している間に変えても位置は跳ばない: 最後に進めたフレームの位置から、新しい速さで数え直す
    /// (いまの位置を起点に取り直す)。同じ速さを毎フレーム渡しても位置は変わらない。次のフレームで
    /// 始める前 (``play()`` の後で、まだ ``advance(to:)`` を迎えていない) なら、起点はまだ無く、始めた
    /// フレームから新しい速さで数える。
    ///
    /// - Returns: 受け取ったか。負・数でない値・無限は受け取らない (速さは変わらない)。
    mutating func setSpeed(_ rate: Double) -> Bool {
        guard rate.isFinite, rate >= 0 else { return false }
        speed = rate
        if anchor != nil, let lastTime {
            anchor = Anchor(time: lastTime, position: position, speed: rate)
        }
        return true
    }

    /// 公開の秒 (単精度) を、飛ぶ先の秒 (``jump(to:)`` へ渡す値) に直す。**公開の長さ (``duration`` を単精度に
    /// 丸めたもの) 以上の秒は、内部の長さそのものへ寄せる。** 単精度へ丸めた長さは、内部の長さをわずかに
    /// 割ることがあり (3.3 秒は 3.29999995…)、作者が公開の長さを渡して「終わりへ飛ぶ」つもりでも、
    /// 終わりの手前に着いて「終わりまで映したか」(``hasEnded``) が偽になる (#3303)。数でない値・無限は
    /// そのまま返し、``jump(to:)`` が受け取らない。
    func landing(_ seconds: Float) -> Double {
        guard seconds.isFinite, seconds >= Float(duration) else { return Double(seconds) }
        return duration
    }

    /// 次のフレームで `seconds` 秒の位置を映す。範囲の外は 0 か長さへ寄せる。
    ///
    /// - Returns: 受け取ったか。数でない値・無限は受け取らない (位置は変わらない)。
    mutating func jump(to seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        pendingJump = min(max(seconds, 0), duration)
        anchor = nil
        projection = nil
        return true
    }

    /// フレームの時刻 `time` (秒) まで進め、映す位置を返す。
    mutating func advance(to time: Double) -> Double {
        lastTime = time
        projection = nil
        if let target = pendingJump {
            position = target
            pendingJump = nil
            anchor = nil
        }
        guard isPlaying else { return position }
        guard let anchor else {
            // 始めたフレーム。位置は動かさず、ここから数える
            anchor = Anchor(time: time, position: position, speed: speed)
            projection = anchor
            if isLooping { position = wrapped(position) }
            return position
        }
        projection = anchor
        let raw = anchor.position + (time - anchor.time) * anchor.speed
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

    /// 状態を進めずに、フレームの時刻 `time` (秒) に映す位置を返す。**覗くだけで、積まない。**
    ///
    /// 時刻を指定した観測の枚が、指定の秒に当たるコマを映すのに使う。再生位置・起点・再生中かの
    /// 状態は ``advance(to:)`` が作者の時計の秒で進めたもののままで、観測の秒を受けない
    /// ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。呼ぶのは ``advance(to:)`` の後
    /// (その枚の起点が決まった後) で、再生中でなければいまの位置である。
    ///
    /// **このフレームで終わりに達していても、起点から数え直す。** 観測の秒が終わりより手前なら、手前の
    /// コマを映す (終わりに達したのは作者の時計の秒で、観測の秒ではない)。
    func position(at time: Double) -> Double {
        guard let projection else { return position }
        let raw = projection.position + (time - projection.time) * projection.speed
        if isLooping { return wrapped(raw) }
        return raw >= duration ? duration : max(0, raw)
    }

    /// 長さで折り返した位置。**継ぎ目の手前 ``tolerance`` までは頭とみなす** — 単精度の丸めで
    /// ちょうど長さに乗るはずの時刻がわずかに割っても、終わりのコマを 1 枚余計に映さない。
    private func wrapped(_ raw: Double) -> Double {
        var folded = raw.truncatingRemainder(dividingBy: duration)
        if folded < 0 { folded += duration }
        return duration - folded <= Self.tolerance ? 0 : folded
    }
}
