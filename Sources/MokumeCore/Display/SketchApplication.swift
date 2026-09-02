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
public final class SketchApplication: NSObject {
    private let gpu: RenderDevice
    private let runtime: SketchRuntime
    private let presenter: FramePresenter
    private let title: String

    /// 開いている窓。**読むだけを内へ開けてある** — 検査が実際の経路の窓を閉じるため (#714)。
    private(set) var window: NSWindow?
    private var surface: SketchSurface?
    /// 画面の出口が外のプロセスに在るときの差し出し先。**在れば窓を持たない。**
    ///
    /// 分岐は「ビューアあり / なし」というモードではなく、**与えられた出口の構成**である
    /// ([ADR-0032] 決定 1)。合図は 1 つ (区画があるか) で、窓を開かないことも同じ合図から
    /// 従う。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private var sharedSurface: SharedFrameSurface?
    private var displayLink: CADisplayLink?
    /// 駆動源を紐づけている画面。張り替えの要否をこれで判断する。
    private var linkedScreen: NSScreen?
    /// これまでに 1 度でも画面へ出したか。最初の 1 枚の扱いに使う。
    private var hasPresented = false

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

    /// 速さを名乗る仕掛け。名乗りが与えられたときだけ持つ。
    private var frameRateNotice: Timer?

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
        super.init()
    }

    /// アプリケーションとして走らせる。戻らない。
    public func run() {
        let app = NSApplication.shared
        // **画面の出口を先に決める。** 活動の方針は `app.run()` より前にしか据えられない
        // ので、窓を開くかどうかをここで知っている必要がある。窓を持たないなら Dock にも
        // 並ばない (`.accessory`) — 並ぶと、道具が出す窓と作品が 2 つ並んで見える
        sharedSurface = attachSharedSurface()
        app.setActivationPolicy(sharedSurface == nil ? .regular : .accessory)
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
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "スケッチのフレームを一定の速さで進め続ける")
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

    /// 画面の出口が外のプロセスに在れば、そこへ差し出す用意をする。
    ///
    /// **区画が在るのに用意できなかったときは、窓を開く側へ倒す** — 面も窓も無い実行は、
    /// 外から見て「動いていない」としか見えない。倒したことは黙らずに言う。
    private func attachSharedSurface() -> SharedFrameSurface? {
        guard
            let shared = SharedFrameSurface.makeIfEnabled(
                gpu: gpu, width: runtime.target.width, height: runtime.target.height)
        else { return nil }
        do {
            try shared.publishManifest()
        } catch {
            Diagnostics.warn(
                "絵を渡す面の番号を置けませんでした: \(error.localizedDescription) — 窓を開いて続けます")
            return nil
        }
        return shared
    }

    /// 窓を開き、フレームの駆動源を繋ぐ。``SketchApplicationDelegate`` から呼ばれる。
    ///
    /// **画面の出口が外のプロセスに在れば、窓は作らない** ([ADR-0032] 決定 1)。駆動源は
    /// 窓ではなく画面に紐づくので (下記)、窓が無くてもそのまま繋がる。
    func didFinishLaunching() {
        if sharedSurface != nil {
            attachDisplayLink(to: NSScreen.main)
            return
        }
        let settings = runtime.sketch.settings
        // 窓は描く解像度の半分で開く。描く解像度と窓の大きさは独立なので、
        // どちらに合わせてもよい — 大きな絵が画面からはみ出さない側を既定にする
        let contentSize = NSSize(width: settings.width / 2, height: settings.height / 2)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        // **閉じたときに窓が自分を解放しないようにする。** 素の `NSWindow` の既定は
        // 「閉じたら解放する」で、こちらは強い参照を持ったまま使う人に閉じさせるので、
        // そのままだと解放が 1 回余分になる。しかも駆動源は窓ではなく画面に紐づいて
        // いるので (下記)、窓を閉じてもプロセスが消えるまで `step` は回り続け、その
        // 間ずっと消えた先を触る — 症状は原因から遠いところにしか出ない (#714)
        window.isReleasedWhenClosed = false
        // **覚えている位置があれば、そこへ戻す。** 無いときだけ中央に置く。覚えるのも
        // 画面外へ出さないようにするのも AppKit が持っている ([WindowPlacement])
        if !window.setFrameUsingName(WindowPlacement.autosaveName) { window.center() }
        window.setFrameAutosaveName(WindowPlacement.autosaveName)

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
        KnobOverlay.makeIfNeeded(for: runtime.sketch) { [runtime] in runtime.frameNumbers }?
            .attach(to: surface)
        // **前面を取らないときも、窓は出す。** 出さなければ、作り直すたびに絵が消える
        if takesFocus { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        // **面を第一応答者にしないとキーが来ない。** 窓を出したあとに据える —
        // contentView を差し替えると応答者は窓へ戻る
        window.makeFirstResponder(surface)
        surface.synchronizeDrawableSize()

        self.window = window
        self.surface = surface

        if takesFocus { NSApp.activate() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChangedScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: window)

        attachDisplayLink(to: window.screen ?? NSScreen.main)
        // 窓を開く時刻は起点にしない。速さを数え始めるのは最初のフレームが
        // 来たときである ([FrameTempo]) — 進み始める前に測ったことにすると、
        // 1 枚目で「1 枚 ÷ 待っていた時間」が出て 0.0 という嘘の数字になる
    }

    /// フレームの駆動源を画面のリフレッシュに紐づける。
    ///
    /// **面 (`NSView`) からではなく画面 (`NSScreen`) から取る。** 面から取った駆動源は
    /// 面が hidden になると呼ばれなくなる — AppKit のヘッダが `NSView` の側にだけ
    /// 「If the view is hidden, or not on any display, the callback will not be invoked」と
    /// 書いている。窓を最小化すると面は hidden になるので、フレームループごと止まり、
    /// 絵だけでなく観測も入力も応答しなくなっていた (#223)。
    ///
    /// 画面に紐づければ、最小化・被覆・Space の切り替えのどれでも止まらない。**最小化を
    /// 特別扱いする経路も、時間で叩く 2 本目の駆動源も要らない** — どれも「駆動源を
    /// どこに紐づけるか」1 つの問題だった (ADR-0012 決定 3 の「表示のリフレッシュは
    /// その駆動源の 1 つ」はそのまま)。
    private func attachDisplayLink(to screen: NSScreen?) {
        guard let screen else { return }
        displayLink?.invalidate()

        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // **表示のリフレッシュ率をそのまま使わない。** 画面が 120 Hz なら 120 回
        // 呼ばれてしまい、スケッチが求めたフレームレートが無視される。求めた値を
        // 上限にも下限にも据えて、画面の性能に引きずられないようにする
        let rate = Float(max(1, runtime.sketch.settings.frameRate))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)

        displayLink = link
        linkedScreen = screen
    }

    /// 窓が別の画面へ移ったら駆動源を張り替える。
    ///
    /// 画面ごとにリフレッシュ率が違うので、移った先に付け替えないと駆動が噛み合わない。
    ///
    /// **窓がどの画面にも乗っていないときは触らない。** 最小化でも同じ通知が飛び、その
    /// とき `window.screen` は `nil` を返す — 素直に張り替えると、直そうとした最小化で
    /// こそ駆動源を失う。
    @objc private func windowChangedScreen(_ notification: Notification) {
        guard let screen = window?.screen, screen !== linkedScreen else { return }
        attachDisplayLink(to: screen)
    }

    /// 駆動源を畳む。``SketchApplicationDelegate`` から呼ばれる。
    func willTerminate() {
        // **差込口を先に閉じる。** 送り先のアプリや機材から見ると、こちらが消えるより
        // 先に「終わる」と言われるほうが行儀がよい
        runtime.closePlugins()
        displayLink?.invalidate()
        displayLink = nil
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
    @objc private func step(_ link: CADisplayLink) {
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
        if let sharedSurface {
            // **速さも一緒に渡す。** 数えているのはこちらで、読むのは道具である
            // ([ADR-0030] 決定 7) — 面に載せれば通信路は 1 本も増えない
            try sharedSurface.write(
                runtime.target, using: presenter, numbers: runtime.frameNumbers)
            return
        }
        guard let surface, let layer = surface.metalLayer,
            FramePresenter.shouldPresent(
                windowIsVisible: isWindowVisible, hasPresented: hasPresented)
        else { return }
        if try presenter.present(runtime.target, to: layer) { hasPresented = true }
    }

    /// 続けて描けなかった数。始まりと終わりだけ言うために持つ。
    private var consecutiveFailures = 0

    /// 描けなかったことを 1 度だけ言う。
    ///
    /// **握り潰すと「絵が止まったのに理由がどこにも残らない」になる** — 観測だけが
    /// 黙ったように見える形の調査で、いちばん最初に欲しい 1 行がここだった
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))。一方で毎フレーム
    /// 言えば 1 秒に 60 行流れ、本当に読むべき行が埋まる。だから始まりと終わりだけ言う。
    private func noteFrameFailure(_ failure: RenderFailure) {
        consecutiveFailures += 1
        guard consecutiveFailures == 1 else { return }
        Diagnostics.warn("フレームを描けませんでした: \(failure.headline) — 次のリフレッシュで試し直します")
    }

    /// 描けるようになったことを言う。飛ばした数を添える。
    private func noteFrameRecovery() {
        guard consecutiveFailures > 0 else { return }
        Diagnostics.warn("フレームの描画が回復しました (\(consecutiveFailures) 枚ぶん飛ばしました)")
        consecutiveFailures = 0
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
        true
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
    "スケッチを起動できませんでした。\n\(failure)\n"
}
