// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import QuartzCore

/// スケッチを走らせる。
///
/// ## フレームを進める入口は 1 つ
///
/// [ADR-0012] 決定 3 のとおり、「次のフレームを描く」判断はここにある。**進める入口は
/// ``advance()`` 1 つ**で、誰がそれを叩くかは外側の話 — 1 回だけ叩けば 1 枚だけ描かれ、
/// 一定の間隔で叩けば動き、表示のリフレッシュに合わせて叩けば画面に追随する。
///
/// 進め方が変わっても描かれる中身は変わらない。だから画面を持たない実行と画面に出す
/// 実行が、別の実装に分かれない。
///
/// 例外は 1 つで、**経路** (進め方ではない) で変わる。窓・共有面の経路では、保存した利用者の断片を
/// 裏で組み、組み上がった後のフレームから効かせる ([#2365]・[ADR-0025] 決定 1 の追補 2026-10-14)。
/// 書き出しと、この型を直に作って回す場合は、保存の次のフレームから効く。どちらの経路でも、
/// 叩き方 (main actor を譲るか) で届き方は変わらない。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
@MainActor
public final class SketchRuntime {
    /// 走らせているスケッチ。
    public let sketch: any Sketch
    /// 描いている面。
    public let canvas: Canvas
    /// ``SketchPart/draw(into:_:)`` の閉包の間だけ立つ、スケッチの口の向き先。立っていなければ本体の面
    /// (``canvas``) へ向く。**入れ子では内側の向き先が立ち、抜けると 1 つ前へ戻る** ([#2454])。
    ///
    /// 向き先を引く口は ``activeCanvas`` 1 つだけで、描く・状態を書く・面の大きさを読むスケッチの口
    /// (``SketchPart/liveCanvas(_:_:)``・``SketchPart/canvas``・`emit`・`orbitControl`) がここを通る。
    /// ランタイム自身の描き切り・時刻・出力は本体の面 (``canvas``) のままで、向き先に左右されない。
    ///
    /// [#2454]: https://github.com/mokume-metal/mokume/issues/2454
    var drawingInto: Canvas?
    /// スケッチの口が、いま描く面。``drawingInto`` が立っていればそれ、なければ本体の面。
    var activeCanvas: Canvas { drawingInto ?? canvas }
    /// 出す先。**画面も保存も観測もこの 1 枚を受け取る** ([ADR-0023] 決定 2)。
    ///
    /// 描く細かさを下げているときは、拡大の段を通ったあとの絵である。出口ごとに
    /// 分かれていないので、「画面ではこう見えるのに書き出すと違う」が起こらない。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    public var target: RenderTarget { canvas.output }

    /// いまの絵が、前のフレームの結果に依っているか。意味の説明は ``Sketch`` 側が正本。
    public var usesFrameHistory: Bool { canvas.usesFrameHistory }

    private let timing: FrameTiming
    private let now: () -> Double
    private var hasSetUp = false
    /// ``Sketch/setup()`` が投げた失敗 ([#2401])。立っていれば、フレームは `draw()` を呼ばずにこれを投げる。
    ///
    /// ``start()`` は投げない (公開の口で、呼ぶ側が多い) ので、控えておいて最初のフレームが投げる。
    /// 控えは消えない — 呼び直しても同じ失敗が返り、`draw()` は呼ばれない。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    private(set) var setupFailure: RenderFailure?
    /// ``setupFailure`` を、フレームを投げて受ける道 (``advance()``) の外で見つけたときに知らせる先。窓の経路
    /// (``SketchApplication``) が差し、起動の失敗として終わらせる。名乗りのメニューが開いている間に別の駆動源が
    /// 進めた回 (``advanceForPresence()``) が使う。
    var setupFailureHandler: ((RenderFailure) -> Void)?
    /// 外から止められているか (``pause()``)。
    private var isPaused = false
    /// 作者が回しているか (``noLoop()`` で `false`)。**外の停止とは別に持つ** —
    /// 意味の違いは ``resume()`` の説明にある。
    ///
    /// 読むのは書き出しの経路である — 止まったスケッチは決めた枚数まで進まないので、そこで
    /// 書き出しを終える (`SketchApplication`・[#1282](https://github.com/mokume-metal/mokume/issues/1282))。
    private(set) var isLooping = true
    /// 拡大した字の焼きを、次のフレームへ送ってよい組み方か ([#2446](https://github.com/mokume-metal/mokume/issues/2446))。
    /// **窓・共有面で走らせる `SketchApplication` だけが立てる。** 先送りした字は次のフレームが焼き直すまでぼけて
    /// いるので、絵が窓へ出るだけで、そのフレームを次のフレームが描き直すと分かる走らせ方にしか許さない。
    /// 組み込み (検査・外から `pause()`・画素を読む使い方) と書き出す経路は既定のまま、先送りせず焼き切る。
    var defersEnlargedGlyphBakes = false
    /// 1 枚だけ描いて書き出す口 (``renderFrame(to:)``) の最中か。**書き出す絵は残る**ので、拡大した字の焼きを
    /// 次のフレームへ送らない (``canDeferEnlargedGlyphs``・[#2446](https://github.com/mokume-metal/mokume/issues/2446))。
    private var exportsOneFrame = false
    /// 観測がいま描いているフレームを撮るか (要求を拾った・列を撮っている最中・目録の決着を待っている)。
    /// **撮った絵は残る**ので、拡大した字の焼きを次のフレームへ送らない。``runFrame()`` が描く前に決める。
    private var frameIsObserved = false
    /// 止まっているか — 作者が `noLoop()` で止めた、または外から ``pause()`` されている。
    ///
    /// 窓と出口は、止まっている間に絵が変わっていなければ出し直さない (``SketchApplication``・
    /// [#2367](https://github.com/mokume-metal/mokume/issues/2367))。**走っている間は変わっていなくても
    /// 出す** — 道具が読む速さ・時刻は枚数が上がったときだけ更新されるので、何も描かない回まで飛ばすと
    /// 走っているのに止まって見える。
    var isHeldStill: Bool { !isLooping || isPaused }
    /// 止まっている間に 1 枚だけ描き直すよう頼まれているか (``redraw()``)。
    private var redrawRequested = false
    /// 指定時刻の1枚の最中は連続録画を始めない。通常の時刻へ戻るので順序を保証できない。
    private var observingAtTime = false

    /// 登録された出口。**宣言順**に呼ぶ ([ADR-0024] 決定 4)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private var outlets: [(seam: any Outlet, health: SeamHealth)] = []
    /// 登録された入り口。同じく宣言順。
    private var inlets: [(seam: any Inlet, health: SeamHealth)] = []
    /// 差込口を巡回している深さ (``whileVisitingSeams(_:)``)。
    ///
    /// **巡回の最中に並びを変えてはいけない。** 巡回は並びを `inout` で渡しているので、
    /// その最中に同じ並びへ足した変更は、巡回の終わりの書き戻しで消える (保留を外して
    /// 確かめると、`supply()` の中で足した入り口が黙って並びから落ちた)。入り口の
    /// `supply()` の中から別の入り口を足す、といった頼みはここで見分けて後へ回す (#1988)。
    private var seamVisitDepth = 0
    /// 巡回の最中に頼まれた足し・外し。巡回が終わってから、頼まれた順に当てる。
    private var deferredSeamChanges: [() -> Void] = []
    /// 差込口を閉じたか (``closePlugins(_:)``)。**閉じた後に足したものは誰にも閉じられない**
    /// ので、足す頼みを断る。
    private var seamsClosed = false
    /// 実行中に足した出口が、足されたフレーム。**それより前に描いた絵は渡さない。**
    ///
    /// 配るのは 1〜2 枚遅れなので (#927・#2743)、`draw()` の中で足した出口は、そのままだと同じ
    /// フレームのうちに前の絵を受け取る。足す前に描かれた絵は、頼んだ側から見れば
    /// 自分の知らない絵である (撮る係が #1456 で同じ見分けを自分で持っている)。
    private var outletJoinedAt: [ObjectIdentifier: Int] = [:]

    /// 絵をファイルにする組み込みの出口。**頼まれてはじめて作る。**
    ///
    /// 頼まれている間だけ ``outlets`` に居る (``attachRecorderIfNeeded()``)。
    private var recorder: FrameRecorder?
    /// 撮る係へ渡す刻み。**起動のときに決まった時計の刻み** ([#1457]・[#1282])。
    ///
    /// フレーム番号から導く時計なら、その刻み。実時間の時計なら、起動のときに読んだ
    /// ``SketchSettings/frameRate`` (`deltaTime` の上限も同じ写しから採る)。
    ///
    /// 係を作るとき (最初の `save` か `beginRecord`) に読み直すと、走っている最中に代入した
    /// スケッチでは、各枚の間隔は起動のときのまま、動画の最後の 1 枚の長さだけが代入した値に
    /// 従う。**時計と別の値を採っても同じことが起きる** — 宣言が 60 の作品を 30 の時計で
    /// 回すと (`mokume render --fps 30`)、各枚は 1/30 ずつ進むのに最後の 1 枚だけが 1/60 になる。
    ///
    /// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
    /// [#1457]: https://github.com/mokume-metal/mokume/issues/1457
    private let launchFrameRate: Int

    /// 組み立てで検めた、宣言のフレームレート (``checkFrameRates(declared:clock:)`` を越えた値)。
    ///
    /// **画面の駆動源へ渡す速さはこれを読む** (`SketchApplication`)。`settings` を読み直すと、
    /// 計算型の `settings` は読むたびに別の値を返しうるので、検めた値と渡す値が別物になる
    /// ([#1642](https://github.com/mokume-metal/mokume/issues/1642))。検めた値そのものを持ち回れば、
    /// 1 を割る値が届かないことを構造で保証できる。
    let declaredFrameRate: Int

    /// ランタイムが 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// 走っている最中に ``SketchSettings/frameRate`` が起動のときの値から変わった。
        case frameRateChangedWhileRunning
        /// 観測へ差し出された値が非有限の数だった (``SketchPart/expose(_:_:)-(_,Double)``)。
        /// **ランタイムで 1 度だけ** — 毎フレーム差し出す口で、名前ごとに言うと名前を動的に
        /// 作る作品で控えが増え続ける。
        case nonFiniteExposed
        /// フレームの絵を組んだ投入を GPU が打ち切ったので、そのフレームを出口へ配らなかった
        /// (``settleOldestOutletFrame(_:)``・#2743)。**ランタイムで 1 度だけ** — 壊れた GPU は
        /// 打ち切りを続けうる。
        case droppedOutletFrame
    }

    /// 1 度だけ言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    /// `draw()` の中の同期の読み込みを、口ごとに 1 度だけ知らせる控え (#2601)。読み込みの口が
    /// ``SketchPart/noticeBlockingLoad(_:instead:)`` から言う。
    let blockingLoads = BlockingLoads()

    /// 走っている最中の ``SketchSettings/frameRate`` への代入を、1 度だけ警告して断る
    /// ([#1323](https://github.com/mokume-metal/mokume/issues/1323))。
    ///
    /// 速さは起動のときに 1 度だけ読む (``declaredFrameRate``)。`var settings` と持てば
    /// 代入は通り、読み返しても代入した値が返るので、**黙っていると変えられたように見える**
    /// ([ADR-0020] 決定 5 の「黙って変えない」)。枚数・`time`・`deltaTime` は起動のときの
    /// まま変えず、変わっていないことを言うだけにする。
    ///
    /// 見るのはフレームを進める呼び出しの終わりで、`setup()`・`draw()`・入力のコールバック
    /// のどこで代入しても、止めている間でも、その呼び出しのうちに気付く。計算型の
    /// `settings` が読むたびに違う値を返すスケッチでは、代入していなくても言うことがある
    /// (`SketchApplication` の #1642 の注)。そのときも値は使っていないことに変わりはない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnIfFrameRateWasReassigned() {
        guard !warnings.hasWarned(.frameRateChangedWhileRunning) else { return }
        let current = sketch.settings.frameRate
        guard current != declaredFrameRate else { return }
        warnings.warnOnce(
            .frameRateChangedWhileRunning,
            "settings.frameRate is read only at launch, so changing it to \(current) while"
                + " running has no effect; frames, time and deltaTime keep following"
                + " \(declaredFrameRate) fps")
    }

    /// 組み立てで受け取る刻みを検める。**宣言 (``SketchSettings/frameRate``) も、差し替えた
    /// 時計の刻み (``Clock/frameIndex(frameRate:)``) も 1 以上でなければ断る。**
    ///
    /// 黙って 1 fps へ丸めない ([ADR-0020] 決定 5 の 2 行目・[#1642])。`frameRate: 0` を
    /// 「止める」の意味で書いた人は、1 秒に 1 枚だけ進む絵を見ることになる。窓の経路も
    /// 書き出しの経路もこの組み立てを通るので、**刻みを読む先 (`FrameTiming`・`FrameDriver`・
    /// `MovieFile`・画面の駆動源) へは、ここを越えた値しか届かない。**
    ///
    /// 組み立ての入口は 2 つあるので、どちらもここを呼ぶ。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1642]: https://github.com/mokume-metal/mokume/issues/1642
    static func checkFrameRates(declared: Int, clock: Clock?) throws(RenderFailure) {
        guard declared >= 1 else { throw .invalidFrameRate(declared) }
        if case .frameIndex(let frameRate) = clock, frameRate < 1 {
            throw .invalidFrameRate(frameRate)
        }
    }

    /// 組み立てで検めた、窓を開く倍率 (``checkWindowScale(_:)`` を越えた値)。
    ///
    /// **窓を開く側はこれを読む** (`SketchApplication`)。``declaredFrameRate`` と同じく、
    /// `settings` を読み直すと検めた値と使う値が別物になりうる。
    let windowScale: Float

    /// 組み立てで窓を開く倍率を検める。**0 より大きい有限の数でなければ断る**
    /// ([ADR-0020] 決定 5 の 2 行目)。
    ///
    /// 窓を開かない実行でも断る — 書き出しで通った作品が、窓を開く起こし方に移って初めて
    /// 落ちる形にしない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    static func checkWindowScale(_ scale: Float) throws(RenderFailure) {
        guard scale.isFinite, scale > 0 else { throw .invalidWindowScale(scale) }
    }

    /// 全画面で出すディスプレイ。**組み立てのときに選ぶ** (``SketchSettings/fullScreenDisplay``)。
    /// 窓で開くなら `nil`。
    ///
    /// **窓を開く側はこれを読む** (`SketchApplication`)。``windowScale`` と同じく、`settings` を
    /// 読み直すと、選んだディスプレイと描く大きさが別物になりうる。
    let fullScreenDisplay: Display?

    /// 描く大きさを決める。全画面ならディスプレイを選び、その全画面の大きさにする ([#2020])。
    ///
    /// **窓で開くなら一覧を読まない** — 全画面を頼まないスケッチの起動は、ディスプレイの顔ぶれに
    /// 何も依らない。選べなければ型のついたエラーで断る (``Display/choose(_:from:)``)。窓を
    /// 開かない実行 (書き出し・窓を持たない `SketchRuntime`) でも同じに選ぶ — 書き出す絵は画面に
    /// 出る絵と同じ大きさになり、窓を開く起こし方へ移って初めて落ちる形にもならない。
    ///
    /// - Parameter displays: ディスプレイの一覧の出どころ。**検査から差し替える。**
    ///
    /// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
    static func stage(
        for settings: SketchSettings, displays: () -> [Display]
    ) throws(RenderFailure) -> (width: Int, height: Int, display: Display?) {
        guard let number = settings.fullScreenDisplay else {
            return (settings.width, settings.height, nil)
        }
        let display = try Display.choose(number, from: displays())
        return (display.width, display.height, display)
    }

    /// 撮る係へ渡す刻みを、時計から決める (``launchFrameRate``)。
    static func recordingFrameRate(clock: Clock, declared: Int) -> Int {
        switch clock {
        case .frameIndex(let frameRate): frameRate
        case .wallClock: declared
        }
    }

    /// 閉じ終えるのを待っている撮る係。**居る間はフレームを進めない** (``closePlugins(_:)``)。
    private var closingRecorder: FrameRecorder?
    /// 閉じ終えた撮る係が、1 度でも書き損じていたか (``FrameRecorder/hasFailedToWrite``)。
    ///
    /// **係は閉じ終えたところで手放すので、答えはここに残す。** 読むのは書き出しの経路で、
    /// 書けたかを終了コードにする (`SketchApplication`・[#1282](https://github.com/mokume-metal/mokume/issues/1282))。
    private(set) var recordingFailed = false

    /// 組んだけれどまだ配っていない絵 1 枚。
    private struct PendingOutletFrame {
        /// 出力段を通した絵の置き場。``RenderTarget`` が使い回している 1〜2 枚のどれか。
        let image: EncodedImage
        /// 何枚目の絵か。
        let frame: Int
        /// 並びの時刻 (``OutputFrame/time``)。
        let time: Double
        /// そのフレームを描き始めたときの投入の番号 ([#2743])。**配る前に、これより後の投入の打ち切りを
        /// 判定する** (``settleOldestOutletFrame(_:)``)。
        ///
        /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
        let drawnAfter: UInt64
        /// 組み終えた時点で、出す先の面を最後に書き換えた投入の番号 (``RenderTarget/lastWriteSubmission``)。
        /// 面の中身が欠けている印 (``outletHeldDrop``) を下ろすかを、この絵について決める。
        let lastWriteAtEncode: UInt64
    }

    /// 結末がまだ届いていない絵を、どう決着させるか (#2743)。
    private enum OutcomePatience {
        /// 待たずに問い、届いていなければ控えを残す。毎フレームの経路と、塞がずに閉じる口。
        case ask
        /// 届くまで、上限 (`RenderDevice.outcomeWaitLimit`) まで待つ。次が来ない経路。
        case wait
        /// 待たずに、届いていない結末を届かなかったもの (打ち切り) として決着させる。塞がずに閉じる口が
        /// 上限を過ぎたとき。
        case giveUp
    }

    /// 組んだけれどまだ配っていない絵 (古い順・**高々 2 枚**)。**出口へ渡すのは 1 枚遅らせる** ([#927])。
    /// 結末が未着なら、さらに 1 枚遅れる (下)。
    ///
    /// 組んだフレームでそのまま配ると、配る側が GPU の完了を待つことになり、フレーム
    /// ごとに CPU が GPU に追いつく。1 枚遅らせると、待つ番号は前のフレームのもので、
    /// そこまでに積んだ CPU の仕事 (このフレームの組み立て) が GPU と重なる。
    ///
    /// **配る前に、その絵を組んだ投入の結末を確かめる** ([#2743])。GPU が打ち切っていたら配らない
    /// (置き場には前の絵が残っている)。結末は完了の合図より遅れて届くので、配る時点でまだ届いて
    /// いなければ待たずに次のフレームへ持ち越し、その間のフレームはもう 1 枚の置き場へ組む。だから
    /// 持ち越したフレームは 2 枚遅れで届き、ここには 2 枚まで溜まる。
    ///
    /// 絵は使い回している置き場なので (ADR-0023 決定 5)、ここが持つのは参照である。まだ配って
    /// いない前のフレームの置き場へは組まない (``outletStorageToAvoid()``)。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private var pendingOutletFrames: [PendingOutletFrame] = {
        var frames: [PendingOutletFrame] = []
        frames.reserveCapacity(2)
        return frames
    }()
    /// 絵を取り出せなかったことを、既に言ったか。**毎フレーム言わない。**
    private var warnedEncodeFailed = false
    /// 描いているフレームを描き始めたときの投入の番号 (``PendingOutletFrame/drawnAfter`` の出どころ)。
    private var frameDrawnAfter: UInt64 = 0
    /// 決着させて、まだ出口へ渡していない絵 (古い順)。**渡すのは ``handOverReadyOutletFrames()`` の 1 か所で、
    /// 1 回の巡回にまとめる** (#2743 の反証 5)。同じ進めで 2 枚決着しても、差込口の健康は 1 回ぶんだけ数える。
    private var readyOutletFrames: [PendingOutletFrame] = {
        var frames: [PendingOutletFrame] = []
        frames.reserveCapacity(2)
        return frames
    }()
    /// 決着した絵を渡している最中か。渡した出口の中から呼び直されても、同じ絵を 2 度渡さない。
    private var isHandingOverOutletFrames = false
    /// 出口へ配る前の判定を、最後に済ませた投入の番号 (#2743)。**次の判定の範囲はこれより後から** —
    /// フレームの床 (``PendingOutletFrame/drawnAfter``) と大きいほう。止まっている間に組み直した絵が、
    /// もう判定した打ち切りを数え直さない。面の中身が欠けているかは ``outletHeldDrop`` が持ち越す。
    private var outletJudgedThrough: UInt64 = 0
    /// 出口へ配る前の判定で見つけた、**出す先の面へ書いた投入**の打ち切り ([#2743])。出す先の面へ書く新しい
    /// 投入 (``PendingOutletFrame/lastWriteAtEncode`` が `droppedAt` を越える) まで持ち越し、そのあいだの
    /// 絵は範囲に打ち切りが無くても落とす。
    ///
    /// 打ち切られた投入は 1 画素も書かないので、面の中身は欠けたままである。次のフレームが面へ何も書か
    /// なければ (押している間だけ線を描くスケッチの、押していないフレーム)、その絵も欠けている。投げる
    /// 読む口の持ち越し (``RenderTarget`` の `heldDrop`) と同じ規則で、面へ新しく書けば下ろす。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private var outletHeldDrop: (reason: String, droppedAt: UInt64)?
    /// GPU の打ち切りで出口へ配らなかった枚数 (作ってから通算・#2743)。書き出す経路の終わり
    /// (`SketchApplication`) が、揃わなかった枚数として名乗り、0 以外で終わる。
    private(set) var outletFramesDropped = 0
    /// 閉じる口が、控えの絵を決着させている最中か。**このあいだはフレームを進めない** (``runFrame()``)。
    /// 塞がずに見に来る閉じ方 (``Patience/peek``) は、決着するまで何度も呼ばれる。
    private var outletsClosing = false
    /// 塞がずに見に来る閉じ方が、届いていない結末を諦める時刻 (#2743)。最初に見に来たときに決める。
    private var closingOutcomesGiveUpAt: ContinuousClock.Instant?

    /// 外から観測されるための窓口。区画が無ければ `nil` で、**そのときフレームループは
    /// 観測の存在を一切払わない** (ADR-0018 の面が満たすべき性質)。
    private let observer: FrameObserver?
    /// 外から送られる入力の受け口。区画が無ければ `nil`。
    private let inbox: InputInbox?
    /// 道具の窓が拾った出来事の受け口。**窓を持つ道具に起こされた ``SketchApplication`` が
    /// 渡したときだけ在る** (``relayToolInput(from:)``)。窓を持たない `SketchRuntime` は
    /// 共有面へ差し出さないので、標準入力に触らない
    /// ([#2024](https://github.com/mokume-metal/mokume/issues/2024))。
    private var relayed: StandardInputEvents?
    /// つまみの面 (区画が在るときだけ働く)。
    private let params: ParamSurface?
    /// 合わせた値の保存。**区画とは無関係に既定で効く** (ADR-0030 決定 6)。
    /// 宣言された値の索引。**起動時に 1 度だけ引く。**
    ///
    /// 窓 (``KnobOverlay``) もここから受け取る — それぞれが引き直すと、重複した宣言の
    /// 警告が数えた回数だけ出る ([#994](https://github.com/mokume-metal/mokume/issues/994) の 13)。
    let paramRegistry: ParamRegistry
    private let paramStore: ParamStore?
    /// 入力の合流点。窓からの操作も、外から送られたものもここへ集まる。
    public let input = InputState()
    /// カーソルを捕まえる要求 (``SketchPart/requestPointerLock()``)。``SketchPart/exitPointerLock()`` まで残る。
    ///
    /// **読むのは窓である** — 直に走らせた窓は ``SketchApplication`` が毎リフレッシュ渡し、見張りの
    /// 子は共有面の属性に載せて道具の窓へ渡す ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    /// 窓の無い実行 (書き出し・窓を持たない `SketchRuntime`) では誰も読まないので、何も起きない。
    var pointerLockRequested = false
    /// 矢印のカーソルを隠す要求 (``SketchPart/noCursor()``)。``SketchPart/cursor()`` まで残る。
    ///
    /// ``pointerLockRequested`` と同じく**読むのは窓である** — 直に走らせた窓は ``SketchApplication`` が
    /// 毎リフレッシュ渡し、見張りの子は共有面の属性 (``SharedFrameSurface/cursorHiddenAttribute``) に載せて
    /// 道具の窓へ渡す ([#2439](https://github.com/mokume-metal/mokume/issues/2439))。窓の無い実行では
    /// 誰も読まないので、何も起きない。絵には触れない。
    var cursorHidingRequested = false
    /// 視点を操る道具の状態。**フレームを越える** — 引きずった角度が積み上がる先なので、
    /// 視点 (シーンの記述) と違ってフレームごとには戻らない。まだ触っていなければ `nil`。
    var orbit: Orbit?
    /// 視点を戻す先。**最初に `orbitControl()` を呼んだフレームの ``orbit``** (`setup()` で書いた値か既定)。
    /// ダブルクリックで戻す先になる ([#2762](https://github.com/mokume-metal/mokume/issues/2762))。
    /// **1 度控えたきりで、後から `orbit` を書き換えても変わらない** (決定どおり。`orbitControl` と `orbit` の説明が代償として名乗る)。
    var orbitHome: Orbit?
    /// 視点を操る道具を、最後に進めたフレーム。
    ///
    /// 1 フレームに 2 回呼ばれても 2 回ぶん回さないための目印。同じ引きずった量を
    /// 2 度食わせると倍の速さで回るが、**絵が速いだけなので気付けない**。
    var orbitAdvancedAt = -1
    /// 乱数の状態。**フレームを越える** — 列は呼んだぶんだけ進むものなので、
    /// フレームの頭で戻すと `draw()` が毎回同じ列を引くことになる。
    ///
    /// 揺らぎ (``Canvas/noiseSeed(_:)``) と違って断片へは届かない。断片には列が無く
    /// (画素どうしが独立している)、**値の一致がそもそも定義できない**ためである。
    var randomness = Randomness()
    /// 乱数の列が**置き換えられた回数**。``randomSource`` で取り出した写しが、この列の続きか (印が同じ)、
    /// 自分で作ったもの・古い写し (印が違う) かを見分ける。値には効かない。
    var randomLine: UInt64 = 0
    /// 形の組み立ての中で書いた乱数の種と揺らぎの設定の控え。出口で ``randomness`` と、本体の面の
    /// 揺らぎの設定を戻す (`SketchRuntime+ShapeSeed.swift`・
    /// [#1936](https://github.com/mokume-metal/mokume/issues/1936)・[#2041](https://github.com/mokume-metal/mokume/issues/2041))。
    var seedScopes = SeedScopes()
    /// このフレームでスケッチが差し出した値。観測が無ければ溜めない。
    private var exposedValues: [String: ExposedValue] = [:]
    /// スケッチが測った値 (``measure(_:_:)``)。**フレームを越えて残る** — 同じ名前で
    /// 測り直すまで。観測が無ければ溜めない。
    ///
    /// 報告へ載せるのはここからではなく ``exposedValues`` からで、フレームの頭で
    /// 差し戻す (``beginFrame()``)。報告を組む場所は 2 つあるので、それぞれで合わせると
    /// 片方だけ腐る (#808 と同じ形)。
    private var measuredValues: [String: ExposedValue] = [:]
    /// 続けて撮っている最中の列。撮り終えるまで次の要求を拾わない。
    private var capture: FrameCapture?
    /// 撮り終えて、**書き込みの決着を待っている目録** ([#2381])。全部の書き込みが決着してから書く。
    ///
    /// 撮り終えた時点に組んでおく (フレーム・時刻・負荷はその時点のもの)。決着を待つ間に進んだフレームの
    /// 数字を載せない。決着するまで次の要求は拾わない — 次の撮影の `clearProducts()` が、前の撮影の
    /// 書き込みが走っている最中に絵を消すと、古い絵と新しい目録が組になる。
    ///
    /// [#2381]: https://github.com/mokume-metal/mokume/issues/2381
    private var settling: ObservationReport?
    /// メニューバーで名乗る係。**組み立てのときには何も出さない** — 出すのは
    /// ``SketchPresence/grace`` 秒ぶん進み続けてからである。
    private lazy var presence = SketchPresence(source: self)
    /// 最初に ``advance()`` が呼ばれた時刻。名乗りの経過はここを起点に測る。
    private var firstAdvanceAt: Double?
    /// 名乗りが読む実時間の出どころ。**既定は実時間の単調な時計で、internal の初期化子だけが差し替える**
    /// (検査が実時間も偽れるように・[#3119])。
    ///
    /// [#3119]: https://github.com/mokume-metal/mokume/issues/3119
    private let presenceClock: () -> Double
    /// 最初に ``advance()`` が呼ばれたときの ``presenceClock`` の読み。``firstAdvanceAt`` と対で立つ。
    private var firstAdvanceRealAt: Double?
    /// いまフレームを描いている最中か。入れ子で描き始めないための目印。
    private var isAdvancingFrame = false
    /// 描き終えた (描けなかったものも含む) 最後のフレームの番号。**録りの幅の終わりになる。**
    ///
    /// `frameCount` そのものは、描いている最中なら描き終えていないフレームを、止まっている
    /// 間なら描き終えたフレームを指す。止める口 (`endRecord()`) はどちらからも呼ばれるので、
    /// `frameCount - 1` のような決め打ちでは片方で 1 枚ずれる (#1626 の反証)。
    private var drawnThrough = 0
    /// 最後にフレームを描き終えた時刻。**誰かが進めているか**の判断に使う。
    private var lastFrameAt: Double = 0
    /// フレームの速さを数える、**ただ 1 つの集計器** ([ADR-0030] 決定 7)。
    ///
    /// 窓に出る数字も観測の応答が返す数字もここから採る。**観測の有無に関わらず
    /// 数える** — 窓は観測が無くても数字を出すので、観測が有効なときだけ数えると
    /// 窓の側が自分で測り直す羽目になり、源が 2 つに割れる。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private var tempo = FrameTempo()
    /// 1 フレームの予算を越えたフレームの控え ([#2601])。速さと同じく、窓に出る数字も観測の重さも
    /// ここから採る。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    private var budget: FrameBudget
    /// いま描いているフレームの仕事を始めた時刻 (``budget`` が測る長さの起点)。`setup()` の後に置く。
    private var frameWorkBegan: Double?

    /// 窓に出す数字。**観測の応答が返すものと同じ集計器から採る** (ADR-0030 決定 7)。
    var frameNumbers: FrameNumbers {
        let moment = now()
        return FrameNumbers(
            frameCount: timing.frameCount,
            time: Double(timing.time),
            frameRate: tempo.frameRate(now: moment),
            frameTimeMs: tempo.frameTimeMs(now: moment)?.mean,
            overBudgetFrames: budget.overBudgetFrames,
            heaviestFrame: budget.heaviest?.frame)
    }

    /// これまでに描いたフレームの数。
    public var frameCount: Int { timing.frameCount }
    /// いまのフレームの時刻 (秒)。
    ///
    /// **時刻を指定した観測の枚では、観測の秒を読むのは ``Sketch/draw()`` (と、その直前の入り口の供給)
    /// の間だけである。** それ以外 — 入力のコールバック・`setup()`・止まっている間 — は作者の時計の秒を
    /// 読む。観測の秒がここから漏れると、コールバックで `jumpTime(time + 0.25)` したとき、作者の時計が
    /// 観測の秒へ飛ぶ ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。観測でない枚では
    /// どちらも同じ値である。
    public var time: Float { showsObservedTime ? timing.time : timing.authorTime }
    /// ``time`` が示す秒を、倍精度のまま持つもの。``time`` と同じ約束で読み分ける (観測の秒を読むのは
    /// ``Sketch/draw()`` と入り口の供給の間だけ)。周期の位相 (``SketchPart/phase(period:)``) が読む。
    var timeSeconds: Double { showsObservedTime ? timing.shownSeconds : timing.seconds }
    /// 作者の時計の上の、いまのフレームの時刻 (秒)。**観測の指定秒が描き直す枚でも作者の時計の値。**
    /// 本体が持つ状態 (動画の再生位置・録った音の起点) はこちらで進める。
    var authorTime: Float { timing.authorTime }
    /// ``Sketch/draw()`` と入り口の供給が、観測の秒を読んでいる間だけ立つ。``time`` を参照。
    private var showsObservedTime = false
    /// 前のフレームからの経過 (**秒**)。p5.js の `deltaTime` はミリ秒なので、写すときは係数を 1000 倍する
    /// (`x += 0.2 * deltaTime` → `x += 200 * deltaTime`)。意味の説明は ``SketchPart/deltaTime`` が正本。
    public var deltaTime: Float { timing.deltaTime }
    /// 時刻の出どころ。意味の説明は ``SketchPart/clock`` が正本。
    var clock: Clock { timing.clock }
    /// 描いたフレームの経過を足し込んだもの (秒・``Countdown`` が読む)。
    var elapsed: Double { timing.elapsed }

    /// 画面へ出しながら回しているか。**外の時間で動くもの (音の再生) は、これが真なら実際に鳴らす。**
    ///
    /// 窓・共有面の経路 (`SketchApplication`) が組み立てで頼めば、時計によらず真 — 作品がフレームの
    /// 時計を選んでいても鳴らす ([#2601])。時計だけを見て決めると、フレームの時計を選んだ窓が無音に
    /// なる。頼まなければ時計から決まり、実時間の時計なら真、フレームの時計なら偽 (書き出しと、窓を
    /// 持たずに直に回す実行) である。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    let isOnScreen: Bool

    /// スケッチとその舞台を組み立てる。
    ///
    /// - Parameters:
    ///   - sketch: 走らせるスケッチ。
    ///   - gpu: 描画の土台。
    ///   - clock: 時刻の出どころ。省略すると設定のフレームレートから導く
    ///     **再現する時計**になる — 画面に出す経路が実時間を選ぶ。
    ///   - persistsParams: 合わせたつまみの値の保存 (`.mokume/state/params.json`) を持つか。
    ///     既定は持つ — 起動で保存から値を戻し、変わった値を書く (窓の経路と同じ・
    ///     [ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 6)。
    ///     **`false` なら読みも書きもしない**。撮り直せば同じ絵になることを名乗る書き出し
    ///     (同じ番号のフレームを描く参照スケッチ・説明文の例の撮影) は、撮った人の手元にだけ在る
    ///     保存で絵が変わらないよう、これで組む ([#1832](https://github.com/mokume-metal/mokume/issues/1832))。
    ///     作品の `@Param` は宣言した既定値で動く。
    public convenience init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock? = nil,
        persistsParams: Bool = true
    ) throws(RenderFailure) {
        try self.init(
            sketch: sketch, gpu: gpu, clock: clock, now: { CACurrentMediaTime() },
            persistsParams: persistsParams)
    }

    /// 実時間の出どころを差し替えられる入口 (検査用)。
    ///
    /// - Parameters:
    ///   - displays: ディスプレイの一覧の出どころ (``stage(for:displays:)``)。既定は
    ///     いま繋がっているもの。**検査と、窓を開く側 (`SketchApplication`) から渡す。**
    ///   - onScreen: 画面へ出しながら回すか (``isOnScreen``)。**窓・共有面の経路だけが立てる。**
    ///     立てて `clock` を省くと、時計は作品の設定 (``SketchSettings/clock``) から決まる
    ///     (``Clock/launching(_:frameRate:)``)。設定はここで 1 度だけ読む ([#1642])。
    ///   - persistsParams: 保存を持つか。意味は公開の初期化子の同名の引数が正本。
    ///   - opensFacets: 区画 `observe` / `input` / `params` が在れば開くか。**書き出しの子
    ///     (`SketchApplication` が書き出しの頼みつきで組むとき) だけが偽にする** ([#1619])。
    ///     保存された値の復元は区画と別の口なので、偽でも戻る。
    ///
    /// [#1642]: https://github.com/mokume-metal/mokume/issues/1642
    /// [#1619]: https://github.com/mokume-metal/mokume/issues/1619
    init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock?,
        now: @escaping () -> Double,
        displays: () -> [Display] = { Display.connected },
        onScreen: Bool = false,
        persistsParams: Bool = true,
        opensFacets: Bool = true,
        presenceClock: @escaping () -> Double = { CACurrentMediaTime() }
    ) throws(RenderFailure) {
        let settings = sketch.settings
        try Self.checkFrameRates(declared: settings.frameRate, clock: clock)
        try Self.checkWindowScale(settings.windowScale)
        let stage = try Self.stage(for: settings, displays: displays)
        let clock =
            clock
            ?? (onScreen
                ? Clock.launching(settings.clock, frameRate: settings.frameRate)
                : .frameIndex(frameRate: settings.frameRate))
        self.sketch = sketch
        self.declaredFrameRate = settings.frameRate
        self.windowScale = settings.windowScale
        self.fullScreenDisplay = stage.display
        self.launchFrameRate = Self.recordingFrameRate(clock: clock, declared: settings.frameRate)
        let target = try RenderTarget(gpu: gpu, width: stage.width, height: stage.height)
        self.canvas = try Canvas(
            output: target, gpu: gpu, pixelDensity: settings.pixelDensity,
            upscale: settings.upscale)
        self.timing = FrameTiming(clock: clock, frameRate: settings.frameRate, now: now)
        self.isOnScreen = onScreen || clock == .wallClock
        self.budget = FrameBudget(frameRate: settings.frameRate)
        self.now = now
        self.presenceClock = presenceClock
        // **観測・入力・つまみの区画は、書き出しの子には開かない** (`opensFacets`・#1619)。書き出しは
        // 外から届くものを水準 2 (同じ引数から同じ動き) を壊すものとして断る (ADR-0032「書き出す起こし方」)。
        // 区画を開くと、見張りの世代交代の瞬間に要求を取り合い (入力・つまみの値が絵に混ざる)、
        // 見張りの目録 (`params/report.json`) も起動しただけで書き換える。**保存された値は区画と別の口
        // (`ParamStore`) なので、下で戻る**
        self.observer = opensFacets ? FrameObserver.makeIfEnabled() : nil
        self.inbox = opensFacets ? InputInbox.makeIfEnabled() : nil
        // **管はここで開かない。** 開いてよいかは出口で決まり、出口を決めるのは窓を持つ
        // 側である (``relayToolInput(from:)``・#2024)
        self.relayed = nil
        // 索引は 1 度だけ引き、保存と面と窓が同じものを持ち回る
        let registry = ParamRegistry(of: sketch)
        self.paramRegistry = registry
        // **保存を持たない組み方では、読みも書きもしない** (`persistsParams`・#1832)
        let store = persistsParams ? ParamStore.makeIfNeeded(for: registry) : nil
        self.paramStore = store
        self.params = opensFacets ? ParamSurface.makeIfEnabled(for: registry, store: store) : nil
        canvas.isRuntimeSurface = true
    }

    /// 観測の窓口を差し替えられる入口 (検査用)。
    init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock?,
        now: @escaping () -> Double,
        observer: FrameObserver?,
        inbox: InputInbox? = nil,
        params: ParamSurface? = nil,
        paramStore: ParamStore? = nil,
        displays: () -> [Display] = { Display.connected },
        presenceClock: @escaping () -> Double = { CACurrentMediaTime() }
    ) throws(RenderFailure) {
        let settings = sketch.settings
        try Self.checkFrameRates(declared: settings.frameRate, clock: clock)
        try Self.checkWindowScale(settings.windowScale)
        let stage = try Self.stage(for: settings, displays: displays)
        let clock = clock ?? .frameIndex(frameRate: settings.frameRate)
        self.sketch = sketch
        self.declaredFrameRate = settings.frameRate
        self.windowScale = settings.windowScale
        self.fullScreenDisplay = stage.display
        self.launchFrameRate = Self.recordingFrameRate(clock: clock, declared: settings.frameRate)
        let target = try RenderTarget(gpu: gpu, width: stage.width, height: stage.height)
        self.canvas = try Canvas(
            output: target, gpu: gpu, pixelDensity: settings.pixelDensity,
            upscale: settings.upscale)
        self.timing = FrameTiming(clock: clock, frameRate: settings.frameRate, now: now)
        self.isOnScreen = clock == .wallClock
        self.budget = FrameBudget(frameRate: settings.frameRate)
        self.now = now
        self.presenceClock = presenceClock
        self.observer = observer
        self.inbox = inbox
        self.relayed = nil
        self.paramRegistry = ParamRegistry(of: sketch)
        self.params = params
        self.paramStore = paramStore
        canvas.isRuntimeSurface = true
    }

    // MARK: - 進める

    /// 一度だけの初期化を走らせる。``advance()`` が要れば自分で呼ぶので、
    /// 明示的に呼ばなくてもよい。
    public func start() {
        guard !hasSetUp else { return }
        hasSetUp = true
        registerPlugins()
        // **戻すのは setup より先。** setup も最初の draw も、復元された値を見る
        // (ADR-0030 決定 6)
        let restoration = paramStore?.restore() ?? .init()
        // `setup()` で置いたものは最初のフレームへ持ち越す (``carryingOver(_:)``)。
        // **投げたら控えて、最初のフレームが投げ直す** (``setupFailure``・#2401)
        do {
            try withActiveRuntime { try carryingOver { try sketch.setup() } }
        } catch {
            // 文面は ``Diagnostics/failureText(_:)`` の読み方 1 つ (型を問わず全文・`NSError` はダンプしない)
            setupFailure = .setupFailed(reason: Diagnostics.failureText(error))
        }
        // 最初の応答は setup のあとに書く。setup で決めた値が、外から読める最初の
        // 姿になる
        params?.start(after: restoration)
    }

    /// 宣言された束を差込口へ登録する。**組み立てのときに 1 度だけ。**
    ///
    /// 開くのに失敗した束は**それだけ外して続ける** ([ADR-0024] 決定 7)。1 つの束が
    /// 使えないことでスケッチごと動かなくなるのは、代償が釣り合わない。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private func registerPlugins() {
        for plugin in sketch.plugins {
            let registry = PluginRegistry()
            plugin.register(into: registry)
            // **束の単位で開く。** 出口と入り口の両方を持つ束は、片方が開けなければ
            // 束ごと外れる — 半分だけ生きた束は、書いた人の想定にない状態である
            //
            // **外すのは登録簿からだけでは足りない。** 先に開けた差込口が掴んだ外の資源
            // (映像の口・音の装置) は、ここで閉じないと誰も閉じない — 外した束は下の並びに
            // 載らないので、``closePlugins()`` が届かないためである ([#926])。戻すのは開いた
            // 逆順で、後から開いたものが先に開いたものに依っていても順序が壊れないようにする
            //
            // [#926]: https://github.com/mokume-metal/mokume/issues/926
            // **戻す手を、開いた順に積む。** 開いた側ごとに別の並びを持つと、
            // 差込口の種類が増えた日に巻き戻しの手当てだけが抜ける — 抜けても
            // コンパイルは通り、症状は「掴んだ外の資源が誰にも閉じられない」だけになる
            var undo: [() -> Void] = []
            do {
                for outlet in registry.outlets {
                    try outlet.open()
                    undo.append(outlet.close)
                }
                for inlet in registry.inlets {
                    try inlet.open()
                    undo.append(inlet.close)
                }
            } catch {
                for close in undo.reversed() { close() }
                Diagnostics.warn(
                    "Could not open \(type(of: plugin)): \(error). Carrying on without it")
                continue
            }
            outlets += registry.outlets.map { ($0, SeamHealth()) }
            inlets += registry.inlets.map { ($0, SeamHealth()) }
        }
    }

    /// 差込口を閉じる。**投げない** ([ADR-0024] 決定 7)。
    ///
    /// 頼んだ全部がファイルになるまで**塞いで**待つ。終わりの経路は塞がずに待つ
    /// ``closePlugins(_:)`` を通る。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public func closePlugins() { closePlugins(.block) }

    /// 差込口を閉じ、撮る係が書き終えるのを選んだ待ち方で待つ。**投げない** ([ADR-0024] 決定 7)。
    ///
    /// 終わりの経路は塞がずに見に来る (``Patience/peek``・[#978])。**呼び直せば続きから
    /// 見る** — 差込口を閉じるのは最初の 1 回だけで、2 回目からは撮る係の待ちだけを見る
    /// (終わりの処理で、同じ差込口の `close()` を 2 度呼ばない。外して足し直したときに
    /// `open()` がもう 1 度来る約束とは別の話である — ``Inlet/open()``)。
    ///
    /// **待つのは撮る係だけで、差込口とつまみは先に済ませる。** 撮る係の待ちは動画を閉じ
    /// 終えるまでかかりうるので、その後ろに置くと、待っている間にプロセスが殺されたときに
    /// つまみの最後の 1 手まで失う。
    ///
    /// 待っている間はフレームを進めない (``runFrame()`` の冒頭)。
    ///
    /// - Parameter patience: まだ済んでいないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (全部済んだ・諦めた)。``Patience/block`` なら必ず `true`。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    @discardableResult
    func closePlugins(_ patience: Patience) -> Bool {
        // **閉じる前に決着させる。** 最後のフレームの絵はまだ誰にも渡っていないし (#927)、
        // 止まっている間に頼まれた `save()` にとってはここが最後の機会である (#1300)。
        //
        // **塞がずに見に来る閉じ方では、結末も待たない** (#2743)。届いていない絵があれば、決着して
        // いないと返して次に見に来るのを待つ。届かないまま待つ上限 (`outcomeWaitLimit`) を過ぎたら、
        // 届かなかったものとして落として決着させる — 塞いで待つ閉じ方と同じ上限で諦める
        outletsClosing = true
        let outcomes: OutcomePatience
        switch patience {
        case .block:
            outcomes = .wait
        case .peek:
            let now = ContinuousClock.now
            let giveUpAt = closingOutcomesGiveUpAt ?? (now + target.gpu.outcomeWaitLimit)
            closingOutcomesGiveUpAt = giveUpAt
            outcomes = now >= giveUpAt ? .giveUp : .ask
        }
        guard settleWithoutAnotherFrame(outcomes) else { return false }
        closingOutcomesGiveUpAt = nil
        // 撮り終えた観測の書き込みが決着していなければ、決着させて目録を書く ([#2381])。**終わる前に
        // 目録を書かないと、読み手は絵が揃ったのに目録が来ないまま待つ**
        if let observer, !settleObservation(patience, through: observer) { return false }
        // **撮る係はここでは閉じない。** 並びに居れば同じ `close()` が塞いで待つので、
        // 下で選んだ待ち方で閉じる
        for entry in outlets where entry.seam !== recorder { entry.seam.close() }
        for entry in inlets { entry.seam.close() }
        // **まとめている途中の保存を落とさない。** 引いたつまみの最後の 1 手だけが
        // 消えると、直したはずの値が次の起動で戻っていない形で出る
        paramStore?.flushIfPending()
        // 区画も同じ。最後のフレームで変えた値が応答に届かないまま終わらせない (#1704)。
        // 保存の後に書く — 応答に載った値は保存にも入っている (#1143)
        params?.flushIfChanged()
        outlets.removeAll()
        inlets.removeAll()
        SeamHomes.forgetAll(in: self)
        outletJoinedAt.removeAll()
        seamsClosed = true
        // **並びに居なくても閉じる。** 撮る係は遊んでいる間は外れているので、
        // 並びだけを畳むと最後に頼んだ 1 枚が書かれないまま終わりうる
        if let recorder {
            closingRecorder = recorder
            self.recorder = nil
        }
        guard let closingRecorder else {
            outletsClosing = false
            return true
        }
        // **最後に描いたフレームまでを録りの幅にする。** 撮る係が途中で外れていたら、
        // 末尾の欠けはここで教えないと落ちた数に入らない (#1626)
        guard closingRecorder.close(patience, through: drawnThrough) else { return false }
        if closingRecorder.hasFailedToWrite { recordingFailed = true }
        self.closingRecorder = nil
        outletsClosing = false
        return true
    }

    /// フレームを 1 つ進める。
    ///
    /// 止めている間は描かない — **止めたのに進む**経路を作らないため。ただし観測には
    /// 応える (下記)。呼び出し側は走っているかどうかを気にせずこれを叩けばよい。
    ///
    /// **描けなかったときも観測には応えてから投げる。** 観測を描画の後ろに置いたまま
    /// 素通しで投げると、描画が失敗した瞬間から観測は要求の検出にすら到達せず、
    /// [ADR-0018] 決定 3 の「失敗しても必ず応答する」が効かなくなる。入力は描画の前に
    /// 流し込まれるので生き続け、外からは**観測だけが黙った**ようにしか見えない
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    public func advance() throws(RenderFailure) {
        try advance(displayTime: nil)
    }

    /// フレームを 1 つ進める。実時間の時計では、その枚の時刻を `displayTime` にする。
    ///
    /// **窓・共有面の経路が、表示のリフレッシュが運んだ「その枚が表示される予定の時刻」を渡す口**である
    /// ([#2390])。コールバックが走った時刻は main が他の仕事で遅れたぶん揺れ、``SketchPart/deltaTime`` の
    /// 揺れとして作品に見える。予定の時刻は表示の刻みの間隔のまま並ぶ。フレームの時計・書き出し・観測の指定秒の
    /// 値は変わらない (``FrameTiming/advance(at:displayTime:)``)。
    ///
    /// - Parameter displayTime: この枚が表示される予定の時刻 (`CACurrentMediaTime()` と同じ時間軸の秒)。
    ///   `nil` (予備のタイマーが進めた回・直に回す面) なら現在時刻。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    func advance(displayTime: Double?) throws(RenderFailure) {
        // **描く前に済ませる。** 名乗りのメニューが開くとしたらこの中なので、そのとき
        // ``target`` には直前のフレームが揃っている。止めている間も名乗りは続ける —
        // 止まっているスケッチも、居座っていることに変わりはない
        updatePresence()
        try runFrame(displayTime: displayTime)
    }

    /// フレームを 1 つ進める本体。**名乗りの世話は含まない。**
    ///
    /// 分けてあるのは、名乗りのメニューが開いている間だけ**ここが別の駆動源から呼ばれる**
    /// ためである (``advanceForPresence()``)。``advance()`` ごと呼ぶと、追跡ループの中で
    /// 名乗りの世話が入れ子になる。
    private func runFrame(displayTime: Double? = nil) throws(RenderFailure) {
        // **閉じ終えるのを待っている間は進めない** ([#978])。待ちは塞がずに見に来る形なので、
        // その間も駆動源 (画面の link・予備の Timer・名乗りのメニューの Timer) は呼んでくる。
        // 進めると `draw()` が新しい録りや `save()` を頼み、誰にも閉じられないまま終わる。
        // 駆動源の側で止めないのは、3 本のどれを止め忘れても同じ穴になるためである
        //
        // [#978]: https://github.com/mokume-metal/mokume/issues/978
        let observation = capture == nil && settling == nil ? takeObservationRequest() : nil
        // **`setup()` が投げているなら、どの枝にも入らず投げる** ([#2401])。時刻指定の観測・外の停止・作者の停止
        // (`setup()` で `noLoop()` を呼んでから投げる形はここ) のどれも、この失敗より先に動かない — 動くと、
        // 入力が失敗したスケッチへ配られ、窓は終わらず、書き出しは空の絵を書く。観測の要求には失敗を載せて
        // 応える (ADR-0018 決定 3 の「失敗しても必ず応答する」)。
        //
        // **ここで見えるのは 2 枚目以降。** ``setupFailure`` が立つのは ``start()`` の中で、`start()` を呼ぶ最初の
        // 場所はこの先にある。最初のフレームで `setup()` を走らせる枝は、走らせた直後に自分で見て投げる —
        // 通常の枝は下の ``drawSketchFrame(deliveredInput:at:displayTime:)``、時刻指定の観測の枝は
        // `start()` の直後、外から止められた枝・作者が止めた枝の観測の一枚描きは、応えた直後。見落とすと、
        // 窓の経路は `presentFrame()` へ進み、共有の面は絵を 1 枚書く
        try throwSetupFailure(answering: observation)
        // **観測のフレームでは、保存した断片の組み上がりを待つ** ([#2365])。観測が返す絵と目録は、
        // 保存した中身で描いたものでなければならない (ADR-0018 決定 3)。描かない枝の取り込みも
        // このフレームの中なので、ここで立てれば覆える
        //
        // [#2365]: https://github.com/mokume-metal/mokume/issues/2365
        canvas.gpu.waitsForShaderRebuilds = observation != nil || capture != nil
        defer { canvas.gpu.waitsForShaderRebuilds = false }
        var requestedTime: Float?
        if let observation, observation.time != nil, let observer {
            var refusal = observation.timeWarning
            if isPaused { refusal = "Cannot draw at a specified time while externally paused" }
            if closingRecorder != nil { refusal = "Cannot draw at a specified time while recording is closing" }
            if refusal == nil {
                start() // setupが録画を始める場合も、指定の絵を描く前に断る。
                // **`setup()` が投げたなら、断って返らず投げる** (#2401)。ここは最初のフレームでしか通らない
                // 頭の検査の外なので、自分で見る。返ってしまうと、窓の経路は絵を出しに進む
                try throwSetupFailure(answering: observation)
                if recorder?.isRecording == true {
                    refusal = "Cannot draw at a specified time while recording"
                }
            }
            if let refusal {
                observer.clearProducts()
                finish(
                    id: observation.id, through: observer, frames: [], complete: false,
                    warnings: [observation.unknownKeysWarning, refusal].compactMap { $0 })
                return
            }
            requestedTime = Float(observation.time!)
        }
        // 閉じる口が控えの絵を決着させるのを待っている間も進めない (塞がずに見に来る閉じ方・#2743)
        guard closingRecorder == nil, !outletsClosing else { return }
        observingAtTime = requestedTime != nil
        let keepStopped = observingAtTime && !isLooping
        // 撮る絵は残る。拡大した字の焼きを次へ送らない (#2446)
        frameIsObserved = observation != nil || capture != nil || settling != nil
        defer {
            observingAtTime = false
            frameIsObserved = false
        }
        isAdvancingFrame = true
        defer {
            isAdvancingFrame = false
            lastFrameAt = now()
            warnIfFrameRateWasReassigned()
        }
        guard !isPaused else {
            // **外から止めている間も、出す先が描く先に追い付いていなければ追い付く** ([#1906])。
            // 配った直後の追い付き (下) が失敗した後に止められると、書き込み待ち (細かさを下げた
            // 面なら広げ直し) が残ったまま、止めが解けるまで誰もやり直さない。門で守られている
            // ので、追い付いていれば何も積まない
            //
            // [#1906]: https://github.com/mokume-metal/mokume/issues/1906
            canvas.catchUpOutputWithoutThrowing()
            takeFragmentChangesWithoutAFrame()
            settleWithoutAnotherFrame()
            serveObservationIfRequested(request: observation)
            // 観測の一枚描きが最初のフレームで `setup()` を走らせて、投げたなら、応えた後で投げる (#2401)
            if let setupFailure { throw setupFailure }
            return
        }
        // **作者が止めている間も入力は配る** (``deliverWhileStopped()``)。配ったコールバックが
        // `loop()` か `redraw()` を呼べば、このフレームで描く
        var deliveredInput = false
        if !isLooping, requestedTime == nil {
            if !redrawRequested {
                guard deliverWhileStopped() else {
                    // **配ったコールバックが描く先を変えたなら、ここで出す先を追い付かせる**
                    // (書いた画素を書き戻し、細かさを下げた面なら広げ直す・[#1882]・[#1906])。
                    // 窓・共有の面・書き出し・観測・CPU の読み出しはどれも出す先を読むので、
                    // コールバックを配る 1 点で追い付けば、どの口も同じ 1 枚を受け取る。描き直す
                    // ときは、そのフレームの頭の書き戻しと終わりの拡大が済ませる。変えていなければ
                    // 何も積まない
                    //
                    // [#1882]: https://github.com/mokume-metal/mokume/issues/1882
                    // [#1906]: https://github.com/mokume-metal/mokume/issues/1906
                    canvas.catchUpOutputWithoutThrowing()
                    takeFragmentChangesWithoutAFrame()
                    settleWithoutAnotherFrame()
                    serveObservationIfRequested(request: observation)
                    if let setupFailure { throw setupFailure }  // 上の外の停止の枝と同じ (#2401)
                    return
                }
                deliveredInput = true
            }
            // **止めていたところから描く 1 枚は、目標の 1 フレームぶん進める** ([#1366])。
            // 止まっていた時間は乗せず、ほぼ 0 にもしない。頼んだ経路 (コールバックの中・
            // 呼び出しの外・外の停止の間) をここ 1 か所で拾うので、経路で値が割れない
            //
            // [#1366]: https://github.com/mokume-metal/mokume/issues/1366
            timing.stepOneFrameNext()
        }
        var drawFailure: RenderFailure?
        do {
            try drawSketchFrame(deliveredInput: deliveredInput, at: requestedTime, displayTime: displayTime)
        } catch {
            drawFailure = error
        }
        lastFrameFailedToDraw = drawFailure != nil
        // **落とすのは描いた後。** `draw()` の中で呼ばれた `redraw()` を次のフレームへ
        // 持ち越すと、止めたはずのスケッチが回り続ける (手本も draw の中では効かない)
        redrawRequested = false
        if keepStopped { isLooping = false }
        // **配ってから組む。** 配るのは前のフレームで組んだ絵で、待つ番号もそれなので、
        // ここまでの CPU の仕事が前のフレームの GPU と重なる (#927)。**結末は待たない** — まだ
        // 届いていない絵は次のフレームへ持ち越す (#2743)。ここでは決着させるだけで、配るのは組む
        // 直前 (``encodeForOutlets()``) にまとめる — 組む前にもう 1 枚決着させても巡回は 1 回で済む
        if drawFailure == nil { settlePendingOutletFrames(.ask) }
        // **外すのは配った後、組む前** (配るのは ``encodeForOutlets()`` の頭)。1 枚だけ撮ったスケッチは
        // 配った時点で用済みになるので、この順なら道を 2 回通らない (ADR-0023 決定 5)
        detachRecorderIfDone()
        if drawFailure == nil { encodeForOutlets() }
        // **このフレームで止まったなら、組んだ絵をその場で配る。** 遅らせているのは
        // 次のフレームの CPU と重ねるためなので、次が来ないなら遅らせる意味が無い (#1300)。
        // ここでの `redrawRequested` は上で落としてあるので、残る理由は作者の `noLoop()` である
        if !isLooping { settleWithoutAnotherFrame() }
        // **組み終えたところで測る。** 観測に応える仕事 (絵を書き出す) は作品の重さではない
        if let began = frameWorkBegan {
            budget.record(frame: timing.frameCount, seconds: now() - began)
            frameWorkBegan = nil
        }
        serveObservationIfRequested(request: observation, drawFailure: drawFailure, appliedTime: requestedTime)
        if let drawFailure { throw drawFailure }
    }

    /// ``setup()`` が投げているなら、観測の要求には失敗を載せて応え、同じ失敗を投げる ([#2401])。
    ///
    /// 立っていなければ何もしない。``runFrame(displayTime:)`` の頭と、時刻指定の観測の枝が `start()` を
    /// 呼んだ直後に使う。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    private func throwSetupFailure(answering observation: ObservationRequest?) throws(RenderFailure) {
        guard let setupFailure else { return }
        serveObservationIfRequested(request: observation, drawFailure: setupFailure)
        throw setupFailure
    }

    /// フレームを 1 枚描く手順。**正本はここ 1 つ。**
    ///
    /// 通常のフレーム (``runFrame()``) と、観測がまだ 1 枚も描いていないスケッチを
    /// 叩いたときの 1 枚 (``serveObservationIfRequested(request:drawFailure:appliedTime:)``) が、同じここを
    /// 通る。**かつては 2 か所に書かれており、観測の側だけが腐っていた** — 入り口の
    /// 供給と面への時刻の受け渡しが落ちていて、しかも窓で走らせている限り再現しな
    /// かった ([#808](https://github.com/mokume-metal/mokume/issues/808))。
    ///
    /// 段を足すときはここへ書けば、両方の経路に等しく効く。
    ///
    /// - Parameter deliveredInput: このフレームの入力を、止まっている間に既に当てて配ったか
    ///   (``deliverWhileStopped()``)。当て直すと、前のフレームからの動き (`pmouseX`・
    ///   引きずった量・スクロール) が描くフレームから消える。
    private func drawSketchFrame(
        deliveredInput: Bool = false, at requestedTime: Float? = nil, displayTime: Double? = nil
    ) throws(RenderFailure) {
        // **このフレームの絵が拠る投入は、ここより後に積まれる** (#2743)。出口へ配る前の判定の範囲の
        // 始まりである。`setup()` で積んだものが入るのは、`setup()` をここ (下の `start()`) で走らせる
        // とき — ふつうの最初のフレーム — だけで、先に `start()` を呼んだ使い方 (公開の `start()`・時刻を
        // 指定した観測) では範囲の外になり、出口の側は `setup()` の投入の打ち切りを判定しない。`setup()` で
        // 置いたものは最初のフレームの描き切りが描くので、そちらは範囲に入る
        frameDrawnAfter = target.gpu.submissionCount
        start()
        // **`setup()` が投げたなら、1 枚も描かない** (#2401)。時計も進めず、`draw()` も呼ばない
        if let setupFailure { throw setupFailure }
        // **測るのは `setup()` の後から** — `setup()` は描いていた時間ではない (``FrameBudget``)
        frameWorkBegan = now()
        timing.advance(at: requestedTime, displayTime: displayTime)
        // 描けなかったフレームも、録りの幅には入る (落ちた 1 枚として数える・ADR-0025 決定 2)
        defer { drawnThrough = timing.frameCount }
        beginFrame()
        if !deliveredInput { collectInput() }
        canvas.time = timing.time
        canvas.frameStep = timing.step
        // このフレームの絵を次のフレームが描き直すと分かっているときだけ、拡大した字の焼きを次へ送ってよい。
        // 残る絵 (書き出す・撮る・止める・形に記録する) は要る段で焼き切る (#2446)
        canvas.atlas.mayDeferScaledBakes = canDeferEnlargedGlyphs(at: requestedTime)
        // **入力の配布も入り口の供給も、描き始めた中で行う。**
        //
        // ランタイムが差さっていないと `mousePressed()` の中で `width` を読んだだけで
        // 落ちる。描き始めた中でないと、コールバックの中の `translate()` や `pushStyle()` が
        // 無言で効かない (変換とスタイルの口は `guard isShaping`・光と切り抜きの口は
        // `guard isDrawing` で守られている。形を組み立てている最中でもないので、どちらも外である)。
        // 図形・絵・画素の口は `guard canPlace` で守られている。フレームの外で置けるのは、この面に
        // ランタイムが持ち越しを約束した区間 (`setup()` と止まっている間のコールバック・
        // ``carryingOver(_:)``) だけで、そこで置いたものは次に描くフレームへ出る
        try canvas.draw {
            withActiveRuntime {
                if !deliveredInput { input.beginFrame { deliver($0) } }
                // **観測の秒を読ませるのは、ここから `draw()` の終わりまで。** 上の入力のコールバックは
                // 作者の時計の秒を読む (``time``・#2357)
                showsObservedTime = true
                defer { showsObservedTime = false }
                // **押した・離した (`keyboard.justPressed`) は、描いたフレームの終わりで消す。**
                // 止めている間に配った分は、ここを通るまで残る (`InputState.endFrame()`)
                defer { input.endFrame() }
                supplyFromInlets()
                // **`draw()` の間だけ立てる。** 同期の読み込みを知らせるのはここだけで、`setup()` と
                // 入力のコールバック (上の配り) では言わない (``BlockingLoads``)
                blockingLoads.isDrawing = true
                defer { blockingLoads.isDrawing = false }
                // 作者の `draw()` の区間 (Instruments・#2378)
                let drawInterval = FrameSignposts.beginDraw()
                defer { FrameSignposts.endDraw(drawInterval) }
                sketch.draw()
                // **`draw()` の中で後から決まったことは、ここで知る。** `noLoop()` で止めた・`save()` や
                // `beginRecord()` で撮ると頼んだフレームは、描き直されずに残る。そのフレームで先送りした字は、
                // フレームの終わりに払う (``Canvas/settleDeferredGlyphs(baking:)``・#2446)
                canvas.framePersists = !isLooping || recorder?.isIdle == false
            }
        }
    }

    /// 拡大した字の焼きを、次のフレームへ送ってよいか ([#2446])。**このフレームの絵を、次のフレームが描き直す
    /// と分かっているときだけ** — 近い段の画素で置いた字は、次のフレームが焼き直すまでぼけているので、
    /// 残る絵に載せてはいけない。
    ///
    /// 許すのは、窓・共有面へ出しながら回している間 (``defersEnlargedGlyphBakes``) で、作者が止めておらず・外から止めて
    /// おらず・時刻を指しておらず・観測が撮らず・撮る係 (`save()`・`beginRecord()`・`mokume render`) が
    /// 頼まれておらず・1 枚の書き出しでもないフレームだけである。書き出す・撮る・止める絵と、
    /// `draw()` の中で後から `noLoop()`・`save()` を呼ぶ絵は、既定で許さない側に倒れる。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    private func canDeferEnlargedGlyphs(at requestedTime: Float?) -> Bool {
        defersEnlargedGlyphBakes && isLooping && !isPaused && requestedTime == nil && !frameIsObserved
            && !exportsOneFrame && recorder?.isIdle != false && closingRecorder == nil
    }

    /// 作者が止めている間に届いた入力を引き取り、コールバックを配る。
    ///
    /// **止めていても入力は配る。** 止めたスケッチを動かし直す口 (``loop()`` /
    /// ``redraw()``) は、ふつうコールバックの中から呼ばれる — 配らなければ、一度
    /// 止めたスケッチは二度と動かない。
    ///
    /// 配るのは**フレームの外**である。`draw()` を呼ばないフレームを組むと、効果や
    /// 視点の無い絵が出口へ出て、止まっている間の絵が変わってしまう。そのため
    /// コールバックの中の `translate()` は効かない。**置いた図形・絵・背景は、持ち越しの区間
    /// (``carryingOver(_:)``) の中なので、次に描くフレームへ溜まる** — `redraw()` を呼べばその
    /// フレームに出る。呼ばずに置き続けると、上限を付けずに溜まり続ける (作者が置き続けている
    /// からである・ADR-0021 決定 4 の追補 (2026-09-27))。**書いた画素は溜めない。** 同じ
    /// コールバックで `redraw()` を呼ばなければ、配った直後に面へ戻す (``runFrame()`` の追い付き・
    /// [#1906])。窓に出した絵がそのまま残るので、後で描くフレームの描き切りが失敗しても消えない。
    /// 同じコールバックで `redraw()` を呼べば、そのフレームの頭で戻し、描き切りが失敗すれば
    /// 置いた図形と一緒に捨てる。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    /// 置かれるのは変換も切り抜きも光も周囲も無い状態で、前のフレームが最後に残した分も
    /// 効かない (描き終えたところで戻す — `Canvas.endFrame()`・#1472・#1504)。
    ///
    /// - Returns: 配った結果、このフレームを描くことになったか。
    private func deliverWhileStopped() -> Bool {
        collectInput()
        withActiveRuntime { carryingOver { input.beginFrame { deliver($0) } } }
        // 描き直しの 1 枚の経過は ``runFrame()`` が決める
        return isLooping || redrawRequested
    }

    /// 配られた 1 件を、スケッチの書いた口へ渡す。
    ///
    /// **どの出来事がどの呼び出しになるかは ``InputState`` が決める。** ここは受け取った
    /// 並びをそのまま流すだけで、押下状態の写しを持たない。
    private func deliver(_ callback: InputCallback) {
        switch callback {
        case .mousePressed: sketch.mousePressed()
        case .mouseReleased: sketch.mouseReleased()
        case .mouseClicked: sketch.mouseClicked()
        case .mouseMoved: sketch.mouseMoved()
        case .mouseMovedBy(let deltaX, let deltaY):
            sketch.mouseMoved(deltaX: deltaX, deltaY: deltaY)
        case .mouseDragged(let deltaX, let deltaY):
            sketch.mouseDragged(deltaX: deltaX, deltaY: deltaY)
        case .mouseWheel(let deltaX, let deltaY):
            sketch.mouseWheel(deltaX: deltaX, deltaY: deltaY)
        case .keyPressed: sketch.keyPressed()
        case .keyReleased: sketch.keyReleased()
        case .keyTyped: sketch.keyTyped()
        }
    }

    /// 送られてきた入力を、このフレームの待ち行列へ集める。
    ///
    /// **集めるだけで、当てるのは描き始めてから** (``drawSketchFrame()``)。当てるのと
    /// 同時にコールバックを配るので、配る先がランタイムの差さった描画の中である必要が
    /// ある。集めるほうにその制約は無い。
    private func collectInput() {
        // **窓からのぶんを先に引き取る。** どちらも同じ待ち行列へ入るので、順は
        // 「起きた順に近いほう」を選ぶ — 区画は要求 1 回ぶんをまとめて運ぶので、
        // 窓の 1 件より古いことがある
        relayed?.drain(into: input)
        inbox?.drain(into: input)
        params?.drain()
        paramStore?.tick()
    }

    /// 道具の窓が拾った出来事を、管から受け始める。
    ///
    /// **呼ぶのは、窓を持つ道具に起こされ、区画も在った ``SketchApplication`` だけである**
    /// ([ADR-0032] 決定 1・4)。共有面を用意できずに窓へ倒れた回も呼ぶ — 道具が去ったことに
    /// 気付く口はこの管しか無い。書き出す経路と窓を持たない `SketchRuntime` は呼ばない
    /// ので、標準入力に触らず、閉じていても終わらない (#2024・#2025)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    func relayToolInput(from events: StandardInputEvents) {
        relayed = events
    }

    /// 起こした道具が居なくなっていたら 1 度だけ `true` を返す (``StandardInputEvents/takeDeparture()``)。
    ///
    /// **見張りから起こされていなければ、常に `false`。** 管を読むのはそのときだけなので
    /// (``relayToolInput(from:)``)、`mokume run`・`mokume render` や直に走らせた子の
    /// 標準入力 (端末・閉じた入力) が閉じても終わらない。
    func takeDriverDeparture() -> Bool {
        relayed?.takeDeparture() ?? false
    }

    /// 入り口に値を供給させる。**`draw()` の直前** ([ADR-0024] 決定 6)。
    ///
    /// 供給した値が同じフレームの `draw()` から見える。1 フレーム遅れて効く形にすると、
    /// 外から動かして確かめるときに毎回 1 枚ぶんずれる。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private func supplyFromInlets() {
        whileVisitingSeams {
            Self.visit(&inlets) { $0.supply() } failure: { $0.failure }
        }
    }

    /// 差込口の巡回を包む。**巡回の最中に頼まれた足し・外しは、終わってから当てる** (#1988)。
    ///
    /// 深さで数えるのは、入れ子になりうるからである — 入り口の `supply()` の中で
    /// ``endRecord()`` を呼ぶと、出口の巡回がその中で始まる。
    private func whileVisitingSeams(_ body: () -> Void) {
        seamVisitDepth += 1
        body()
        seamVisitDepth -= 1
        guard seamVisitDepth == 0, !deferredSeamChanges.isEmpty else { return }
        let changes = deferredSeamChanges
        deferredSeamChanges.removeAll()
        for change in changes { change() }
    }

    /// 差込口を 1 巡し、**続けて転んだものを外す**。
    ///
    /// ## なぜ入り口と出口で 1 つなのか
    ///
    /// [ADR-0024] 決定 7 の「毎フレーム呼ばれるものは投げない。続けて転んだらその
    /// 差込口を外し、外したことを診断に出す」は**対で守るもの**である。2 度書いて
    /// いたころ、片方だけ手当てが抜ければ**転び続ける差込口が外れないまま毎フレーム
    /// 費用を払い続ける**形が成立していた — 落ちも警告も出ず、症状は「触っても
    /// 効かない」だけになる。
    ///
    /// **文面もここに置く。** 入り口と出口で 1 バイトも違わなかったので、動かしたのは
    /// 置き場だけである — [#956](https://github.com/mokume-metal/mokume/issues/956) が
    /// 文面 4 本を畳まなかったのは、あちらが**違うことを言っており**、畳むには語幹から
    /// 組み立てる必要があったからで ([#947](https://github.com/mokume-metal/mokume/issues/947)
    /// の「頼んた」)、ここには組み立てが無い。
    ///
    /// `warn` は外したことを知らせる口で、**検査が差し替える**。標準エラーへ実際に出た行は
    /// 検査から読めないので、言ったかどうかと何と言ったかはここで受け取って確かめる
    /// ([#1442])。ランタイムの状態には触れないので、差し替えて回すのに面は要らない。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [#1442]: https://github.com/mokume-metal/mokume/issues/1442
    static func visit<Seam>(
        _ seams: inout [(seam: Seam, health: SeamHealth)], calling act: (Seam) -> Void,
        failure: (Seam) -> String?, warn: (String) -> Void = Diagnostics.warn
    ) {
        for index in seams.indices where seams[index].health.isAttached {
            let seam = seams[index].seam
            act(seam)
            // **理由は 1 度だけ読む。** 2 度読むと、外した判断と言う理由が別の値になりうる
            let reason = failure(seam)
            if seams[index].health.note(reason) {
                // **名乗りは `Any` を経て取る。** `Seam` には存在型 (`any Outlet` /
                // `any Inlet`) が入るので、`type(of: seam)` は中身ではなく存在型そのもの
                // を返し、どれを外したのかが分からない ([#1442])。`Any` へ包み直すと、
                // 中身の型まで降りる
                warn(
                    "\(type(of: seam as Any)) failed again and again, so it was detached"
                        + " (the last reason: \(reason ?? "unknown"))")
            }
        }
    }

    /// 描いた絵を組んで、次のフレームで配れるように控える。
    ///
    /// **道を通るのは 1 フレームに 1 回**で、出口が何本あっても同じ 1 枚を配る
    /// ([ADR-0024] 決定 6 の「全ての出口が同じ道から受け取る」)。出口が 1 つも
    /// 付いていなければ**道を 1 回も通らない** — 使わない機能の費用を、使っていない
    /// スケッチが払わない。
    ///
    /// 組むだけで、GPU の完了は待たない。配るのは次のフレームの
    /// ``deliverPendingToOutlets(_:)`` である ([#927])。
    ///
    /// **まだ配っていない前のフレームの置き場へは組まない** ([#2743]・``outletStorageToAvoid()``)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private func encodeForOutlets() {
        // 組む前に置き場を空け、決着させた絵 (この進めで先に決着させた分も) を 1 回の巡回で配る
        let busy = outletStorageToAvoid()
        // 配った絵で、1 枚だけ撮った係が用済みになったなら外して、組まない
        // (配った後に外す ``runFrame()`` と同じ理由・ADR-0023 決定 5)
        detachRecorderIfDone()
        guard outlets.contains(where: { $0.health.isAttached }) else { return }
        let image: EncodedImage
        do {
            image = try target.encodeToImage(avoiding: busy)
        } catch {
            // 毎フレーム走る経路なので投げない (ADR-0020 決定 5)。1 度だけ言う
            guard !warnedEncodeFailed else { return }
            warnedEncodeFailed = true
            Diagnostics.warn("Could not take the frame that goes to an outlet: \(error.headline)")
            return
        }
        // 同じ置き場を指す控えは、同じフレームの絵を組み直したものなので 1 つにまとめる
        pendingOutletFrames.removeAll { $0.image === image }
        // 並びの時刻は作品の `time` ではなく時計の上の位置 (作者が止めても動画が壊れない・#1286)
        pendingOutletFrames.append(
            PendingOutletFrame(
                image: image, frame: timing.frameCount, time: timing.timeline,
                drawnAfter: frameDrawnAfter, lastWriteAtEncode: target.lastWriteSubmission))
    }

    /// 出力段を組む前に、**上書きしてはいけない置き場**を答える ([#2743])。いまの絵より前のフレームの、
    /// まだ配っていない絵の置き場である。
    ///
    /// 同じフレームの絵の置き場は上書きしてよい (同じ絵を組み直すだけ)。前のフレームの絵で 2 枚とも
    /// 埋まっていたら、古いほうを決着させる — 置き場は 2 枚までで、持ち越しが続いて埋まったときだけ
    /// 待つ (打ち切りの無い普段の経路では、次のフレームで配るときに結末がほぼ必ず届いている)。
    ///
    /// **組む前に、決着させた絵を配る** (``handOverReadyOutletFrames()``)。置き場を空けるために決着させた
    /// 絵は、組めば書き換わる。
    ///
    /// 出口へ配る絵のほか、観測の撮影・1 枚だけ描いて書き出す入口・名乗りの絵も、同じ置き場へ組む
    /// ので、ここを通す。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private func outletStorageToAvoid() -> EncodedImage? {
        let current = timing.frameCount
        if pendingOutletFrames.count >= 2, pendingOutletFrames.allSatisfy({ $0.frame != current }) {
            // **先に、組む前の待ち (前の出力段の合図・#927) を済ませてから問い直す。** その待ちは組む
            // ときに必ず通るので、前に出しても待ちは増えない。待つ間に古いほうの結末が届いていれば、
            // 結末を待たずに決着する
            target.gpu.waitForSubmissionQuietly(
                target.lastEncodeSubmission,
                orWarn: "Could not wait for the GPU before taking the frame that goes to an outlet")
            if !settleOldestOutletFrame(.ask) {
                settleOldestOutletFrame(.wait)
            }
        }
        handOverReadyOutletFrames()
        return pendingOutletFrames.first { $0.frame != current }?.image
    }

    /// 控えてある絵を古い順に決着させ、決着した絵を出口へ配る。控えが無ければ何もしない。
    ///
    /// **配る絵は中身が確定している。** 組んだ投入を名指しで待ってから渡すので、出口は
    /// 受け取った ``OutputFrame/texture`` をそのまま別のプロセスや機材へ手渡せる —
    /// 外の出口はこの保証に寄りかかっている ([#927])。遅らせているぶん、この待ちは
    /// ふつう何もせずに返る。
    ///
    /// **GPU が打ち切ったフレームは配らない** ([#2743])。中身を確定させるのは合図の待ちだが、合図は
    /// 打ち切りでも進む。配る前に結末を確かめる (``settleOldestOutletFrame(_:)``)。
    ///
    /// **転んだフレームでは配らない** ([ADR-0024] 決定 10)。控えはそのまま持ち越して、
    /// 次に描けたフレームか終わり (``closePlugins()``) で配る — 描けた絵を落とさない。
    ///
    /// - Parameter patience: 結末がまだ届いていない絵の扱い。待つのは次が来ない経路 (止め際・閉じ際・
    ///   止まったスケッチの `save()`) だけで、**毎フレームの経路 (``runFrame()``) は待たない**。
    /// - Returns: 控えが全部決着したか。待たずに、届いていない絵が残ったら `false`。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    @discardableResult
    private func deliverPendingToOutlets(_ patience: OutcomePatience) -> Bool {
        let settled = settlePendingOutletFrames(patience)
        handOverReadyOutletFrames()
        return settled
    }

    /// 控えてある絵を古い順に決着させる。**配るのは呼んだ側** (``handOverReadyOutletFrames()``)。
    ///
    /// 毎フレームの経路は、ここで決着させた絵を組む前にまとめて配る (``encodeForOutlets()``) — 同じ進めで
    /// 組む前にもう 1 枚決着させても、出口の巡回は 1 回で済む。
    ///
    /// - Returns: 控えが全部決着したか。
    @discardableResult
    private func settlePendingOutletFrames(_ patience: OutcomePatience) -> Bool {
        while !pendingOutletFrames.isEmpty {
            guard settleOldestOutletFrame(patience) else { return false }
        }
        return true
    }

    /// 控えのうち最も古い絵を決着させる — 配る絵に回すか、打ち切りなら配らずに捨てる ([#2743])。
    ///
    /// **判定の範囲は、そのフレームを描き始めたときの投入の後から、置き場へ組んだ最後の出力段まで**
    /// (前に判定を済ませた投入より前は入れない・``outletJudgedThrough``)。面へ書く投入に絞らない — 置いた
    /// 別の描き場所の描画のように、絵が拠るのに面へは書かない投入もあるので、投げる読む口
    /// (``RenderTarget/readPixels()``) と同じく保守的に落とす側へ倒す。打ち切られた投入は 1 画素も書かない
    /// ので、置き場には前の絵が残っている — それをそのフレームの番号で配ると、書き出しが前の絵をその
    /// 番号で書く。
    ///
    /// **範囲に打ち切りが無くても、面の中身が欠けたままなら落とす** (``outletHeldDrop``)。出す先の面へ書いた
    /// 投入が打ち切られた後、面へ新しく書くまでの絵である。
    ///
    /// **書き直さずに落とす。** 配るのは次のフレームの途中で、面には既に次のフレームを描いてあり、
    /// 打ち切られたフレームの絵を作り直す材料が残っていない。描画が転んだフレームと同じく出口へは
    /// 配らない (ADR-0024 決定 10) — 動画からはその枚が欠け (前の枚が 1 枚ぶん長く映り、ほかの枚の
    /// 時刻はずれない)、連番は詰まり、どちらも止め際に落ちた数として名乗る。`save()` は次に配れた
    /// フレームの絵で書く。外から足した出口も同じに受け取らない。ランタイムで 1 度だけ言い、書き出す
    /// 経路は落とした枚数で揃わなかったと名乗る (``outletFramesDropped``)。
    ///
    /// - Parameter patience: 結末がまだ届いていないときの扱い (``deliverPendingToOutlets(_:)``)。
    /// - Returns: 決着したか。待たずに、結末がまだ届いていなかったら `false` (控えは残す)。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    @discardableResult
    private func settleOldestOutletFrame(_ patience: OutcomePatience) -> Bool {
        guard let pending = pendingOutletFrames.first else { return true }
        guard outlets.contains(where: { $0.health.isAttached }) else {
            pendingOutletFrames.removeFirst()
            return true
        }
        // 置き場へ最後に組んだ出力段。同じフレームの絵を組み直していれば (観測の撮影など) それを指す
        let through = pending.image.pendingSubmission
        let floor = max(pending.drawnAfter, outletJudgedThrough)
        let gpu = target.gpu
        gpu.waitForSubmissionQuietly(
            through, orWarn: "Could not wait for the GPU before handing the frame to an outlet")
        // **まず待たずに問う。** 結末は合図より遅れて届くので、間を空けずに回すと配る時点でまだ届いて
        // いないことが多い。範囲の結末が揃っていれば、待つ形でも答えは同じである
        var drops = gpu.settledDrops(after: floor, through: through)
        if drops == nil {
            switch patience {
            case .ask:
                // この絵からあとを次のフレームへ持ち越す
                return false
            case .wait:
                drops = gpu.droppedWork(after: floor, through: through)
            case .giveUp:
                drops = gpu.droppedWork(after: floor, through: through, waitingUpTo: .zero)
            }
        }
        pendingOutletFrames.removeFirst()
        outletJudgedThrough = max(outletJudgedThrough, through)
        let surface = ObjectIdentifier(target)
        if let drops, let dropped = drops.first {
            // 出す先の面へ書いた投入が打ち切られていたら、面の中身が欠けている印を持ち越す
            if let wrote = drops.last(where: { $0.wrote.contains(surface) }) {
                outletHeldDrop = (wrote.reason, wrote.submission)
            }
            noteDroppedOutletFrame(pending.frame, reason: dropped.reason)
            return true
        }
        if let held = outletHeldDrop {
            // 面へ新しく書いていなければ、面の中身はまだ欠けている
            guard pending.lastWriteAtEncode > held.droppedAt else {
                noteDroppedOutletFrame(pending.frame, reason: held.reason)
                return true
            }
            outletHeldDrop = nil
        }
        readyOutletFrames.append(pending)
        return true
    }

    /// 最後に進めたフレームの描画が転んだか ([#2769])。**転んだ間は、面の絵が描き終えていない**。止まって
    /// いるスケッチが頼まれた `save()` のために絵を組み直す道 (``settleWithoutAnotherFrame(_:)``) は、
    /// 閉じるときも含めて、転ぶ前の絵をそのフレームの番号で書いてしまうので通らない。予約は残り、次に
    /// 描けた絵で書く。次に描けたフレームで下りる。
    ///
    /// [#2769]: https://github.com/mokume-metal/mokume/issues/2769
    private var lastFrameFailedToDraw = false

    /// いま出す先の面の中身が、打ち切りで欠けたままか (``outletHeldDrop``)。
    private var outletSurfaceLacksDroppedWork: Bool {
        guard let held = outletHeldDrop else { return false }
        return target.lastWriteSubmission <= held.droppedAt
    }

    /// 打ち切りで配らなかった 1 枚を数え、ランタイムで 1 度だけ言う。
    private func noteDroppedOutletFrame(_ frame: Int, reason: String) {
        outletFramesDropped += 1
        warnings.warnOnce(
            .droppedOutletFrame,
            "The GPU dropped the work behind frame \(frame) (\(reason)), so that frame was not "
                + "handed to the outlets: a recording leaves it out and counts it as dropped when it "
                + "stops, and a save() asked for in that frame writes the next frame that is handed "
                + "over (said once)")
    }

    /// 決着した絵を、古い順に並びの出口へ配る (``readyOutletFrames``)。
    ///
    /// **1 回の巡回で全部渡す** (#2743 の反証 5)。差込口の健康 (``SeamHealth``) は巡回 1 回につき 1 回数える
    /// ので、持ち越した絵と次の絵を同じ進めで 2 枚配っても、続けて転んだ数は 1 つしか進まない。1 枚ごとに
    /// 巡回すると、撮る係の 1 回きりの書き損じ (新しい知らせが来るまで前の値を保つ・#1272) が 2 回ぶんに
    /// 数えられ、1 回早く外れる。
    private func handOverReadyOutletFrames() {
        guard !isHandingOverOutletFrames else { return }
        isHandingOverOutletFrames = true
        defer { isHandingOverOutletFrames = false }
        while !readyOutletFrames.isEmpty {
            let count = readyOutletFrames.count
            let joinedAt = outletJoinedAt
            whileVisitingSeams {
                Self.visit(&outlets) { outlet in
                    for index in 0..<count {
                        let pending = self.readyOutletFrames[index]
                        // 足される前に描いた絵は渡さない (``outletJoinedAt``)
                        if let since = joinedAt[ObjectIdentifier(outlet)], pending.frame < since { continue }
                        outlet.receive(
                            OutputFrame(image: pending.image, frame: pending.frame, time: pending.time))
                    }
                } failure: {
                    $0.failure
                }
                // **渡し終えた絵は、巡回の後に当てる外しより前に落とす。** 巡回の最中に頼まれた
                // ``detachNow(_:)-(any Outlet)`` は、まだ誰にも渡していない絵だけを外す出口へ渡すので、
                // 渡し終えた絵が残っていると同じ絵を 2 度渡す (#2246)。渡している最中に決着した絵
                // (出口の中から呼び直された分) は残り、次の巡回で渡す
                self.readyOutletFrames.removeFirst(count)
            }
        }
    }

    // MARK: - 実行中に差込口を足す・外す

    /// 入り口を並びへ足す。転送 (正本は ``SketchPart/attach(_:)-(Inlet)``)。
    ///
    /// - Returns: 並びに居るか (開けた・既に居た・巡回の後に回した)。
    @discardableResult
    public func attach(_ inlet: any Inlet) -> Bool {
        guard seamVisitDepth == 0 else {
            deferredSeamChanges.append { [unowned self] in self.attachNow(inlet) }
            return true
        }
        return attachNow(inlet)
    }

    /// 出口を並びへ足す。転送 (正本は ``SketchPart/attach(_:)-(Outlet)``)。
    @discardableResult
    public func attach(_ outlet: any Outlet) -> Bool {
        guard seamVisitDepth == 0 else {
            deferredSeamChanges.append { [unowned self] in self.attachNow(outlet) }
            return true
        }
        return attachNow(outlet)
    }

    /// 入り口が並びに居るか。外す頼みが実際に何かを外すかを、頼む前に知るために使う (#3122)。
    package func isAttached(_ inlet: any Inlet) -> Bool {
        inlets.contains { $0.seam === inlet }
    }

    /// 入り口を並びから外して閉じる。転送 (正本は ``SketchPart/detach(_:)-(Inlet)``)。
    public func detach(_ inlet: any Inlet) {
        guard seamVisitDepth == 0 else {
            deferredSeamChanges.append { [unowned self] in self.detachNow(inlet) }
            return
        }
        detachNow(inlet)
    }

    /// 出口を並びから外して閉じる。転送 (正本は ``SketchPart/detach(_:)-(Outlet)``)。
    public func detach(_ outlet: any Outlet) {
        guard seamVisitDepth == 0 else {
            deferredSeamChanges.append { [unowned self] in self.detachNow(outlet) }
            return
        }
        detachNow(outlet)
    }

    @discardableResult
    private func attachNow(_ inlet: any Inlet) -> Bool {
        guard admits(inlet) else { return false }
        if let index = inlets.firstIndex(where: { $0.seam === inlet }) {
            // **居れば開き直さない** (開いているものを重ねて足しても `open()` は呼ばない。外して足し直したときは
            // ここに来ず、下で `open()` をもう 1 度呼ぶ — ``Inlet/open()``)。続けて転んで外されていれば、
            // 数え直して入れ直す (撮る係の ``rejoin(_:into:)`` と同じ)
            if !inlets[index].health.isAttached { inlets[index].health = SeamHealth() }
            return true
        }
        guard Self.open(inlet, opening: inlet.open) else { return false }
        inlets.append((inlet, SeamHealth()))
        SeamHomes.record(inlet, in: self)
        return true
    }

    @discardableResult
    private func attachNow(_ outlet: any Outlet) -> Bool {
        guard admits(outlet) else { return false }
        if let index = outlets.firstIndex(where: { $0.seam === outlet }) {
            if !outlets[index].health.isAttached { outlets[index].health = SeamHealth() }
            return true
        }
        guard Self.open(outlet, opening: outlet.open) else { return false }
        outlets.append((outlet, SeamHealth()))
        SeamHomes.record(outlet, in: self)
        outletJoinedAt[ObjectIdentifier(outlet)] = timing.frameCount
        return true
    }

    private func detachNow(_ inlet: any Inlet) {
        guard let index = inlets.firstIndex(where: { $0.seam === inlet }) else { return }
        inlets.remove(at: index)
        SeamHomes.forget(inlet)
        inlet.close()
    }

    private func detachNow(_ outlet: any Outlet) {
        // 撮る係は頼まれている間だけ居る係なので、外から外させない
        guard outlet !== recorder,
            let index = outlets.firstIndex(where: { $0.seam === outlet })
        else { return }
        // **外す直前に描き終えた絵を、先に渡す。** 描けた絵を落とさない (ADR-0024 決定 10・撮る係の
        // ``endRecord()`` と同じ向き)。渡すのは外す出口にだけで、ほかの出口は今までどおり次の巡回で受け取る
        if outlets[index].health.isAttached { handOverPendingFrames(to: outlet) }
        // 渡している最中に出口が自分で外れていれば、閉じるのは 1 度だけ
        guard let index = outlets.firstIndex(where: { $0.seam === outlet }) else { return }
        outlets.remove(at: index)
        SeamHomes.forget(outlet)
        outletJoinedAt[ObjectIdentifier(outlet)] = nil
        outlet.close()
    }

    /// 描き終えて、まだ誰にも渡していない絵を、`outlet` にだけ渡す ([#2246])。外す出口が、外す直前に
    /// 描き終えた最後の絵を受け取ってから閉じるためである。
    ///
    /// **配り方は ``deliverPendingToOutlets(_:)`` と同じ。** 控えを古い順に決着させ (投入を名指しで待つ・
    /// 打ち切られた絵は配らない・待つのは結末だけ。止め際と同じ ``OutcomePatience/wait``)、足される前に
    /// 描いた絵は渡さない (``outletJoinedAt``)。決着させた絵は ``readyOutletFrames`` に残るので、外さない出口は
    /// 今までどおり次の巡回で同じ絵を受け取る (欠けも二重も無い)。
    ///
    /// **渡している間の足し・外しは、終わってから当てる** (``whileVisitingSeams(_:)``)。この出口の `receive` が
    /// 別の差込口を足したり外したりしても、並びを巡回の最中に書き換えない。
    ///
    /// [#2246]: https://github.com/mokume-metal/mokume/issues/2246
    private func handOverPendingFrames(to outlet: any Outlet) {
        settlePendingOutletFrames(.wait)
        let joinedAt = outletJoinedAt[ObjectIdentifier(outlet)]
        let frames = readyOutletFrames
        guard !frames.isEmpty else { return }
        whileVisitingSeams {
            for pending in frames {
                // 足される前に描いた絵は渡さない
                if let joinedAt, pending.frame < joinedAt { continue }
                outlet.receive(OutputFrame(image: pending.image, frame: pending.frame, time: pending.time))
            }
        }
    }

    /// 足してよいか。**閉じた後は断る** — 足したものを閉じる者がもう居ない。
    private func admits(_ seam: AnyObject) -> Bool {
        guard seamsClosed else { return true }
        Diagnostics.warn(
            "Could not attach \(type(of: seam as Any)): the sketch has already closed its plugins")
        return false
    }

    /// 開く。投げたら知らせて `false` ([ADR-0024] 決定 7 — 開くときは投げてよく、
    /// そのときはそれだけ外して続ける)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private static func open(_ seam: AnyObject, opening: () throws -> Void) -> Bool {
        do {
            try opening()
            return true
        } catch {
            Diagnostics.warn("Could not open \(type(of: seam as Any)): \(error). Carrying on without it")
            return false
        }
    }

    // MARK: - 名乗り

    /// 走り続けていることをメニューバーの名乗りへ伝える。
    ///
    /// 起点は**最初のフレーム**で、組み立てた時刻ではない。1 枚も描かないまま持っている
    /// ランタイム (検査が作るもの) は走っているとは言えないため。
    ///
    /// **経過は「作者の時計 (``now``) での経過」と「実時間での経過」の小さいほうで数える** ([#3119])。
    /// ``now`` は検査が差し替えて進められる (`.wallClock` の週をまたぐ検査など)。それだけで名乗ると、
    /// プロセス全体の状態 (活性化の方針・状態バー・出来事の取り出し) が変わり、同じプロセスで窓を
    /// 開閉する検査の run loop が止まって `exit(0)` で要約を残さず終わる ([#1527])。逆に ``now`` を
    /// 止めた検査 (`now: { 0 }`) は、実時間だけで数えると混んだ機械で 30 秒を越えて名乗ってしまう
    /// (直す前は経過 0 で名乗らなかった)。**両方が猶予を越えたときだけ名乗る**。本番の ``now`` は
    /// `CACurrentMediaTime()` で、実時間と同じ値を返すので、振る舞いは変わらない。
    ///
    /// [#3119]: https://github.com/mokume-metal/mokume/issues/3119
    /// [#1527]: https://github.com/mokume-metal/mokume/issues/1527
    private func updatePresence() {
        guard firstAdvanceAt != nil else {
            firstAdvanceAt = now()
            firstAdvanceRealAt = presenceClock()
            return
        }
        presence.advanced(runningFor: presenceElapsed)
    }

    /// 名乗っているか。検査が読む (名乗りの本体 ``presence`` は持たせたまま外へ出さない)。
    var isPresenceAnnounced: Bool { presence.isAnnounced }

    /// 走り続けている時間 (秒)。名乗りが読む。最初のフレームの前は 0。
    ///
    /// 作者の時計での経過と実時間での経過の**小さいほう** (``updatePresence()``)。戻った時計で負にしない。
    var presenceElapsed: Double {
        guard let firstAdvanceAt, let firstAdvanceRealAt else { return 0 }
        return max(0, min(now() - firstAdvanceAt, presenceClock() - firstAdvanceRealAt))
    }

    /// 名乗りのメニューが開いている間、プレビューを動かすために呼ばれる。
    ///
    /// **誰かが既に進めているなら何もしない。** 窓を開く経路の駆動源 (`CADisplayLink`) は
    /// `.common` モードに登録されているので、メニューを開いている間もフレームは進み続ける
    /// — そこで二重に進めると、**メニューを開けている間だけ倍の速さで動く**。
    ///
    /// 逆に窓を開かない経路では、メニューを開いた時点で `advance()` が AppKit の追跡ループ
    /// の中で止まっている。**そのままではプレビューが静止画になる**ので、ここが進める。
    ///
    /// **この回は表示の予定の時刻を持たず、現在時刻で進む** ([#2390])。時刻は前の枚より小さくならない
    /// (``SketchPart/time``)。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    func advanceForPresence() {
        guard !isAdvancingFrame, now() - lastFrameAt > Self.presenceStallThreshold else { return }
        do throws(RenderFailure) {
            try runFrame()
        } catch {
            // **`setup()` が投げた失敗は捨てない** ([#2401])。直らない失敗なので、窓の経路へ知らせて終わらせる。
            // それ以外の失敗は、次の回でやり直す
            if case .setupFailed = error { setupFailureHandler?(error) }
        }
    }

    /// これだけ描かれていなければ「誰も進めていない」とみなす (秒)。
    ///
    /// 想定する一番遅い駆動が 30 fps (33 ms) なので、その倍を取る。短くすると、
    /// 進んでいるのに二重に進めてしまう。
    private static let presenceStallThreshold: Double = 0.066

    /// いま描かれている絵を、名乗りのメニューに載る大きさで返す。
    ///
    /// **出口が受け取るのと同じ道を通す** ([ADR-0024] 決定 6)。小さくするのは通した後で、
    /// 出るバイト列は通す前に間引いたのと同じである
    /// ([#382](https://github.com/mokume-metal/mokume/issues/382)) — 観測が絵を採るときと
    /// 同じ理屈なので、経路をもう 1 本作らない。
    ///
    /// **1 枚も描いていなければ `nil`。** 描いていない絵を出すよりは、出さないほうがよい。
    ///
    /// - Parameter maxWidth: 返す絵の幅の上限 (画素)。**縮小率ではなく幅で頼む** — 絵の
    ///   大きさはスケッチが決めるので、率で指定すると出来上がりがスケッチごとに変わる。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func presencePreview(maxWidth: Int) -> DisplayImage? {
        guard timing.frameCount > 0 else { return nil }
        guard let image = try? encodePictureForReading() else { return nil }
        // 縮めてから読む (#1745)。出るバイト列は、原寸を読んでから縮めたのと同じ
        return image.read(scaledBy: min(1, Double(maxWidth) / Double(max(1, image.width))))
    }

    /// いまの絵を、出口へ配るのと同じ道で組む。**まだ配っていない前のフレームの絵は上書きしない**
    /// ([#2743]・``outletStorageToAvoid()``)。
    ///
    /// 出力段の置き場は出口と分け合うので、配るのを持ち越している間に置き場を選ばずに組むと、前の
    /// フレームとして配る絵がいまの絵に書き換わる。名乗りの絵と、絵を読む検査がここを通る。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    func encodePictureForReading() throws(RenderFailure) -> EncodedImage {
        try target.encodeToImage(avoiding: outletStorageToAvoid())
    }

    /// フレームの頭で片付けること。
    private func beginFrame() {
        // 速さは**いつでも**数える。窓は観測が無くても数字を出すためで、ここを
        // 観測に紐づけると窓が自分で測り直すことになる (源が 2 つに割れる)
        tempo.record(now: now())
        // GPU 時間を数えるフレームの区切り (#2378)。投入を待たず、番号を 1 つ控えるだけ
        target.gpu.markFrameStart()
        guard observer != nil else { return }
        exposedValues.removeAll(keepingCapacity: true)
        // **測った値はここで差し戻す。** 差し出した値はフレームごとに消えるが、測った値は
        // 測り直すまで残る約束なので、どのフレームの報告も「そのフレームで差し出した値」
        // のまま測った値を含む。`setup()` の中で測った値が最初のフレームに載るのも、
        // この差し戻しが消去の後にあるためである
        exposedValues.merge(measuredValues) { _, measured in measured }
    }

    /// 進めるのを止める。**外から止める口** (作者の口は ``SketchPart/noLoop()``)。
    ///
    /// 止めている間は入力も集めない。観測にだけ応える。
    public func pause() { isPaused = true }

    /// 外から止めたのを再開する。
    ///
    /// **時刻の起点を現在へ寄せ直す。** 止めている間も実時間は進むので、寄せ直さないと
    /// 止めていた時間まるごとが再開後の最初の経過時間として渡る。
    ///
    /// ## 作者の `noLoop()` は覆さない
    ///
    /// 止まる理由は 2 つある — 外 (``pause()``) と作者 (``SketchPart/noLoop()``)。
    /// これが戻すのは**外の理由だけ**で、作者が止めたスケッチは再開しても止まったまま
    /// である。「1 度だけ描く」ことが作品の主題であるとき、ホストが再開しただけで
    /// 動き出すと作品の意味が壊れるため
    /// ([#900](https://github.com/mokume-metal/mokume/issues/900))。
    ///
    /// 判定する関門は ``advance()`` の中の 1 か所で、外が止めていればそちらが先に効く
    /// (作者の口がコールバックから呼ばれることもない)。外が止めている間に頼まれた
    /// ``SketchPart/redraw()`` は、再開した後の最初のフレームで効く。
    public func resume() {
        isPaused = false
        timing.resync()
    }

    /// 外から止められていないか。**作者の ``SketchPart/noLoop()`` はここに現れない** —
    /// 意味の違いは ``resume()`` の説明にある。
    public var isRunning: Bool { !isPaused }

    /// 作者の口の転送 (正本は ``SketchPart/noLoop()``)。
    func noLoop() {
        isLooping = false
        // このフレームの残りの字も、次が来ないので要る段で焼き切る (#2446)
        canvas.atlas.mayDeferScaledBakes = false
    }

    /// 作者の口の転送 (正本は ``SketchPart/loop()``)。
    func loop() {
        guard !isLooping else { return }
        isLooping = true
        // 止まっていた間の実時間を、再開後の最初の経過に乗せない (``resume()`` と同じ理由)。
        // 寄せ直すのではなく 1 フレームぶんにするのは、``SketchPart/redraw()`` の 1 枚と揃える
        // ため。コールバックから呼ばれたときは ``runFrame()`` も同じ印を付ける
        timing.stepOneFrameNext()
    }

    /// 作者の口の転送 (正本は ``SketchPart/redraw()``)。
    ///
    /// 回っている間に呼ばれても旗を立てるだけで、そのフレームを描いた後に落ちる。
    func redraw() { redrawRequested = true }

    /// 作者の口の転送 (正本は ``SketchPart/pauseTime()``)。
    func pauseTime() { timing.pauseTime() }

    /// 作者の口の転送 (正本は ``SketchPart/playTime()``)。
    func playTime() { timing.playTime() }

    /// 作者の口の転送 (正本は ``SketchPart/jumpTime(_:)``)。
    func jumpTime(_ seconds: Float) { timing.jumpTime(Double(seconds)) }

    // MARK: - 使いやすい入口

    /// 1 枚だけ描いて、画像に書き出す。
    ///
    /// 既定の時計はフレーム番号から導くので、**同じスケッチを 2 回走らせれば
    /// 同じ絵が出る**。
    ///
    /// **出口が受け取るのと同じ道を通る** ([ADR-0024] 決定 6)。読み戻して CPU で
    /// 変換する経路と出るバイト列は同じだが ([#440] で画素まで一致することを測った)、
    /// 同じ道を通しておけば**一致が構造で保たれる** — 片方だけ直したときに黙って
    /// 食い違うことがなくなる。
    ///
    /// **GPU が仕上げなかったフレームは書き出さない** ([#1932])。書き出す絵が拠った投入 (前にこの口か
    /// 描画先の投げる読む口が判定した後に積まれた投入すべて) のどれかを GPU が打ち切っていたら、
    /// 結末が届くのを待ってから ``RenderFailure/workDropped(reason:)`` を投げ、ファイルを書かない。
    /// 範囲と投げた後の扱いは ``RenderTarget/readPixels()`` と同じである。
    ///
    /// [#440]: https://github.com/mokume-metal/mokume/issues/440
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public func renderFrame(to url: URL) throws {
        // 書き出す絵は残る。拡大した字の焼きを次へ送らない (#2446)
        exportsOneFrame = true
        defer { exportsOneFrame = false }
        try advance()
        try PNGFile.write(try target.encodeToImageAndRead(avoiding: outletStorageToAvoid()), to: url)
    }

    // MARK: - 絵をファイルにする

    /// このフレームの絵を 1 枚だけ書き出すよう頼む。転送 (正本は ``SketchPart/save(_:)``)。
    public func save(_ path: String) {
        // **頼まれたフレームを一緒に渡す。** 配るのは 1〜2 枚遅れるので、番号が無いと
        // 「そのフレームの絵」ではなく前の絵が書かれる (#927・#2743)
        requireRecorder().save(path, at: timing.frameCount)
        attachRecorderIfNeeded()
        // 撮る絵は残る。これより後に置く字は、先送りせず要る段で焼く (#2446)
        canvas.atlas.mayDeferScaledBakes = false
    }

    /// 連番を始める。転送 (正本は ``SketchPart/beginRecord(_:)``)。
    public func beginRecord(_ pattern: String) {
        beginRecord(pattern, rendering: nil)
    }

    /// 連番か動画を始める。**`rendering` は、`mokume render` が先に知っている枚数** ([#2440]) —
    /// 配る形 (GIF・MP4) は、枚数を知っている入口だけが頼める。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    func beginRecord(_ pattern: String, rendering frameCount: Int?) {
        guard !observingAtTime else {
            Diagnostics.warn("beginRecord(): cannot start recording in a specified-time observation; start on a normal frame")
            return
        }
        // **頼まれたフレームを一緒に渡す** (`save(_:)` と同じ理由)。番号が無いと、撮る係が
        // 前から並びに居たときに 1 つ前の絵から録る (#1456)
        requireRecorder().beginRecord(pattern, at: timing.frameCount, rendering: frameCount)
        attachRecorderIfNeeded()
        // 撮る絵は残る。これより後に置く字は、先送りせず要る段で焼く (#2446)
        canvas.atlas.mayDeferScaledBakes = false
    }

    /// 連番を止める。転送 (正本は ``SketchPart/endRecord()``)。
    public func endRecord() {
        guard let recorder else {
            Diagnostics.warn("endRecord(): nothing is being recorded")
            return
        }
        // **控えを先に配る。** 撮り終わりは描き切りの中から呼ばれるので、ここで配らないと
        // 前のフレームの絵が誰にも渡らないまま録りが閉じる = 最後の 1 枚が落ちる (#927)。
        // 持ち越した絵も、結末を待ってここで決着させる (#2743)
        deliverPendingToOutlets(.wait)
        // **止めたフレームを一緒に渡す。** 撮る係が途中で外れていると最後の絵が届かないので、
        // どこまでが録りの幅かを教えないと、末尾の欠けが落ちた数に入らない (#1626)
        recorder.endRecord(through: drawnThrough)
    }

    /// 撮る係が言った注意の控え。撮る係がまだ無いか、閉じ終えて手放した後は `nil`。**検査が読む。**
    var recorderWarnings: WarningLog<FrameRecorder.Warning>? { recorder?.warnings }

    /// 撮る係。**頼まれてはじめて作る** — 撮らないスケッチは 1 バイトも払わない。
    private func requireRecorder() -> FrameRecorder {
        if let recorder { return recorder }
        let made = FrameRecorder(frameRate: launchFrameRate)
        recorder = made
        return made
    }

    /// 頼まれているなら差込口の並びへ入れる。
    ///
    /// **入れ直すときは健康状態も新しくする。** 並びから外れている理由は「遊んでいた」か
    /// 「続けて転んで外された」かのどちらかで、次に明示的に頼まれた時点がどちらにとっても
    /// 仕切り直しになる。
    ///
    /// **撮る係の持ち越しも同じ時点で下ろす** (``FrameRecorder/startAfresh()``)。健康状態だけを
    /// 新しくすると、係が保っている前の書き損じが最初のフレームで 1 回ぶん数えられる。
    /// 録っている最中に外されて `save()` で戻るときも同じである (#1626)。
    private func attachRecorderIfNeeded() {
        guard let recorder else { return }
        Self.rejoin(recorder, into: &outlets)
    }

    /// 頼まれている撮る係を、並びへ入れる (入れ直す)。
    ///
    /// **並びに居ても、外されていれば入れ直す** (#1626 の反証)。外された係は、そのフレームを
    /// 配り終えるまで並びに残る (``detachRecorderIfDone()``)。その間に頼まれると (描き切りの中の
    /// `endRecord()` で外れ、同じ `draw()` の中で `save()` する形)、居ることだけを見て入れ直さず、
    /// 直後に並びから外されて、頼んだものが終わりまで書かれない。
    ///
    /// - Returns: 入れた・入れ直したか。
    @discardableResult
    static func rejoin(
        _ recorder: FrameRecorder, into outlets: inout [(seam: any Outlet, health: SeamHealth)]
    ) -> Bool {
        guard !recorder.isIdle else { return false }
        if let index = outlets.firstIndex(where: { $0.seam === recorder }) {
            guard !outlets[index].health.isAttached else { return false }
            outlets[index].health = SeamHealth()
        } else {
            outlets.append((recorder, SeamHealth()))
        }
        recorder.startAfresh()
        return true
    }

    /// 頼まれているものが無くなったら並びから外す。
    ///
    /// 付けっぱなしにすると、1 枚だけ撮ったスケッチが以後ずっと毎フレーム道を通る
    /// ([ADR-0023] 決定 5)。続けて転んで外されたものも、並びに置いたままにしない。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private func detachRecorderIfDone() {
        guard let recorder,
            let entry = outlets.first(where: { $0.seam === recorder }),
            recorder.isIdle || !entry.health.isAttached
        else { return }
        outlets.removeAll { $0.seam === recorder }
    }

    /// 描かずに戻るフレームで、保存し直した断片を読み直す ([#1830] の 2 回目の反証 1)。
    ///
    /// 読み直しを取るのは本体の面のフレームの頭 (``Canvas`` の `beginFrame()`) なので、描かない
    /// 間 (外から止めた間・作者の `noLoop()` で描き直しを頼まれていない間) は、main actor を
    /// 譲らないループでは取る者がいなかった。窓なら積んだ `Task` が取るので、`failure` と観測の
    /// 目録 (`canvas.shaderFailures`) が、叩き方で古いまま残るかどうかが割れた。ここは描いて
    /// いないので、組み直しても 1 つのフレームの中で断片が混ざることはない。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    private func takeFragmentChangesWithoutAFrame() {
        FileWatcher.takeChanges()
    }

    /// 抱えている絵と予約を、**次のフレームを当てにせずに**決着させる。
    ///
    /// 配りを遅らせているのは、次のフレームの CPU の仕事を前のフレームの GPU と
    /// 重ねるためである ([#927])。止まったスケッチに次のフレームは来ないので、遅らせた
    /// ぶんがそのまま「いつまでも配られない」になる — `noLoop()` で止めたスケッチの
    /// `save()` がファイルにならなかったのはこれで、そのまま終わりの経路まで落ちれば
    /// 永久に出ない ([#1300])。道具が子を止める `SIGTERM` も、いまは終わりの経路を通る
    /// (``StopSignals``)。
    ///
    /// 段は 2 つある。控えがあれば配り、**それでも果たせない予約が残っていれば組み直して
    /// 配る**。後者は止まっている間に頼まれた `save()` (`keyPressed()` から呼ぶ形) で、
    /// 宛先の絵は既に描かれているのに、控えは前のフレームで配り終えている。
    ///
    /// **予約が無ければ組み直さない。** 止まっている絵は変わらないので、毎フレーム組み直すと
    /// 止めたスケッチが回っているときと同じ費用を払い続ける (ADR-0023 決定 5)。
    ///
    /// **次が来ないので、結末は待って決着させる** ([#2743])。持ち越した絵もここで配るか捨てる (塞がずに
    /// 閉じる口だけは待たずに問い、届いていなければ `false` を返す)。**面の中身が打ち切りで欠けたまま
    /// なら、組み直さない** (``outletSurfaceLacksDroppedWork``)。組み直しても配れず、止まっている間じゅう
    /// 毎回組み直すことになる。コールバックが面へ書き直せば (画素を書くなど)、組み直して配る。書き直さ
    /// なければ、その `save()` は次に描いて配れたフレームの絵で書く (終わるまで描かなければ、閉じるときに
    /// 書けなかったと言う)。
    ///
    /// - Parameter patience: 結末がまだ届いていない絵の扱い。止まっている間とふつうの閉じ方は待つ。
    /// - Returns: 控えも予約の組み直しも決着したか。待たずに、届いていない絵が残ったら `false`。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    /// [#1300]: https://github.com/mokume-metal/mokume/issues/1300
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    /// [#2769]: https://github.com/mokume-metal/mokume/issues/2769
    @discardableResult
    private func settleWithoutAnotherFrame(_ patience: OutcomePatience = .wait) -> Bool {
        defer { detachRecorderIfDone() }
        guard deliverPendingToOutlets(patience) else { return false }
        if recorder?.hasUnwrittenShots(upTo: timing.frameCount) == true,
            !outletSurfaceLacksDroppedWork, !lastFrameFailedToDraw
        {
            encodeForOutlets()
            return deliverPendingToOutlets(patience)
        }
        return true
    }

    // MARK: - 観測に応える

    /// 外から値を差し出す (``SketchPart/expose(_:_:)-(_,Double)`` から呼ばれる)。
    ///
    /// 観測が有効でなければ溜めない。
    ///
    /// **非有限の数 (NaN・無限) は溜めずに、1 度だけ名乗る。** 応答は JSON で、非有限の数を
    /// 符号化できない — 溜めると、その枚の応答がまるごと置けなくなる
    /// ([#2271](https://github.com/mokume-metal/mokume/issues/2271))。差し出さなかった値は
    /// 応答の `values` に載らない (他の値は載る)。前の枚の値は残らない — 差し出した値は
    /// フレームの頭で消える (``beginFrame()``)。**例外は ``measure(_:_:)`` で測った名前**: 測った
    /// 値はフレームの頭で差し戻されるので、その名前に非有限を差し出しても、載るのは測った値である。
    func expose(_ name: String, _ value: ExposedValue) {
        guard observer != nil else { return }
        guard value.paramValue.hasOnlyFiniteNumbers else {
            // 文面は言う回にしか組まない (毎フレーム差し出す口で、黙る回に文字列を確保しない)
            warnings.warnOnce(.nonFiniteExposed, Self.nonFiniteExposedNotice(name, value))
            return
        }
        exposedValues[name] = value
    }

    /// 非有限の値を差し出されたときの 1 行。数は今は `.float` だけが持つ。
    private static func nonFiniteExposedNotice(_ name: String, _ value: ExposedValue) -> String {
        let shown: String
        if case .float(let number) = value { shown = "\(number)" } else { shown = "\(value)" }
        return "expose(): \"\(name)\" was given \(shown), which is not a finite number, "
            + "so it is not exposed (said once)"
    }

    /// 処理を 1 度走らせ、かかった実時間をミリ秒で差し出す (``SketchPart/measure(_:_:)`` から
    /// 呼ばれる)。
    ///
    /// **時計は ``now`` を読む。** フレームの時刻 (``FrameTiming``) はフレームの途中で
    /// 進まず、再現する時計ではフレーム番号から導かれるので、区間を測れない。
    ///
    /// 観測が有効でなければ、時計も読まず溜めもしない。処理だけを走らせる。処理が
    /// 投げたときは何も溜めない — 測り終えていない。
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard observer != nil else { return try body() }
        let began = now()
        let result = try body()
        let value = ExposedValue.float((now() - began) * 1000)
        measuredValues[name] = value
        // このフレームの報告にも載せる。次のフレームからは ``beginFrame()`` が差し戻す
        exposedValues[name] = value
        return result
    }

    /// 要求が来ていれば応える。
    ///
    /// **止まっていても応える。** 返すのは最後に描いた絵で、観測のためにフレームを
    /// 進めることはしない — 観測の有無で番号が動くと、同じスケッチを 2 回走らせれば
    /// 同じ絵になるという性質が観測に壊される。
    ///
    /// 時刻なしの観測で新たに描くのは「まだ1枚も描いていない」ときだけ。指定時刻は runFrame で既に描いている。
    /// 最初の 1 枚は観測の有無によらず必ず描かれるものなので、再現性は損なわれない。
    ///
    /// **列を撮っている間は次の要求を拾わない。** 拾うと 2 つの列が同じ区画へ混ざり、
    /// どちらの目録も数が合わなくなる。
    ///
    /// - Parameter drawFailure: このフレームの描画が失敗していれば、その理由。
    private func serveObservationIfRequested(
        request: ObservationRequest?, drawFailure: RenderFailure? = nil, appliedTime: Float? = nil
    ) {
        guard let observer else { return }
        // **書き込みの決着を待っている間は、決着を見るだけ** ([#2381])。塞がずに見に来て、フレームは進める
        //
        // [#2381]: https://github.com/mokume-metal/mokume/issues/2381
        if settling != nil {
            settleObservation(.peek, through: observer)
            return
        }
        if capture != nil {
            continueCapture(through: observer, drawFailure: drawFailure)
            return
        }
        guard let request else { return }
        // **通常のフレームと同じ手順で描く。** 手順をここへ写すと、段を足すたびに
        // 片方だけ腐る (#808)。**失敗は握りつぶさず、応えに載せる** — `setup()` が投げたのに「撮れた」と
        // 答えない ([#2401])
        var drawFailure = drawFailure
        if drawFailure == nil, timing.frameCount == 0 {
            do throws(RenderFailure) {
                try drawSketchFrame()
            } catch {
                drawFailure = error
            }
        }
        beginCapture(for: request, through: observer, drawFailure: drawFailure, appliedTime: appliedTime)
    }

    /// 列を撮り始める。1 枚だけの要求も同じ道を通る。
    ///
    /// 枚数で道が分かれると、めったに通らない側だけが腐る。1 枚は「1 枚で終わる列」
    /// として扱い、撮る・目録を書くの手順を 1 本に保つ。
    private func beginCapture(
        for request: ObservationRequest, through observer: FrameObserver,
        drawFailure: RenderFailure?, appliedTime: Float? = nil
    ) {
        let limits = request.clamped()
        // 前回の成果物は**撮り始める前に**消す。新しい識別子の目録と古い絵が
        // 組にされると、読み手は古い絵を新しいと信じる (ADR-0018 決定 3)
        observer.clearProducts()

        // 描画に失敗したフレームでは描画先の中身が信用できないので、**絵は採りに
        // 行かない**。目録は空のまま、理由を載せて返す
        if let drawFailure {
            finish(
                id: request.id, through: observer, frames: [], complete: false,
                warnings: limits.warnings + ["Drawing this frame failed: \(drawFailure)"])
            return
        }
        capture = FrameCapture(
            id: request.id, scale: limits.scale, count: limits.count, every: limits.every,
            warnings: limits.warnings, appliedTime: appliedTime)
        continueCapture(through: observer, drawFailure: nil)
    }

    /// 撮っている列を 1 フレームぶん進める。
    ///
    /// **フレームループは止めない。** 撮り終わるまで待つあいだもスケッチは描き続ける —
    /// 止めてから撮ると、測っている対象そのものが変わってしまう。
    private func continueCapture(through observer: FrameObserver, drawFailure: RenderFailure?) {
        guard var pending = capture else { return }

        if let drawFailure {
            // 途中で描けなくなったら、そこまでの絵は目録に残したまま打ち切る。
            // 絵が揃っていないことは「宣言した数と合わない」で読み手に伝わる
            capture = nil
            finishCapture(
                id: pending.id, through: observer, frames: pending.frames, complete: false,
                warnings: pending.warnings + ["Drawing this frame failed: \(drawFailure)"])
            return
        }

        guard pending.wait == 0 else {
            pending.wait -= 1
            capture = pending
            return
        }

        do {
            // **出口が受け取るのと同じ道を通す** ([ADR-0024] 決定 6)。小さくするのは
            // 通した後で、出るバイト列は通す前に間引いたのと同じである (#382)
            // 原寸の配列は作らず、置き場から拾う画素だけを読む (#1745)
            //
            // **GPU が仕上げなかった絵は撮らない** (#1932)。拠った投入の打ち切りは投げる読む口と
            // 同じく判定し、投げたら下の catch が目録を `complete: false` にして理由を警告に載せる
            // まだ配っていない前のフレームの絵は上書きしない (#2743)
            let image = try target.encodeToImageAndRead(
                scaledBy: pending.scale, avoiding: outletStorageToAvoid())
            // **PNG の符号化とファイルの置き換えは、フレームの外で行う** ([#2381])。ここで払うのは読み戻しと
            // 統計 (64x64 だけ拾う) で、置けたかどうかは撮り終えた後に見る (``settleObservation(_:through:)``)
            //
            // [#2381]: https://github.com/mokume-metal/mokume/issues/2381
            let stats = FrameStats.summarize(image)
            let name = observer.enqueueFrame(image, at: pending.frames.count)
            pending.frames.append(
                ObservationReport.CapturedFrame(
                    image: name,
                    frame: timing.frameCount,
                    time: Double(timing.time),
                    stats: stats,
                    values: exposedValues.isEmpty ? nil : exposedValues))
        } catch {
            // 採れなくても黙らない。読み手が「まだか / 失敗か / 死んだか」を
            // 区別できるようにするため (ADR-0018 決定 3)
            capture = nil
            finishCapture(
                id: pending.id, through: observer, frames: pending.frames, complete: false,
                warnings: pending.warnings + ["Could not take the image: \(error)"])
            return
        }

        guard pending.frames.count < pending.count else {
            capture = nil
            // 描けてはいるが直っていないもの (組み立てに失敗した断片など) は、
            // 目録の警告として出す。**絵が出ているぶん、これが無いと気付けない**
            finishCapture(
                id: pending.id, through: observer, frames: pending.frames, complete: true,
                warnings: pending.warnings + canvas.shaderFailures
                    + Self.repetitionWarnings(pending.frames), appliedTime: pending.appliedTime)
            return
        }
        pending.wait = pending.every - 1
        capture = pending
    }

    /// 撮り終えた列の目録を、**頼んだ書き込みが全部決着してから**書く ([#2381])。
    ///
    /// 目録は撮り終えた時点で組む。書き込みを頼んでいなければ (描けなかった・1 枚も撮れなかった)
    /// その場で書く。頼んでいれば、決着するまで ``settling`` に置き、``settleObservation(_:through:)``
    /// が書く。
    ///
    /// [#2381]: https://github.com/mokume-metal/mokume/issues/2381
    private func finishCapture(
        id: String, through observer: FrameObserver,
        frames: [ObservationReport.CapturedFrame], complete: Bool, warnings: [String],
        appliedTime: Float? = nil
    ) {
        let snapshot = report(
            id: id, frames: frames, complete: complete, warnings: warnings, appliedTime: appliedTime)
        guard observer.hasPendingWrites else {
            observer.finish(snapshot)
            return
        }
        settling = snapshot
        // 裏で続けない観測は、撮り終えたフレームのうちに決着まで待つ (``FrameObserver/writesInBackground``)
        if !observer.writesInBackground { settleObservation(.block, through: observer) }
    }

    /// 決着を待っている目録があれば、書き込みの決着を見て、決着していれば書く。
    ///
    /// **全枚が置けたなら、組んでおいた目録をそのまま書く。** 置けなかった枚があれば、その枚の手前で
    /// 目録を終え (``ObservationReport/truncated(after:because:)``)、理由を警告で返す — 今と同じく
    /// `complete` の鍵が無く、絵が揃っていないことが読み手に伝わる (ADR-0018 決定 3)。
    ///
    /// - Returns: 決着したか (待っているものが無い・書いた)。``Patience/peek`` なら、まだなら `false`。
    @discardableResult
    private func settleObservation(_ patience: Patience, through observer: FrameObserver) -> Bool {
        guard let snapshot = settling else { return true }
        guard let settlement = observer.settleWrites(patience) else { return false }
        settling = nil
        switch settlement {
        case .written:
            observer.finish(snapshot)
        case .failed(let index, let reason):
            observer.finish(snapshot.truncated(after: index, because: reason))
        }
        return true
    }

    /// 目録を書いて、この要求を終える。
    ///
    /// 上の階の `image` / `frame` / `time` / `stats` は**最後に撮った 1 枚**を指す。
    /// 揃わなかったときは `image` を落とす — 読み手はこの鍵の有無だけで成否を言える。
    private func finish(
        id: String, through observer: FrameObserver,
        frames: [ObservationReport.CapturedFrame], complete: Bool, warnings: [String], appliedTime: Float? = nil
    ) {
        observer.finish(
            report(id: id, frames: frames, complete: complete, warnings: warnings, appliedTime: appliedTime))
    }

    /// 観測の要求を拾う。**`id` だけ読めた要求は、撮らずにここで応えて `nil` を返す** (#2550)。
    /// 時刻の指定を断るのと同じく、前回の成果物を消し、理由を載せた目録を書く
    /// (``FrameObserver/refuse(id:reason:report:)``)。
    private func takeObservationRequest() -> ObservationRequest? {
        guard let observer, let pending = observer.pendingRequest() else { return nil }
        switch pending {
        case .request(let request):
            return request
        case .unreadable(let id, let reason):
            observer.refuse(id: id, reason: reason) { id, warnings in
                report(id: id, frames: [], complete: false, warnings: warnings)
            }
            return nil
        }
    }

    /// 目録を組む。``finish(id:through:frames:complete:warnings:appliedTime:)`` と、読めない要求への
    /// 応え (``takeObservationRequest()``) が同じ中身を書く。
    private func report(
        id: String, frames: [ObservationReport.CapturedFrame], complete: Bool, warnings: [String],
        appliedTime: Float? = nil
    ) -> ObservationReport {
        let last = complete ? frames.last : nil
        return ObservationReport(
            id: id,
            image: last?.image,
            frame: timing.frameCount,
            time: Double(timing.time),
            size: ObservationReport.Size(width: target.width, height: target.height),
            // スケッチのプロセスが言った警告 (走っている実行の外から呼ばれた語彙 (#2265) も含む) を、
            // 言った後の最初の応答に 1 度だけ載せる (#2761)。標準エラーの 1 行は MCP から読めず、
            // `init` で読んだ `width` が 0 だったことを観測で辿れなくなる。最後に足すので、失敗の
            // 理由より前には来ない
            warnings: warnings + Diagnostics.takeUnreported(),
            stats: last?.stats,
            load: RuntimeLoad.sample(tempo: tempo, budget: budget, now: now()),
            values: exposedValues.isEmpty ? nil : exposedValues,
            inputs: inputReports,
            stamp: SourceStamp.current,
            frames: frames, appliedTime: complete ? appliedTime.map(Double.init) : nil)
    }

    /// 名乗りを持つ入り口の状態 (``Inlet/report``)。1 つも無ければ `nil` で、応答から鍵ごと落ちる。
    ///
    /// **続けて転んで外された入り口も載せる。** 並びに居る限り、値が来ない理由を名乗れるのは
    /// その入り口だけである ([ADR-0028] 決定 4)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    private var inputReports: [SourceReport]? {
        let reports = inlets.compactMap { $0.seam.report }
        return reports.isEmpty ? nil : reports
    }

    /// 同じフレームが並んでいたら、そのことわり。
    ///
    /// 止めているあいだに列を頼むと、同じ絵が枚数ぶん並ぶ。**それは応答としては正しい**
    /// (画面に出ているのはその絵である) が、動きを見たい読み手には見分けが付かない。
    /// フレーム番号という事実から導けるので、止まっているかどうかの旗を見に行かない。
    private static func repetitionWarnings(_ frames: [ObservationReport.CapturedFrame]) -> [String]
    {
        let numbers = frames.map(\.frame)
        guard numbers.count > 1, Set(numbers).count < numbers.count else { return [] }
        return [
            "The same frame appears more than once (shooting while nothing advances gives images "
                + "that do not move)"
        ]
    }

    /// 撮っている最中の列。
    private struct FrameCapture {
        let id: String
        /// 書き出す絵の縮小率 (範囲の端で丸めた後・``ObservationRequest/clamped()``)。
        let scale: Double
        /// 撮る枚数 (範囲の端で丸めた後)。
        let count: Int
        /// 何フレームおきに撮るか (範囲の端で丸めた後)。
        let every: Int
        /// 目録に載せることわり。切り詰めたことなど、撮り始める前に決まるもの。
        var warnings: [String]
        var appliedTime: Float?
        /// ここまでに撮れた絵。
        var frames: [ObservationReport.CapturedFrame] = []
        /// 次に撮るまで残っているフレーム数。0 ならこのフレームで撮る。
        var wait = 0
    }

    /// 自分の面に、持ち越しを約束する区間の印を立てて `body` を走らせる ([#1672])。
    ///
    /// **置いたものをフレームの外に置いてよいのは、次のフレームを約束する主体が約束した区間
    /// だけである** (ADR-0021 決定 4 の追補 (2026-09-27))。本体の面で約束するのはランタイムで、
    /// 区間は `setup()` と止まっている間のコールバックの 2 つ。どちらも次に描くフレームが来る
    /// (最初のフレーム・`redraw()` か `loop()` の後のフレーム) ので、そこで置いたものはそこへ
    /// 持ち越す。`setup()` だけで 1 枚を描く書き方 (Processing の基本) はこれに頼る。
    ///
    /// 立てるのは自分の面 (``canvas``) にだけである。描き場所 (`createGraphics`) の区間は作者の
    /// `beginDraw()`〜`endDraw()` で、`setup()` の中でも立てない。**`defer` で必ず下ろす** —
    /// 下ろし損ねると、`Task` の続きのような区間の外で置いたものまで持ち越してしまう。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    private func carryingOver(_ body: () throws -> Void) rethrows {
        let previous = canvas.carriesOver
        canvas.carriesOver = true
        defer { canvas.carriesOver = previous }
        try body()
    }

    /// いま走っているランタイムとして自分を差し込んでから `body` を実行する。
    ///
    /// 差し込みを入れ子にしても壊れないよう、前の値へ必ず戻す。
    ///
    /// **同じ範囲で面も束ねる** (``LaunchingSketch``)。中で起こされた `Task` が、差し込みが
    /// 外れた後もこの面へ読み込めるようにするためである ([#1367])。束ねた値は範囲を出れば
    /// 自動で戻る。
    ///
    /// **形の組み立てを知らせる先 (``shapeAssemblyListener``) も、同じ所で差して外す** ([#2041])。
    /// 乱数の種を書く鍵は ``runningSketch`` なので、組み立ての出口で戻す鍵も同じ寿命に揃える。
    /// 面ごとに付けると、ランタイムが付けていない面 (直に作った面とそこから作った描き場所) で
    /// 中で書いた種が漏れる。
    ///
    /// **検査がランタイムを差すときも、ここを通す** (`private` にしない理由)。``runningSketch`` だけを
    /// 手で差すと知らせる先が差さらず、検査の中の組み立てで書いた種が漏れたまま黙る。
    ///
    /// [#1367]: https://github.com/mokume-metal/mokume/issues/1367
    /// [#2041]: https://github.com/mokume-metal/mokume/issues/2041
    func withActiveRuntime(_ body: () throws -> Void) rethrows {
        let previous = runningSketch
        let previousListener = shapeAssemblyListener
        runningSketch = self
        shapeAssemblyListener = self
        defer {
            runningSketch = previous
            shapeAssemblyListener = previousListener
        }
        try LaunchingSketch.$canvas.withValue(canvas, operation: body)
    }
}
