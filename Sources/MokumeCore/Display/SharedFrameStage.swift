// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import IOSurface
import Metal
import MokumeDiagnostics
import QuartzCore

/// 別のプロセスが差し出している絵を、1 つの窓に出す台。
///
/// ## なぜ台を分けるのか
///
/// 道具は窓を 2 種類出す — 何も載せない**作品の窓** (``SharedFrameWindow``) と、制作を
/// 助けるものが載る**プレビュー** (``SharedFramePreview``)。両者の違いは**見た目だけ**で、
/// 区画の見張り方も面の引き方も差し出し方も同じである ([ADR-0032] 決定 1)。
///
/// 二重に書けば片方だけが直る形になるので、同じところはここに 1 つ持つ。
///
/// ## 焼き直さない
///
/// 出力段を走らせたのは子である ([ADR-0032] 決定 2)。ここが渡す明るさは既定なので、
/// 差し出しの断片は早期に返して画素に 1 ビットも触らない — 面に載っている 1.0 超の
/// 明るさがそのまま画面へ届く。
///
/// ## 子の入れ替わりに、外から知らせなくてよい
///
/// 差し出し元は区画に置かれた番号で決まるので、**区画を見張っていれば自分で気付く**。
/// 道具の側に「差し替えろ」と言う口を作らないのは、言い忘れが「絵が古いまま」という
/// 形でしか出ないためである。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class SharedFrameStage: NSObject, ScreenDisplayLinkOwner {
    /// 窓の見た目。**台が決めないもの**をここへ集める。
    struct Look {
        /// 窓の名前。
        let title: String
        /// 位置を覚えるときの名前。**窓ごとに別にする** — 同じ名前だと互いの位置を
        /// 上書きし合い、2 枚が重なって開く。
        let autosaveName: String
        /// 覚えている枠が無いときの大きさ。
        let defaultSize: NSSize
        /// 覚えている枠が無いとき、中央からどれだけずらすか。
        ///
        /// **2 枚が重なって開くのを避ける。** 作品の窓とプレビューは同じ大きさで中央へ
        /// 出るので、ずらさないと**寸分違わず重なり**、窓が 1 つしか無いように見える (実測)。
        /// 一度動かせば以後は覚えた位置が使われるので、効くのは初めての 1 回だけである。
        var nudge: NSSize = .zero
        /// 差し出し元が頼む窓の大きさ (描く大きさ × ``SketchSettings/windowScale``) に従うか。
        ///
        /// **作品の窓だけが従う。** 作品の窓の見え方は直に走らせたときと同じである
        /// ([ADR-0032] 決定 1)。プレビューは手元に置く道具の窓で、作品の宣言に大きさを
        /// 決めさせる理由が無い。
        ///
        /// 従うのは指定が前と変わったときだけで、変わらなければ手で動かした大きさと位置が
        /// 残る (``WindowPlacement/honour(_:in:autosaveName:defaults:warn:)``)。
        var followsRequestedSize = false
        /// 作品の窓が頼まれた大きさで置き直されたとき、その真下へ置き直すか。
        ///
        /// **プレビューだけが置き直す。** 作品の窓が描く大きさ × 倍率で開くので、既定の
        /// 大きさを前提にした初めの位置 (``nudge``) のままだと、作品の窓が高いスケッチで
        /// 2 枚が重なる (``WindowPlacement/placeBeneathArtwork(_:window:autosaveName:defaults:)``)。
        var placesBeneathRequestedArtwork = false
    }

    /// × を押された人に問う言葉。
    ///
    /// **台は言葉を決めない。** 何と言うかは窓を持つ側 (道具) の仕事で、ここは出し方だけを
    /// 持つ — 端末に出ている言葉と揃える必要があるからである
    /// (``SharedFramePreview/report(_:spinning:)`` と同じ規律)。
    ///
    /// 実体は ``MokumeCore/CloseQuestion``。走っているスケッチ自身の窓
    /// (``SketchApplication``) も同じ問いを出すので、型と出し方はそちらが持つ。
    typealias CloseQuestion = MokumeCore.CloseQuestion

    /// 面の 1 枚を、差し出せる形にしたもの。
    private struct Frame: PresentableFrame {
        let texture: any MTLTexture
        let width: Int
        let height: Int
        /// **焼き直さない** ([ADR-0032] 決定 2)。既定は断片が早期に返す設定である。
        let brightness = Brightness.default
    }

    /// いま見ている差し出し元。
    private struct Source {
        let ids: [UInt32]
        /// 面を引いたまま持ち続ける読み手。**番号の組が変わる (= 別の世代) までは引き直さない**
        /// ([#2368](https://github.com/mokume-metal/mokume/issues/2368))。
        let lookup: SharedFrameSurface.Lookup
        let width: Int
        let height: Int
        /// 番号ごとのテクスチャ。引けなかった面は入らない。
        let frames: [UInt32: Frame]
        /// 窓を開く倍率。**名乗らない子 (古いライブラリ) なら `nil`** で、窓の大きさに触らない。
        let windowScale: Float?
    }

    private let gpu: RenderDevice
    private let facet: URL
    private let look: Look
    private let presenter: FramePresenter

    /// 窓が拾った出来事の行き先。**渡ってくるのはそのまま子の標準入力へ書ける 1 行。**
    ///
    /// 窓を出した後に差し替えてもよい (見張りは子を入れ替えるので、書き先は変わる)。
    var onInput: ((String) -> Void)?

    /// 表示のリフレッシュごとに呼ばれる。**絵が来ていなくても呼ぶ** — 面を読み直す側は
    /// 絵の有無と関係なく進む必要がある。
    var onTick: (() -> Void)?

    /// × を押されたときに問うこと。**無ければ素直に閉じる** — 窓を持つ側が終わり方を
    /// 決めていないなら、AppKit の既定を変える理由が無い。
    private var closeQuestion: CloseQuestion?
    /// 閉じてよいと確定したときの行き先。
    ///
    /// **実際に窓を畳むのはここではない。** 見張りは子を止め、区画を片付けてから畳む
    /// 必要があるので、台が先に閉じると後始末の順が壊れる ([ADR-0032] 決定 1)。
    private var onCloseConfirmed: (() -> Void)?
    /// 問いを持っているか。**検査から見る** (`SharedFramePreview.hasPanel` と同じ扱い)。
    var asksBeforeClosing: Bool { closeQuestion != nil }

    /// 差し出し元を掴めているか。**検査から見る** — 目録を読み直せたかどうかは、外からは
    /// 「絵が出るか」でしか見えない。
    var hasSource: Bool { source != nil }

    /// まだ出していない世代を控えているか。**検査から見る。**
    var hasIncoming: Bool { incoming != nil }

    /// 面を引いた (`IOSurfaceLookup`) 回数。出している世代と控えている世代の合計。**検査から
    /// 見る** — 番号の組が変わらない間は、リフレッシュを重ねても増えないこと
    /// ([#2368](https://github.com/mokume-metal/mokume/issues/2368))。
    var surfaceLookups: Int {
        retiredLookups + (source?.lookup.lookups ?? 0) + (incoming?.lookup.lookups ?? 0)
    }
    /// 手放した世代が引いた回数。``surfaceLookups`` を世代の入れ替わりをまたいで数えるため。
    private var retiredLookups = 0

    /// 問いの出し方。**検査から差し替える** — 既定は窓へシートを下ろすので、そのままでは
    /// 「押した後どうなるか」を検められない (`WatchSession.Hooks` と同じ流儀)。
    var presentQuestion: @MainActor (CloseQuestion, NSWindow, @escaping (Bool) -> Void) -> Void =
        CloseQuestion.presentSheet

    private(set) var window: NSWindow?
    private var view: SketchSurface?

    /// 重ねる面を足す先。**窓が出ている間だけ在る。**
    ///
    /// 後から差し替えられるようにしてあるのは、宣言の顔ぶれが変わったらつまみを
    /// 組み直すためである ([ADR-0032] 決定 5)。
    var host: NSView? { view }
    /// フレームの駆動源。**速さは据えない** (``ScreenDisplayLink/frameRate`` が理由を持つ)。
    private let screenLink = ScreenDisplayLink()

    private var source: Source?
    /// 目録に現れたが、**まだ 1 枚も書いていない世代。**
    ///
    /// **前の世代を捨てずに持つ。** 目録が変わった瞬間に乗り換えると、新しい子が最初の
    /// フレームを焼くまで出せる絵が無くなる — 手元では保存のたびに **417 ms** 画面が
    /// 止まっていた ([#1142](https://github.com/mokume-metal/mokume/issues/1142))。
    ///
    /// **面は死なない。** `IOSurface` は参照計数なので、目録が上書きされても、置いた子が
    /// 消えても、こちらが握っているテクスチャはそのまま出せる。
    private var incoming: Source?
    /// 出す世代が入れ替わったことの知らせ。
    ///
    /// **知らせるだけで、止めるのはここではない。** 古い子を止めるのは道具 (`WatchCommand`)
    /// の仕事で、この台は絵の出口しか知らない。
    var onGenerationPromoted: (() -> Void)?
    /// 控えた世代の絵を、この台が受け取れないことの知らせ ([#2928])。
    ///
    /// **乗り換えの知らせが来ない形のうち、道具だけが知る 2 つ** (``UndeliverableGeneration``)。
    /// 子は自分の目録が読まれないことも、面が引けないことも知らないので、子からの申告は届かない。
    /// **知らせるだけで、前の世代を畳むのはここではない** (``onGenerationPromoted`` と同じ分担)。
    /// どの世代の知らせかは目録が印を持たないので、受け取る側が「乗り換えを待っている世代」だけを見る。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    var onGenerationUndeliverable: ((UndeliverableGeneration) -> Void)?
    /// 出す世代の最初の 1 枚を画面へ出したことの知らせ ([#2875])。
    ///
    /// **入れ替わりの知らせとは別に持つ。** 最初の世代は絵が来る前に採用されるので
    /// (``promoteIfReady()``)、入れ替わりの知らせでは子の `setup()` の間を覆えない。
    /// 受け取る側 (プレビューの「起こしている」表示) が畳む合図はこちらである。
    ///
    /// [#2875]: https://github.com/mokume-metal/mokume/issues/2875
    var onGenerationShown: (() -> Void)?
    /// いま出している世代の絵を、もう 1 枚でも出したか。**採用のたびに下ろす。**
    private var shownCurrentGeneration = false
    /// 区画に置かれた目録の見張り。**変わったときだけ読み直す** — 書きかけを掴んだ改訂は、
    /// 確定させずに次の機会へ回る (``WatchedFile``)。
    ///
    /// **読めない改訂は、台が名乗る** ([#2889]): 作ったときに渡す口で、台の `warn` へ流す。`lazy` なのは、
    /// 口が台自身を指すため (初期化の後でないと自分を取れない)。
    ///
    /// [#2889]: https://github.com/mokume-metal/mokume/issues/2889
    private lazy var manifest = WatchedFile<SharedFrameSurface.Manifest>(
        url: facet.appendingPathComponent(SharedFrameSurface.manifestName)
    ) { [weak self] failure in self?.noteUnreadableManifest(failure) }
    /// 道具の端末への名乗り。**検査から差し替える** — 既定は標準エラー。
    var warn: (String) -> Void = Diagnostics.warn
    /// 最後に画面へ出した枚数。**同じ絵を二度出さない**ための目印。
    ///
    /// **差し出しを投入した直後に記し、結末は後で見る** ([#2735])。投入を GPU が打ち切ったら、
    /// 結末が届いた後のリフレッシュで記しを戻し (``submissionSettled(_:dropped:)``)、同じ枚を
    /// 出し直す。戻さないと、書き手が書くのをやめたとき (子の終了・異常終了・詰まり・とても低い
    /// フレームレート) は枚数が進まず、窓は打ち切られる前の絵のままになる。子は `noLoop()` や一時停止の
    /// 間も毎リフレッシュ書いて枚数を進めるので、生きて書いている間は次の枚で上書きされる。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    private var lastFrame = 0
    /// ``lastFrame`` を記した差し出しの投入の番号。**この番号の打ち切りだけが記しを戻す** —
    /// 後の差し出しが記し直していれば、前の差し出しの打ち切りは見送る。
    private var lastFrameSubmission: UInt64 = 0
    /// 差し出した回数 (作ってから通算)。**検査から読む** — 打ち切られた 1 枚を出し直したか、
    /// 打ち切りの無い経路で差し出しを増やしていないか ([#2735]) は、外からはこの数でしか見えない。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    private(set) var presentations = 0
    /// 最後に面から読んだ枚数。**出せた枚数とは別に持つ** — 差し出しに失敗した回でも
    /// 数字は届いているので、`lastFrame` に相乗りさせると失敗した回だけ数字が古くなる。
    private var lastSeenFrame = 0
    /// 走っている側が数えた速さ。**自分では数えない** ([ADR-0030] 決定 7)。
    private var tempo = RemoteTempo()
    /// 出している世代のスケッチが、カーソルを捕まえるよう頼んでいるか。**面の属性から読む**
    /// (``SharedFrameSurface/pointerLockAttribute``・[#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    ///
    /// 読むのは新しい枚数が来たときだけで (速さと同じ)、渡すのは毎リフレッシュである — 窓が
    /// 前に出たか・ポインタが面の上かは、要求と関係なく変わる。**検査から読む。**
    private(set) var pointerLockRequested = false
    /// 出している世代のスケッチが、矢印のカーソルを隠すよう頼んでいるか。**面の属性から読む**
    /// (``SharedFrameSurface/cursorHiddenAttribute``・[#2439](https://github.com/mokume-metal/mokume/issues/2439))。
    /// 読み方と渡し方は ``pointerLockRequested`` と同じで、**自分が映す世代の頼みに従う**。検査から読む。
    private(set) var cursorHiddenRequested = false
    /// 続けて差し出せなかった数。**始まりと終わりだけ**言うために持つ。
    private var failures = FrameFailureLog()

    /// 窓の出来事を、台を強く持たずに中継する。
    ///
    /// **窓の delegate に台を直に据えない。** AppKit は delegate を弱く持つが、呼ぶ前に
    /// 一時的な強い参照を作る (autorelease) ので、**手放した台の解放がプールの掃除まで
    /// 遅れる** — [#738] が入れた検査 (`close()` を呼ばずに手放したら解放される) は、直に
    /// 据えた版で実際に落ちた。駆動源が持ち主を弱く持つのも同じ理由である
    /// (``ScreenDisplayLink/owner``)。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    @MainActor private final class WindowRelay: NSObject, NSWindowDelegate {
        weak var stage: SharedFrameStage?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            stage?.shouldClose(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            stage?.willClose()
        }
    }

    private let windowRelay = WindowRelay()

    /// - Parameter facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    init(gpu: RenderDevice, facet: URL, look: Look) throws(RenderFailure) {
        self.gpu = gpu
        self.facet = facet
        self.look = look
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        super.init()
        screenLink.owner = self
        windowRelay.stage = self
    }

    /// **畳み忘れても、手放した時点で畳む。** 仕掛けを止めない限り、走り続ける
    /// ([#738](https://github.com/mokume-metal/mokume/issues/738))。
    ///
    /// **引いた面を常駐から退かせるのは、`close()` ではなくここである** ([#795])。
    /// 世代の差し替えでは外していたが、台そのものを手放したときは外していなかった。
    /// `close()` に置かないのは、畳んだ窓をもう一度 `open()` できるからである — 畳んでも
    /// 世代は捨てないので、そこで外すと開き直した窓が常駐していない面を読む。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit {
        close()
        for generation in [source, incoming].compactMap({ $0 }) {
            for frame in generation.frames.values { gpu.retire(frame.texture) }
        }
    }

    /// 窓を出し、区画を見張り始める。
    ///
    /// **覚えている位置があればそこへ戻す。** 覚え方は走っているスケッチの窓と同じ
    /// (`WindowPlacement`) — 使う人から見れば同じ「スケッチの窓」なので、起こし方で
    /// 置き場所が変わらないほうがよい。
    ///
    /// - Parameter overlay: 絵に重ねる面。**無ければ何も足さない** — 作品の窓に道具の
    ///   都合が 1 画素も出ないのは、ここに何も渡さないことで成り立っている
    ///   ([ADR-0032] 決定 1)。
    func open(overlay: NSView? = nil) {
        // 大きさは差し出し元が来るまで分からない。**来てから合わせる**ので、ここは
        // 覚えている枠が無いときの初期値でしかない
        let window = WindowPlacement.makeWindow(
            title: look.title, autosaveName: look.autosaveName,
            defaultSize: look.defaultSize, nudge: look.nudge)

        // **面はスケッチの窓と同じものを使う。** 画素形式・色空間・EDR の既定を 1 か所に
        // 保つためで、別に作ると片方だけが規範から外れる (ADR-0011)
        let view = SketchSurface(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size),
            device: gpu.device, input: InputState(), canvasSize: (1, 1))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        // **絵が来るまでは黒で塗る** ([#2875])。窓は作り直しより先に開くので、最初の 1 枚
        // までは drawable を一度も受け取っていない層が見え、中身が透明か不定になる。黒は
        // 絵が収まらない帯の色 (`FramePresenter`) と同じで、作品の表示に無いものを足さない
        // — 言葉も印も載せないのは ADR-0032 決定 6 の追補のとおり。直に走らせる窓は
        // 層を作る側 (`SketchSurface`) が同じなので、塗るのは道具の窓のここだけにする
        //
        // [#2875]: https://github.com/mokume-metal/mokume/issues/2875
        view.metalLayer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        // **窓より先に繋ぐ。** 出してから繋ぐと、その隙間に触ったぶんが落ちる
        view.relay = { [weak self] line in self?.onInput?(line) }
        window.contentView = view
        // **絵の面へ足す。** 別の窓にしないのは、重ねるものが絵と一緒に動く必要が
        // あるからで、経路そのものは絵と別のまま (AppKit の層) である
        if let overlay { view.addSubview(overlay) }
        // **閉じようとしたことを受け取る。** 繋がないと × は AppKit の既定で通り、絵の
        // 出口だけが消えて誰も止まらない ([#826])。窓は delegate を弱く持つので環にならない
        //
        // [#826]: https://github.com/mokume-metal/mokume/issues/826
        window.delegate = windowRelay
        window.makeKeyAndOrderFront(nil)
        // **面を第一応答者に据える。** 据わっていない窓にはキーが 1 件も来ない —
        // 理由と、AppKit の自動選択に頼らない訳は `SketchSurface.acceptsFirstResponder`
        // が持つ
        window.makeFirstResponder(view)
        view.synchronizeDrawableSize()

        self.window = window
        self.view = view

        screenLink.attach(to: window.screen ?? NSScreen.main, following: window)
    }

    /// × を押されたら、確かめてから知らせる。**確かめている間は閉じない。**
    ///
    /// - Parameters:
    ///   - question: 問う言葉。
    ///   - confirmed: 閉じてよいと確定したときに呼ばれる。**窓を畳むのは受け取った側**で、
    ///     台はここでは何も畳まない。
    func askBeforeClosing(_ question: CloseQuestion, then confirmed: @escaping () -> Void) {
        closeQuestion = question
        onCloseConfirmed = confirmed
    }

    /// 畳む。
    func close() {
        screenLink.invalidate()
        // **下りているシートを先に畳む。** 兄弟窓 (作品の窓とプレビュー) は独立に × を
        // 押せるので、片方で確定した後始末が**もう片方のシートが出たままの窓**を閉じる
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        // **先に受け口を外す。** `close()` は問いを通らない経路 (delegate を経ずに閉じる)
        // だが、繋いだまま手放すと閉じた窓から呼ばれうる余地を残す
        window?.delegate = nil
        window?.close()
        window = nil
        view = nil
        // **閉じ手を手放す。** 畳んだ後に呼ばれる余地を残さない (この台は #738 で
        // 環を切ったばかりなので、持ち続ける参照はここで切る)
        onCloseConfirmed = nil
    }

    // MARK: - 駆動

    func displayLinkFired() {
        // **結末の届いた差し出しを、出すかを決める前に照らす** ([#2735])。打ち切られていれば
        // ``submissionSettled(_:dropped:)`` が記しを戻し、このリフレッシュが同じ枚を出し直す。
        // 道具のプロセスには描き切り (`Canvas.flush`) が無いので、照会を完了の知らせだけに任せると
        // 出し直しが知らせの走る時刻に縛られる。待たずに問い、置き場は持ち回る (#2199)
        //
        // [#2735]: https://github.com/mokume-metal/mokume/issues/2735
        gpu.revokeDroppedDeliveries()
        onTick?()
        reloadSourceIfChanged()
        promoteIfReady()
        // **絵が出せない回も渡す。** 要求を読む・読まないは絵の有無に依るが、窓が退いた・
        // 要求が消えたで放すのは、絵が来ていなくても効く必要がある (#1144)
        defer {
            self.view?.followPointerLock(requested: pointerLockRequested)
            self.view?.followCursorHiding(requested: cursorHiddenRequested)
        }
        guard let source, let newest = source.lookup.newest() else { return }
        // **面に載ったもの (速さ・捕まえの要求) は、窓の有無と関係なく読む。** 絵を出す先が
        // 無くても、走っている側が名乗ったことは変わらない
        readNumbers(from: newest, in: source.lookup)
        guard let view, let layer = view.metalLayer,
            newest.frame != lastFrame, let frame = source.frames[newest.id]
        else { return }
        do {
            // **出せた枚数だけを覚える。** 面を取れずに見送ったときに覚えると、次の
            // リフレッシュで「同じ枚数だから出さない」と判断して 1 枚落とす
            if try presenter.present(frame, to: layer) {
                lastFrame = newest.frame
                presentations += 1
                // **記した直後に結末を預ける** (#2199 の作法)。打ち切られたら記しを戻す
                lastFrameSubmission = presenter.lastSubmission
                gpu.awaitSettlement(of: lastFrameSubmission, by: self)
                if !shownCurrentGeneration {
                    shownCurrentGeneration = true
                    onGenerationShown?()
                }
            }
            noteRecovery()
        } catch {
            noteFailure(error)
        }
    }

    // MARK: - 速さ

    /// いま名乗ってよい速さ。**しばらく新しい絵が来なければ `nil`** (``RemoteTempo``)。
    var numbers: FrameNumbers? { tempo.numbers(now: CACurrentMediaTime()) }

    /// 新しい絵が来ていれば、その面に載っている速さを読む。
    ///
    /// **新しい枚数のときだけ引く。** 同じ絵に対して引き直しても数字は変わらないので、
    /// 毎リフレッシュ読むぶんだけ無駄になる。
    private func readNumbers(
        from newest: (id: UInt32, frame: Int), in lookup: SharedFrameSurface.Lookup
    ) {
        guard newest.frame != lastSeenFrame else { return }
        lastSeenFrame = newest.frame
        // `newest` を返した面は握っているので、引き直さない (#2368)
        guard let surface = lookup.surface(newest.id) else { return }
        // 捕まえの要求も同じ面に載っている。速さが載っていない面でも読む
        pointerLockRequested = SharedFrameSurface.pointerLockRequested(on: surface)
        cursorHiddenRequested = SharedFrameSurface.cursorHiddenRequested(on: surface)
        guard let numbers = SharedFrameSurface.numbers(on: surface) else { return }
        tempo.record(numbers, at: CACurrentMediaTime())
    }

    // MARK: - 差し出し元

    /// 区画が変わっていれば読み直す。
    ///
    /// **更新時刻で見る。** 毎フレーム読み解くのは無駄で、中身が変わるのは子が入れ替わった
    /// ときだけである。
    private func reloadSourceIfChanged() {
        guard let manifest = manifest.changed() else { return }
        adopt(manifest)
    }

    /// 新しい差し出し元を**控える。** 出している世代には触らない。
    ///
    /// 乗り換えるのは ``promoteIfReady()`` で、控えた世代が 1 枚書いてからである。
    private func adopt(_ manifest: SharedFrameSurface.Manifest) {
        // **控えていた世代は捨てる。** 重ねるのは 2 つまでで、まだ 1 枚も出していない
        // 世代を積み上げても、出る絵は増えない
        if let waiting = incoming {
            retiredLookups += waiting.lookup.lookups
            try? gpu.releaseResidency(of: waiting.frames.values.map(\.texture))
            incoming = nil
        }
        var frames: [UInt32: Frame] = [:]
        for id in manifest.ids {
            guard let frame = makeFrame(id: id, width: manifest.width, height: manifest.height)
            else { continue }
            frames[id] = frame
        }
        guard !frames.isEmpty else {
            // **直前の絵はそのまま残す** (決定 6)。引けなかったのは、置いた側が既に居ない (子の側で
            // 決まる — 道具の側の「子の離脱」が畳む) か、子は生きているのに引けない (面が全域でない
            // など・道具の側だけが知る) かのどちらかで、後者は知らせないと乗り換えの合図が来ない
            // ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。どちらかは受け取る側が決める
            onGenerationUndeliverable?(.noSurface)
            return
        }
        incoming = Source(
            ids: manifest.ids, lookup: SharedFrameSurface.Lookup(ids: manifest.ids),
            width: manifest.width, height: manifest.height, frames: frames,
            windowScale: manifest.windowScale)
    }

    /// 控えている世代が絵を出せるなら、そちらへ乗り換える。
    ///
    /// **待つのは「1 枚書いたか」だけで、時計は見ない** (ADR-0032 決定 3)。面は書き終わって
    /// から `mokume.frame` を上げるので、``SharedFrameSurface/newest(among:)`` が掴めた時点で
    /// 出せる絵が在る。
    ///
    /// **出している世代が無いときは待たない。** 待っても出るものが無く、見張りを始めた
    /// 最初の 1 回がそれに当たる。
    private func promoteIfReady() {
        guard let waiting = incoming else { return }
        if source != nil, waiting.lookup.newest() == nil { return }
        // **前の面を常駐から外す。** 外さないと、見張っている間ずっと死んだ面が積み上がる
        if let previous = source {
            retiredLookups += previous.lookup.lookups
            try? gpu.releaseResidency(of: previous.frames.values.map(\.texture))
        }
        source = waiting
        incoming = nil
        // 触った操作を写す規則は描く解像度に依る (レーン 4 で使う)
        view?.setCanvasSize((waiting.width, waiting.height))
        followRequestedSize(of: waiting)
        // **枚数の数え直しに備える。** 新しい子は 1 から数えるので、前の子の枚数を
        // 覚えたままだと、そこへ追い付くまで 1 枚も出さないことになる (速さも同じで、
        // 追い付くまで前の子の数字を名乗り続けることになる)
        // 捕まえの要求も同じ理由で、新しい世代の面から読み直す (#1144)。乗り換えるのは新しい
        // 世代が 1 枚焼いた後なので、同じリフレッシュの ``readNumbers(from:)`` が読む — 要求して
        // いない世代なら、そこで外れる
        lastFrame = 0
        lastSeenFrame = 0
        shownCurrentGeneration = false
        onGenerationPromoted?()
    }

    /// 出す世代が頼む窓の大きさに合わせる (``Look/followsRequestedSize``)。プレビューなら、
    /// その大きさで置き直された作品の窓の真下へ動く (``Look/placesBeneathRequestedArtwork``)。
    ///
    /// **乗り換えのたびに呼ぶが、当たるのは指定が変わったときだけである。** 保存のたびに
    /// 窓が戻らないこと ([#679](https://github.com/mokume-metal/mokume/issues/679)) は
    /// ``WindowPlacement/honour(_:in:autosaveName:defaults:warn:)`` が持つ。
    private func followRequestedSize(of generation: Source) {
        guard let scale = generation.windowScale, let window else { return }
        let requested = WindowPlacement.requestedSize(
            width: generation.width, height: generation.height, scale: scale)
        if look.followsRequestedSize {
            WindowPlacement.honour(
                requested, in: window, autosaveName: look.autosaveName, defaults: defaults)
        } else if look.placesBeneathRequestedArtwork {
            WindowPlacement.placeBeneathArtwork(
                requested, window: window, autosaveName: look.autosaveName, defaults: defaults)
        }
    }

    /// 開く大きさの指定を覚える先。**検査から差し替える** — 既定のままだと、検査を走らせた
    /// プロセスの記憶に指定が残る。
    var defaults: UserDefaults = .standard

    /// 番号から面を引き、差し出せる形にする。
    private func makeFrame(id: UInt32, width: Int, height: Int) -> Frame? {
        guard let surface = IOSurfaceLookup(id) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard
            let texture = gpu.device.makeTexture(
                descriptor: descriptor, iosurface: surface, plane: 0)
        else { return nil }
        gpu.makeResident(texture)
        return Frame(texture: texture, width: width, height: height)
    }

    // MARK: - 言うこと

    /// 読めない目録を掴んだことを、改訂ごとに 1 度言う ([#2889])。
    ///
    /// **差し出し元は変えない** — 読めない目録からは乗り換え先が分からないので、直前の絵を出したままにする
    /// (ADR-0032 決定 6)。名乗りの文面は ``UnreadableRevision`` で、つまみの応答と揃える。
    /// 「目録が読めない回」を知る口はここだけである。
    ///
    /// [#2889]: https://github.com/mokume-metal/mokume/issues/2889
    private func noteUnreadableManifest(_ failure: UnreadableRevision.Failure) {
        // **作品の窓とプレビューは、それぞれ台を持ち、同じ目録を別々に読む**ので、同じ改訂は台ごとに
        // 1 度ずつ (高々 2 行) 名乗る。文面もそう言う (「1 度」と言い切ると、2 行出て偽になる)
        warn(
            UnreadableRevision.notice(
                of: "The shared-frame manifest", at: manifest.url, failure: failure,
                saidBy: "each window"))
        // 読めない目録は乗り換えの合図も起こさないので、前の世代が残る ([#2928])。**名乗りは上で済んで
        // いる** — 受け取る側は同じ候補を端末へ 2 度言わない (``UndeliverableGeneration``)
        //
        // [#2928]: https://github.com/mokume-metal/mokume/issues/2928
        switch failure {
        case .cannotDecode: onGenerationUndeliverable?(.unreadableManifest)
        case .cannotRead: onGenerationUndeliverable?(.unreadableFile)
        }
    }

    /// 出せなかったことを 1 度だけ言う。**握り潰すと、絵が止まった理由がどこにも残らない。**
    private func noteFailure(_ failure: RenderFailure) {
        guard failures.note() else { return }
        Diagnostics.warn(
            "Could not hand the frame over: \(failure.headline) — trying again on the next refresh")
    }

    private func noteRecovery() {
        guard let skipped = failures.recovered() else { return }
        Diagnostics.warn("Handing frames over has recovered (\(skipped) were skipped)")
    }
}

// MARK: - 閉じようとしたとき

extension SharedFrameStage {
    /// × が通る。**`⌘W` はメインメニューを組んだ日に通る** — 割り当てを配るのは
    /// メニューなので、道具が窓だけを出しているいまは配送されない。
    ///
    /// **問いを持っているなら、ここでは閉じない。** 確かめてから知らせ、実際に畳むのは
    /// 受け取った側である — 見張りは子を止め、区画を片付けてから畳む必要がある
    /// ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    ///
    /// 持っていなければ `true`。**AppKit の既定を変えない** — 窓を持つ側が終わり方を
    /// 決めていない場合に、閉じられない窓を作る理由が無い。
    ///
    /// `close()` はこの経路を通らない (delegate を経ずに閉じる) ので、後始末が問いを
    /// もう一度出すことはない。
    fileprivate func shouldClose(_ sender: NSWindow) -> Bool {
        guard let question = closeQuestion else { return true }
        // **問いを二重に出さない。** 下りている間 AppKit は親窓の操作を吸うが、閉じるよう
        // 頼む経路は残る (`performClose(_:)` など)
        guard sender.attachedSheet == nil else { return false }
        presentQuestion(question, sender) { [weak self] confirmed in
            guard confirmed else { return }
            self?.onCloseConfirmed?()
        }
        return false
    }

    /// 窓が閉じられた。**問いを繋いでいない窓でも、駆動はここで畳む。**
    ///
    /// 表示のリフレッシュは**画面**に紐づいているので、窓が消えても止まらない — 閉じた窓の
    /// 面へ差し出し続け、しかも見えない面への差し出しは待たされる。`close()` を通らずに
    /// 閉じられる経路 (問いを繋がずに出した窓の ×) を、費用だけ払い続ける形にしない (#826)。
    fileprivate func willClose() {
        screenLink.invalidate()
    }
}

// MARK: - 打ち切られた差し出し

extension SharedFrameStage: SettlementObserver {
    /// 差し出しの投入の結末が届いた ([#2735])。
    ///
    /// **打ち切られた投入が、いま記している最後の差し出しなら記しを戻す。** 次のリフレッシュが
    /// 普段の経路で同じ枚を出し直す — 書き手が書くのをやめていても、枚数が進むのを待たない。後の差し出しが
    /// 記し直していれば、前の打ち切りは見送る (後の絵が既に出ている)。打ち切りの無い結末では何もしない。
    ///
    /// **結末を失った差し出しも出し直す** (``RenderDevice/undelivered(_:)``)。`dropped` は記帳を取り消す
    /// 口のための答えで、正しく済んだ中身を潰さないよう、確かめられないものを正常の側へ倒している
    /// (#2199)。台は同じ絵をもう一度出すだけなので、倒し違えても差し出しが 1 回増えるだけで済む。
    ///
    /// 世代を乗り換えた後に前の世代の差し出しの結末が届いても、戻すのは記しだけで、出るのはいまの
    /// 世代の最新の枚である。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    func submissionSettled(_ submission: UInt64, dropped: Bool) {
        guard submission == lastFrameSubmission,
            dropped || gpu.undelivered(submission) == true
        else { return }
        lastFrame = 0
    }
}

/// 道具の窓が新しい世代の絵を受け取れないと、道具だけが知る形 ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。
///
/// 乗り換えの合図が来ないので、知らせないと前の世代が残り、プレビューの「起こしている」が終わらない。
/// **1 枚も焼かない形は含めない** — `setup()` が長いのと固まったのとは時計なしに見分けられず、
/// 時計で見切らない (ADR-0032 決定 3)。
public enum UndeliverableGeneration: Sendable, Equatable {
    /// 目録が読めない (版が違う・形が違う)。**台は理由と候補を端末へ名乗り済み** (#2889)。
    case unreadableManifest
    /// 目録がファイルとして読めない (権限・置き場がディレクトリ)。**台は理由を端末へ名乗り済み。** 版の形とは関係が無い。
    case unreadableFile
    /// 目録は読めたが、番号の面を 1 枚も引けない。**台は何も言っていない。**
    case noSurface
}
