// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics
import QuartzCore

/// スケッチをアプリケーションとして走らせる。
///
/// 窓とアプリケーションの寿命は AppKit が持つ ([ADR-0012] 決定 4)。フレームを進める
/// 判断はランタイムのままで、ここは**表示のリフレッシュに合わせて `advance()` を叩く
/// 3 つ目の駆動源**を足すだけである ([ADR-0012] 決定 3)。
///
/// ## 駆動源は窓ではなく画面に紐づく
///
/// 面 (`NSView`) から取った駆動源は面が hidden になると呼ばれなくなるので、窓を
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
/// 純 CPU のベンチまで同じ倍率で遅くなること・窓を持たないプロセスでは同じ持続負荷でも
/// 起きないこと・前面のままなら起きないことで確かめてある。
///
/// [ADR-0012] 決定 5 は「窓が画面に出ていないときもフレームレートを維持する」を機能要件に
/// 固定したうえで、**「OS の省電力機構は既定では前面でないアプリの周期処理を間引くため、
/// 対処が要る」**と名指しし、手段は「実際に落ちることを確認してから」決めるとして空けていた。
/// ここがその対処である。
///
/// ## AppKit の delegate は別のオブジェクトが受ける
///
/// `NSApplicationDelegate` への準拠は internal な `SketchApplicationDelegate` が持つ。
/// **この型が直接準拠すると、delegate の 3 本が公開 API の一覧に載る** — 呼ぶのは OS で
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
    private let gpu: RenderDevice
    private let runtime: SketchRuntime
    private let presenter: FramePresenter
    private let title: String

    /// 画面の出口。
    ///
    /// 分岐は「ビューアあり / なし」というモードではなく、**与えられた出口の構成**である
    /// ([ADR-0032] 決定 1)。合図は 1 つ (区画があるか) で、窓を開かないことも同じ合図から
    /// 従う。
    ///
    /// **その 1 つの合図を 4 つの変数へ写さない。** かつては窓・面・共有面・出したかの
    /// 4 つの Optional で持っており、片方だけ書き換えれば「窓も出るし面へも書く」が
    /// 型として作れた — どちらの経路もそれを想定していないのに、である
    /// ([#955](https://github.com/mokume-metal/mokume/issues/955))。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private enum ScreenOutlet {
        /// 窓の経路だが、まだ建っていない。
        ///
        /// **``run()`` の既定であり、``didFinishLaunching()`` が置き換える。** 2 段階に
        /// なるのは畳めない事情による — 活動の方針 (`setActivationPolicy`) は
        /// `NSApplication.run()` より前にしか据えられず、窓はその後にしか建たない。
        case pendingWindow
        /// 自分の窓へ出す。付属の `hasPresented` は最初の 1 枚の扱いに使う。
        case window(NSWindow, SketchSurface, hasPresented: Bool)
        /// 外のプロセスが持つ区画へ差し出す。**窓は持たない。**
        case shared(SharedFrameSurface)
    }
    private var outlet: ScreenOutlet = .pendingWindow

    /// 開いている窓。**読むだけを内へ開けてある** — 検査が実際の経路の窓を閉じるため (#714)。
    var window: NSWindow? {
        if case .window(let window, _, _) = outlet { window } else { nil }
    }

    /// 最後の窓が閉じたら、スケッチも終わってよいか。
    ///
    /// **窓を持たない経路では終わらない** ([ADR-0032] 決定 1)。窓が画面の出口である経路では
    /// 「最後の窓が閉じた」は作品が終わったことと同じだが、出口が外のプロセスに在る経路では
    /// 何も意味しない — そこで数えられる窓は作品のものではないからである。
    ///
    /// 実際に数えられていたのは**メニューバーの名乗り** (``SketchPresence``) が開くメニュー
    /// だった。窓を 1 枚も持たないスケッチでは、それが開いて閉じた瞬間が「最後の窓が閉じた」
    /// になり、名乗りを覗いただけでスケッチが終わっていた
    /// ([#1102](https://github.com/mokume-metal/mokume/issues/1102))。窓は道具のものなので
    /// 画面には残り、止まった絵のまま動かない。
    ///
    /// **終わらせる経路が無くなるわけではない。** 窓を持たない子を止めるのは道具で、
    /// 窓の × も端末の `Ctrl-C` も同じ後始末 (`WatchSession.stop()`) を通る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    var endsAfterLastWindowClosed: Bool {
        switch outlet {
        case .shared: false
        case .pendingWindow, .window: true
        }
    }

    /// フレームの駆動源。**画面に紐づく** (``ScreenDisplayLink`` が理由を持つ)。
    private let screenLink: ScreenDisplayLink

    /// × を押した人に問う言葉。**無ければ確かめずに閉じる。**
    ///
    /// 既定は起動の瞬間に決まる — 道具が起こしたときだけ問いを持つ
    /// (``CloseConfirmation``)。**検査から差し替える**: 検査のプロセスに合図は渡らないので、
    /// そのままでは問いの経路を 1 つも通れない。
    var closeQuestion: CloseQuestion? = CloseConfirmation.startupQuestion()

    /// 問いの出し方。**検査から差し替える** (``SharedFrameStage/presentQuestion`` と同じ流儀)。
    var presentQuestion: @MainActor (CloseQuestion, NSWindow, @escaping (Bool) -> Void) -> Void =
        CloseQuestion.presentSheet

    /// 閉じてよいと確定したときの行き先。
    ///
    /// **道具立てごと終わらせる。** 窓を畳むだけでは後始末 (``willTerminate()``) を通らず、
    /// 差込口も駆動源も生きたまま残る — 終わりの経路は `applicationWillTerminate` の 1 本
    /// である。**検査から差し替える**: 既定のままでは、押した後を検めるたびに検査の
    /// プロセスが終わる。
    var onCloseConfirmed: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    /// 窓の出来事を、自分を強く持たせずに受ける。
    ///
    /// **窓の delegate に ``SketchApplication`` を直に据えない。** AppKit は delegate を
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

    /// いま走らせているもの。``run()`` の間だけ入る。
    private static var running: SketchApplication?

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
    /// ディスプレイが勝手に消えるのを断っているもの。**窓を出す経路でだけ持つ。**
    private var displaySleepBlock: DisplaySleepBlock?
    /// 走っている間、ディスプレイが消えるのを断るか。**既定は断る** (#874)。
    ///
    /// 外してよいのは、**画面が消えることそのものを測る検査**だけである
    /// (`scripts/check-observation-roundtrip.sh --display-asleep`)。断ったまま測ると
    /// 「スリープを作れなかったのに緑」という嘘が出る。
    public var blocksDisplaySleep = true
    /// 予備の駆動源。表示のリフレッシュが止まっても進め続けるために回す。
    private var fallbackTimer: Timer?
    /// 最後にフレームを進めた時刻。**どちらの駆動源が進めたかは問わない。**
    private var lastAdvancedAt: Double = 0
    /// 予備の駆動源が引き受けている最中か。表示のリフレッシュが戻れば下りる。
    private var isDrivenByFallback = false

    /// 速さを名乗る仕掛け。名乗りが与えられたときだけ持つ。
    private var frameRateNotice: Timer?

    /// 続けて描けなかった数。**始まりと終わりだけ**言うために持つ。
    private var frameFailures = FrameFailureLog()

    /// 名乗ってよい速さ。**測れていなければ `nil`。**
    ///
    /// 数えるのは**進めたフレーム**で、画面へ出した回数ではない。窓が見えていない間も
    /// スケッチは進み続けるので、ここで出した回数を数えると「最小化したら 0 になった」
    /// と読めてしまう — 測りたいのは絵が進んでいるかである。
    ///
    /// **窓はここでも読み手である** ([ADR-0030] 決定 7)。自分では数えず、観測の応答が
    /// 返すのと同じ集計器を読む。止まったスケッチや起動直後は測れていないので `nil` を
    /// 返す — **欠測を 0 に化けさせると「とても重い」と誤読される** ([ADR-0029] 決定 3)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    public var currentFrameRate: Double? { runtime.frameNumbers.frameRate }

    /// 面を取れずに見送ったフレームの数。
    public var missedFrames: Int { presenter.missedFrames }

    /// 窓がいま画面に出ているか。
    public var isWindowOnScreen: Bool { window?.isVisible ?? false }

    /// 窓の一部でも実際に見えているか。
    ///
    /// 最小化・他の窓による被覆・別の Space への切り替えを **1 つの判定で覆う**。
    /// 最小化だけを特別扱いしないのは、どれも「画面へ出しても誰も見ない」という
    /// 同じ状態だからである。
    private var isWindowVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    /// スケッチを画面に出す用意をする。
    ///
    /// 時刻の出どころは**実時間**にする — 画面に出しながら動かす経路なので、
    /// 実際に流れた時間で動くのが正しい。
    public init(sketch: any Sketch, gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        self.title = sketch.settings.title
        self.runtime = try SketchRuntime(sketch: sketch, gpu: gpu, clock: .wallClock)
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        self.screenLink = ScreenDisplayLink(
            frameRate: Float(max(1, sketch.settings.frameRate)))
        super.init()
        screenLink.owner = self
        windowRelay.application = self
    }

    /// アプリケーションとして走らせる。戻らない。
    public func run() {
        let app = NSApplication.shared
        // **画面の出口を先に決める。** 活動の方針は `app.run()` より前にしか据えられない
        // ので、窓を開くかどうかをここで知っている必要がある。窓を持たないなら Dock にも
        // 並ばない (`.accessory`) — 並ぶと、道具が出す窓と作品が 2 つ並んで見える
        resolveOutlet()
        switch outlet {
        case .shared: app.setActivationPolicy(.accessory)
        // 窓はまだ建っていないが、建てると決まっている
        case .pendingWindow, .window: app.setActivationPolicy(.regular)
        }
        // **delegate と自分を強く持っておく。** AppKit は delegate を弱く参照するので、
        // ここで持たないと、delegate を渡した直後に解放され、以後の呼び出しが 1 つも
        // 来ない (窓が開かない形で表に出る)。走らせている間は生きているべきものなので、
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
        // 「寝てよい」と言いながら片方で断るコードにしないためである
        if blocksDisplaySleep {
            displaySleepBlock = DisplaySleepBlock(reason: "keeping the sketch on screen")
        }
        // **断りは保証ではない。** 外部ディスプレイの電源を切る・蓋を閉じるといった
        // 経路は断れないので、止まったときに拾う側も併せて持つ
        startFallbackDriver()
        // **与えられたときだけ仕掛ける。** 与えられなければ何も足さないので、窓口から
        // 立てたスケッチの出力は 1 バイトも変わらない ([ADR-0029] 決定 5 の 2 番目)
        if FrameRateNotice.announces(
            configuration: FrameRateNotice.configuration, isTerminal: FrameRateNotice.isTerminal),
            let configuration = FrameRateNotice.configuration
        {
            startFrameRateNotice(configuration: configuration)
        }
        app.run()
    }

    /// 1 秒ごとに速さを名乗る。
    ///
    /// **付け足しは本体を妨げない** ([ADR-0029] 決定 5)。投げる経路を持たず、フレームの
    /// 進行にも触れない — 読むのは既に測ってある値だけである。
    ///
    /// **同じ 1 行を書き換える。** 積み上げると、見張りを付けっぱなしにしている間に
    /// 作り直しの記録と失敗の出力が上へ流れていく — いちばん読みたいものが、いちばん
    /// 流されやすくなる ([#685](https://github.com/mokume-metal/mokume/issues/685))。
    private func startFrameRateNotice(configuration: String) {
        frameRateNotice = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let line = FrameRateNotice.line(
                    rate: self.currentFrameRate, configuration: configuration)
                print(FrameRateNotice.rewrite + line, terminator: "")
                fflush(stdout)
            }
        }
    }

    /// 画面の出口を決める。``run()`` が `NSApplication.run()` より前に 1 度だけ呼ぶ。
    ///
    /// **切り出してあるのは、検査が窓を持たない経路を作れるようにするため。** 出口が
    /// 決まるのが `run()` の中だけだと、そこは戻らない呼び出し (`app.run()`) を含むので
    /// 検査から通せず、**窓 0 枚の経路の振る舞いを 1 つも見られない**
    /// ([#1102](https://github.com/mokume-metal/mokume/issues/1102) がそこで見過ごされた)。
    ///
    /// 区画の在処を受けるのは同じ理由で、既定は本番の場所である
    /// (`WorkDirectory.resolve(environment:)` などと同じ、既定引数で口を開ける形)。
    ///
    /// **活動の方針 (`setActivationPolicy`) はここに置かない。** 呼んだプロセス全体に
    /// 効くので、検査から呼べる場所に混ぜると検査の走るプロセスの方針まで動く。
    func resolveOutlet(at directory: URL = WorkDirectory.facet(StartupReads.viewport.key)) {
        if let shared = attachSharedSurface(at: directory) { outlet = .shared(shared) }
    }

    /// 画面の出口が外のプロセスに在れば、そこへ差し出す用意をする。
    ///
    /// **区画が在るのに用意できなかったときは、窓を開く側へ倒す** — 面も窓も無い実行は、
    /// 外から見て「動いていない」としか見えない。倒したことは黙らずに言う。
    private func attachSharedSurface(at directory: URL) -> SharedFrameSurface? {
        guard
            let shared = SharedFrameSurface.makeIfEnabled(
                gpu: gpu, width: runtime.target.width, height: runtime.target.height,
                at: directory)
        else { return nil }
        do {
            try shared.publishManifest()
        } catch {
            Diagnostics.warn(
                "Could not place the identifiers of the surfaces frames go to: "
                    + "\(error.localizedDescription) — opening a window and carrying on")
            return nil
        }
        return shared
    }

    /// 窓を開き、フレームの駆動源を繋ぐ。``SketchApplicationDelegate`` から呼ばれる。
    ///
    /// **画面の出口が外のプロセスに在れば、窓は作らない** ([ADR-0032] 決定 1)。駆動源は
    /// 窓ではなく画面に紐づくので (下記)、窓が無くてもそのまま繋がる。
    func didFinishLaunching() {
        switch outlet {
        case .shared:
            screenLink.attach(to: NSScreen.main)
            return
        // AppKit は 1 度しか呼ばないので来ないが、網羅のために名乗る
        case .window: return
        case .pendingWindow: break
        }
        let settings = runtime.sketch.settings
        // 窓は描く解像度の半分で開く。描く解像度と窓の大きさは独立なので、
        // どちらに合わせてもよい — 大きな絵が画面からはみ出さない側を既定にする
        let contentSize = NSSize(width: settings.width / 2, height: settings.height / 2)
        let window = WindowPlacement.makeWindow(
            title: title, autosaveName: WindowPlacement.autosaveName,
            defaultSize: contentSize)

        // 見張りが起こした入れ替えでは、窓を出しはするが前面は取らない (#679)
        let takesFocus = WindowPlacement.takesFocus(
            isRelaunch: WindowPlacement.isRelaunch(stamp: SourceStamp.current))

        let surface = SketchSurface(
            frame: NSRect(origin: .zero, size: contentSize), device: gpu.device,
            input: runtime.input,
            canvasSize: (runtime.target.width, runtime.target.height))
        surface.wantsLayer = true
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        // **つまみは絵の外に立つ** (ADR-0030 決定 1)。同じ窓へ重ねるだけで、描画の
        // 成果物には 1 画素も触らない。宣言が 1 つも無ければ何も足さない
        // 数字は**読む口を渡すだけ**。窓が自分で数えると源が 2 つに割れる
        // (ADR-0030 決定 7)
        KnobOverlay.makeIfNeeded(for: runtime.paramRegistry) { [runtime] in runtime.frameNumbers }?
            .attach(to: surface)
        // **確かめるのは、道具が起こしたときだけ** ([ADR-0032] 決定 1)。合図が無ければ
        // delegate を据えないので、直に走らせたスケッチと束ねた `.app` の × は、いままで
        // どおり押した瞬間に作品を終わらせる
        if closeQuestion != nil { window.delegate = windowRelay }

        // **前面を取らないときも、窓は出す。** 出さなければ、作り直すたびに絵が消える
        if takesFocus { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        // **面を第一応答者に据える。** 据わっていない窓にはキーが 1 件も来ない —
        // 理由と、AppKit の自動選択に頼らない訳は `SketchSurface.acceptsFirstResponder`
        // が持つ
        window.makeFirstResponder(surface)
        surface.synchronizeDrawableSize()

        outlet = .window(window, surface, hasPresented: false)

        if takesFocus { NSApp.activate() }

        screenLink.attach(to: window.screen ?? NSScreen.main, following: window)
        // 窓を開く時刻は起点にしない。速さを数え始めるのは最初のフレームが
        // 来たときである ([FrameTempo]) — 進み始める前に測ったことにすると、
        // 1 枚目で「1 枚 ÷ 待っていた時間」が出て 0.0 という嘘の数字になる
    }

    /// × を押された。**確かめている間は閉じない。**
    ///
    /// 閉じてしまうと絵の出口が消え、開き直す経路が無い。窓は作品の唯一の出口なので
    /// (メニューを組み立てないこの経路には `⌘Q` も `⌘W` も無い)、押し間違いで消えるのは
    /// 制作中の作品そのものである ([#1120](https://github.com/mokume-metal/mokume/issues/1120))。
    ///
    /// **問いを持たない窓は、そのまま閉じる。** 道具が起こしたのでなければ、AppKit の既定を
    /// 変える理由が無い (`SharedFrameStage.shouldClose(_:)` と同じ規律)。
    fileprivate func shouldClose(_ sender: NSWindow) -> Bool {
        guard let closeQuestion else { return true }
        // **問いを二重に出さない。** 下りている間 AppKit は親窓の操作を吸うが、閉じるよう
        // 頼む経路は残る (`performClose(_:)` など)
        guard sender.attachedSheet == nil else { return false }
        presentQuestion(closeQuestion, sender) { [weak self] confirmed in
            guard confirmed else { return }
            self?.onCloseConfirmed()
        }
        return false
    }

    /// 駆動源を畳む。``SketchApplicationDelegate`` から呼ばれる。
    func willTerminate() {
        // **差込口を先に閉じる。** 送り先のアプリや機材から見ると、こちらが消えるより
        // 先に「終わる」と言われるほうが行儀がよい
        runtime.closePlugins()
        screenLink.invalidate()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        // **返し忘れると、プロセスが終わるまで画面が消えなくなる**
        displaySleepBlock?.release()
        displaySleepBlock = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// 表示のリフレッシュごとに 1 フレーム進めて差し出す。
    ///
    /// **止めるのは「出す」ほうだけ。** 窓が見えていなくてもフレームは進める — 観測が
    /// 返すのは「最後に描いた絵」ではなく「いま描いた絵」で (ADR-0018)、進めるのを
    /// やめるとその約束が窓の状態で緩む。加えて、見えていない面へ差し出そうとすると
    /// `nextDrawable()` が返らずに待つので、飛ばすほうが速い。
    func displayLinkFired() {
        // **表示のリフレッシュが生きている。** 予備が引き受けていたなら、ここで下りる
        isDrivenByFallback = false
        advanceAndPresent()
    }

    /// 予備の駆動源を回し始める。
    ///
    /// **表示のリフレッシュが生きている間は空振りするだけ**なので、目標フレーム間隔で
    /// 細かく回してよい。止まっている間はこの間隔がそのままフレームレートになる。
    ///
    /// `.common` へ載せるのは、メニューを開いている間も回すためである — 名乗りの
    /// メニューを開いたまま画面が消えることは普通に起きる。
    private func startFallbackDriver() {
        let rate = max(1, runtime.sketch.settings.frameRate)
        let timer = Timer(
            timeInterval: FrameDriver.fallbackInterval(frameRate: rate), repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallbackTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// 予備の駆動源から 1 回。**止まっていなければ何もしない。**
    private func fallbackTick() {
        let rate = max(1, runtime.sketch.settings.frameRate)
        guard
            FrameDriver.shouldAdvanceFromFallback(
                now: CACurrentMediaTime(), lastAdvancedAt: lastAdvancedAt,
                stallThreshold: FrameDriver.stallThreshold(frameRate: rate),
                isAlreadyDriving: isDrivenByFallback)
        else { return }
        isDrivenByFallback = true
        advanceAndPresent()
    }

    /// 1 フレーム進めて差し出す。**どちらの駆動源から来ても、通る道は同じ。**
    private func advanceAndPresent() {
        lastAdvancedAt = CACurrentMediaTime()
        do {
            try runtime.advance()
            try presentFrame()
        } catch {
            // 1 フレーム描けなかったことでアプリケーションごと落とさない。
            // 次のリフレッシュでもう一度試す — ただし**黙って捨てない**
            noteFrameFailure(error)
            return
        }
        noteFrameRecovery()
    }

    /// 進めた 1 フレームを、与えられた出口へ差し出す。
    ///
    /// **出口は 1 つに決まっている** — 窓を持つか、外の面へ差し出すかで、両方はしない
    /// ([ADR-0032] 決定 1)。面へ差し出す側で見えているかを見ないのは、**誰が見ているかを
    /// 知っているのが読む側 (道具) だから**である。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private func presentFrame() throws(RenderFailure) {
        switch outlet {
        case .shared(let shared):
            // **速さも一緒に渡す。** 数えているのはこちらで、読むのは道具である
            // ([ADR-0030] 決定 7) — 面に載せれば通信路は 1 本も増えない
            try shared.write(runtime.target, using: presenter, numbers: runtime.frameNumbers)
        case .window(let window, let surface, let hasPresented):
            guard let layer = surface.metalLayer,
                FramePresenter.shouldPresent(
                    windowIsVisible: isWindowVisible, hasPresented: hasPresented)
            else { return }
            // **書き戻すのは 1 度だけ。** 素直に毎回組み直すと、出すたびに窓と面の
            // retain/release が乗る (秒 60 回)。`shouldPresent` は一度 true になれば
            // 戻らないので、立てるのも 1 度でよい
            if try presenter.present(runtime.target, to: layer), !hasPresented {
                outlet = .window(window, surface, hasPresented: true)
            }
        case .pendingWindow:
            return
        }
    }

    /// 描けなかったことを 1 度だけ言う。
    private func noteFrameFailure(_ failure: RenderFailure) {
        guard frameFailures.note() else { return }
        Diagnostics.warn(
            "Could not draw the frame: \(failure.headline) — trying again on the next refresh")
    }

    /// 描けるようになったことを言う。飛ばした数を添える。
    private func noteFrameRecovery() {
        guard let skipped = frameFailures.recovered() else { return }
        Diagnostics.warn("Drawing has recovered (\(skipped) frames were skipped)")
    }

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

    func applicationWillTerminate(_ notification: Notification) {
        application.willTerminate()
    }
}

// MARK: - 入口

extension Sketch {
    /// スケッチを起動する (`@main` から呼ばれる)。
    public static func main() {
        do {
            let gpu = try RenderDevice()
            let application = try SketchApplication(sketch: Self(), gpu: gpu)
            application.run()
        } catch {
            FileHandle.standardError.write(Data(startupFailureText(error).utf8))
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
