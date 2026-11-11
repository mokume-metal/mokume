// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics

/// スケッチをアプリケーションとして走らせる。
///
/// ウィンドウとアプリケーションの寿命は AppKit が持つ ([ADR-0012] 決定 4)。フレームを進める
/// 判断はランタイムのままで、ここは**表示のリフレッシュに合わせて `advance()` を叩く
/// 3 つ目の駆動源**を足すだけである ([ADR-0012] 決定 3)。
///
/// ## 駆動源はウィンドウではなく画面に紐づく
///
/// 面 (`NSView`) から取った駆動源は面が hidden になると呼ばれなくなるので、ウィンドウを
/// 最小化した瞬間にフレームループごと止まっていた。画面 (`NSScreen`) から取れば、
/// 最小化・被覆・Space の切り替えのどれでも止まらない
/// ([#223](https://github.com/mokume-metal/mokume/issues/223))。
///
/// ## 省電力の間引きは明示的に断る
///
/// 駆動源を画面へ繋いでも、それだけでは足りない。**背面のアプリが CPU を使い続けると、OS は
/// そのプロセスを高効率コアへ落とす** — フレームループが止まるのではなく、同じ仕事が一様に
/// 4 倍遅くなる形で現れる。観測を続けているときのように 1 フレームの仕事が重いと、それが
/// そのままフレームレートの低下になり、**負荷を止めるまで戻らない**
/// ([#370](https://github.com/mokume-metal/mokume/issues/370))。
///
/// 落ちているのが**プロセスに割り当てられる CPU そのもの**であることは、観測の経路と無関係な
/// 純 CPU のベンチまで同じ倍率で遅くなること・ウィンドウを持たないプロセスでは同じ持続負荷でも
/// 起きないこと・前面のままなら起きないことで確かめてある。
///
/// [ADR-0012] 決定 5 は「ウィンドウが画面に出ていないときもフレームレートを維持する」を機能要件に
/// 固定したうえで、**「OS の省電力機構は既定では前面でないアプリの周期処理を間引くため、
/// 対処が要る」**と名指しし、手段は「実際に落ちることを確認してから」決めるとして空けていた。
/// ここがその対処である。
///
/// ## AppKit の delegate は別のオブジェクトが受ける
///
/// `NSApplicationDelegate` への準拠は internal な `SketchApplicationDelegate` が持つ。
/// **この型が直接準拠すると、delegate のメソッドが公開 API の一覧に載る** — 呼ぶのは OS で
/// あって利用者ではないのに「呼んでよい」顔で並ぶ ([ADR-0020] 決定 6 /
/// [#324](https://github.com/mokume-metal/mokume/issues/324))。
///
/// `public` を外すだけでは済まない。public な型が public なプロトコルへ準拠すると、
/// Swift は要件を public に要求する:
///
/// ```
/// error: method 'applicationWillTerminate' must be declared public because it
///        matches a requirement in public protocol 'NSApplicationDelegate'
/// ```
///
/// 準拠自身の可視性を下げる書き方が Swift に無いので、**準拠ごと internal な側へ移す**。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@MainActor
public final class SketchApplication: NSObject, ScreenDisplayLinkOwner {
    let gpu: RenderDevice
    private let runtime: SketchRuntime
    private let presenter: FramePresenter
    private let title: String
    /// 別のアプリへ名乗り、絵を渡すか (``SketchSettings/sharesFrames``)。**組み立てのときに 1 度だけ読む。**
    private let sharesFrames: Bool

    /// 画面の出口。
    ///
    /// 分岐は「ビューアあり / なし」というモードではなく、**与えられた出口の構成**である
    /// ([ADR-0032] 決定 1)。決めるのは起こし方で、ウィンドウを持つ道具に起こされたか
    /// (``SharedFrameSurface/launchOwner``) を読む場所は 1 つである。ウィンドウを開かない
    /// ことも、標準入力の管を読むことも、決まった出口から従う。
    ///
    /// **その 1 つの決定を 4 つの変数へ写さない。** かつてはウィンドウ・面・共有面・出したかの
    /// 4 つの Optional で持っており、片方だけ書き換えれば「ウィンドウも出るし面へも書く」が
    /// 型として作れた — どちらの経路もそれを想定していないのに、である
    /// ([#955](https://github.com/mokume-metal/mokume/issues/955))。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private enum ScreenOutlet {
        /// ウィンドウの経路だが、まだ建っていない。
        ///
        /// **``run()`` の既定であり、``didFinishLaunching()`` が置き換える。** 2 段階に
        /// なるのは畳めない事情による — 活動の方針 (`setActivationPolicy`) は
        /// `NSApplication.run()` より前にしか据えられず、ウィンドウはその後にしか建たない。
        case pendingWindow
        /// 自分のウィンドウへ出す。付属の `hasPresented` は最初の 1 枚の扱いに使う。
        case window(NSWindow, SketchSurface, hasPresented: Bool)
        /// ホストのアプリの `NSView` の中へ出す (``SketchView``・#3511)。**ウィンドウは持たない** — ウィンドウも
        /// アプリケーションの寿命もホストのもので、こちらは面と駆動源だけを持つ。付属の
        /// `hasPresented` は ``window`` と同じく最初の 1 枚の扱いに使う。
        case embedded(SketchSurface, hasPresented: Bool)
        /// 外のプロセスが持つ区画へ差し出す。**ウィンドウは持たない。**
        case shared(SharedFrameSurface)
        /// 画面へは出さず、決めた枚数を書き出して終わる (`mokume render`・[#1282])。
        /// **ウィンドウも共有面も持たない** — 出口は撮る係だけである。
        ///
        /// 決まるのは起動の瞬間 (``init(sketch:gpu:render:)``) で、区画 (`viewport`) より先に
        /// 効く。ウィンドウを持たないのは、ウィンドウが受けた入力が作品へ届くと、同じ引数から同じ動きが
        /// 出なくなるためである ([ADR-0025] 決定 1 の水準 2)。
        ///
        /// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
        /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
        case render(RenderRequest)
    }
    private var outlet: ScreenOutlet

    /// 開いているウィンドウ。**読むだけを内へ開けてある** — 検査が実際の経路のウィンドウを閉じるため (#714)。
    var window: NSWindow? {
        if case .window(let window, _, _) = outlet { window } else { nil }
    }

    /// 共有面へ差し出している経路の面。**読むだけを内へ開けてある** — 検査が、面に載せた名乗りの中身を見るため (#3919)。
    var sharedSurface: SharedFrameSurface? {
        if case .shared(let shared) = outlet { shared } else { nil }
    }

    /// 最後のウィンドウが閉じたら、スケッチも終わってよいか。
    ///
    /// **ウィンドウを持たない経路では終わらない** ([ADR-0032] 決定 1)。ウィンドウが画面の出口である経路では
    /// 「最後のウィンドウが閉じた」は作品が終わったことと同じだが、出口が外のプロセスに在る経路では
    /// 何も意味しない — そこで数えられるウィンドウは作品のものではないからである。
    ///
    /// 実際に数えられていたのは**メニューバーの名乗り** (``SketchPresence``) が開くメニュー
    /// だった。ウィンドウを 1 枚も持たないスケッチでは、それが開いて閉じた瞬間が「最後のウィンドウが閉じた」
    /// になり、名乗りを覗いただけでスケッチが終わっていた
    /// ([#1102](https://github.com/mokume-metal/mokume/issues/1102))。ウィンドウは道具のものなので
    /// 画面には残り、止まった絵のまま動かない。
    ///
    /// **終わらせる経路が無くなるわけではない。** ウィンドウを持たない子を止めるのは道具で、
    /// ウィンドウの × も端末の `Ctrl-C` も同じ後始末 (`WatchSession.stop()`) を通る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    var endsAfterLastWindowClosed: Bool {
        switch outlet {
        case .shared, .render: false
        case .pendingWindow, .window: true
        // 最後のウィンドウを数えるのはホストで、`NSApplication` を回すのもホストである
        case .embedded: false
        }
    }

    /// 活動の方針。**ウィンドウを持たない経路では Dock に並ばない** (`.accessory`) — 並ぶと、道具が
    /// 出すウィンドウと作品が 2 つ並んで見える。書き出す経路にはそもそも見せるウィンドウが無い。
    ///
    /// 据えるのは ``run()`` で、ここは決めるだけである。据えると呼んだプロセス全体に効くので、
    /// 検査はこの値だけを読む。
    var activationPolicy: NSApplication.ActivationPolicy {
        switch outlet {
        case .shared, .render: .accessory
        // ウィンドウはまだ建っていないが、建てると決まっている
        // 据えるのは ``run()`` だけで、埋め込んだ経路は据えない (ホストのアプリの方針)
        case .pendingWindow, .window, .embedded: .regular
        }
    }

    /// 時刻の出どころ。**起動の瞬間に決まる** — 書き出すならその刻みのフレーム番号、でなければ
    /// 作品が選んだ時計 (既定は実時間・``Clock/launching(_:frameRate:)``)。
    /// 検査が読む。
    let clock: Clock

    /// 決めた枚数を描き終えた (書き出す経路だけ)。
    ///
    /// **× や終わりの合図と同じ 1 本へ入れる** — 後始末を待つ ``shouldTerminate()`` を通さない
    /// と、書いていた動画が開けないまま残る。**検査から差し替える** (``onCloseConfirmed`` と
    /// 同じ理由)。
    var onRenderFinished: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    /// 書き出しが揃わなかったときに、プロセスを終わらせる口。
    ///
    /// **道具は終了コードで「書けたか」を読む** (`mokume render`)。AppKit の終わりの経路は
    /// 0 で終わるので、揃わなかったときはここから 0 以外で終わる。**検査から差し替える** —
    /// 既定のままでは、揃わなかった回を検めるたびに検査のプロセスが終わる。
    var exitProcess: @MainActor (Int32) -> Void = { exit($0) }

    /// 起動できなかった理由を、見張りへ渡す口 (``reportStartFailure(_:note:)``)。**検査から差し替える** —
    /// 既定の口は、見張りに起こされたときだけ区画へ置く (``WorkDirectory/noteStartFailure(_:forProcess:under:owner:)``)。
    var noteStartFailure: (String) -> Void = { noteOwnStartFailure($0) }

    /// 最初の絵を出したことを、見張りへ渡す口 (``Sketch/main()`` が置いた起動中の印を消す)。**検査から差し替える。**
    var markFirstFrame: () -> Void = {
        if SharedFrameSurface.launchOwner != nil { WorkDirectory.clearStarting() }
    }

    /// 最初の絵を出したか。**最初の `advance` と差し出しが例外なく戻ったら、1 度だけ ``markFirstFrame`` を呼ぶ。**
    /// 差し出しが何も出さずに戻る回(ウィンドウが見えていない・待ちに入る)でも立つ — 印を消す側に倒した安全側の読みで、
    /// 見張りは印が残っていた子だけを「最初の絵の前に終わった」と読む。
    private var hasPresentedFirstFrame = false

    /// 書き出す経路で、描けなかったフレームの数。
    private var framesFailedToDraw = 0

    /// フレームの駆動源。**画面に紐づく** (``ScreenDisplayLink`` が理由を持つ)。書き出す経路は繋がない
    /// (``fullSpeedDriver``)。
    ///
    /// **検査が読む** (据えた速さ・#1642)。
    let screenLink: ScreenDisplayLink

    /// 画面を持たない全速の駆動。**書き出す経路だけが繋ぐ** ([#3474](https://github.com/mokume-metal/mokume/issues/3474))。
    /// 画面に出さない経路が画面の刻みを待つと、作品が宣言した `frameRate` と画面のリフレッシュが書き出しの
    /// 速さの上限になる。叩く入口は画面の駆動源と同じ (``displayLinkFired(at:)``) である。
    ///
    /// **検査が読む** (繋いだか・描き終えて畳んだか)。
    let fullSpeedDriver = FullSpeedFrameDriver()

    /// × を押した人に問う言葉。**無ければ確かめずに閉じる。**
    ///
    /// 既定は起動の瞬間に決まる — 道具が起こしたときだけ問いを持つ
    /// (``CloseConfirmation``)。**検査から差し替える**: 検査のプロセスに合図は渡らないので、
    /// そのままでは問いの経路を 1 つも通れない。
    var closeQuestion: CloseQuestion? = CloseConfirmation.startupQuestion()

    /// 問いの出し方。**検査から差し替える** (``SharedFrameStage/presentQuestion`` と同じ流儀)。
    var presentQuestion: @MainActor (CloseQuestion, NSWindow, @escaping (Bool) -> Void) -> Void =
        CloseQuestion.presentSheet

    /// ファイルを選ばせるダイアログの出し方 ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    /// **検査から差し替える** — 本物の `NSOpenPanel` は人の操作を待つ。
    var filePicker: any FilePicker = OpenPanelPicker()
    /// いま出しているダイアログの頼みの通し番号と、それを結果ごと捨てて閉じる口。答えた後は `answered`。
    private var shownSelection: (serial: Int, dismiss: @MainActor () -> Void, answered: Bool)?
    /// 閉じる問いのシートを出している間か。付いているシートが問いのものか、ファイルを選ばせるものかを分ける
    /// (``shouldClose(_:)``)。
    private var isAskingToClose = false

    /// 閉じてよいと確定したときの行き先。
    ///
    /// **道具立てごと終わらせる。** ウィンドウを畳むだけでは後始末を通らず、差込口も駆動源も
    /// 生きたまま残る — 終わりの経路は `terminate(_:)` の 1 本で、後始末を待つ
    /// ``shouldTerminate()`` から ``willTerminate()`` へ進む。**検査から差し替える**: 既定の
    /// ままでは、押した後を検めるたびに検査のプロセスが終わる。
    var onCloseConfirmed: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    /// 終わりの合図 (`SIGTERM` / `SIGINT`) を受けたときの行き先 ([#1219])。
    ///
    /// **× と同じ 1 本へ入れる** — 後始末を待つ ``shouldTerminate()`` を通さないと、撮って
    /// いた動画が開けないまま残る。**検査から差し替える** (``onCloseConfirmed`` と同じ理由)。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    var onStopSignal: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    /// 起こした道具が居なくなったか。**1 度だけ `true` を返す** ([#1427])。
    ///
    /// 道具が捕まえない合図や `SIGKILL` で消えると、ウィンドウ (道具のもの) だけが一緒に消えて子が
    /// 残り、人が止める入口が無くなる。気付くのは管が畳まれたことで
    /// (``SketchRuntime/takeDriverDeparture()``)、行き先は終わりの合図と同じ 1 本である。
    /// **検査から差し替える** — 検査のプロセスは道具から起こされていない。
    ///
    /// [#1427]: https://github.com/mokume-metal/mokume/issues/1427
    var driverDeparted: @MainActor () -> Bool

    /// 後始末が済んだと AppKit へ返す口。
    ///
    /// **「終わってよい」しか返さない** — 待っている途中で終わりをやめる経路は作らない
    /// ([#978])。**検査から差し替える**: 返事を待っている終了が無いプロセスで既定のまま
    /// 呼ぶと、AppKit が何をするかをこちらで決められない。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    var replyToTermination: @MainActor () -> Void = {
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    /// 終わると決まったか。**立てたら下ろさない** — 終わりの意思は覆さない。
    private var isTerminating = false
    /// ホストのアプリが終わる知らせの受け口 (埋め込みのときだけ。``stopEmbedded()`` が外す)。
    private var terminationObserver: NSObjectProtocol?
    /// 後始末を見に来る仕掛け。**返事を待たせている間だけ持つ。**
    private var terminationPoll: Timer?
    /// 後始末を見に来る間隔 (秒)。
    ///
    /// 見に来るのは返事を待たせている間だけなので、細かく取っても払うのは終わり際の
    /// 数回ぶんである。粗く取ると、そのぶん閉じ終えてから終わるまでが遅れる。
    static let terminationPollInterval = 0.01

    /// ウィンドウの出来事を、自分を強く持たせずに受ける。
    ///
    /// **ウィンドウの delegate に ``SketchApplication`` を直に据えない。** AppKit は delegate を
    /// 弱く参照するが、呼ぶ前に一時的な強い参照を作る (autorelease) ので、据えた側の解放が
    /// プールの掃除まで遅れる — 道具の台が同じ理由で中継を置いている
    /// (`SharedFrameStage.WindowRelay`)。
    @MainActor private final class WindowRelay: NSObject, NSWindowDelegate {
        weak var application: SketchApplication?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            application?.shouldClose(sender) ?? true
        }
    }

    private let windowRelay = WindowRelay()

    /// いま走らせているもの。``run()`` の間と、``SketchView`` の中で走っている間だけ入る。
    /// **入っていれば 2 つ目の ``run()`` を断り** (#2027)、2 つ目の ``SketchView`` は待たせる。
    ///
    /// 空になったら、待っている ``SketchView`` の先頭を起こす (``scheduleEmbeddedWake()``)。
    ///
    /// **入っている間、その実行を映している実行として控える** (``OutsideRun/present(_:)``・#3847)。フレームの外で部品から
    /// 語彙を呼んだとき、映している実行が 1 つだけならそれへ向けるためである。
    private static var running: SketchApplication? {
        didSet {
            if oldValue !== running {
                oldValue?.endPresenting()
                running?.beginPresenting()
            }
            if oldValue != nil, running == nil { scheduleEmbeddedWake() }
        }
    }

    /// 映している実行を載せた控え。**降ろすときも同じ控えから降ろす** — 検査が控えを差して載せたものを、
    /// 差していない所から降ろすと、プロセスの控えを探して残る。
    private var presentedIn: OutsideRun?

    private func beginPresenting() {
        let log = OutsideRun.log
        log.present(runtime)
        presentedIn = log
    }

    private func endPresenting() {
        presentedIn?.withdraw(runtime)
        presentedIn = nil
    }

    /// 待っている ``SketchView`` を起こす仕事を、main の次の回へ送ってあるか。
    ///
    /// **立っている間は、走っているものが無くても ``SketchView`` には「埋まっている」と答える** (``admission(for:)``) —
    /// 送った間に新しく出た ``SketchView`` が、待っているものを追い越して始まらない。``run()`` には空いている。
    private static var embeddedWakePending = false

    /// 順番を待っている ``SketchView`` (待ち始めた順)。**弱く持つ** — 待ちながら消えたビューを起こさない。
    private static var embeddedWaiters: [WeakEmbeddedWaiter] = []

    /// 2 つ目の ``run()`` を断ったと、もう言ったか。**言うのはプロセスで 1 度だけ。**
    private static var refusalAnnounced = false

    /// 2 つ目の ``run()`` を断るときに言う 1 行。検査が読む。
    static let secondRunRefusal =
        "A sketch is already running in this process — this second run() does nothing (one window per process)"

    /// AppKit へ渡した delegate。弱く参照される先なので、こちらで寿命を持つ。
    private var delegate: SketchApplicationDelegate?

    /// 省電力の間引きを断っている印。**手放した時点で断りが切れる**ので、走らせている間は持つ。
    ///
    /// 取る組み合わせにも意味がある。間引きを断るのに要るのは「background ではない」ことだけ
    /// なので、機械のスリープまで止める `.userInitiated` ではなく
    /// `.userInitiatedAllowingIdleSystemSleep` を取る — 要件が求めていない約束を副作用で
    /// 足さないため。`.latencyCritical` は「この周期処理は時刻に縛られている」という名乗りで、
    /// ADR-0012 決定 5 が要件にした性質そのものである。
    private var activity: (any NSObjectProtocol)?
    /// ディスプレイが勝手に消えるのを断っているもの。**ウィンドウを出す経路でだけ持つ。**
    private var displaySleepBlock: DisplaySleepBlock?
    /// 走っている間、ディスプレイが消えるのを断るか。**既定は断る** (#874)。書き出す経路 (`mokume render`) は
    /// 画面に出さないので、この値に依らず断らない (#3474)。
    ///
    /// 外してよいのは、**画面が消えることそのものを測る検査**だけである
    /// (`scripts/check-observation-roundtrip.sh --display-asleep`)。断ったまま測ると
    /// 「スリープを作れなかったのに緑」という嘘が出る。
    public var blocksDisplaySleep = true

    /// 速さを名乗る仕掛け。名乗りが与えられたときだけ持つ。
    private var frameRateNotice: Timer?
    /// 速さの直近の推移 (#3424)。**この子の中にだけ持つ** — 作り直しで子が替われば空から
    /// 始まり、版の違う値が 1 本に見えない。名乗るときだけ持つ。
    private var frameRateHistory: FrameRateNotice.History?

    /// 続けて描けなかった数。**始まりと終わりだけ**言うために持つ。
    private var frameFailures = FrameFailureLog()

    /// 前に出した絵の鍵。**止まっている間に、同じ絵を出し直さない**ために持つ ([#2367])。
    ///
    /// 出していなければ・出せなかったときや、出し直す理由を見つけたときは `nil` に戻す。
    ///
    /// [#2367]: https://github.com/mokume-metal/mokume/issues/2367
    private var lastShown: ShownFrame?

    /// 出した絵が同じかを決める鍵。**絵が変わる理由はすべてここに載せる** — 載せ忘れた理由は、止まって
    /// いる間に変わってもウィンドウにも出口にも出ない。
    ///
    /// - `target`・`revision`: 描画先とその内容 (``RenderTarget/contentRevision``。GPU への書き込みと
    ///   CPU の画素の書き込み)
    /// - `brightness`: 出力段の明るさ (`exposure()`・`toneMapping()`)。止まっている間に変えても絵が変わる
    /// - `drawable`: ウィンドウの面の大きさ。変わったら出し直す (共有面は `nil`)
    /// - `pointerLock`・`cursorHidden`: 共有面に絵と一緒に載る要求。ウィンドウへは渡す経路が別なので `false`
    /// - `selection`: 共有面に絵と一緒に載る、ファイルを選ばせる頼み。ウィンドウへは渡す経路が別なので `nil`
    /// - `windowTitle`: 共有面に絵と一緒に載る、題名を変える頼み (#3709)。ウィンドウへは渡す経路が別なので `nil`
    struct ShownFrame: Equatable {
        let target: ObjectIdentifier
        let revision: UInt64
        let brightness: Brightness
        let drawable: CGSize?
        let pointerLock: Bool
        let cursorHidden: Bool
        let selection: SelectionBroker.Request?
        let windowTitle: String?
    }

    /// 名乗ってよい速さ。**測れていなければ `nil`。**
    ///
    /// 数えるのは**進めたフレーム**で、画面へ出した回数ではない。ウィンドウが見えていない間も
    /// スケッチは進み続けるので、ここで出した回数を数えると「最小化したら 0 になった」
    /// と読めてしまう — 測りたいのは絵が進んでいるかである。
    ///
    /// **ウィンドウはここでも読み手である** ([ADR-0030] 決定 7)。自分では数えず、観測の応答が
    /// 返すのと同じ集計器を読む。止まったスケッチや起動直後は測れていないので `nil` を
    /// 返す — **欠測を 0 に化けさせると「とても重い」と誤読される** ([ADR-0029] 決定 3)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    public var currentFrameRate: Double? { runtime.frameNumbers.frameRate }

    /// 面を取れずに見送ったフレームの数。
    public var missedFrames: Int { presenter.missedFrames }

    /// 画面へ出しながら回す扱いか (`SketchRuntime.isOnScreen`)。**検査が読む。**
    var isOnScreen: Bool { runtime.isOnScreen }

    /// ウィンドウがいま画面に出ているか。
    public var isWindowOnScreen: Bool { window?.isVisible ?? false }

    /// ウィンドウの一部でも実際に見えているか。
    ///
    /// 最小化・他のウィンドウによる被覆・別の Space への切り替えを **1 つの判定で覆う**。
    /// 最小化だけを特別扱いしないのは、どれも「画面へ出しても誰も見ない」という
    /// 同じ状態だからである。
    ///
    /// 埋め込んだ経路では、面が載っているホストのウィンドウを読む。
    private var isWindowVisible: Bool {
        windowVisibilityForTesting
            ?? (window ?? embeddedHostWindow)?.occlusionState.contains(.visible) ?? false
    }

    /// ウィンドウが見えているかの答えを**検査から決める**。製品の経路では常に `nil`。
    ///
    /// 検査のプロセスは前面のアプリケーションではないので、ウィンドウを出しても見えていることにならず
    /// (`occlusionState` が更新されない)、見えている間の出し方 (止まっている間に出し直さない・#2367)
    /// を確かめられない。
    var windowVisibilityForTesting: Bool?

    /// スケッチを画面に出す用意をする。
    ///
    /// 時刻の出どころは**既定で実時間**にする — 画面に出しながら動かす経路なので、
    /// 実際に流れた時間で動くのが正しい。作品が ``SketchSettings/clock`` で
    /// ``SketchSettings/ClockMode/frames`` を選んでいれば、宣言の刻みのフレーム番号にする。
    ///
    /// 道具が書き出しを頼んだとき (`mokume render`・``StartupReads/render``) だけは、ウィンドウを
    /// 開かずに決めた枚数を書き出す。その経路の時刻はフレーム番号から導く。
    ///
    /// **頼みの合図が在って読めなければ、ウィンドウへ倒さず投げる** (``RenderFailure/unreadableRenderRequest(value:)``・
    /// [#2481](https://github.com/mokume-metal/mokume/issues/2481))。
    public convenience init(sketch: any Sketch, gpu: RenderDevice) throws(RenderFailure) {
        try self.init(sketch: sketch, gpu: gpu, embedded: false)
    }

    /// ホストのアプリの中 (``SketchView``) で走らせる組み方を選べる入口。
    ///
    /// - Parameter embedded: `true` なら、全画面 (``SketchSettings/fullScreenDisplay``) を読まず・メニューバーの
    ///   名乗りを出さない (``SketchRuntime/isEmbedded``)。ウィンドウもアプリの寿命もホストのものである。
    convenience init(sketch: any Sketch, gpu: RenderDevice, embedded: Bool) throws(RenderFailure) {
        // **ウィンドウの持ち主の合図を、ここで読んで環境から消す** (``SharedFrameSurface/launchOwner``)。
        // スケッチが `setup()` で子を起こしても、合図はもう継がれない
        _ = SharedFrameSurface.launchOwner
        // **置き場の元の合図も同じ** (#2517)。孫へ継がせない
        _ = ShaderOrigin.startup()
        // **作り直しをまたぐ時計の合図も同じ** (#2414)。書き出しの頼みが在れば使わない (下の `render`)
        let render = try RenderRequest.startup()
        // **記録の合図も同じ** (#3570)。ホストのアプリの中 (``SketchView``) と書き出しの子は記録しない。**使わなくても、
        // 環境からは必ず消す** — 残れば、そこから起こす子が継いで、頼んでいない実行が記録を始める
        let record = ReplayRequest.startup(forRun: !(embedded || render != nil))
        try self.init(
            sketch: sketch, gpu: gpu, render: render,
            handover: ClockHandover.startup(), embedded: embedded, record: record)
    }

    /// 書き出しの頼みを渡せる入口。**検査から渡す** — 本番は起動の瞬間に環境から読む
    /// (``init(sketch:gpu:)``)。
    ///
    /// **頼みは時計と画面の出口の両方を決める。** 時計だけ差し替えてウィンドウを開くと、ウィンドウが受けた
    /// 入力が作品に届き、同じ引数から同じ動きが出なくなる (``ScreenOutlet/render(_:)``)。
    ///
    /// - Parameters:
    ///   - render: 書き出しの頼み。`nil` ならいつものウィンドウの経路。
    ///   - displays: ディスプレイの一覧の出どころ (全画面で出す先を選ぶ・#2020)。既定はいま
    ///     繋がっているもの。**検査から差し替える。**
    ///   - handover: 作り直しをまたいで作者の時計を渡す口 (`watch --keep-time`・#2414)。**書き出しの頼みが
    ///     在れば使わない** — 書き出しは 0 秒から、同じ引数から同じ動きを出す。
    ///   - embedded: ホストのアプリの中 (``SketchView``) で走らせるか (``SketchRuntime/isEmbedded``)。
    ///   - record: 実行を頭から終わりまで記録する頼み (`mokume run --record`・``StartupReads/record``・#3570)。
    ///     **書き出しの頼みが在れば使わない。** フレームの時計のスケッチだけを記録する。
    init(
        sketch: any Sketch, gpu: RenderDevice, render: RenderRequest?,
        displays: () -> [Display] = { Display.connected },
        handover: ClockHandover? = nil,
        embedded: Bool = false,
        record: ReplayRequest? = nil
    ) throws(RenderFailure) {
        self.gpu = gpu
        // **設定は 1 度だけ読む。** 計算型の設定は読むたびに別の値を返しうるので、題名と断る口を別々に読むと、組み立て
        // (`SketchRuntime`) が読む前に読みが増える (#1642・`SetupValueRangeTests` の `Fickle`)
        let settings = sketch.settings
        self.title = settings.title
        self.sharesFrames = settings.sharesFrames
        // **刻みは頼みから採る。** 撮る係の刻みも時計から決まる (`SketchRuntime.launchFrameRate`)
        // ので、`--fps` が作品の宣言と違っても最後の 1 枚まで揃う。頼みが無ければ、ランタイムが
        // 組み立てで読んだ作品の時計 (`SketchSettings.clock`) で、既定は実時間 (#2601)。**ここで
        // 設定を読み直さない** — 計算型の設定は読むたびに別の値を返しうる (#1642)
        let clock: Clock? = render.map { .frameIndex(frameRate: $0.frameRate) }
        self.outlet = render.map(ScreenOutlet.render) ?? .pendingWindow
        // **利用者の断片の保存を裏で組むのも、ウィンドウ・共有面の経路だけ** ([#2365])。書き出しは保存の
        // 次のフレームの頭で組み、同じ引数から同じ絵が出る。ウィンドウの経路はもともと実時間の時計で、
        // 保存のたびにウィンドウが止まるほうが害が大きい ([ADR-0025] 追補 2026-10-14)
        //
        // [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
        // [#2365]: https://github.com/mokume-metal/mokume/issues/2365
        gpu.rebuildsShadersInBackground = render == nil
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: gpu, clock: clock, now: { CACurrentMediaTime() },
            displays: displays, onScreen: render == nil, opensFacets: render == nil,
            handover: Self.handover(given: handover, render: render),
            outputScale: render?.scale ?? 1, embedded: embedded)
        self.clock = runtime.clock
        // **記録は最初の枚の前に始める** (途中から始める口は無い・#3570)。実時間の時計なら始めず、理由を言って走り続ける
        if let record { runtime.startRecording(record) }
        // 先送りを許すのは、ウィンドウ・共有面で回すときだけ。書き出す経路は絵が残るので、焼き切る (#2446)
        // **記録している実行は送らない** (ウィンドウなしで流す側と同じ手順で描くので、画素のハッシュが割れない・#3570)
        runtime.defersEnlargedGlyphBakes = render == nil && runtime.replay == nil
        self.runtime = runtime
        self.driverDeparted = { runtime.takeDriverDeparture() }
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        // **速さは組み立てが検めた値を読む。** `sketch.settings` を読み直すと、計算型の
        // 設定は別の値を返しうる — 検めた値そのものなら 1 を割らない (#1642)
        self.screenLink = ScreenDisplayLink(frameRate: Float(runtime.declaredFrameRate))
        super.init()
        screenLink.owner = self
        fullSpeedDriver.owner = self
        windowRelay.application = self
        // `advance()` の外で `setup()` の失敗を見つけた回 (名乗りのメニューが進めた回) も、同じ道で終わらせる (#2401)
        runtime.setupFailureHandler = { [weak self] failure in self?.stopForSetupFailure(failure) }
    }

    /// 作り直しをまたぐ時計の合図を、使うかどうか決める。**書き出しの頼みが在れば使わない** — 書き出しは
    /// 0 秒から、同じ引数から同じ動きを出す ([#2414](https://github.com/mokume-metal/mokume/issues/2414))。
    static func handover(given: ClockHandover?, render: RenderRequest?) -> ClockHandover? {
        render == nil ? given : nil
    }

    /// アプリケーションとして走らせる。戻らない。
    ///
    /// **1 プロセスに走らせられるのは 1 つだけである。** 既に走っているものが在れば、
    /// 2 つ目の呼び出しは断ったことを 1 度だけ標準エラーへ言い、何にも触れずにすぐ戻る。
    /// 走っている 1 つ目は何も変わらず、撮っている動画も、終わり方によらず開けるまま残る
    /// ([#2027](https://github.com/mokume-metal/mokume/issues/2027))。
    public func run() {
        // **2 つ目は、プロセス全体の状態に触れる前に断る** (#2027)。delegate・活動の方針・
        // 終わりの合図はどれもプロセスに 1 つで、差し替えると 1 つ目の後始末 (書き切りを
        // 待つ経路・#1219) が 2 つ目へ行く。区画へ差し出す用意 (`resolveOutlet()`) も外へ
        // 名乗るので、その前で戻る
        guard !SketchApplication.refusesSecondRun() else { return }
        let app = NSApplication.shared
        // **画面の出口を先に決める。** 活動の方針は `app.run()` より前にしか据えられない
        // ので、ウィンドウを開くかどうかをここで知っている必要がある。ウィンドウを持たないなら Dock にも
        // 並ばない (`.accessory`) — 並ぶと、道具が出すウィンドウと作品が 2 つ並んで見える
        resolveOutlet()
        app.setActivationPolicy(activationPolicy)
        // **delegate と自分を強く持っておく。** AppKit は delegate を弱く参照するので、
        // ここで持たないと、delegate を渡した直後に解放され、以後の呼び出しが 1 つも
        // 来ない (ウィンドウが開かない形で表に出る)。走らせている間は生きているべきものなので、
        // 寿命をここで固定する
        let delegate = SketchApplicationDelegate(application: self)
        self.delegate = delegate
        app.delegate = delegate
        SketchApplication.running = self
        // **省電力の間引きを断る** (上記・ADR-0012 決定 5)。走らせている間ずっと保持し、
        // 終わるときに返す — 途中で手放すと、そこから先だけ間引かれる
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "keeping the sketch's frames advancing at a steady rate")
        // **画面が消えると絵が止まる。** 駆動源は画面のリフレッシュに紐づいているので、
        // ディスプレイがスリープすると絵も観測も入力も同時に黙る (#874)。断りを立てて
        // おく — `beginActivity` から `AllowingIdleSystemSleep` を外したのは、片方で
        // 「寝てよい」と言いながら片方で断るコードにしないためである。書き出す経路は画面を持たない
        // 全速の駆動で回るので当たらず、断らない (``holdsDisplayAwake``・#3474)
        if holdsDisplayAwake {
            displaySleepBlock = DisplaySleepBlock(reason: "keeping the sketch on screen")
        }
        // **断りは保証ではない。** 外部ディスプレイの電源を切る・蓋を閉じるといった
        // 経路は断れないので、止まったときに拾う側も要る — そちらは駆動源
        // (`ScreenDisplayLink`) が持っており、繋いだ時点で回り始める
        // **終わりの合図を、後始末を待つ経路へ運ぶ** (#1219)。見に来るのは駆動源 (書き出す経路では
        // 全速の駆動) が叩く ``displayLinkFired()`` で、`app.run()` の前に立った旗は最初の 1 回が拾う
        StopSignals.install()
        // **与えられたときだけ仕掛ける。** 与えられなければ何も足さないので、MCP サーバから
        // 立てたスケッチの出力は 1 バイトも変わらない ([ADR-0029] 決定 5 の 2 番目)
        if FrameRateNotice.announces(
            configuration: FrameRateNotice.configuration, isTerminal: FrameRateNotice.isTerminal),
            let configuration = FrameRateNotice.configuration
        {
            startFrameRateNotice(configuration: configuration)
        }
        app.run()
        // **戻ったら、もう走っていない** (`NSApp.stop`)。外さないと、以後の ``run()`` が
        // 「既に走っている」と言って断る (#2027)
        SketchApplication.running = nil
    }

    /// 画面のスリープを断るか。**画面に絵が出る経路で、``blocksDisplaySleep`` が立っているときだけ。**
    ///
    /// 断るのは、駆動源が画面のリフレッシュに紐づいていて、画面が消えると絵も観測も入力も黙るからである (#874)。
    /// 書き出す経路は画面に出さず、画面を持たない全速の駆動で回るので (``fullSpeedDriver``)、断る理由が無い
    /// ([#3474](https://github.com/mokume-metal/mokume/issues/3474))。**検査が読む** — 据えるのは ``run()`` だけである。
    var holdsDisplayAwake: Bool {
        guard blocksDisplaySleep else { return false }
        if case .render = outlet { return false }
        return true
    }

    /// 席を求めるもの。**席は 1 プロセスに 1 つ**で、``run()`` (``Sketch/main()``) と ``SketchView`` が同じ席を取り合う。
    enum SeatRequester: Equatable {
        /// ``SketchView`` の中で走る (``startEmbedded(pointerLock:cursorHiding:)``)。
        case embedded
        /// ``run()`` と ``Sketch/main()``。
        case run
    }

    /// 席を求めたときの答え。
    enum SeatAdmission: Equatable {
        /// 席が空いている。始める。
        case start
        /// 席は ``SketchView`` が持っている (または、持っているものが消えて、待っているものを起こす仕事が送られている)。
        /// ``SketchView`` なら列に並んで待つ。
        case wait
        /// 席を持っているものは、このまま居続ける。``run()`` なら 2 つ目として断り、``SketchView`` なら待っても
        /// 始まらないので何も映さない。
        case refuse
    }

    /// 席を求めたら、始められるか・待つか・断られるか。**席の判定はここ 1 か所** — ``run()``・``Sketch/main()``・
    /// ``SketchView`` (``startEmbedded(pointerLock:cursorHiding:)``) が同じ関数を読む。
    ///
    /// | 席を持っているもの | ``SketchView`` | ``run()`` |
    /// | --- | --- | --- |
    /// | 無い | 始める | 始める |
    /// | 無いが、待っているものを起こす仕事が送られている | 待つ (追い越さない) | 始める (席を取る。待っているものは断る側へ倒れる) |
    /// | ``SketchView`` | 待つ | 断る |
    /// | ``run()`` | 断る (待っても始まらない) | 断る |
    static func admission(for requester: SeatRequester) -> SeatAdmission {
        guard let running else {
            return embeddedWakePending && requester == .embedded ? .wait : .start
        }
        if requester == .embedded, case .embedded = running.outlet { return .wait }
        return .refuse
    }

    /// 既に走っているものが在れば、断ったことを 1 度だけ言って `true` を返す (#2027)。
    ///
    /// ``run()`` と ``Sketch/main()`` が、プロセス全体の状態に触れる前に呼ぶ。`main()` は
    /// 組み立ての前に呼ぶ — 組み立てが投げると `exit(1)` でプロセスを落とし、走っている
    /// 1 つ目の後始末 (書き切りを待つ経路・#1219) を飛ばすからである。
    ///
    /// 断るかは ``admission(for:)`` が決める。**``SketchView`` が走っていても断る** (席は 1 つ)。
    static func refusesSecondRun() -> Bool {
        guard admission(for: .run) == .refuse else { return false }
        if !refusalAnnounced {
            refusalAnnounced = true
            Diagnostics.warn(secondRunRefusal)
        }
        return true
    }

    // MARK: - ホストのアプリの中で走らせる (SketchView・#3511)

    /// ``SketchView`` が待たされるときに言う 1 行。**言うのはプロセスで 1 度だけ** (``announceEmbeddedWait()``)。
    /// 検査が読む。
    ///
    /// ``secondRunRefusal`` (`run()` の断り) とは別の文面である — `SketchView` は断られて空のまま残るのでなく、
    /// 先の ``SketchView`` が消えれば始まる。
    static let embeddedWaitNotice =
        "A SketchView is already running in this process — this SketchView waits and starts when it goes away (one sketch per process)"

    /// ``SketchView`` が始められず、待っても始まらないときに言う 1 行。**言うのはプロセスで 1 度だけ。**
    /// ``run()`` (``Sketch/main()``) で走っているスケッチは、プロセスが終わるまで居る。検査が読む。
    static let embeddedRefusalNotice =
        "A sketch is already running in this process (run() or Sketch.main()) — this SketchView shows nothing, since it lasts as long as the process (one sketch per process)"

    private static var embeddedWaitAnnounced = false
    private static var embeddedRefusalAnnounced = false

    /// 待つ理由を、プロセスで 1 度だけ言う。**待つビューの数・画面の出入りで繰り返さない。**
    static func announceEmbeddedWait() {
        guard !embeddedWaitAnnounced else { return }
        embeddedWaitAnnounced = true
        Diagnostics.warn(embeddedWaitNotice)
    }

    /// 待っても始まらない理由を、プロセスで 1 度だけ言う。
    static func announceEmbeddedRefusal() {
        guard !embeddedRefusalAnnounced else { return }
        embeddedRefusalAnnounced = true
        Diagnostics.warn(embeddedRefusalNotice)
    }

    /// 言ったかの控えを戻す (待つ理由・待っても始まらない理由・2 つ目の ``run()`` の断り)。**検査から呼ぶ** —
    /// プロセスで 1 度の名乗りを、検査ごとに数え直すため。
    static func resetEmbeddedAnnouncementsForTesting() {
        embeddedWaitAnnounced = false
        embeddedRefusalAnnounced = false
        refusalAnnounced = false
    }

    /// ``run()`` が走っている印だけを立てる。**検査から呼ぶ** — `run()` は戻らないので、走っているのが
    /// ``run()`` のときの ``SketchView`` の振る舞いを、検査から見るために要る。
    func markRunningForTesting() { SketchApplication.running = self }

    /// ``markRunningForTesting()`` で立てた印を下ろす。
    func unmarkRunningForTesting() {
        if SketchApplication.running === self { SketchApplication.running = nil }
    }

    /// 順番待ちの列へ並ぶ。**同じものを 2 度並べない。**
    static func enqueueEmbeddedWaiter(_ waiter: some EmbeddedWaiter) {
        embeddedWaiters.removeAll { $0.waiter == nil || $0.waiter === waiter }
        embeddedWaiters.append(WeakEmbeddedWaiter(waiter: waiter))
    }

    /// 順番待ちの列から外れる (待ちながらビューが外れた)。
    static func dequeueEmbeddedWaiter(_ waiter: some EmbeddedWaiter) {
        embeddedWaiters.removeAll { $0.waiter == nil || $0.waiter === waiter }
    }

    /// 走っているものが無くなった。**待っている ``SketchView`` を起こす仕事を、main の次の回へ送る。**
    ///
    /// 同期に起こさない — 起こす側 (`dismantleNSView`・フレームの途中の失敗) は SwiftUI の更新や駆動源の呼び出しの
    /// 最中で、起こされたビューの重い初期化 (描画の土台・面の追加・第一応答者) をそこへ載せない。
    private static func scheduleEmbeddedWake() {
        guard !embeddedWaiters.isEmpty, !embeddedWakePending else { return }
        embeddedWakePending = true
        // **送った側の警告の行き先を持って行く。** `DispatchQueue.main.async` の中は `Task` ではなく、タスクローカル値
        // (`Diagnostics.digest`) が切れる — 起こされたビューが組み立てで言う警告が、送った側と別の溜め場へ行く
        let digest = Diagnostics.digest
        DispatchQueue.main.async {
            Diagnostics.$digest.withValue(digest) {
                MainActor.assumeIsolated {
                    embeddedWakePending = false
                    wakeNextEmbeddedWaiter()
                }
            }
        }
    }

    /// 先頭から順に、**誰かが走り始めるまで** 起こす。
    ///
    /// 起こされたビューは自分で始める (``EmbeddedWaiter/vacancyOpened()``)。外れたもの・始められなかった
    /// (組み立てが投げた) ものは飛ばして、次を起こす。走り始めたら残りは待ったままである。
    ///
    /// **起こす仕事が送られている間に、``run()`` が席を取ったら、待っているものは全部列から外して起こす** —
    /// 起こされたビューは自分で席を求め直し (``admission(for:)``)、断られて、「待っても始まらない」と 1 度だけ
    /// 言って何も映さない。残すと、プロセスが終わるまで「先が終われば始まる」と名乗ったまま待ち続ける。
    private static func wakeNextEmbeddedWaiter() {
        if let running, !embeddedWaiters.isEmpty {
            if case .embedded = running.outlet { return }
            let waiters = embeddedWaiters
            embeddedWaiters.removeAll()
            for entry in waiters { entry.waiter?.vacancyOpened() }
            return
        }
        while running == nil, !embeddedWaiters.isEmpty {
            let next = embeddedWaiters.removeFirst()
            next.waiter?.vacancyOpened()
        }
    }

    /// ホストのアプリの中 (``SketchView``) で走らせる組み方か (``SketchRuntime/isEmbedded``)。検査が読む。
    var runsEmbedded: Bool { runtime.isEmbedded }

    /// 埋め込んだ面が載っているホストのウィンドウ。載っていなければ `nil`。
    private var embeddedHostWindow: NSWindow? {
        if case .embedded(let surface, _) = outlet { surface.window } else { nil }
    }

    /// ホストのアプリの中で走らせる用意をして、絵を映す面を返す。**面をホストの `NSView` へ載せるのは
    /// 呼び出し側** (``SketchView``)。
    ///
    /// ``run()`` の代わりに呼ぶ。**`NSApplication` を回さない** — アプリの寿命・メニュー・ウィンドウ・Dock の
    /// 方針はホストのもので、ここは面と駆動源と省電力の断りだけを持つ。据えないもの:
    ///
    /// - 活動の方針 (`setActivationPolicy`)・`NSApplicationDelegate`・終わりの合図 (`StopSignals`)・
    ///   速さの名乗り: プロセス全体に効くので、ホストのものに触れない
    /// - ディスプレイのスリープの断り: 画面が消えるのを断るかはホストが決める (止まれば駆動源の
    ///   予備が叩く・``ScreenDisplayLink``)
    ///
    /// **1 プロセスに走らせられるのは 1 つだけ。** 席が空いていなければ (``admission(for:)`` が `.start` でなければ)、
    /// **黙って** `nil` を返す。待たせて名乗るのは呼び出し側 (``SketchView``・``enqueueEmbeddedWaiter(_:)``) — `run()` の
    /// 断り (``refusesSecondRun()``) は使わない。あれは「この呼び出しは何もしない」と言うもので、`SketchView` は
    /// 先が終われば始まり、`Sketch.main()` が断る 1 度の名乗りも食わない。
    ///
    /// 駆動源は面がホストのウィンドウに載ってから ``attachEmbeddedDriver()`` で繋ぐ。終わるときは
    /// ``stopEmbedded()`` を呼ぶ。
    ///
    /// - Parameters:
    ///   - pointerLock: 面が使うポインタの捕まえ。**検査から差し替える** — 本番の口のままでは、検査を走らせている人の
    ///     カーソルを奪う。
    ///   - cursorHiding: 面が使う矢印の隠し。同じく検査から差し替える。
    func startEmbedded(
        pointerLock: PointerLock = PointerLock(), cursorHiding: CursorHiding = CursorHiding()
    ) -> SketchSurface? {
        guard SketchApplication.admission(for: .embedded) == .start else { return nil }
        // **ファイルのドロップは受けない** (`acceptsFileDrops: false`)。ウィンドウはホストのもので、ホスト側のドロップと
        // 取り合わない。受けるのは macOS の自前のウィンドウだけ (``Sketch/fileDropped(_:)``)
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: runtime.target.width, height: runtime.target.height),
            device: gpu.device, input: runtime.input,
            canvasSize: (runtime.target.width, runtime.target.height), pointerLock: pointerLock,
            cursorHiding: cursorHiding, acceptsFileDrops: false)
        surface.wantsLayer = true
        surface.autoresizingMask = [.width, .height]
        // **つまみは絵の外に立つ** (ADR-0030 決定 1)。`Sketch.main()` のウィンドウと同じく重ねる
        KnobOverlay.makeIfNeeded(for: runtime.paramRegistry) { [runtime] in runtime.frameNumbers }?
            .attach(to: surface)
        outlet = .embedded(surface, hasPresented: false)
        SketchApplication.running = self
        // **ホストのアプリが終わるときも、同じ後始末を通す。** ホストの終了では SwiftUI が `dismantleNSView` を通らず、
        // 差込口の閉じ・つまみの保存の flush が飛ぶ。`stopEmbedded()` が自分で外す。
        // **受け口は同期に走らせる** (`queue: nil`) — `.main` を渡すと次の回へ送られ、終わる前に走らない。
        // アプリの終了の知らせは main で来る
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopEmbedded() }
        }
        // 省電力の間引きを断る (ADR-0012 決定 5)。走らせている間ずっと保持し、終わるときに返す
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "keeping the sketch's frames advancing at a steady rate")
        return surface
    }

    /// 面がホストのウィンドウに載った。駆動源をウィンドウの画面へ繋ぎ、ウィンドウが移ったら追う。
    ///
    /// **ウィンドウに何も据わっていなければ、面を第一応答者にする** (キーが 1 件も来ないため・
    /// ``SketchSurface/acceptsFirstResponder``)。ホストが別のものを据えていれば奪わない。
    func attachEmbeddedDriver() {
        guard case .embedded(let surface, _) = outlet, !isTerminating,
            let window = surface.window
        else { return }
        if window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(surface)
        }
        surface.synchronizeDrawableSize()
        screenLink.attach(to: window.screen ?? NSScreen.main, following: window)
    }

    /// 面がホストのウィンドウから外れた。駆動源を畳む (ウィンドウが無い間は進めない)。載り直したら
    /// ``attachEmbeddedDriver()`` が繋ぎ直す。
    func detachEmbeddedDriver() {
        guard case .embedded = outlet else { return }
        screenLink.invalidate()
        // **ウィンドウから外れたら、シートも閉じる** — ビューが消えたのに、シートが元のウィンドウに残らない。結果は取り消しとして渡り、
        // 載り直した最初のフレームが汲む。dismantle を通らない外れ方 (別のウィンドウへ付け替える・ホストが外す) もここへ来る
        _ = cancelOpenSelectionDialog()
    }

    /// ホストの中で走らせるのをやめて、後始末をする。**何度呼んでもよい。**
    ///
    /// ``willTerminate()`` と同じ後始末を、`NSApplication` を終わらせずに通す。差込口 (カメラ・音・
    /// シリアル・ソケット) を閉じ、撮っていた動画は書き切りを待つ。**走っているものの印を外す** — 外すと
    /// 待っている `SketchView` が起こされる。外し忘れると、待っているものは永久に起こされない
    /// (「断られる」のは、2 つ目の ``run()`` と、``run()`` が走っている間に出た `SketchView` だけである)。
    ///
    /// **止めた後は、同じフレームの続きも含めて面に触れない** (``followPointerLockRequest()`` が止まった後は何もしない)。
    /// 呼び出しは、ビューが外れたとき (`dismantleNSView`・`isolated deinit`)、`setup()` が投げたとき、ホストの
    /// アプリが終わるとき (``NSApplication/willTerminateNotification``) である。ホストが終わるときは SwiftUI が
    /// `dismantleNSView` を通らないので、通知で受ける — 塞いで待つのは撮る係の書き切りだけで、その待ちは
    /// ``willTerminate()`` の最後の砦と同じ期限で諦める。
    ///
    /// **ホストのウィンドウに残しうるものも手放す。** ファイルを選ばせるシートが開いていれば閉じ (自前のウィンドウで閉じたときと同じ
    /// 取り消しの結果を渡す)、捕まえているポインタと隠している矢印を戻し、面が第一応答者なら手放す — 次に始まる
    /// ``SketchView`` の面が、キーを受けられる。
    func stopEmbedded() {
        guard case .embedded(let surface, _) = outlet, !isTerminating else { return }
        isTerminating = true
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        _ = cancelOpenSelectionDialog()
        surface.pointerLock.tearDown()
        surface.cursorHiding.stop()
        if let window = surface.window, window.firstResponder === surface {
            window.makeFirstResponder(nil)
        }
        runtime.closePlugins()
        screenLink.invalidate()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if SketchApplication.running === self { SketchApplication.running = nil }
    }

    /// 1 秒ごとに速さを名乗る。
    ///
    /// **付け足しは本体を妨げない** ([ADR-0029] 決定 5)。投げる経路を持たず、フレームの
    /// 進行にも触れない — 読むのは既に測ってある値だけである。
    ///
    /// **同じ 1 行を書き換える。** 積み上げると、見張りを付けっぱなしにしている間に
    /// 作り直しの記録と失敗の出力が上へ流れていく — いちばん読みたいものが、いちばん
    /// 流されやすくなる ([#685](https://github.com/mokume-metal/mokume/issues/685))。
    ///
    /// 推移は直近 30 秒を 1 秒 1 文字で添える (#3424)。縦軸の上端は、起動のときに検めた
    /// 宣言値 (``SketchRuntime/declaredFrameRate``) で、`settings` は読み直さない
    /// (#1642・#1323)。
    ///
    /// **行は端末の幅に収める** (#3536)。1 秒ごとに ``FrameRateNotice/columns`` を読み直し、
    /// 収まらない分は推移の古い側から落とす。幅を越えた行が折り返すと、書き換えが今いる物理行
    /// しか消さないので、上の物理行が毎秒 1 行ずつ積み上がる — この約束が破れる。それでも越える
    /// 幅 (推移を全部落としても足りない・曖昧幅を全角で描く設定) のために、**書く間だけ端末の
    /// 自動折り返しを切る** (``FrameRateNotice/rewriting(_:)``)。越えた分は右で切れる。
    private func startFrameRateNotice(configuration: String) {
        frameRateHistory = FrameRateNotice.History(declaredFrameRate: runtime.declaredFrameRate)
        frameRateNotice = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var history = self.frameRateHistory else { return }
                let rate = self.currentFrameRate
                history.record(rate: rate, at: FrameRateNotice.monotonicSeconds)
                self.frameRateHistory = history
                let line = FrameRateNotice.line(
                    rate: rate, configuration: configuration, history: history,
                    columns: FrameRateNotice.columns)
                print(FrameRateNotice.rewriting(line), terminator: "")
                fflush(stdout)
            }
        }
    }

    /// 画面の出口を決める。``run()`` が `NSApplication.run()` より前に 1 度だけ呼ぶ。
    ///
    /// **切り出してあるのは、検査がウィンドウを持たない経路を作れるようにするため。** 出口が
    /// 決まるのが `run()` の中だけだと、そこは戻らない呼び出し (`app.run()`) を含むので
    /// 検査から通せず、**ウィンドウ 0 枚の経路の振る舞いを 1 つも見られない**
    /// ([#1102](https://github.com/mokume-metal/mokume/issues/1102) がそこで見過ごされた)。
    ///
    /// 区画の在処と起こした道具の名乗りを受けるのは同じ理由で、既定は本番の場所と本番の
    /// 環境である (`WorkDirectory.resolve(environment:)` などと同じ、既定引数で口を開ける形)。
    ///
    /// **ウィンドウを持つ道具に起こされ、区画も在るときだけ、標準入力の管を読み始める**
    /// ([ADR-0032] 決定 4)。ウィンドウの経路と書き出す経路は管に触らない — 区画が在っても、閉じた
    /// 標準入力を「道具が去った」と読まず (#2025)、端末に `O_NONBLOCK` を残さない (#2024)。
    ///
    /// **共有面を用意できずにウィンドウへ倒れた回も、管は読む。** 管を引いたのは見張りで、見張りが
    /// 去ったことに気付く口はこの管しか無い ([#1427](https://github.com/mokume-metal/mokume/issues/1427))。
    /// 出口が倒れたことと、起こした者が誰かは別の話である。
    ///
    /// **活動の方針 (`setActivationPolicy`) はここに置かない。** 呼んだプロセス全体に
    /// 効くので、検査から呼べる場所に混ぜると検査の走るプロセスの方針まで動く。
    ///
    /// - Parameter owner: 起こした道具の名乗り。**無ければ区画が在っても自分のウィンドウを開き、
    ///   そのことを 1 度名乗る** (#2026)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    func resolveOutlet(
        at directory: URL = WorkDirectory.facet(StartupReads.viewport.key),
        owner: String? = SharedFrameSurface.launchOwner
    ) {
        // **書き出す経路は区画より先に決まっている。** 見張りが畳めずに残した区画が在っても
        // 共有面へは差し出さない — その経路の出口は撮る係だけである
        guard case .pendingWindow = outlet else { return }
        if let notice = SharedFrameSurface.strayFacetNotice(at: directory, owner: owner) {
            announce(notice)
        }
        guard SharedFrameSurface.isEnabled(at: directory, owner: owner) else { return }
        runtime.relayToolInput(from: StandardInputEvents(descriptor: toolInput))
        guard let shared = attachSharedSurface(at: directory, owner: owner) else {
            // **倒れたことを道具へ知らせる** (#2350)。道具は目録を置いた子がウィンドウを乗り換えた合図で
            // 前の世代を畳むので、目録を置かない子では前の世代が残る
            SharedFrameSurface.declareFallback(at: directory)
            return
        }
        outlet = .shared(shared)
        // **名乗るのは道具** ([ADR-0049] 決定 2)。子は「断っていない」と作品名・題を面に載せ、道具がそれを見て名乗る
        // **断った作品は載せない** (#3921)。道具は載っていない世代では名乗らず、名乗っていれば下ろす
        shared.frameShare =
            sharesFrames ? FrameShare(sketch: FrameAnnouncement.ownSketchName, title: title) : nil
        // **全画面の頼みは、目録に載せて道具へ渡した** (#2188)。作品のウィンドウは道具が持つので
        // ([ADR-0032] 決定 1)、こちらからは全画面にできない。道具が頼みを受けて、宣言した
        // ディスプレイで全画面にする。**道具が頼みを読んだかは、こちらからは分からない** —
        // 読まない古い道具ならウィンドウのままなので、そのときの手当てまで 1 行で言う。描く大きさは
        // ディスプレイから決めてあるので、手で全画面にすれば合う
        if let display = runtime.fullScreenDisplay {
            announce(
                "The sketch asks for full screen on display \(display.number) (\(display.name)), "
                    + "and \(owner ?? "the tool") puts the window it holds there — if the window "
                    + "stays a window, the tool is older than the mokume this sketch depends on: "
                    + "update them together, or put that window into full screen by hand")
        }
    }

    /// 道具のウィンドウが拾った出来事が来る管。**本番は標準入力** — 見張りが子の標準入力に引く
    /// (`WatchSession`)。**検査から差し替える**: 既定のまま共有面の経路を通すと、検査を
    /// 走らせている端末の標準入力に `O_NONBLOCK` が立つ。
    var toolInput: Int32 = FileHandle.standardInput.fileDescriptor

    /// 人へ 1 行伝える口。**検査から差し替える** (言ったかどうかを数えるため)。
    var announce: @MainActor (String) -> Void = { Diagnostics.warn($0) }

    /// 自分のウィンドウを開いたときに名乗る口 ([ADR-0049] 決定 2・[#3919])。引数は一覧に見せる名前 (題)。
    ///
    /// **名乗るのは自分のウィンドウを持つ実行だけ** — 直に走らせる・`run`・束ねた `.app`・見張りの子が自分の
    /// ウィンドウへ倒れた回。共有面へ差し出す子は道具が代わりに名乗り、書き出しと埋め込みは名乗らない。
    /// **検査から差し替える** (名乗ったかを数えるため)。
    ///
    /// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
    /// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
    var listFrames: @MainActor (String) -> FrameAnnouncement? = { title in
        FrameAnnouncement.announce(
            sketch: FrameAnnouncement.ownSketchName, identity: FrameAnnouncement.ownIdentity,
            title: title)
    }

    /// 名乗っている項目。自分のウィンドウを開くまでと、名乗れなかった実行では `nil`。
    private(set) var frameAnnouncement: FrameAnnouncement?

    /// メニューバーの名乗りへ渡している相手 (``SketchRuntime/presenceReceivers``)。**検査から読む。**
    var presenceReceivers: [String] { runtime.presenceReceivers }

    /// 受け手の頼みを main queue で受けるか。**検査は `false` にして**、送り手の ``FrameSender/drain()`` を直に呼ぶ。
    var listensForReceivers = true

    /// 自分のウィンドウの経路で、繋いできた受け手の面へ今のフレームを書く ([#3920])。
    ///
    /// **ウィンドウの見え方に縛られない** — 画面への差し出しはウィンドウが見えない間 (最小化・被覆・別の Space) は
    /// 休むが (``FramePresenter/shouldPresent(windowIsVisible:hasPresented:)``)、受け手へは書く。マッパーの裏に作品の
    /// ウィンドウを隠すのは普通の使い方である (ADR-0049 決定 4)。受け手が居なければ何もしない。
    ///
    /// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
    private func deliverToReceivers() throws(RenderFailure) {
        guard let sender = frameAnnouncement?.sender, sender.receiverCount > 0 else { return }
        try sender.deliver(
            width: runtime.target.width, height: runtime.target.height,
            frameCount: Int64(runtime.frameNumbers.frameCount), hostTime: mach_absolute_time()
        ) { [presenter, runtime] texture throws(RenderFailure) in
            try presenter.draw(runtime.target, into: texture)
        }
    }

    /// 全画面で出すディスプレイの画面を引く口 (#2020)。外れていれば `nil`。
    ///
    /// **検査から差し替える** — 検査が注入した一覧のディスプレイは、この機械の画面に無い。
    var screenForDisplay: @MainActor (Display) -> NSScreen? = { Display.screen(for: $0) }

    /// ウィンドウを全画面にする口 (#2020)。
    ///
    /// **検査から差し替える** — 既定のままでは、検査を走らせた機械の画面が全画面の操作
    /// スペースへ切り替わる。
    var enterFullScreen: @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) }

    /// 画面の出口が外のプロセスに在れば、そこへ差し出す用意をする。
    ///
    /// **区画が在るのに用意できなかったときは、ウィンドウを開く側へ倒す** — 面もウィンドウも無い実行は、
    /// 外から見て「動いていない」としか見えない。倒したことは黙らずに言う。
    private func attachSharedSurface(at directory: URL, owner: String?) -> SharedFrameSurface? {
        guard
            let shared = SharedFrameSurface.makeIfEnabled(
                gpu: gpu, width: runtime.target.width, height: runtime.target.height,
                windowScale: runtime.windowScale,
                fullScreenDisplay: runtime.fullScreenDisplay.map(SharedFrameSurface.FullScreenDisplay.init),
                at: directory, owner: owner, warn: { announce($0) })
        else { return nil }
        do {
            try shared.publishManifest()
        } catch {
            // **どのファイルかを添える** (#2839)。理由は POSIX の事情を優先して外側の説明
            // (ファイル名入り) を捨てるので、場所は自分で名乗る
            announce(
                "Could not place the identifiers of the surfaces frames go to "
                    + "(\(directory.appendingPathComponent(SharedFrameSurface.manifestName).path)): "
                    + "\(Diagnostics.reason(error)) — opening a window and carrying on")
            return nil
        }
        return shared
    }

    /// ウィンドウを開き、フレームの駆動源を繋ぐ。``SketchApplicationDelegate`` から呼ばれる。
    ///
    /// **画面の出口が外のプロセスに在れば、ウィンドウは作らない** ([ADR-0032] 決定 1)。駆動源は
    /// ウィンドウではなく画面に紐づくので (下記)、ウィンドウが無くてもそのまま繋がる。
    func didFinishLaunching() {
        switch outlet {
        case .shared:
            screenLink.attach(to: NSScreen.main)
            return
        case .render(let request):
            // **最初のフレームより前に撮り始める。** 撮る係は頼まれたフレームの絵から録るので
            // (#1456)、ここで頼めば 1 枚目から入る。作品が `beginRecord` を呼ぶ必要は無い
            runtime.beginRecord(request.destination, rendering: request.frameCount)
            // **画面には繋がない** (#3474)。画面の刻みを待つと、作品が宣言した `frameRate` と画面のリフレッシュが
            // 書き出しの速さの上限になる。全速の駆動は run loop の 1 回ごとに 1 枚だけ進めて戻るので、終わりの
            // 合図も AppKit の終わりの経路も回る
            fullSpeedDriver.start()
            return
        // AppKit は 1 度しか呼ばないので来ないが、網羅のために名乗る。埋め込んだ経路は
        // ここを通らず、ホストのウィンドウに載ったとき ``attachEmbeddedDriver()`` が繋ぐ
        case .window, .embedded: return
        case .pendingWindow: break
        }
        // **全画面なら、選んだディスプレイの画面に立てる** (#2020)。位置も開く大きさの指定も
        // 覚えない — 置き場所は番号が決める (`WindowPlacement.makeFullScreenWindow`)
        let fullScreenScreen = runtime.fullScreenDisplay.flatMap(screenForFullScreen(_:))
        let window: NSWindow
        if let fullScreenScreen {
            window = WindowPlacement.makeFullScreenWindow(
                title: title, on: fullScreenScreen,
                canvas: NSSize(width: runtime.target.width, height: runtime.target.height))
        } else {
            // ウィンドウは描く解像度 × 倍率で開く (既定 0.5)。描く解像度とウィンドウの大きさは独立なので、
            // どちらに合わせてもよい — 既定は大きな絵が画面からはみ出さない側にしてある
            let requested = WindowPlacement.requestedSize(
                width: runtime.target.width, height: runtime.target.height,
                scale: runtime.windowScale)
            window = WindowPlacement.makeWindow(
                title: title, autosaveName: WindowPlacement.autosaveName,
                defaultSize: requested)
            // **覚えた大きさより、変わった指定を取る** (#1624)。変わっていなければ何もしない
            WindowPlacement.honour(
                requested, in: window, autosaveName: WindowPlacement.autosaveName)
        }

        // 見張りが起こした入れ替えでは、ウィンドウを出しはするが前面は取らない (#679)
        let takesFocus = WindowPlacement.takesFocus(
            isRelaunch: WindowPlacement.isRelaunch(stamp: SourceStamp.current))

        let surface = SketchSurface(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size), device: gpu.device,
            input: runtime.input,
            canvasSize: (runtime.target.width, runtime.target.height))
        surface.wantsLayer = true
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        // **つまみは絵の外に立つ** (ADR-0030 決定 1)。同じウィンドウへ重ねるだけで、描画の
        // 成果物には 1 画素も触らない。宣言が 1 つも無ければ何も足さない
        // 数字は**読む口を渡すだけ**。ウィンドウが自分で数えると源が 2 つに割れる
        // (ADR-0030 決定 7)
        KnobOverlay.makeIfNeeded(for: runtime.paramRegistry) { [runtime] in runtime.frameNumbers }?
            .attach(to: surface)
        // **確かめるのは、道具が起こしたときだけ** ([ADR-0032] 決定 1)。合図が無ければ
        // delegate を据えないので、直に走らせたスケッチと束ねた `.app` の × は、いままで
        // どおり押した瞬間に作品を終わらせる
        if closeQuestion != nil { window.delegate = windowRelay }

        // **前面を取らないときも、ウィンドウは出す。** 出さなければ、作り直すたびに絵が消える
        if takesFocus { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        // **面を第一応答者に据える。** 据わっていないウィンドウにはキーが 1 件も来ない —
        // 理由と、AppKit の自動選択に頼らない訳は `SketchSurface.acceptsFirstResponder`
        // が持つ
        window.makeFirstResponder(surface)
        surface.synchronizeDrawableSize()

        outlet = .window(window, surface, hasPresented: false)
        // **ウィンドウを持ったので名乗る** ([ADR-0049] 決定 2)。名乗れなくても走り続ける。名乗れたら受け手の頼みを
        // 受け始める (繋がっていない間はフレームの仕事は増えない・#3920)
        // **断った作品は名乗らない** (``SketchSettings/sharesFrames``・#3921)
        if sharesFrames { frameAnnouncement = listFrames(title) }
        if let sender = frameAnnouncement?.startSending(
            gpu: gpu, width: runtime.target.width, height: runtime.target.height,
            startsListening: listensForReceivers)
        {
            // **繋がった相手をメニューバーの名乗りに出す** (ADR-0049 決定 6)。繋がれば猶予を待たずに名乗る
            sender.onReceiversChanged = { [runtime] names in runtime.presenceReceivers = names }
        }

        if takesFocus { NSApp.activate() }

        screenLink.attach(to: window.screen ?? NSScreen.main, following: window)
        // ウィンドウを開く時刻は起点にしない。速さを数え始めるのは最初のフレームが
        // 来たときである ([FrameTempo]) — 進み始める前に測ったことにすると、
        // 1 枚目で「1 枚 ÷ 待っていた時間」が出て 0.0 という嘘の数字になる

        // **全画面はウィンドウを前へ出した後に頼む** — 画面に出ていないウィンドウには効かない。駆動源はウィンドウの
        // 居る画面を追うので、全画面の操作スペースへ移っても張り替えは要らない
        if fullScreenScreen != nil { goFullScreen(window) }
    }

    /// 全画面で出す画面を引く (#2020)。
    ///
    /// **組み立ての後にディスプレイが外れていたら、ウィンドウで開くことを 1 行言って `nil` を返す。**
    /// 組み立てが描く大きさを決めてからウィンドウを出すまでの間にも、抜かれうる。そこから組み立てを
    /// やり直す道は無く、黙って別の画面を全画面で塞ぐよりは、言ったうえでウィンドウを出す。
    private func screenForFullScreen(_ display: Display) -> NSScreen? {
        if let screen = screenForDisplay(display) { return screen }
        announce(
            "Display \(display.number) (\(display.name)) went away before the window opened — "
                + "opening a window instead of going full screen")
        return nil
    }

    /// ウィンドウを全画面にし、入ったら中身の大きさを描く大きさと突き合わせる (#2020)。
    private func goFullScreen(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification, object: window)
        enterFullScreen(window)
    }

    /// 全画面に入った。**描く大きさと中身が食い違えば 1 行言う** (`WindowPlacement.fullScreenMismatch`)。
    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let mismatch = WindowPlacement.fullScreenMismatch(
            content: window.contentLayoutRect.size, scale: window.backingScaleFactor,
            canvasWidth: runtime.target.width, canvasHeight: runtime.target.height)
        {
            announce(mismatch)
        }
    }

    /// × を押された。**確かめている間は閉じない。**
    ///
    /// 閉じてしまうと絵の出口が消え、開き直す経路が無い。ウィンドウは作品の唯一の出口なので
    /// (メニューを組み立てないこの経路には `⌘Q` も `⌘W` も無い)、押し間違いで消えるのは
    /// 制作中の作品そのものである ([#1120](https://github.com/mokume-metal/mokume/issues/1120))。
    ///
    /// **問いを持たないウィンドウは、そのまま閉じる。** 道具が起こしたのでなければ、AppKit の既定を
    /// 変える理由が無い (`SharedFrameStage.shouldClose(_:)` と同じ規律)。
    ///
    /// **終わりに向かっている間は問わずに閉じる** ([#978])。問いの先は `terminate(_:)` で、
    /// 後始末を待っている間にそれを重ねると、AppKit は問い直さずに**待ちを飛ばして**終わる
    /// (実測)。ウィンドウを閉じるだけなら終わりは重ならない — 最後のウィンドウが閉じても、返事を待っている
    /// 間の AppKit は `applicationShouldTerminateAfterLastWindowClosed(_:)` を問わない (実測)。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    fileprivate func shouldClose(_ sender: NSWindow) -> Bool {
        guard let closeQuestion, !isTerminating else { return true }
        // **問いを二重に出さない。** 下りている間 AppKit は親ウィンドウの操作を吸うが、閉じるよう
        // 頼む経路は残る (`performClose(_:)` など)
        //
        // **ただし付いているのがファイルを選ばせるシートなら、それを取り消して問いへ進む** — 黙って × が効かない
        // ウィンドウにしない (#3062)。問いのシートが付いている間は、今までどおり受け流す
        if sender.attachedSheet != nil {
            guard !isAskingToClose, cancelOpenSelectionDialog() else { return false }
        }
        isAskingToClose = true
        presentQuestion(closeQuestion, sender) { [weak self] confirmed in
            self?.isAskingToClose = false
            // **問いが出ている間に終わりが始まっていたら、答えで終わりを重ねない** —
            // シートはウィンドウにだけ掛かるので、出ている間も Dock からの終了は届く
            guard confirmed, let self, !self.isTerminating else { return }
            self.onCloseConfirmed()
        }
        return false
    }

    /// 終わってよいかを問われた。**後始末が済むまで、main を塞がずに待たせる** ([#978])。
    ///
    /// これまでは ``willTerminate()`` の中で塞いで待っていた。そこで待つのは動画を閉じる
    /// `AVAssetWriter.finishWriting` で、Apple は main を塞いだまま走らせると失敗しうると
    /// 書いている。AppKit の正規の口は「後で返す」(`.terminateLater`) で、済んだら
    /// ``replyToTermination`` で返す。
    ///
    /// ## 待ちは run loop から見に来る
    ///
    /// **main actor の仕事 (`Task`) では待たない。** `terminate(_:)` が main actor の仕事の中
    /// から呼ばれると、返事を待っている間 AppKit は run loop を回すが、main キューは入れ子
    /// では捌かれないので、**`await` の続きが永久に来ず、終わりが保留されたまま固まる**
    /// (実測)。`.common` の Timer はどの呼ばれ方でも回ったので、そこから見に来る。
    ///
    /// ## 待つ長さ
    ///
    /// 別の期限は持たない。見に来る先 (``SketchRuntime/closePlugins(_:)``) は塞いで待つ
    /// ときと同じ期限のコードを通るので、書き出しが止まっていても #958 の期限で諦めて
    /// 返事に至る。
    ///
    /// ## 待っている間
    ///
    /// 駆動源 (画面のリフレッシュと予備) は止まらずに呼んでくるが、フレームはランタイムの側で進めない。
    /// 書き出しの全速の駆動は、描き終えた後の最初の回で畳む (``displayLinkFired(at:)``)。ウィンドウの × と
    /// 問いへの答えは、終わりを重ねないよう ``shouldClose(_:)`` が受け流す。
    ///
    /// **何も書き出していなければ、その場で終わる** (`.terminateNow`) — いつもの終わり方は
    /// 変わらない。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    func shouldTerminate() -> NSApplication.TerminateReply {
        isTerminating = true
        // **返事は 1 回だけ。** 既に待たせているなら、見に来る仕掛けがそのまま返す
        guard terminationPoll == nil else { return .terminateLater }
        if runtime.closePlugins(.peek) { return .terminateNow }
        let timer = Timer(timeInterval: Self.terminationPollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.pollTermination() }
        }
        RunLoop.main.add(timer, forMode: .common)
        terminationPoll = timer
        return .terminateLater
    }

    /// 後始末を 1 回だけ見に来る。**塞がない。** 済んでいたら「終わってよい」と返す。
    ///
    /// 返事を待たせていなければ何もしない。検査は run loop を回さないので、Timer に
    /// 代わってここを直に呼ぶ。
    func pollTermination() {
        guard let timer = terminationPoll, runtime.closePlugins(.peek) else { return }
        timer.invalidate()
        terminationPoll = nil
        replyToTermination()
    }

    /// 駆動源を畳む。``SketchApplicationDelegate`` から呼ばれる。
    func willTerminate() {
        terminationPoll?.invalidate()
        terminationPoll = nil
        // **差込口を先に閉じる。** 送り先のアプリや機材から見ると、こちらが消えるより
        // 先に「終わる」と言われるほうが行儀がよい
        //
        // ふつうは ``shouldTerminate()`` が済ませているので何もしない。塞いで待つことに
        // なるのは、AppKit が返事を待たずに終わらせたとき (返事を待っている間に
        // `terminate(_:)` が重なったとき) だけで、ここが最後の砦である
        runtime.closePlugins()
        // **目録から下ろす** ([ADR-0049] 決定 3)。信号で落ちた実行の項目は、次に名乗る送り手が掃除する
        frameAnnouncement?.withdraw()
        screenLink.invalidate()
        fullSpeedDriver.invalidate()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didEnterFullScreenNotification, object: nil)
        // **返し忘れると、プロセスが終わるまで画面が消えなくなる**
        displaySleepBlock?.release()
        displaySleepBlock = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        // **書けたかは最後に言う** — 撮る係の答えは閉じ終えてはじめて揃う
        concludeRender()
    }

    /// 書き出しを締めくくる。**書き出す経路でなければ何もしない。**
    ///
    /// 揃わなかったら理由を名乗り、0 以外で終わる — 道具 (`mokume render`) は終了コードで
    /// 「書けたか」を読む。揃ったとは、決めた枚数を全部描き、**GPU がどの枚の仕事も打ち切らず**、
    /// 撮る係が 1 度も書き損じなかったことである。書き損じの中身は撮る係が既に名乗っているので、
    /// ここでは繰り返さない。
    ///
    /// **GPU が打ち切った枚は、描けなかった枚と同じく穴に数える** ([#2743])。打ち切った枚は出口へ
    /// 配らないので書き出しに入らない (`SketchRuntime` の `outletFramesDropped`)。1 枚だけ描いて書き出す
    /// 入口 (`renderFrame(to:)`) が打ち切りで投げるのとも揃う。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private func concludeRender() {
        guard case .render(let request) = outlet else { return }
        var complete = true
        if runtime.frameCount < request.frameCount {
            complete = false
            Diagnostics.warn(
                "Rendering stopped after \(runtime.frameCount) of \(request.frameCount) frames"
                    + " — \(request.destination) holds only those")
        }
        if framesFailedToDraw > 0 {
            complete = false
            Diagnostics.warn(
                "\(request.destination) is missing \(framesFailedToDraw) of \(request.frameCount)"
                    + " frames (they could not be drawn)")
        }
        if runtime.outletFramesDropped > 0 {
            complete = false
            Diagnostics.warn(
                "\(request.destination) is missing \(runtime.outletFramesDropped) of \(request.frameCount)"
                    + " frames (the GPU dropped the work behind them)")
        }
        if runtime.recordingFailed {
            complete = false
            Diagnostics.warn(
                "\(request.destination) could not be written in full (the reason is above)")
        }
        if !complete { exitProcess(1) }
    }

    /// 表示のリフレッシュごとに 1 フレーム進めて差し出す。書き出す経路では、画面を持たない全速の駆動
    /// (``fullSpeedDriver``) が run loop の 1 回ごとに叩く。
    ///
    /// **止めるのは「出す」ほうだけ。** ウィンドウが見えていなくてもフレームは進める — 観測が
    /// 返すのは「最後に描いた絵」ではなく「いま描いた絵」で (ADR-0018)、進めるのを
    /// やめるとその約束がウィンドウの状態で緩む。加えて、見えていない面へ差し出そうとすると
    /// `nextDrawable()` が返らずに待つので、飛ばすほうが速い。
    ///
    /// - Parameter displayTime: この枚が表示される予定の時刻 (``ScreenDisplayLinkOwner/displayLinkFired(at:)``)。
    ///   実時間の時計の時刻になる。`nil` なら現在時刻。
    func displayLinkFired(at displayTime: Double?) {
        pollStopSignal()
        // **書き出す経路では、決めた枚数より先を描かない。** 終わりを頼んだ後も駆動源は
        // 呼んでくるので、描けば枚数 + 1 枚目が撮る係へ届く。
        //
        // **全速の駆動はここで畳む** (#3474)。効くのは、終わりが駆動の外から頼まれたとき (メニューの
        // 「終了」など) である。そのとき後始末を待つ間 (`.terminateLater`) も全速の駆動は回り続けるので、
        // 畳まないと書き切りを待つ間ずっと空回りする。駆動の中から頼んだ回 (``onRenderFinished``・
        // ``onStopSignal`` は全速の駆動のタイマーの中から同期で `terminate(_:)` を呼ぶ) は、待ちが入れ子の
        // run loop で回っても発火中のタイマーは入れ子では再発火しないので (CFRunLoop の振る舞いによる)、
        // ここへは来ない
        guard !rendersNoMore else { return fullSpeedDriver.invalidate() }
        advanceAndPresent(displayTime: displayTime)
        followPointerLockRequest()
        finishRenderIfDone()
    }

    /// スケッチの捕まえの要求を、自分のウィンドウの面へ渡す ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    ///
    /// **自分のウィンドウを持つ経路だけ。** 共有面の経路は要求を面の属性に載せて道具のウィンドウへ渡し
    /// (``presentFrame()``)、書き出す経路にはウィンドウが無いので、要求は誰にも読まれない。
    /// 毎リフレッシュ渡すのは、ウィンドウが前に出たか・ポインタが面の上かが、要求と関係なく変わるため
    /// である。
    private func followPointerLockRequest() {
        if case .embedded(let surface, _) = outlet {
            // **止めた後は面に触れない。** `setup()` が投げた回は、`advanceAndPresent` の中で止めた (``stopEmbedded()``) 後も
            // 同じフレームの続きがここへ来る — 戻した矢印を隠し直し、ポインタを捕まえ直し、シートを出し直すと、
            // 駆動源は畳まれていて誰も戻さない
            guard !isTerminating else { return }
            surface.followPointerLock(requested: runtime.pointerLockRequested)
            surface.followCursorHiding(requested: runtime.cursorHidingRequested)
            if let window = surface.window {
                // **ホストのウィンドウがシートを受けられるときだけ出す** — 見えていないウィンドウへは、独立したパネルになり、
                // ホストのアプリを前面へ出す (決定: ホストのウィンドウのシートで出す)。見えるまで頼みは残り、見えたリフレッシュで出す
                followSelectionRequest(
                    window: window, surface: surface,
                    canPresent: window.isVisible && !window.isMiniaturized)
            }
            return
        }
        guard case .window(let window, let surface, _) = outlet else { return }
        surface.followPointerLock(requested: runtime.pointerLockRequested)
        // 矢印を隠す要求も同じ経路で渡す ([#2439](https://github.com/mokume-metal/mokume/issues/2439))
        surface.followCursorHiding(requested: runtime.cursorHidingRequested)
        followSelectionRequest(window: window, surface: surface)
        // 題名を変える頼みも同じ経路で当てる ([#3709](https://github.com/mokume-metal/mokume/issues/3709))。
        // 頼んでいなければ起動のときの題名のまま触らない。同じ題名は当て直さない (毎リフレッシュ通る)
        if let title = runtime.windowTitleRequest, window.title != title { window.title = title }
    }

    /// スケッチのファイルを選ばせる頼み (``SketchPart/selectInput(_:)``) を、自分のウィンドウで出す
    /// ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    ///
    /// **頼みの番号が変わったら出す。** 同じ番号の間は出し直さない (結果の出来事が合流点に当たるまで、頼みは残る)。
    /// 頼みが無くなった・別の番号になったら、出しているダイアログは結果ごと捨てて閉じる。結果は**同じ形の
    /// 出来事**にして自分の合流点へ積む — 外から送られた結果と同じ道を通る。共有面の経路は頼みを面の属性に
    /// 載せて道具のウィンドウへ渡す (``presentFrame()``)。
    private func followSelectionRequest(
        window: NSWindow, surface: SketchSurface, canPresent: Bool = true
    ) {
        let pending = runtime.input.selection.pending
        if let shown = shownSelection, shown.serial != pending?.serial {
            shown.dismiss()
            shownSelection = nil
        }
        guard let pending, shownSelection == nil, canPresent else { return }
        let serial = pending.serial
        // `pick` が同じ呼び出しのうちに結果を返した検査の口のために、先に控えてから出す
        shownSelection = (serial, {}, false)
        let dismiss = filePicker.pick(prompt: pending.prompt, over: window) {
            [weak self, weak surface] path in
            // 番号を載せる — 頼み直しの後に、前の頼みへの答えが溜まりに残っても、新しい待ちを終えない
            self?.markSelectionAnswered(serial: serial)
            surface?.deliver(.fileSelected(path: path, serial: serial))
        }
        shownSelection?.dismiss = dismiss
    }

    private func markSelectionAnswered(serial: Int) {
        if shownSelection?.serial == serial { shownSelection?.answered = true }
    }

    /// ウィンドウの × が押されたとき、**ファイルを選ばせるシートが付いているなら、それを取り消す** (取り消しは
    /// 利用者がダイアログを取り消したのと同じ結果として渡す)。
    ///
    /// シートが付いている間 ``shouldClose(_:)`` は閉じる問いを出さないので、黙って × が効かなくなる
    /// ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    ///
    /// - Returns: 取り消したか。答え済みの (もう閉じている) ダイアログ・出していないときは `false`。
    private func cancelOpenSelectionDialog() -> Bool {
        guard let shown = shownSelection, !shown.answered else { return false }
        let surface: SketchSurface
        switch outlet {
        case .window(_, let windowSurface, _): surface = windowSurface
        case .embedded(let embeddedSurface, _): surface = embeddedSurface
        default: return false
        }
        shown.dismiss()
        markSelectionAnswered(serial: shown.serial)
        surface.deliver(.fileSelected(path: nil, serial: shown.serial))
        return true
    }

    /// 書き出す経路で、もう描かないか。**決めた枚数を描いた後と、終わりに向かっている間。**
    /// 書き出す経路でなければ常に `false`。
    private var rendersNoMore: Bool {
        guard case .render(let request) = outlet else { return false }
        return isTerminating || runtime.frameCount >= request.frameCount
    }

    /// 書き出す経路で、描き終えたら終わりを頼む。
    ///
    /// **作者が止めたスケッチ (`noLoop()`) は、そこで終える。** 止まったスケッチは入力が
    /// 来なければ動き直さず、書き出す経路にはウィンドウも入力も無い — 待てば永久に決めた枚数に
    /// 届かない。揃わなかったことは ``concludeRender()`` が終了コードで言う。
    private func finishRenderIfDone() {
        guard case .render(let request) = outlet, !isTerminating else { return }
        if runtime.frameCount >= request.frameCount {
            onRenderFinished()
        } else if !runtime.isLooping {
            Diagnostics.warn(
                "The sketch stopped its loop (noLoop()) at frame \(runtime.frameCount) of"
                    + " \(request.frameCount), so the rest cannot be drawn — ending here")
            onRenderFinished()
        }
    }

    /// 終わりの合図 (``StopSignals``) を 1 回だけ見に来る。受けていたら終わりを頼む ([#1219])。
    ///
    /// **見に来るのは駆動源が叩く回である** (``displayLinkFired()``)。表示のリフレッシュが
    /// 止まっている間は予備が叩くので (``ScreenDisplayLink``)、画面が眠っていても、
    /// `noLoop()` で止めていても、後始末を待たせている間も来る (畳むのは ``willTerminate()``)。
    /// 書き出す経路で叩くのは画面を持たない全速の駆動 (``fullSpeedDriver``) で、描き終えた後と終わりに
    /// 向かってからは畳む — その後の合図は下のとおり受け流すので、見に来なくても変わらない。
    ///
    /// **終わりに向かっている間の合図は受け流す。** 返事を待たせている間に `terminate(_:)` を
    /// 重ねると、AppKit は返事を待たずに終わらせる (``willTerminate()`` の「最後の砦」)。
    /// 2 度目の合図で急がせる経路は作らない — 待てない側には `SIGKILL` がある。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    ///
    /// **起こした道具が居なくなったことも、同じ 1 本へ入れる** ([#1427])。ウィンドウを持たない子に
    /// とって、ウィンドウの持ち主が消えたことは終われと言われたのと同じである。両方を先に読むのは、
    /// 短絡で片方の印を読み残さないためである。
    ///
    /// [#1427]: https://github.com/mokume-metal/mokume/issues/1427
    func pollStopSignal() {
        let signalled = StopSignals.takeRequest()
        let departed = driverDeparted()
        guard signalled || departed, !isTerminating else { return }
        // **道具が居なくなって終わることは名乗る。** 黙って消えると、道具が後始末を通らずに
        // 消えた回 (捕まえない合図・`SIGKILL`) などで、なぜ終わったのかが読めない
        if departed, !signalled {
            Diagnostics.warn(
                "The tool that started this sketch is gone (its input pipe closed) — ending,"
                    + " since the window it owned went with it")
        }
        onStopSignal()
    }

    /// 1 フレーム進めて差し出す。
    ///
    /// **予備の駆動源から来た回もここを通る。** 表示のリフレッシュが止まっている間
    /// (画面が眠っている間) に叩くのは駆動源の側の仕事で、通る道は同じである (``ScreenDisplayLink``)。
    /// 違うのは `displayTime` が `nil` (予定の時刻が無い) なことだけで、時刻は現在時刻で代わる。
    private func advanceAndPresent(displayTime: Double?) {
        do {
            try runtime.advance(displayTime: displayTime)
            // 差し出しの区間 (Instruments・#2378)。ウィンドウと共有面の両方がここを通る
            let presentInterval = FrameSignposts.beginPresent()
            defer { FrameSignposts.endPresent(presentInterval) }
            try presentFrame()
        } catch {
            // **`setup()` が投げたなら、直らないので続けない** (#2401)。起動の失敗として全文を言って終わる
            if case .setupFailed = error { return stopForSetupFailure(error) }
            // 1 フレーム描けなかったことでアプリケーションごと落とさない。
            // 次のリフレッシュでもう一度試す — ただし**黙って捨てない**
            noteFrameFailure(error)
            return
        }
        noteFrameRecovery()
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
            markFirstFrame()
        }
    }

    /// ``Sketch/setup()`` が投げたので、起動できなかったことを言って 0 以外で終わる ([#2401])。
    ///
    /// 文面は組み立てが投げたとき (``Sketch/main()``) と同じ ``startupFailureText(_:)`` で、ウィンドウの経路も
    /// 書き出し (`mokume render`) も同じになる。1 フレームも描いていないので、後始末する書き出しは無い。
    /// 道具は終了コードで「書けたか」を読むので、0 以外で終わる (``exitProcess``)。
    ///
    /// **終わる前に差込口を閉じる** — `setup()` が投げる前に開いたカメラ・音・シリアル・ソケットを、通常の終わり
    /// (``willTerminate()``) と同じに閉じる (ADR-0024 決定 7)。`exit` は後始末を通らないので、ここで済ませる。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    private func stopForSetupFailure(_ failure: RenderFailure) {
        guard !isTerminating else { return }
        // **ホストのアプリの中 (``SketchView``) では、プロセスを終わらせない** — アプリはホストのもので、組み立ての
        // 失敗 (``SketchView`` が警告に留める) と同じに、理由を警告して、このビューだけを止める
        if case .embedded = outlet {
            Diagnostics.warn("SketchView could not start the sketch: \(failure.headline)")
            stopEmbedded()
            return
        }
        isTerminating = true
        reportStartFailure(failure, note: noteStartFailure)
        runtime.closePlugins()
        // **目録から下ろす** ([ADR-0049] 決定 3)。信号で落ちた実行の項目は、次に名乗る送り手が掃除する
        frameAnnouncement?.withdraw()
        screenLink.invalidate()
        fullSpeedDriver.invalidate()
        exitProcess(1)
    }

    /// 進めた 1 フレームを、与えられた出口へ差し出す。
    ///
    /// **出口は 1 つに決まっている** — ウィンドウを持つか、外の面へ差し出すかで、両方はしない
    /// ([ADR-0032] 決定 1)。面へ差し出す側で見えているかを見ないのは、**誰が見ているかを
    /// 知っているのが読む側 (道具) だから**である。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private func presentFrame() throws(RenderFailure) {
        switch outlet {
        case .shared(let shared):
            // **速さも一緒に渡す。** 数えているのはこちらで、読むのは道具である
            // ([ADR-0030] 決定 7) — 面に載せれば通信路は 1 本も増えない。**名乗るのは
            // 前に焼いた 1 枚**で、いま焼く絵は次のリフレッシュで出る (#748)。走っている間は毎リフレッシュ
            // ここを通るので、控えが出ないまま残ることはない。捕まえの要求も
            // 同じ面に載せて渡す — 捕まえるのは道具のウィンドウである (#1144)。矢印を隠す要求も同じ (#2439)
            //
            // **止まっている間は、絵が変わらなければ焼かない** (#2367)。最後に変わった後の 1 回を焼いたら、
            // 以後は控えを名乗らせるだけにする (走っていないので次の書き込みは来ない)。変わる理由には、
            // 捕まえ・矢印の要求も入る — 飛ばすと、止めたスケッチがカーソルを捕まえる・放すのが道具に届かない
            let shown = shownFrame(
                drawable: nil, pointerLock: runtime.pointerLockRequested,
                cursorHidden: runtime.cursorHidingRequested,
                selection: runtime.input.selection.pending,
                windowTitle: runtime.windowTitleRequest)
            if runtime.isHeldStill, shown == lastShown {
                let droppedBefore = shared.droppedBurns
                try shared.publishPending()
                // 打ち切られた焼きは名乗らずに捨てる。次の書き込みが来ない間は、焼き直さないと
                // 道具は前の絵を出し続ける (走っている間は次の書き込みが自然に直す・#2735)
                if shared.droppedBurns != droppedBefore { lastShown = nil }
                return
            }
            lastShown = nil
            if try shared.write(
                runtime.target, using: presenter, numbers: runtime.frameNumbers,
                pointerLock: shown.pointerLock, cursorHidden: shown.cursorHidden,
                selection: shown.selection, windowTitle: shown.windowTitle)
            {
                lastShown = shown
            }
        case .window(let window, let surface, let hasPresented):
            // 受け手へは、見え方の判定 (``presentToSurface(_:hasPresented:)``) より前に書く
            try deliverToReceivers()
            if try presentToSurface(surface, hasPresented: hasPresented), !hasPresented {
                outlet = .window(window, surface, hasPresented: true)
            }
        case .embedded(let surface, let hasPresented):
            if try presentToSurface(surface, hasPresented: hasPresented), !hasPresented {
                outlet = .embedded(surface, hasPresented: true)
            }
        // 書き出す経路の出口は撮る係だけで、絵はランタイムが配っている
        case .pendingWindow, .render:
            return
        }
    }

    /// 自分で持つ面 (ウィンドウの中の面・ホストの中の面) へ絵を出す。**出したら `true`** (最初の 1 枚の印を
    /// 立てるのは呼び出し元)。
    private func presentToSurface(_ surface: SketchSurface, hasPresented: Bool) throws(RenderFailure) -> Bool {
        guard let layer = surface.metalLayer,
            FramePresenter.shouldPresent(
                windowIsVisible: isWindowVisible, hasPresented: hasPresented)
        else {
            // 見えていない間は出さない。見えるようになったら、同じ絵でも 1 回出し直す (#2367)
            lastShown = nil
            return false
        }
        // **止まっている間は、絵が変わらなければ出し直さない** (#2367)。ウィンドウの面の大きさ・明るさの
        // 設定も鍵に入る。GPU が前の present を打ち切っていたら、次の書き込みは来ないので出し直す
        let shown = shownFrame(
            drawable: layer.drawableSize, pointerLock: false, cursorHidden: false,
            selection: nil, windowTitle: nil)
        if hasPresented, runtime.isHeldStill, shown == lastShown {
            if gpu.undelivered(presenter.lastSubmission) != true { return false }
            lastShown = nil
        }
        // **書き戻すのは 1 度だけ。** 素直に毎回組み直すと、出すたびにウィンドウと面の
        // retain/release が乗る (秒 60 回)。`shouldPresent` は一度 true になれば
        // 戻らないので、立てるのも 1 度でよい
        if try presenter.present(runtime.target, to: layer) {
            lastShown = shown
            return true
        }
        return false
    }

    /// いま出そうとしている絵の鍵 (``ShownFrame``)。**絵そのものは読まない** — 描画先の番号と明るさの
    /// 設定を読むだけで、追い付きの済んだ後 (``presentFrame()``) に呼ぶ。
    private func shownFrame(
        drawable: CGSize?, pointerLock: Bool, cursorHidden: Bool, selection: SelectionBroker.Request?,
        windowTitle: String?
    ) -> ShownFrame {
        let target = runtime.target
        return ShownFrame(
            target: ObjectIdentifier(target), revision: target.contentRevision,
            brightness: target.brightness, drawable: drawable, pointerLock: pointerLock,
            cursorHidden: cursorHidden, selection: selection, windowTitle: windowTitle)
    }

    /// 描けなかったことを 1 度だけ言う。
    private func noteFrameFailure(_ failure: RenderFailure) {
        // **書き出す経路では数える。** 描けなかったフレームは撮る係へ届かず、書き出したものの
        // 穴になる — 揃ったかを終了コードで言うのに要る (``concludeRender()``)
        if case .render = outlet { framesFailedToDraw += 1 }
        guard frameFailures.note() else { return }
        Diagnostics.warn(
            "Could not draw the frame: \(failure.headline) — trying again on the next refresh")
    }

    /// 描けるようになったことを言う。飛ばした数を添える。
    private func noteFrameRecovery() {
        guard let skipped = frameFailures.recovered() else { return }
        Diagnostics.warn(Self.recoveryNotice(skipped: skipped, gate: gpu.queueGate.closure))
    }

    /// 描けるようになったときの 1 行。
    ///
    /// **GPU の待ちが一度期限を越えていれば、関所の印が残っていることを言い添える** (#2052 の反証)。
    /// 印は下ろさない (``CommandQueueGate``) ので、「回復した」とだけ言うと、そのプロセスで新しい土台を
    /// 作れないことと食い違って読める。
    static func recoveryNotice(skipped: Int, gate closure: CommandQueueGate.Closure?) -> String {
        let recovered = "Drawing has recovered (\(skipped) frames were skipped)"
        guard closure != nil else { return recovered }
        return recovered
            + " — but a wait for the GPU went past its limit, so this process still sets up no new drawing"
            + " foundation; start it again to clear that"
    }

}

// MARK: - SketchView の順番待ち (#3509)

/// 別のスケッチが終わるのを待っている ``SketchView``。
@MainActor
protocol EmbeddedWaiter: AnyObject {
    /// 走っているものが無くなった。**自分で始める** (始められなくても列からは外れている)。
    func vacancyOpened()
}

/// 順番待ちの列の 1 件。**待ちながら消えたビューを強く持たない。**
@MainActor
struct WeakEmbeddedWaiter {
    weak var waiter: (any EmbeddedWaiter)?
}

// MARK: - AppKit との接点

/// AppKit の delegate を受けて ``SketchApplication`` へ渡す。
///
/// **この型が公開されないことに意味がある。** `NSApplicationDelegate` の要件は、準拠する型が
/// public なら public にならざるを得ない — つまり準拠を公開の型に置いた時点で、OS しか呼ばない
/// メソッドが利用者向けの API 一覧に載る ([ADR-0020] 決定 6)。受け口をここへ分けることで、
/// ``SketchApplication`` の面には利用者が実際に呼ぶもの (`init` と `run()` と観測の値) だけが
/// 残る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@MainActor
final class SketchApplicationDelegate: NSObject, NSApplicationDelegate {
    private let application: SketchApplication

    init(application: SketchApplication) {
        self.application = application
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        application.didFinishLaunching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        application.endsAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        application.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        application.willTerminate()
    }
}

// MARK: - 入口

extension Sketch {
    /// スケッチを起動する (`@main` から呼ばれる)。
    ///
    /// **既に 1 つ走っていれば、組み立てずに戻る** (`SketchApplication.run()` と同じ断り・
    /// [#2027](https://github.com/mokume-metal/mokume/issues/2027))。
    public static func main() {
        // 組み立てより前に断る。組み立てが投げると下の `exit(1)` が、走っている 1 つ目を
        // 後始末なしに落とす
        guard !SketchApplication.refusesSecondRun() else { return }
        // **起動中の印を、できるだけ早く置く** ([#3222](https://github.com/mokume-metal/mokume/issues/3222))。
        // スケッチの組み立て (`Self()`)・GPU の確保・ウィンドウの用意より前に置けば、そこで失敗して終わった子も、
        // 見張りは最初の絵の前に終わったと読める(置くのは見張りに起こされた子だけ)。最初の絵を出したら
        // 消える(``SketchApplication``)。これより前に死ぬ子(動的リンクの失敗・`main()` に届く前の大域の
        // 初期化)は置けず、今までどおり「自分で消えた」と読まれる
        markOwnStarting()
        do {
            let gpu = try RenderDevice()
            let application = try SketchApplication(sketch: Self(), gpu: gpu)
            application.run()
        } catch {
            reportStartFailure(error)
            exit(1)
        }
    }
}

/// 起動できなかったときに標準エラーへ出す文面 (末尾の改行まで)。
///
/// **切り出してあるのは、検査が呼んで確かめられるようにするため。** `Sketch.main()` は
/// この直後に `exit(1)` するので、そのままでは呼べない。
///
/// 名乗りと中身を 2 行に分けるのは、``RenderFailure/description`` が多行だからである —
/// 1 行に繋ぐと「起動できませんでした: 〜が見つからない: 〜」と冒頭に : が 2 つ並ぶ。
///
/// **ここは全文を出す。** 走っている最中の警告は 1 行に保つため
/// ``RenderFailure/headline`` を使うが、起動の失敗はそこで終わりなので、次にすることまで
/// 出さないと読む人に打つ手が残らない ([#600](https://github.com/mokume-metal/mokume/issues/600))。
func startupFailureText(_ failure: RenderFailure) -> String {
    "The sketch could not start.\n\(failure)\n"
}

/// このプロセスが起動中であることを、見張りの区画へ置く (``Sketch/main()``)。**見張りに起こされていなければ
/// 置かない** (``WorkDirectory/markStarting(forProcess:under:owner:)``)。
func markOwnStarting() {
    WorkDirectory.markStarting(owner: SharedFrameSurface.launchOwner)
}

/// このプロセスの起動の失敗を、見張りの区画へ置く。**見張りに起こされていなければ置かない**
/// (``WorkDirectory/noteStartFailure(_:forProcess:under:owner:)``)。
func noteOwnStartFailure(_ text: String) {
    WorkDirectory.noteStartFailure(text, owner: SharedFrameSurface.launchOwner)
}

/// 起動できなかったことを、標準エラーへ言い、見張りへも渡す ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
///
/// **組み立ての失敗 (``Sketch/main()``) と `setup()` の失敗 (`stopForSetupFailure`) の 2 か所が、ここを通る。**
/// 呼び出しを 1 行にしてあるのは、`exit` の前で呼べない呼び出し元の代わりに、検査がここを見るため。
/// 見張りへ渡すのは理由の全文 (標準エラーに出した文面と同じ中身) で、渡すかどうかは `note` が決める
/// (既定は、見張りに起こされたときだけ区画へ置く)。
///
/// - Parameter note: 理由の全文を受ける口。
func reportStartFailure(
    _ failure: RenderFailure, note: (String) -> Void = { noteOwnStartFailure($0) }
) {
    FileHandle.standardError.write(Data(startupFailureText(failure).utf8))
    note("\(failure)")
}
