// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import QuartzCore

/// 時刻の出どころ。
///
/// フレームを進める仕組みと、時刻をどこから取るかは別の話である。同じ進め方でも
/// 時刻の出どころを変えれば、絵が再現するかどうかが変わる。
public enum Clock: Equatable, Sendable {
    /// 実際に流れた時間。画面に出しながら動かすときの既定。
    case wallClock

    /// フレーム番号から導く。
    ///
    /// **同じスケッチを 2 回走らせると、同じ絵になる。** 実時間を混ぜると、走らせる
    /// たびに数フレームぶんずれた絵が出る — 機械が「変わっていない」と言えなくなる。
    case frameIndex(frameRate: Int)
}

/// 1 フレームの長さ。
///
/// **フレーム番号から導く時計では、秒ではなく「fps 分の 1 秒」のまま持つ** ([#1640])。
/// 1/fps は 2 進で閉じないので、秒に直した値をどの精度で足し合わせても、整数に届く
/// はずのところでわずかに足りなかったり越えたりする。数を数える側 (`emit` の繰り越し) は、
/// 整数の fps のまま受け取って「rate × 枚数 ÷ fps」を丸めずに数える
/// ([ADR-0025] 決定 6 — 揃えたいものを積分で作らない)。
///
/// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
enum FrameStep: Equatable {
    /// 整数の fps の 1 フレーム。長さはちょうど 1/`perSecond` 秒。
    case frame(perSecond: Int)
    /// 秒で測った長さ (実時間の経過・直に回す面)。毎回違う値なので、数は「長い目で見て」
    /// 頼んだとおりになる。
    case seconds(Double)

    /// 秒。
    var seconds: Double {
        switch self {
        case .frame(let perSecond): 1 / Double(max(1, perSecond))
        case .seconds(let seconds): seconds
        }
    }

    /// 利用者に見せる単精度の秒 (``Sketch/deltaTime``)。
    var deltaTime: Float { Float(seconds) }
}

/// 時刻を配り、フレームの進みを数える。
///
/// 実時間で動かすときの落とし穴を 1 つ引き受ける: **止めている間も実時間は進む。**
/// 止めて再開したとき起点を寄せ直さないと、止めていた時間まるごとが 1 フレームの
/// 経過時間として渡り、それを積分に使う側は 1 回で破綻する。止まり方で口が 2 つある:
///
/// - 外から止めて再開した (`SketchRuntime.resume()`) — ``resync()`` で起点を寄せ直し、
///   再開してから次のフレームまでの経過を渡す
/// - 作者が止めていたところから描く (`redraw()` の 1 枚・`loop()` で戻った最初の 1 枚) —
///   ``stepOneFrameNext()`` で、次の 1 枚の経過を**目標の 1 フレームぶん**にする。寄せ直すと
///   頼んだ直後に描くので経過がほぼ 0 になり、`deltaTime` で動かすものが 1 枚進めても
///   動かない ([#1366])。フレーム番号から導く時計の 1 枚と同じ値になる
///
/// **寄せ直せない止まり方もある。** ディスプレイのスリープや駆動源の停止は
/// `pause()` を通らないので ``resync()`` が呼ばれない ([#874])。そこで経過そのものに
/// 上限を置く — 上限に当たったぶん `Σ deltaTime` は ``time`` より短くなるが、
/// **時刻がずれるのと、絵が 1 枚で吹き飛ぶのは別の害**であり、後者だけを断つ
/// ([ADR-0025] 決定 2 が「番号は進め、絵だけ抜く」と決めているのと同じ向き)。
///
/// [#874]: https://github.com/mokume-metal/mokume/issues/874
/// [#1366]: https://github.com/mokume-metal/mokume/issues/1366
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
@MainActor
final class FrameTiming {
    private let clock: Clock
    /// 実時間の出どころ。検査が時間を操れるよう差し替えられる形にしてある。
    private let now: () -> Double
    private let started: Double
    private var previous: Double

    /// これまでに進めたフレームの数。最初のフレームの最中は 1。
    private(set) var frameCount = 0
    /// いまのフレームの時刻 (秒)。
    private(set) var time: Float = 0
    /// 前のフレームからの経過。**フレーム番号から導く時計では、秒に直さずに持つ**
    /// (``FrameStep``・[#1640])。経過を数に変える側 (`emit` の端数の繰り越し) がこれを読む。
    /// 単精度の秒を渡していた頃は、`Float(1/50)` のように 1/fps より小さく丸まる fps で、
    /// 毎秒 1 個少なく出ていた。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    private(set) var step: FrameStep = .seconds(0)
    /// いまの枚が時計の上で占める位置 (秒)。**作者が止めた・飛んだぶんを含まない** —
    /// ``time`` は作品が描く時刻で、こちらは枚が並ぶ時刻である。動画のように枚の並びに
    /// 時刻を付ける出口はこちらを読む。止めた間の ``time`` は同じ値が続き、後ろへ飛べば
    /// 戻るので、それを並びの時刻にすると壊れた動画になる ([#1286])。口を使わなければ
    /// ``time`` と同じ値である。
    ///
    /// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
    private(set) var timeline: Double = 0
    /// 前のフレームからの経過 (秒)。``step`` の単精度の写しで、利用者に見せる値。
    var deltaTime: Float { step.deltaTime }

    /// 1 フレームぶんとして渡す経過の上限 (秒)。**実時間で動かすときだけ効く。**
    private let maximumDeltaTime: Double
    /// 目標の 1 フレームぶんの間隔 (秒)。``stepOneFrameNext()`` が渡す経過。
    private let frameInterval: Double
    /// 次の ``advance()`` の経過を ``frameInterval`` にするか。1 枚で落ちる。
    private var stepsOneFrame = false

    /// 時計の生の時刻に足す、原点のずれ (秒)。作者が止めた・飛んだぶんだけ動く ([#1286])。
    /// 0 のままなら、時刻は口が入る前と同じ値になる。
    ///
    /// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
    private var offset: Double = 0
    /// いまの枚の時刻 (秒)。``time`` の倍精度の元で、止めた秒をここから取る。
    private var seconds: Double = 0
    /// 作者が止めた秒 (``pauseTime()``)。止めていなければ `nil`。
    private var heldAt: Double?
    /// 次の枚で飛ぶ先の秒 (``jumpTime(_:)``)。1 枚で落ちる。
    private var pendingJump: Double?

    /// 上限を目標フレームレートから導く。**目標フレーム間隔の 10 倍。**
    ///
    /// 通常のフレーム落ち (数枚) では当たらず、スリープのような長い停止でだけ効く
    /// 水準にしてある。固定値にすると、遅いフレームレートを求めたスケッチで
    /// 1 枚ぶんの間隔が上限を越えてしまう。
    static func maximumDeltaTime(frameRate: Int) -> Double {
        // `max(1, …)` は、組み立て (`SketchRuntime.checkFrameRates`) が 1 未満を断っているので届かない (#1642)。割り算の守りとして残す
        10 / Double(max(1, frameRate))
    }

    /// - Parameters:
    ///   - clock: 時刻の出どころ。
    ///   - frameRate: 目標のフレームレート。**実時間で動かすときの**経過の上限と、止めていた
    ///     ところから描く 1 枚の経過をここから導く。フレーム番号から導く時計は、自分の
    ///     フレームレートで進む。
    ///   - now: 実時間の出どころ。
    init(
        clock: Clock, frameRate: Int = 60,
        now: @escaping () -> Double = { CACurrentMediaTime() }
    ) {
        self.clock = clock
        self.maximumDeltaTime = Self.maximumDeltaTime(frameRate: frameRate)
        // `max(1, …)` は、組み立て (`SketchRuntime.checkFrameRates`) が 1 未満を断っているので届かない (#1642)。割り算の守りとして残す
        self.frameInterval = 1 / Double(max(1, frameRate))
        self.now = now
        let start = now()
        self.started = start
        self.previous = start
    }

    /// フレームを1つ進め、時刻を更新する。指定秒があればこの枚だけ経過を0にする。
    /// 次の枚は元の時計へ戻り、実時計の経過も指定秒との差にはしない。
    ///
    /// 作者が飛んだ枚 (``jumpTime(_:)``) と止めている間 (``pauseTime()``) も経過は 0 で、
    /// 原点のずれを寄せ直して、次の枚がそこから元の刻みで進むようにする。観測の指定秒は
    /// ずれに触れない — 撮った後は作者の時計へ戻る。
    func advance(at requestedTime: Float? = nil) {
        let now = now()
        frameCount += 1
        defer { stepsOneFrame = false }
        let raw: Double
        switch clock {
        case .wallClock:
            raw = now - started
        case .frameIndex(let frameRate):
            // 時計の刻みも組み立てで検めている。`max(1, …)` は割り算の守り (#1642)。
            // 最初のフレームを 0 秒にする
            raw = Double(frameCount - 1) / Double(max(1, frameRate))
        }
        timeline = raw
        if let requestedTime {
            time = requestedTime
            seconds = Double(requestedTime)
            step = .seconds(0)
            previous = now
            return
        }
        switch clock {
        case .wallClock:
            // **時刻は絶対経過のまま (`raw`)。** 何枚落ちても復帰した瞬間に追いつく — 揃えたい
            // ものがあるならこちらを読む (ADR-0025)。止めていたところから描く 1 枚も同じ
            if stepsOneFrame {
                // 止めていた長さによらず、回っているときの 1 枚ぶん (``stepOneFrameNext()``)
                step = .seconds(frameInterval)
            } else {
                // **経過には上限を置く。** 止まっていた時間まるごとを渡すと、積分している
                // 側 (粒・視点) が 1 枚で吹き飛ぶ
                step = .seconds(min(max(0, now - previous), maximumDeltaTime))
            }
            previous = now
        case .frameIndex(let frameRate):
            // 止めていたところから描く 1 枚も、既に 1 フレームぶんしか進まないので
            // ``stepOneFrameNext()`` は効かせるものが無い。見せる `deltaTime` は
            // `Float(1 / rate)` のまま (``FrameStep/deltaTime``)
            step = .frame(perSecond: max(1, frameRate))
        }
        if let target = pendingJump ?? heldAt {
            // 飛んだ枚と止めている枚。**ずれを毎枚寄せ直す** — 再開した次の枚は、
            // 生の時刻の 1 枚ぶんの進みだけ先になる (実時計の経過へ跳ね戻らない)
            pendingJump = nil
            offset = target - raw
            step = .seconds(0)
        }
        seconds = raw + offset
        time = Float(seconds)
    }

    /// 次の枚から時刻を止める。止めた秒は**いまの枚の** ``time`` で、描画は続く。
    /// 止めている間の経過は 0 である。既に止めていれば何もしない。
    func pauseTime() {
        // 同じ枚で先に飛ぶ先を頼まれていれば、そこで止める
        if heldAt == nil { heldAt = pendingJump ?? seconds }
    }

    /// 止めた秒から時刻を進め直す。止めていなければ何もしない。
    func playTime() {
        heldAt = nil
    }

    /// 次の枚の時刻を `target` 秒にする。その枚の経過は 0 で、次の枚からは `target` から
    /// 元の刻みで進む。止めている間なら、`target` で止まり続ける。
    func jumpTime(_ target: Double) {
        pendingJump = target
        if heldAt != nil { heldAt = target }
    }

    /// フレームを 1 枚も進めずに時刻だけが進んだときに、起点を寄せ直す。**外から止めて
    /// 再開したときの口** — 次の経過は、寄せ直してから次のフレームまでに流れた時間になる。
    ///
    /// 実時間で動かしているときにしか効かない — フレーム番号から導く時刻は
    /// そもそも実時間に依存しないので、寄せ直すものがない。
    func resync() {
        previous = now()
    }

    /// 次の ``advance()`` の経過 (``deltaTime``) を、目標の 1 フレームぶんにする。
    /// **作者が止めていたところから描くときの口。**
    ///
    /// 効くのは次の 1 枚だけで、その次からは実際に流れた時間に戻る。``time`` には
    /// 触れない — 止めていた時間ごと進む (ADR-0025 決定 6)。
    ///
    /// 寄せ直し (``resync()``) では足りない。頼まれてすぐ描くので、寄せ直した直後の
    /// 経過はほぼ 0 になる。フレーム番号から導く時計では既に 1 フレームぶんなので、
    /// こちらでは何も変わらない — **どちらの時計でも、止めて 1 枚描いたときの送りが揃う。**
    func stepOneFrameNext() {
        stepsOneFrame = true
    }
}
