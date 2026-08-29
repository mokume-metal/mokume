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
/// `NSApplicationDelegate` への準拠は internal な ``SketchApplicationDelegate`` が持つ。
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

    private var window: NSWindow?
    private var surface: SketchSurface?
    private var displayLink: CADisplayLink?
    /// 駆動源を紐づけている画面。張り替えの要否をこれで判断する。
    private var linkedScreen: NSScreen?
    /// これまでに 1 度でも画面へ出したか。最初の 1 枚の扱いに使う。
    private var hasPresented = false

    /// 直近に測ったフレームレート。
    ///
    /// 数えるのは**進めたフレーム**で、画面へ出した回数ではない。窓が見えていない間も
    /// スケッチは進み続けるので、ここで出した回数を数えると「最小化したら 0 になった」
    /// と読めてしまう — 測りたいのは絵が進んでいるかである。
    public private(set) var measuredFrameRate: Double = 0
    private var frameRateWindowStart: Double = 0
    private var frameRateWindowCount = 0

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
        app.setActivationPolicy(.regular)
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
        app.run()
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

    /// 窓を開き、フレームの駆動源を繋ぐ。``SketchApplicationDelegate`` から呼ばれる。
    func didFinishLaunching() {
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
        window.center()

        let surface = SketchSurface(
            frame: NSRect(origin: .zero, size: contentSize), device: gpu.device,
            input: runtime.input,
            canvasSize: (runtime.target.width, runtime.target.height))
        surface.wantsLayer = true
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        // **面を第一応答者にしないとキーが来ない。** 窓を出したあとに据える —
        // contentView を差し替えると応答者は窓へ戻る
        window.makeFirstResponder(surface)
        surface.synchronizeDrawableSize()

        self.window = window
        self.surface = surface

        NSApp.activate()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChangedScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: window)

        attachDisplayLink(to: window.screen ?? NSScreen.main)
        frameRateWindowStart = CACurrentMediaTime()
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
        guard let surface, let layer = surface.metalLayer else { return }
        do {
            try runtime.advance()
            if FramePresenter.shouldPresent(
                windowIsVisible: isWindowVisible, hasPresented: hasPresented)
            {
                if try presenter.present(runtime.target, to: layer) { hasPresented = true }
            }
        } catch {
            // 1 フレーム描けなかったことでアプリケーションごと落とさない。
            // 次のリフレッシュでもう一度試す — ただし**黙って捨てない**
            noteFrameFailure(error)
            return
        }
        noteFrameRecovery()
        recordFrameRate()
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
        Diagnostics.warn("フレームを描けませんでした: \(failure) — 次のリフレッシュで試し直します")
    }

    /// 描けるようになったことを言う。飛ばした数を添える。
    private func noteFrameRecovery() {
        guard consecutiveFailures > 0 else { return }
        Diagnostics.warn("フレームの描画が回復しました (\(consecutiveFailures) 枚ぶん飛ばしました)")
        consecutiveFailures = 0
    }

    private func recordFrameRate() {
        frameRateWindowCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - frameRateWindowStart
        guard elapsed >= 1 else { return }
        measuredFrameRate = Double(frameRateWindowCount) / elapsed
        frameRateWindowCount = 0
        frameRateWindowStart = now
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
            FileHandle.standardError.write(
                Data("スケッチを起動できませんでした: \(error)\n".utf8))
            exit(1)
        }
    }
}
