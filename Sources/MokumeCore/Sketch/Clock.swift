// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import QuartzCore

/// 時刻の出どころ。
///
/// フレームを進める仕組みと、時刻をどこから取るかは別の話である。同じ進め方でも
/// 時刻の出どころを変えれば、絵が再現するかどうかが変わる。
public enum Clock: Equatable, Sendable {
    /// 実際に流れた時間。画面に出しながら動かすときの既定。
    ///
    /// 窓では、その枚が表示される予定の時刻で進む (``SketchPart/time``)。
    case wallClock

    /// フレーム番号から導く。
    ///
    /// **同じスケッチを 2 回走らせると、同じ絵になる。** 実時間を混ぜると、走らせる
    /// たびに数フレームぶんずれた絵が出る — 機械が「変わっていない」と言えなくなる。
    case frameIndex(frameRate: Int)
}

extension SketchSettings {
    /// 窓で走らせるときの時計の選び方 (``SketchSettings/clock``)。
    ///
    /// 走っている時計そのもの (``Clock``) とは別の型にしてある。選ぶ側は刻みを書かずに
    /// ``frames`` と書き、刻みは ``SketchSettings/frameRate`` から採る — 刻みを 2 か所に書くと、
    /// 食い違ったときにどちらを取るかの答えが要る。
    public nonisolated enum ClockMode: Sendable, Hashable, Codable {
        /// 実際に流れた時間で進む (既定)。重いフレームでは時刻を進めて絵だけ抜く。
        case wallClock
        /// フレームの数で進む。``Sketch/draw()`` 1 回がちょうど 1 / ``SketchSettings/frameRate`` 秒で、
        /// 重いフレームでは絵を抜かずに遅くなる。走っている間の ``SketchPart/clock`` は
        /// ``Clock/frameIndex(frameRate:)`` になる。
        case frames
    }
}

extension Clock {
    /// 窓・共有面の経路の時計を、作品の設定から決める。``SketchSettings/ClockMode/frames`` なら宣言の
    /// 刻みのフレーム番号、既定は実時間である。
    ///
    /// 書き出しの頼みがあるときはここを通らず、頼みの刻みのフレーム番号になる (`SketchApplication`) —
    /// `--fps` が作品の宣言と違っても、撮る係の刻み (`SketchRuntime.launchFrameRate`) と最後の 1 枚まで
    /// 揃う。
    ///
    /// - Parameters:
    ///   - mode: 作品が選んだ時計 (``SketchSettings/clock``)。
    ///   - frameRate: 作品の宣言の刻み (``SketchSettings/frameRate``)。
    static func launching(_ mode: SketchSettings.ClockMode, frameRate: Int) -> Clock {
        switch mode {
        case .wallClock: return .wallClock
        case .frames: return .frameIndex(frameRate: frameRate)
        }
    }

    /// 音 (音声ファイルの再生・合成音) をフレームの数で進めるなら、その刻み。実際に鳴らすなら `nil`。
    ///
    /// **鳴らさずに数で進めるのは、フレームの時計で、かつ画面へ出していないときだけ** — 書き出しと、
    /// 窓を持たずに直に回す実行である。フレームの時計を選んだ窓 (``SketchSettings/ClockMode/frames``)
    /// は鳴らす。時計だけで決めると、その窓が無音になる ([#2601])。代償として、処理落ちの間は音が
    /// 実時間で進み、絵とずれる。
    ///
    /// - Parameter onScreen: 画面へ出しながら回しているか (`SketchRuntime.isOnScreen`)。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    package func soundFrameRate(onScreen: Bool) -> Int? {
        guard case .frameIndex(let frameRate) = self, !onScreen else { return nil }
        return frameRate
    }
}

extension SketchPart {
    /// 画面へ出しながら回しているか (`SketchRuntime.isOnScreen`)。音の口が鳴らすかを決めるのに読む
    /// (``Clock/soundFrameRate(onScreen:)``)。走っていなければ `false`。
    package var isOnScreen: Bool { runningSketch?.isOnScreen ?? false }
}

/// 1 フレームの長さ。
///
/// **フレーム番号から導く時計では、秒ではなく「fps 分の 1 秒」のまま持つ** ([#1640])。
/// 1/fps は 2 進で閉じないので、秒に直した値をどの精度で足し合わせても、整数に届く
/// はずのところでわずかに足りなかったり越えたりする。数を数える側 (`emit` の繰り越し・
/// 粒の寿命) は、整数の fps のまま受け取って「rate × 枚数 ÷ fps」「⌊寿命 × fps⌋ 枚」を
/// 丸めずに数える ([ADR-0025] 決定 6 — 揃えたいものを積分で作らない・[#1710])。
///
/// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
/// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
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

    /// 利用者に見せる単精度の秒 (``SketchPart/deltaTime``。p5.js のミリ秒ではない)。
    var deltaTime: Float { Float(seconds) }
}

/// 時刻を配り、フレームの進みを数える。
///
/// 実時間で動かすときの落とし穴を 1 つ引き受ける: **止めている間も実時間は進む。**
/// 止めて再開したとき起点を寄せ直さないと、止めていた時間まるごとが 1 フレームの
/// 経過時間として渡り、それを積分に使う側は 1 回で破綻する。止まり方で口が 2 つあり、
/// 最初の枚も同じ扱いにする:
///
/// - 外から止めて再開した (`SketchRuntime.resume()`) — ``resync()`` で起点を寄せ直し、
///   再開してから次のフレームまでの経過を渡す
/// - 作者が止めていたところから描く (`redraw()` の 1 枚・`loop()` で戻った最初の 1 枚) —
///   ``stepOneFrameNext()`` で、次の 1 枚の経過を**目標の 1 フレームぶん**にする。寄せ直すと
///   頼んだ直後に描くので経過がほぼ 0 秒になり、`deltaTime` (秒) で動かすものが 1 枚進めても
///   動かない ([#1366])。フレーム番号から導く時計の 1 枚と同じ値になる
/// - 最初の枚 — 時計を作ってから最初の枚までの間 (アプリの起動・窓・`setup()`) は描いていた
///   時間ではない。最初の ``advance(at:)`` が起点をその枚へ寄せ、同じ印で経過を目標の
///   1 フレームぶんにする ([#2413])
///
/// **寄せ直せない止まり方もある。** ディスプレイのスリープや駆動源の停止は
/// `pause()` を通らないので ``resync()`` が呼ばれない ([#874])。そこで経過そのものに
/// 上限を置く — 上限に当たったぶん `Σ deltaTime` は ``time`` より短くなるが、
/// **時刻がずれるのと、絵が 1 枚で吹き飛ぶのは別の害**であり、後者だけを断つ
/// ([ADR-0025] 決定 2 が「番号は進め、絵だけ抜く」と決めているのと同じ向き)。
///
/// [#874]: https://github.com/mokume-metal/mokume/issues/874
/// [#1366]: https://github.com/mokume-metal/mokume/issues/1366
/// [#2413]: https://github.com/mokume-metal/mokume/issues/2413
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
@MainActor
final class FrameTiming {
    /// 時刻の出どころ。``SketchPart/clock`` が読む。
    let clock: Clock
    /// 実時間の出どころ。検査が時間を操れるよう差し替えられる形にしてある。
    private let now: () -> Double
    /// 作者への知らせの出口。検査が文面と回数を受け取れるよう差し替えられる形にしてある。
    private let warn: (String) -> Void
    /// 実時間の時計の起点。**最初の枚で、その枚の時刻へ寄せ直す** ([#2413])。作ったときの
    /// 時刻のままにすると、最初の枚の ``time`` に起動・窓・`setup()` の長さが乗る。
    ///
    /// [#2413]: https://github.com/mokume-metal/mokume/issues/2413
    private var started: Double
    private var previous: Double
    /// 直近の枚の「表示の予定の時刻 − 現在時刻」(秒・0 以上)。**予定の時刻を運ばなかった枚は 0。**
    /// 外から止めて再開したときに、起点を予定の時刻の軸へ据えるのに使う (``resync()``・[#2390])。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    private var displayLead: Double = 0

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
    /// これまでの枚の経過 (``step``) を足し込んだもの (秒)。``Countdown`` が減る元 ([#2602])。
    ///
    /// 経過が 0 の枚 (``pauseTime()`` の間・``jumpTime(_:)`` の枚・時刻を指定した観測の枚) では増えず、
    /// 枚が来ない間 (`noLoop()`・外からの停止) も増えない。倍精度で足すので、1/60 を足し続けた丸めは
    /// 単精度の秒 (``Countdown`` が比べる単位) に届かない。
    ///
    /// [#2602]: https://github.com/mokume-metal/mokume/issues/2602
    private(set) var elapsed: Double = 0

    /// 1 フレームぶんとして渡す経過の上限 (秒)。**実時間で動かすときだけ効く。**
    private let maximumDeltaTime: Double
    /// 目標の 1 フレームぶんの間隔 (秒)。止めていたところから描く 1 枚 (``stepOneFrameNext()``) と
    /// 実時間の時計の最初の枚に渡す経過。
    private let frameInterval: Double
    /// 次の ``advance()`` の経過を ``frameInterval`` にするか。1 枚で落ちる。立てるのは
    /// ``stepOneFrameNext()`` と、実時間の時計の最初の ``advance(at:)``。
    private var stepsOneFrame = false

    /// 時計の生の時刻に足す、原点のずれ (秒)。作者が止めた・飛んだぶんだけ動く ([#1286])。
    /// 0 のままなら、時刻は口が入る前と同じ値になる。
    ///
    /// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
    private var offset: Double = 0
    /// いまの枚の、**作者の時計の上の**時刻 (秒)。止めた秒をここから取る。観測の指定秒が
    /// 描き直す枚でも作者の時計の値で、その枚の ``time`` だけが指定秒になる。指定秒を
    /// こちらに入れると、その枚で止めた秒が観測の秒になり、撮った後も作者の時計へ戻らない
    /// ([#2328])。観測の枚を除けば、``time`` の倍精度の元である。
    ///
    /// [#2328]: https://github.com/mokume-metal/mokume/issues/2328
    private(set) var seconds: Double = 0
    /// いまの枚の、``time`` が示す時刻 (倍精度)。観測の指定秒が描き直す枚では、その指定秒 (``time`` と同じ)
    /// で、それ以外は ``seconds`` と同じ。周期の位相 (``SketchPart/phase(period:)``) は、``time`` が
    /// 示す秒から巡らせるのでこちらを読む。
    private(set) var shownSeconds: Double = 0
    /// いまの枚の、作者の時計の上の時刻 (単精度)。**観測の指定秒が描き直す枚でも作者の時計の値**で、
    /// 観測の枚を除けば ``time`` と同じ値である。``draw()`` の外 (入力のコールバック) と、本体が
    /// 持つ状態 (動画の再生位置・録った音の起点) が読む — 観測の秒を状態として積まないために
    /// ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。
    var authorTime: Float { Float(seconds) }
    /// 作者が止めた秒 (``pauseTime()``)。止めていなければ `nil`。
    private var heldAt: Double?
    /// 次の枚で飛ぶ先の秒 (``jumpTime(_:)``)。1 枚で落ちる。
    private var pendingJump: Double?
    /// 数でない飛び先を知らせたか (``jumpTime(_:)``)。2 回目からは言わない。
    private var warnedJump = false

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
    ///   - frameRate: 目標のフレームレート。**実時間で動かすときの**経過の上限と、最初の枚・
    ///     止めていたところから描く 1 枚の経過をここから導く。フレーム番号から導く時計は、自分の
    ///     フレームレートで進む。
    ///   - now: 実時間の出どころ。
    ///   - warn: 作者への知らせの出口。
    init(
        clock: Clock, frameRate: Int = 60,
        now: @escaping () -> Double = { CACurrentMediaTime() },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.clock = clock
        self.warn = warn
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
    /// ずれにも止めた秒にも触れない — 撮った後は作者の時計へ戻る。
    ///
    /// **観測の枚も、作者の時計の帳簿は観測が無い枚と同じに進める** ([#2328])。飛び先は
    /// この枚に着地し、止めている間はずれを寄せ直す。指定秒が上書きするのは、見せる ``time``
    /// と経過 (``step``) だけである。帳簿を飛ばすと、観測の枚をまたいだ飛び先の着地が 1 枚
    /// 遅れ、止めている間に観測の枚で再開した枚が 1 枚先へ進み、観測の枚で止めた秒が作者の
    /// 時計から外れる。代償として、飛び先の秒がこの枚に当たると、その秒の絵は出ない (この枚は
    /// 指定秒を描く)。
    ///
    /// [#2328]: https://github.com/mokume-metal/mokume/issues/2328
    ///
    /// - Parameters:
    ///   - requestedTime: 観測の指定秒。
    ///   - displayTime: この枚が表示される予定の時刻 (`CACurrentMediaTime()` と同じ時間軸の秒)。**実時間の
    ///     時計 (``Clock/wallClock``) だけが読む** ([#2390])。窓・共有面の経路で、表示のリフレッシュが運んだ
    ///     回が渡す。`nil` (予備のタイマーが進めた回・直に回す面) は現在時刻で代える。コールバックが走った
    ///     時刻は main が他の仕事で遅れたぶん揺れるが、予定の時刻は表示の刻みの間隔のまま並ぶ。
    ///     **どちらの回でも ``time`` は前の枚より小さくならない** — 予定の時刻は現在時刻より先なので、
    ///     予備の回の現在時刻が前の枚の予定を下回ることがあり、そのときは前の枚の時刻に留める。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    func advance(at requestedTime: Float? = nil, displayTime: Double? = nil) {
        // 実時間の時計の、この枚の時刻。**前の枚より前へは戻さない** (上の `displayTime`)。
        // フレームの時計は時刻を読まない
        let current = now()
        var moment = max(displayTime ?? current, previous)
        if frameCount == 0, clock == .wallClock {
            // **最初の枚を起点にする** ([#2413])。時刻は時計によらず 0 から始まり (``SketchPart/time``
            // の約束)、経過は止めていたところから描く 1 枚と同じく目標の 1 フレームぶん —
            // 作ってからここまでの間 (起動・窓・`setup()`) は、描いていた時間ではない。
            // フレーム番号の時計は既に 0 と 1 フレームぶんなので、寄せるものが無い
            //
            // **起点は予定の時刻と、ここでの現在時刻の遅いほう** ([#2390])。予定の時刻は表示のリフレッシュが
            // 来た時点で決まっていて、`setup()` (最初の枚の中・先に呼んだ `start()`・止まっている間のコールバック)
            // はその後に走る。予定の時刻だけを起点にすると、`setup()` にかかった時間が 2 枚目の ``time`` と
            // ``deltaTime`` に戻る (#2413 の退行)。`setup()` が刻みの内に収まるなら予定の時刻のままで、
            // 2 枚目の経過は表示の刻みの間隔になる
            //
            // [#2413]: https://github.com/mokume-metal/mokume/issues/2413
            // [#2390]: https://github.com/mokume-metal/mokume/issues/2390
            moment = max(moment, current)
            started = moment
            stepsOneFrame = true
        }
        displayLead = displayTime.map { max(0, $0 - current) } ?? 0
        frameCount += 1
        defer { stepsOneFrame = false }
        let raw: Double
        switch clock {
        case .wallClock:
            raw = moment - started
        case .frameIndex(let frameRate):
            // 時計の刻みも組み立てで検めている。`max(1, …)` は割り算の守り (#1642)。
            // 最初のフレームを 0 秒にする
            raw = Double(frameCount - 1) / Double(max(1, frameRate))
        }
        timeline = raw
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
                step = .seconds(min(max(0, moment - previous), maximumDeltaTime))
            }
            previous = moment
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
        shownSeconds = seconds
        if let requestedTime {
            // 観測の指定秒は、見せる時刻と経過だけを上書きする。作者の時計 (`seconds`・
            // `offset`) は上で観測が無い枚と同じに進めてあり、次の枚はそこから続く
            time = requestedTime
            shownSeconds = Double(requestedTime)
            step = .seconds(0)
        }
        // **見せる経過そのものを足す** — 止めた枚・飛んだ枚・観測の枚は 0 で、積み上げは動かない
        elapsed += step.seconds
    }

    /// 次の枚から時刻を止める。止めた秒は**いまの枚の作者の時計の秒** (``seconds``) で、
    /// 描画は続く。ふだんは ``time`` と同じ値で、観測の指定秒が描き直す枚でだけ違う。
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
    ///
    /// **数でない値・無限は受け取らない** ([#2327])。時計は飛ばずに進み (止めていれば止めた
    /// 秒のまま)、同じ枚で先に頼んだ飛び先も取り消さない。受け取ると原点のずれが非有限になり、
    /// 有限の秒へ飛び直すまで ``time`` が戻らない。毎フレーム呼ばれうる口なので、知らせは
    /// この時計で 1 度だけにする ([ADR-0020] 決定 5・同じ動詞の `Movie.jump(_:)` と同じ形)。
    ///
    /// [#2327]: https://github.com/mokume-metal/mokume/issues/2327
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func jumpTime(_ target: Double) {
        guard target.isFinite else {
            guard !warnedJump else { return }
            warnedJump = true
            return warn("jumpTime(): \(target) is not a time, so the time does not jump")
        }
        pendingJump = target
        if heldAt != nil { heldAt = target }
    }

    /// フレームを 1 枚も進めずに時刻だけが進んだときに、起点を寄せ直す。**外から止めて
    /// 再開したときの口** — 次の経過は、寄せ直してから次のフレームまでに流れた時間になる。
    ///
    /// 実時間で動かしているときにしか効かない — フレーム番号から導く時刻は
    /// そもそも実時間に依存しないので、寄せ直すものがない。
    ///
    /// **起点は、次の枚が使う時間軸に据える** ([#2390])。窓の経路の次の枚は表示の予定の時刻で進み、それは
    /// 現在時刻より約 1 刻み先にある。現在時刻に据えると最初の経過が 1〜2 刻みぶんになるので、直近の枚で
    /// 見た「予定の時刻と現在時刻の差」(``displayLead``) だけ先に据える。**前の枚より前へは戻さない**
    /// (戻すと、前の枚の予定の時刻と今の間が経過に入る)。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    func resync() {
        previous = max(previous, now() + displayLead)
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
