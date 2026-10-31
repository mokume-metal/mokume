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
        ///
        /// **全画面の頼み (``SketchSettings/fullScreen(_:)``) にも、同じ窓だけが同じ規律で従う**
        /// (``SharedFrameStage/followRequestedFullScreen(of:)``・[#2188](https://github.com/mokume-metal/mokume/issues/2188))。
        var followsRequestedSize = false
        /// 作品の窓が頼まれた大きさで置き直されたとき、その真下へ置き直すか。
        ///
        /// **プレビューだけが置き直す。** 作品の窓が描く大きさ × 倍率で開くので、既定の
        /// 大きさを前提にした初めの位置 (``nudge``) のままだと、作品の窓が高いスケッチで
        /// 2 枚が重なる (``WindowPlacement/placeBeneathArtwork(_:window:autosaveName:defaults:)``)。
        var placesBeneathRequestedArtwork = false
        /// スケッチがファイルを選ばせるダイアログ (``SketchPart/selectInput(_:)``) を頼んだら、この窓が出すか。
        ///
        /// **作品の窓だけが出す** ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。作品の窓とプレビューは
        /// 同じ面の頼みを読むので、両方が出すとパネルが 2 枚出る。作品の窓は直に走らせた窓と同じ見え方で、
        /// ダイアログもそこに出る。
        var showsSelectionDialogs = false
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
        /// 作品の窓を全画面にするよう頼むディスプレイ。**頼まない子・名乗らない子 (古いライブラリ) なら `nil`**
        /// ([#2188](https://github.com/mokume-metal/mokume/issues/2188))。
        let fullScreenDisplay: FullScreenDisplay?
        /// 目録を置いた子の番号。**名乗らない子 (古いライブラリ) なら `nil`** (#2982)。
        let pid: Int32?
    }

    /// 全画面にするディスプレイ。``SharedFrameSurface/FullScreenDisplay``。
    typealias FullScreenDisplay = SharedFrameSurface.FullScreenDisplay

    /// 全画面に触れる口。**検査から差し替える** — 既定のままでは、検査を走らせた機械の画面が全画面の
    /// 操作スペースへ切り替わる (`SketchApplication.enterFullScreen` と同じ流儀)。
    struct FullScreenAccess {
        /// 頼まれたディスプレイの画面を、いま繋がっている中から引く。外れていれば `nil`。
        var screen: @MainActor (FullScreenDisplay) -> NSScreen? = { request in
            NSScreen.screens.first { $0.screenID == request.screenID }
        }
        /// 窓がいる画面の識別子 (`CGDirectDisplayID`)。画面に出ていなければ `nil`。
        var windowScreenID: @MainActor (NSWindow) -> UInt32? = { $0.screen?.screenID }
        /// 窓がいま全画面か。
        var isFullScreen: @MainActor (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) }
        /// 窓を全画面にする。**窓が画面に出てから呼ぶ** (`toggleFullScreen` は出ている窓にしか効かない)。
        var enter: @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) }
        /// 全画面の窓を抜けさせる。抜け終わりは窓の delegate が受ける (``SharedFrameStage/didExitFullScreen()``)。
        var leave: @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) }
    }

    /// 全画面に触れる口。**検査から差し替える。**
    var fullScreen = FullScreenAccess()
    /// 窓へ当てた全画面の頼み。**同じ頼みを 2 度当てないための覚えで、この台が生きている間 (見張り 1 回の
    /// 間) だけ持つ** ([#2188](https://github.com/mokume-metal/mokume/issues/2188))。
    ///
    /// ``WindowPlacement/honour(_:in:autosaveName:defaults:warn:)`` と違い `UserDefaults` には残さない —
    /// 全画面と置いた画面は窓の寿命に紐づく ([ADR-0032] 文脈) ので、見張りを止めて起こし直したら、また頼みどおりに
    /// 出す。手で全画面を抜けた窓へ、同じ頼みの世代が来ても戻さないのは、この覚えが頼みそのものを持つからで、
    /// 窓がいま全画面かは見ない。頼みが無い世代が来たら捨てる (あとで同じ頼みが戻ってきたら、変わったと読む)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private(set) var appliedFullScreen: FullScreenDisplay?
    /// 全画面を抜け終えたら入り直す頼み。**別のディスプレイの全画面にいる窓を移すとき**だけ持つ
    /// (全画面の窓は動かせないので、抜けてから移す)。
    private var pendingFullScreenEntry: FullScreenDisplay?

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
    /// 閉じる問いのシートを出している間か。**付いているシートが問いのものか、ファイルを選ばせるものかを分ける**
    /// (``shouldClose(_:)``)。
    private var isAskingToClose = false
    /// 問いを持っているか。**検査から見る** (`SharedFramePreview.hasPanel` と同じ扱い)。
    var asksBeforeClosing: Bool { closeQuestion != nil }

    /// 差し出し元を掴めているか。**検査から見る** — 目録を読み直せたかどうかは、外からは
    /// 「絵が出るか」でしか見えない。
    var hasSource: Bool { source != nil }

    /// まだ出していない世代を控えているか。**検査から見る。**
    var hasIncoming: Bool { incoming != nil }

    /// いま映している世代の目録が名乗った子の番号。**検査から見る。**
    var displayedPID: Int32? { source?.pid }

    /// 乗り換えた直前の世代を、常駐させたまま持っているか (``superseded``)。**検査から見る。**
    var holdsSupersededSource: Bool { superseded != nil }

    /// 面を引いた (`IOSurfaceLookup`) 回数。出している世代と控えている世代の合計。**検査から
    /// 見る** — 番号の組が変わらない間は、リフレッシュを重ねても増えないこと
    /// ([#2368](https://github.com/mokume-metal/mokume/issues/2368))。
    var surfaceLookups: Int {
        retiredLookups + (source?.lookup.lookups ?? 0) + (incoming?.lookup.lookups ?? 0)
            + (superseded?.lookup.lookups ?? 0)
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
    ///
    /// **引数は、乗り換えた世代の目録が名乗った子の番号** ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    /// 名乗らない子 (古いライブラリ) は `nil`。受け取る側は、番号があれば待っている世代のものかを照合する。
    var onGenerationPromoted: ((Int32?) -> Void)?
    /// 控えた世代の絵を、この台が受け取れないことの知らせ ([#2928])。
    ///
    /// **乗り換えの知らせが来ない形のうち、道具だけが知る 2 つ** (``UndeliverableGeneration``)。
    /// 子は自分の目録が読まれないことも、面が引けないことも知らないので、子からの申告は届かない。
    /// **知らせるだけで、前の世代を畳むのはここではない** (``onGenerationPromoted`` と同じ分担)。
    /// どの世代の知らせかは、目録が番号を名乗れば照合できる (下の引数)。名乗らなければ、受け取る側が
    /// 「乗り換えを待っている世代」だけを見る。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    ///
    /// **2 つ目の引数は、読めた目録が名乗った子の番号** (#2982)。読めない目録の知らせ・番号を名乗らない
    /// 子の目録では `nil`。
    var onGenerationUndeliverable: ((UndeliverableGeneration, Int32?) -> Void)?
    /// 出す世代の最初の 1 枚を画面へ出したことの知らせ ([#2875])。
    ///
    /// **入れ替わりの知らせとは別に持つ。** 最初の世代は絵が来る前に採用されるので
    /// (``promoteIfReady()``)、入れ替わりの知らせでは子の `setup()` の間を覆えない。
    /// 受け取る側 (プレビューの「起こしている」表示) が畳む合図はこちらである。
    ///
    /// **引数は、1 枚目を出した世代の目録が名乗った子の番号** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// 名乗らない子 (古いライブラリ) は `nil`。見張りは、子が絵を出す前に終わったかをこの知らせで読む
    /// (目録は `setup()` より前に置かれるので、乗り換えの知らせは絵が出た時点を指さない)。
    ///
    /// [#2875]: https://github.com/mokume-metal/mokume/issues/2875
    var onGenerationShown: ((Int32?) -> Void)?
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
    /// 出している世代のスケッチが、いま待っているファイルを選ばせる頼みと、その世代の子の番号。**面の属性から読む**
    /// (``SharedFrameSurface/selectInputAttribute``・[#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    /// 読み方は ``pointerLockRequested`` と同じで、**自分が映す世代の頼みに従う**。検査から読む。
    private(set) var selectionRequested: (pid: Int32?, request: SelectionBroker.Request)?
    /// ファイルを選ばせるダイアログの出し方。**検査から差し替える** — 本物の `NSOpenPanel` は人の操作を待つ。
    var filePicker: any FilePicker = OpenPanelPicker()
    /// いま出している (出していた) ダイアログ。**頼みが面から消えるまで持つ** — 答えた後も、頼みが残っている間は
    /// 結果を送り直すため、また同じ頼みを出し直さないための印でもある。
    private var shownSelection: ShownSelection?

    private struct ShownSelection {
        /// 頼みの出どころの世代の子の番号。
        let pid: Int32?
        /// 頼みの通し番号。
        let serial: Int
        /// 結果ごと捨てて閉じる口。
        var dismiss: @MainActor () -> Void
        /// 利用者が答えた結果と、最後に子へ送った時刻。**答えるまでは `nil`。** 取り消しは `path` が `nil`。
        var answer: (path: String?, sentAt: CFTimeInterval)?
    }

    /// いまの時刻 (秒)。**検査から差し替える** — 結果の送り直しの間合いを、待たずに進める。
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// 子へ送った結果を、頼みがまだ面に残っているとき送り直す間合い (秒)。
    ///
    /// **結果の 1 行は落ちうる** — 子の標準入力の管が一杯のとき・書き残しの間・子の合流点の溢れ・外から止められて
    /// いる間 ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。落ちると頼みが面に残ったままになるので、
    /// それを「届かなかった」の印にして送り直す。間合いは**普段の届き方より十分に長く**取る: 届けば子は次の
    /// フレームで待ちを終え、頼みを消した絵を差し出し、台がそれを読むまでに数フレームかかる。その間に送り直しても
    /// 子は番号の違う (終わった) 結果として黙って捨てるので害は無いが、毎フレーム送る理由も無い。半秒なら、
    /// 落ちた結果は次の瞬きの間に届き、管を埋めている子 (重いフレームの最中) に毎秒 2 行以上は積まない。
    static let selectionResendInterval: CFTimeInterval = 0.5
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

        func windowDidExitFullScreen(_ notification: Notification) {
            stage?.didExitFullScreen()
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
        //
        // **渡す `InputState` は溜め置きでしかない** ([#2777])。出来事は `relay` の線で子へ渡り、
        // こちらの状態は誰も流し込まない (`beginFrame` を呼ぶ者が居ない)。上限 (4096 件) に達すると
        // 最も古い 1 件を溢れの経路で当て、その和が収まらなければ `Dropped the input event` と警告
        // しうるが、それは 4096 件前の出来事についてで、子へ届いた出来事を指さない
        //
        // [#2777]: https://github.com/mokume-metal/mokume/issues/2777
        let view = SketchSurface(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size),
            device: gpu.device, input: InputState(), canvasSize: (1, 1))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
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

    /// 表示の予定の時刻は使わない (この台は絵を作っていない・``ScreenDisplayLinkOwner``)。
    func displayLinkFired(at displayTime: Double?) {
        displayLinkFired()
    }

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
            self.followSelectionRequest()
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
                    // 1 枚目を出した世代が死んでも、見張りは前の版を戻さない。直前の世代はもう要らない (#3172)
                    releaseSuperseded()
                    onGenerationShown?(source.pid)
                }
            }
            noteRecovery()
        } catch {
            noteFailure(error)
        }
    }

    // MARK: - ファイルを選ばせる

    /// スケッチのファイルを選ばせる頼みを、この窓で出す ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
    ///
    /// **出すのは `showsSelectionDialogs` の窓だけで、同じ頼み (子の番号と通し番号の組) は 1 度だけ出す。**
    /// 頼みが無くなった・別の頼みになったら、出しているダイアログは結果ごと捨てて閉じる。結果は入力の出来事を
    /// 1 行にして子へ渡す (``onInput``) — 子が結果で待ちを終える。**頼んだ世代が入れ替わった後に届いた結果は
    /// 子へ渡さない** (新しい子は待っていない)。
    ///
    /// **結果には頼みの通し番号を載せ、頼みが面に残っている間は送り直す** (``selectionResendInterval``)。
    /// 1 行が落ちても待ちは永久には続かない。子は番号が違う結果を黙って捨てるので、送り直しが重なっても待ちを
    /// 終えるのは 1 度である。
    private func followSelectionRequest() {
        guard look.showsSelectionDialogs else { return }
        let wanted = selectionRequested
        if let shown = shownSelection,
            wanted == nil || wanted?.pid != shown.pid || wanted?.request.serial != shown.serial
        {
            shown.dismiss()
            shownSelection = nil
        }
        resendSelectionAnswer()
        guard let wanted, shownSelection == nil, let view, view.window != nil else { return }
        let (pid, serial) = (wanted.pid, wanted.request.serial)
        // `pick` が同じ呼び出しのうちに結果を返した検査の口のために、先に控えてから出す
        shownSelection = ShownSelection(pid: pid, serial: serial, dismiss: {})
        let dismiss = filePicker.pick(prompt: wanted.request.prompt, over: view.window) {
            [weak self] path in
            self?.answerSelection(path, pid: pid, serial: serial)
        }
        shownSelection?.dismiss = dismiss
    }

    /// 利用者がダイアログに答えた (取り消しは `nil`)。子へ 1 度送り、頼みが残る間の送り直しの印を立てる。
    private func answerSelection(_ path: String?, pid: Int32?, serial: Int) {
        guard let shown = shownSelection, shown.pid == pid, shown.serial == serial,
            shown.answer == nil
        else { return }
        shownSelection?.answer = (path, now())
        sendSelectionAnswer(path, pid: pid, serial: serial)
    }

    /// 結果を 1 行にして子へ渡す。**頼んだ世代が入れ替わっていたら渡さない。**
    private func sendSelectionAnswer(_ path: String?, pid: Int32?, serial: Int) {
        guard source?.pid == pid else { return }
        onInput?(InputEvent.fileSelected(path: path, serial: serial).wireLine)
    }

    /// 答えた結果を、頼みがまだ面に残っていて、間合いが過ぎていれば送り直す。
    private func resendSelectionAnswer() {
        guard let shown = shownSelection, let answer = shown.answer,
            now() - answer.sentAt >= Self.selectionResendInterval
        else { return }
        shownSelection?.answer = (answer.path, now())
        sendSelectionAnswer(answer.path, pid: shown.pid, serial: shown.serial)
    }

    /// 窓の × が押されたとき、**ファイルを選ばせるシートが付いているなら、それを取り消す。**
    ///
    /// シートが付いている間 `windowShouldClose` は閉じる問いを出さないので、黙って × が効かなくなる
    /// ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。取り消しは利用者がダイアログを取り消したのと
    /// 同じ結果として子へ渡す (待ちが `nil` で終わる)。
    ///
    /// - Returns: 取り消したか。答え済みの (もう閉じている) ダイアログ・出していないときは `false`。
    private func cancelOpenSelectionDialog() -> Bool {
        guard look.showsSelectionDialogs, let shown = shownSelection, shown.answer == nil else {
            return false
        }
        shown.dismiss()
        answerSelection(nil, pid: shown.pid, serial: shown.serial)
        return true
    }

    // MARK: - 速さ

    /// いま名乗ってよい速さ。**しばらく新しい絵が来なければ `nil`** (``RemoteTempo``)。
    var numbers: FrameNumbers? { tempo.numbers(now: CACurrentMediaTime()) }

    /// 走らせている子が言った警告。**古くなっても消えず、次に子が入れ替わって絵が来るまで残る** (#3087)。
    /// 1 つも言っていなければ `nil`。
    private(set) var warnings: WarningSummary?

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
        // 捕まえの要求も同じ面に載っている。速さが載っていない面でも読む。**手放した世代の面からは
        // 読まない** — 畳まれる世代の最後の数枚で頼みが戻る (#2983)
        if !isReleased(source) {
            pointerLockRequested = SharedFrameSurface.pointerLockRequested(on: surface)
            cursorHiddenRequested = SharedFrameSurface.cursorHiddenRequested(on: surface)
            selectionRequested = SharedFrameSurface.selectionRequest(on: surface).map {
                (source?.pid, $0)
            }
        }
        let numbers = SharedFrameSurface.numbers(on: surface)
        // **警告の控えは、数字が載っていない面でも新しい世代の値にする。** 速さを載せない古いライブラリの子は
        // ここで抜けるので、先に抜けると前の世代の警告が残る (#3087)。載っていなければ空。
        // **手放した世代の面からは読まない** — 畳まれる世代の最後の数枚で、新しい世代の控えを上書きしない
        if !isReleased(source) {
            warnings = numbers.flatMap { numbers in
                guard numbers.warningCount > 0, let last = numbers.lastWarning else { return nil }
                return WarningSummary(count: numbers.warningCount, last: last)
            }
        }
        guard let numbers else { return }
        tempo.record(numbers, at: CACurrentMediaTime())
    }

    // MARK: - 差し出し元

    /// 区画が変わっていれば読み直す。
    ///
    /// **更新時刻で見る。** 毎フレーム読み解くのは無駄で、中身が変わるのは子が入れ替わった
    /// ときだけである。
    private func reloadSourceIfChanged() {
        guard let manifest = manifest.changed() else { return }
        remember(manifest)
        // **この台が映さない世代の目録は採らない** (``acceptsGeneration``)。読んだ印は付いている (同じ改訂を
        // 読み直さない) ので、採り直す契機は ``returnToGeneration(pid:)`` だけである
        if let accepts = acceptsGeneration, !accepts(manifest.pid) { return }
        adopt(manifest)
    }

    /// この台が、どの世代の目録を採るかを決める関所 ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// **目録は 1 枚で、最後に書いた子のもので上書きされる。** 試聴の間は、作品の窓が本番の目録だけを、プレビューが
    /// 試聴の子の目録だけを採りたい。引数は読んだ目録が名乗る子の番号 (``SharedFrameSurface/Manifest/pid``) で、
    /// **番号を名乗らない子 (古いライブラリ) は `nil`** — 世代を区別できないので、返す値は見張りが決める。
    /// 設定しなければ (既定) どの目録も採る。
    ///
    /// **目録の置き方も形も変えない。** 区画の書き手の番号を、読み手が選ぶだけである。
    var acceptsGeneration: ((Int32?) -> Bool)?

    /// 読んだ目録を、書き手の子の番号ごとに最後のものだけ覚える。**関所が弾いた目録も覚える**
    /// (``returnToGeneration(pid:)`` が戻る先)。古いほうから押し出す。
    private var remembered: [(pid: Int32, manifest: SharedFrameSurface.Manifest)] = []
    /// 覚える目録の上限。試聴で子が入れ替わるたびに増えるので、無限に溜めない。
    private static let rememberedLimit = 4
    /// 押し出さずに覚え続ける世代の子の番号 (``holdGeneration(pids:)``)。
    private var heldPIDs: Set<Int32> = []

    private func remember(_ manifest: SharedFrameSurface.Manifest) {
        guard let pid = manifest.pid else { return }
        remembered.removeAll { $0.pid == pid }
        remembered.append((pid, manifest))
        while remembered.count > Self.rememberedLimit,
            let oldest = remembered.firstIndex(where: { !heldPIDs.contains($0.pid) })
        {
            remembered.remove(at: oldest)
        }
    }

    /// 押し出さずに覚えておく世代を決める ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// 試聴に入ったとき、本番の世代 (作品の窓が映す版。乗り換えを待つ間は 2 つ) の目録を留める。試聴の子が
    /// 何度入れ替わっても、出る (``returnToGeneration(pid:)``) ときの戻り先を失わない。空で外す。
    func holdGeneration(pids: [Int32]) {
        heldPIDs = Set(pids)
    }

    /// 覚えている目録の世代へ戻る ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// 目録は上書きされて読み直せないので、試聴を出るときに、プレビューを本番の絵へ戻すために使う。
    /// 控えるだけで、乗り換えるのは普段の経路 (``promoteIfReady()``) である — 戻り先が 1 枚書いていれば
    /// 次のリフレッシュで映る。**関所は通らない** (戻ると決めたのは見張りである)。
    ///
    /// - Returns: 戻れる (もう映している・控えた) なら `true`。覚えが無い、面をもう引けない (置いた子が
    ///   消えた) なら `false` で、何も動かさない — 引けない目録を控えると、乗り換えないまま受け取れないと
    ///   知らせることになる (``adopt(_:)``)。
    @discardableResult
    func returnToGeneration(pid: Int32) -> Bool {
        if source?.pid == pid {
            // 既に映している。別の世代を控えていたなら捨てる
            if let waiting = incoming {
                retiredLookups += waiting.lookup.lookups
                try? gpu.releaseResidency(of: waiting.frames.values.map(\.texture))
                incoming = nil
            }
            return true
        }
        // **区画の目録が今もその世代のものなら、覚えより区画を採る。** 同じ子が目録を書き直した (大きさの頼みを
        // 変えた、など) とき、覚えは古い改訂で、区画に在るのが新しい改訂である — 古い改訂を優先すると、戻った先が
        // 頼みの古い絵になる。覚えから押し出されていた世代も、これで読み直せる。読んだ改訂は印が付いて二度と
        // 配られない (``reloadSourceIfChanged()``) ので、関所に弾かれた間に読んだだけの世代は、ここで拾わなければ
        // 次に書き直されるまで戻れない
        guard
            let manifest = SharedFrameSurface.readManifest(at: facet).flatMap({ $0.pid == pid ? $0 : nil })
                ?? remembered.first(where: { $0.pid == pid })?.manifest,
            manifest.ids.contains(where: { IOSurfaceLookup($0) != nil })
        else { return false }
        adopt(manifest)
        return incoming?.pid == pid
    }

    /// 新しい差し出し元を**控える。** 出している世代には触らない。
    ///
    /// 乗り換えるのは ``promoteIfReady()`` で、控えた世代が 1 枚書いてからである。
    private func adopt(_ manifest: SharedFrameSurface.Manifest) {
        // 見張りが「乗り換えない」と決めた世代 (起動に失敗して前の版を戻した回の、死んだ子) の目録は採らない
        if let pid = manifest.pid, abandonedPIDs.contains(pid) { return }
        // **控えていた世代は捨てる。** 重ねるのは 2 つまでで、まだ 1 枚も出していない
        // 世代を積み上げても、出る絵は増えない
        if let waiting = incoming {
            retiredLookups += waiting.lookup.lookups
            try? gpu.releaseResidency(of: waiting.frames.values.map(\.texture))
            incoming = nil
        }
        var frames: [UInt32: Frame] = [:]
        var anyLookedUp = false
        for id in manifest.ids {
            let made = makeFrame(id: id, width: manifest.width, height: manifest.height)
            anyLookedUp = anyLookedUp || made.lookedUp
            guard let frame = made.frame else { continue }
            frames[id] = frame
        }
        guard !frames.isEmpty else {
            // **直前の絵はそのまま残す** (決定 6)。引けなかったのは、置いた側が既に居ない (子の側で
            // 決まる — 道具の側の「子の離脱」が畳む) か、子は生きているのに引けない (面が全域でない
            // など・道具の側だけが知る) か、面は引けたが絵にできない (道具の GPU の事情) かのどれかで、
            // あとの 2 つは知らせないと乗り換えの合図が来ない
            // ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。どれかは受け取る側が決める
            //
            // **目録は読めたので、寸法は分かる。** 受け取る側が前の世代を畳むなら、入力を受けるのは
            // この寸法の新しい子なので、入力の写し (キャンバスの寸法) を追随させる。前の世代のカーソルの
            // 頼みは下ろす (``releaseInheritedRequests()``)
            view?.setCanvasSize((manifest.width, manifest.height))
            releaseInheritedRequests()
            onGenerationUndeliverable?(anyLookedUp ? .unusableSurface : .noSurface, manifest.pid)
            return
        }
        incoming = Source(
            ids: manifest.ids, lookup: SharedFrameSurface.Lookup(ids: manifest.ids),
            width: manifest.width, height: manifest.height, frames: frames,
            windowScale: manifest.windowScale, fullScreenDisplay: manifest.fullScreenDisplay,
            pid: manifest.pid)
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
        // **前の面を常駐から外す。** 外さないと、見張っている間ずっと死んだ面が積み上がる。ただし**直前の
        // 世代は、乗り換えた世代が 1 枚目を出すまで持つ** (``superseded``・#3172)。もう 1 つ前の世代はここで外す
        releaseSuperseded()
        superseded = source
        source = waiting
        incoming = nil
        // **前の世代の警告は捨てる** (#3087)。新しい世代の値は、同じリフレッシュの ``readNumbers(from:in:)`` が
        // 面から読み直す。数字の載らない面 (古いライブラリの子) が読み直しの前に抜けても、前の世代のものを残さない
        warnings = nil
        // 手放した番号の世代へ乗り換えたときだけ、番号を残す (それ以外なら、もう要らない)。面の番号の覚えは
        // 乗り換えで必ず捨てる (使い回しで、後の生きた世代の頼みを読まないままにしない)
        if let pid = waiting.pid, relinquishedPIDs.contains(pid) {} else { relinquishedPIDs.removeAll() }
        relinquishedLegacyIDs = nil
        abandonedPIDs.removeAll()
        // 触った操作を写す規則は描く解像度に依る (レーン 4 で使う)
        view?.setCanvasSize((waiting.width, waiting.height))
        followRequestedSize(of: waiting)
        followRequestedFullScreen(of: waiting)
        // **枚数の数え直しに備える。** 新しい子は 1 から数えるので、前の子の枚数を
        // 覚えたままだと、そこへ追い付くまで 1 枚も出さないことになる (速さも同じで、
        // 追い付くまで前の子の数字を名乗り続けることになる)
        // 捕まえの要求も同じ理由で、新しい世代の面から読み直す (#1144)。乗り換えるのは新しい
        // 世代が 1 枚焼いた後なので、同じリフレッシュの ``readNumbers(from:)`` が読む — 要求して
        // いない世代なら、そこで外れる
        lastFrame = 0
        lastSeenFrame = 0
        shownCurrentGeneration = false
        onGenerationPromoted?(waiting.pid)
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

    /// 出す世代が頼む全画面を、作品の窓へ当てる ([#2188](https://github.com/mokume-metal/mokume/issues/2188))。
    ///
    /// **当てるのは作品の窓だけで (``Look/followsRequestedSize``)、頼みが変わったときだけである**
    /// (``appliedFullScreen``)。保存のたびに当てると、手で全画面を抜けた窓が戻る — 見張りから本番を回す窓で、
    /// 保存で全画面が外れても戻ってもならない ([ADR-0032] 決定 1)。
    ///
    /// - 頼みが無い世代 (全画面を頼まない子・古いライブラリの子): 何もしない。いま全画面なら、そのままにする
    /// - 頼まれた画面が引けない: 窓のままにして 1 行言う。**覚えない** — 次の世代で引けたら当てる
    /// - 窓が別の画面の全画面にいる: 抜けてから移して入り直す (``didExitFullScreen()``)
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private func followRequestedFullScreen(of generation: Source) {
        guard look.followsRequestedSize, let window else { return }
        guard let request = generation.fullScreenDisplay else {
            appliedFullScreen = nil
            pendingFullScreenEntry = nil
            return
        }
        guard request != appliedFullScreen else { return }
        guard let screen = fullScreen.screen(request) else {
            warn(
                "The sketch asks for full screen on \(request.label), but no such display is "
                    + "connected to this machine — leaving the window as it is")
            return
        }
        appliedFullScreen = request
        pendingFullScreenEntry = nil
        if fullScreen.isFullScreen(window) {
            // 全画面の窓は動かせない。**同じ画面の全画面なら、そのまま** (頼みどおりである)
            guard fullScreen.windowScreenID(window) != screen.screenID else { return }
            pendingFullScreenEntry = request
            fullScreen.leave(window)
            return
        }
        enterFullScreen(window, on: screen)
    }

    /// 窓を頼まれた画面へ移して、全画面にする。
    private func enterFullScreen(_ window: NSWindow, on screen: NSScreen) {
        // **全画面にできる窓であることを自分で言う。** 既定の動きに頼らない
        window.collectionBehavior.insert(.fullScreenPrimary)
        if fullScreen.windowScreenID(window) != screen.screenID {
            WindowPlacement.move(window, onto: screen)
        }
        fullScreen.enter(window)
    }

    /// 全画面を抜け終えた (窓の delegate から)。**別の画面へ頼みが変わっていたなら、そこで入り直す。**
    ///
    /// 手で抜けたときは持っている頼みが無く、何もしない (戻さない)。
    func didExitFullScreen() {
        guard let request = pendingFullScreenEntry, let window else { return }
        pendingFullScreenEntry = nil
        guard let screen = fullScreen.screen(request) else {
            warn(
                "The sketch asks for full screen on \(request.label), but no such display is "
                    + "connected to this machine — leaving the window as it is")
            return
        }
        enterFullScreen(window, on: screen)
    }

    /// 開く大きさの指定を覚える先。**検査から差し替える** — 既定のままだと、検査を走らせた
    /// プロセスの記憶に指定が残る。
    var defaults: UserDefaults = .standard

    /// 番号から面を引き、差し出せる形にする。
    ///
    /// - Returns: `lookedUp` は面を引けたか。引けても絵にできなければ `frame` は `nil` (道具の GPU の事情)。
    private func makeFrame(id: UInt32, width: Int, height: Int) -> (frame: Frame?, lookedUp: Bool) {
        guard let surface = IOSurfaceLookup(id) else { return (nil, false) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard
            let texture = gpu.device.makeTexture(
                descriptor: descriptor, iosurface: surface, plane: 0)
        else { return (nil, true) }
        gpu.makeResident(texture)
        return (Frame(texture: texture, width: width, height: height), true)
    }

    /// 前の世代のカーソルの頼み (捕まえる・隠す) を下ろす ([#2928])。
    ///
    /// **新しい世代の絵を受け取れないと知ったとき**に呼ぶ。見張りがその世代へ乗り換えたとみなして
    /// 前の世代を畳むと、前の世代はもう絵を書かないので、頼みを読み直す契機 (``readNumbers(from:in:)``
    /// は新しい枚数のときだけ読む) が来ず、窓はカーソルを捕まえたまま・隠したままになる。
    ///
    /// **写しを空にするだけでは足りない** ([#2983])。止めるまでに前の世代が書く 1 枚 (止まらない子は
    /// 数秒書き続ける) で、同じ面から頼みを読み直して戻る。だから**手放した世代の面を覚え**
    /// (``relinquishedPIDs``・``relinquishedLegacyIDs``)、その世代からは次に乗り換えるまで頼みを読まない。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    private func releaseInheritedRequests() {
        pointerLockRequested = false
        cursorHiddenRequested = false
        selectionRequested = nil
        // **番号を名乗る世代は子の番号で、名乗らない世代 (古いライブラリ) は面の番号で覚える**
        if let pid = source?.pid {
            relinquishedPIDs.insert(pid)
        } else {
            relinquishedLegacyIDs = source?.ids
        }
    }

    /// 番号を名乗らない世代 (古いライブラリ) の、頼みを手放した面の番号。**その世代が出している間は、頼みを
    /// 読まない。** 面の番号は再利用されうるので、**乗り換えで捨てる** (``promoteIfReady()``)。
    private var relinquishedLegacyIDs: [UInt32]?
    /// 見張りが手放した世代の子の番号 ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    /// **まだ採っていない目録も、この番号を名乗れば生まれたときから手放した扱いにする** — 離脱の知らせが
    /// 台の拍より先に来ると、台は死んだ子 (1 枚書いてすぐ死んだ) へ乗り換えてその頼みを読む。別の番号の
    /// 世代へ乗り換えたら捨てる (番号の使い回しで、無関係な世代を手放したことにしない)。
    private var relinquishedPIDs: Set<Int32> = []

    /// この世代の頼みを読まないか。
    private func isReleased(_ generation: Source?) -> Bool {
        guard let generation else { return false }
        if let pid = generation.pid { return relinquishedPIDs.contains(pid) }
        return relinquishedLegacyIDs == generation.ids
    }

    /// 見張りが乗り換えないと決めた世代の子の番号 ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// **乗り換えで捨てる。** 乗り換えの無いまま起動の失敗が重なっても溜まりすぎず、番号が一周しても新しい子の
    /// 目録を捨てないよう、見張りが新しい子を起こしたときにその番号を外す (``expectGeneration(pids:)``)。
    private var abandonedPIDs: Set<Int32> = []

    /// 乗り換えた直前の世代。**乗り換えた世代が 1 枚目を出すまで、常駐を外さずに持つ** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// 乗り換えた世代が 1 枚も出さずに死ぬと、見張りは起動に失敗した版を捨てて前の版を現役に戻す。台は
    /// その子の目録へ乗り換え済みでも、動いている前の版へ映し直せなければならない
    /// (``abandonIncoming(pids:)``)。目録は死んだ子のもので上書きされ、前の版は目録を置き直さないので、
    /// 乗り換えの時点で持っているものを手放さないのが唯一の道である。**1 枚目を出したら外す** (見張りが
    /// 前の版を戻すのも、1 枚目の前に終わった子についてだけ)。次の乗り換えでも外す。
    private var superseded: Source?

    /// 乗り換えた直前の世代の常駐を外す。
    private func releaseSuperseded() {
        guard let previous = superseded else { return }
        retiredLookups += previous.lookup.lookups
        try? gpu.releaseResidency(of: previous.frames.values.map(\.texture))
        superseded = nil
    }

    /// 見張りが、乗り換えないと決めた ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// **起動に失敗した新しい版を捨てて、前の版を現役に戻した回に呼ぶ。** 失敗した子が 1 枚書いてから死ぬと、
    /// 台はその子の目録へ乗り換え、動いている前の版の代わりに死んだ子の最後の絵を映す。次の 3 つを同じ番号で行う。
    /// - まだ採っていない目録がその番号なら採らない (``abandonedPIDs``)
    /// - 控えている世代がその番号なら捨てる
    /// - **映している世代がその番号なら、直前の世代 (``superseded``) へ映し直す。** 乗り換えは済み、描画が
    ///   見送られた (面が取れない拍) 子でも、1 枚目の合図は鳴らない — 控えを捨てるだけでは覆えない。
    ///   直前の世代の常駐を外していないので、そのまま映せる。番号を名乗らない世代 (古いライブラリ) は
    ///   照合できないので映し直さない
    func abandonIncoming(pids: [Int32]) {
        abandonedPIDs.formUnion(pids)
        if let waiting = incoming, let pid = waiting.pid, pids.contains(pid) {
            retiredLookups += waiting.lookup.lookups
            try? gpu.releaseResidency(of: waiting.frames.values.map(\.texture))
            incoming = nil
        }
        guard let dead = source, let pid = dead.pid, pids.contains(pid), let previous = superseded
        else { return }
        retiredLookups += dead.lookup.lookups
        try? gpu.releaseResidency(of: dead.frames.values.map(\.texture))
        source = previous
        superseded = nil
        // 死んだ世代の警告を捨てる。前の版の値は、次のリフレッシュが前の版の面から読み直す (#3087)
        warnings = nil
        // 乗り換えと同じく、枚数の数え直しと窓の大きさの追随を、映し直した世代に対して行う。前の版は
        // もう 1 枚目を出している (出していなければ見張りは戻さない) ので、合図は鳴らし直さない
        lastFrame = 0
        lastSeenFrame = 0
        shownCurrentGeneration = true
        view?.setCanvasSize((previous.width, previous.height))
        followRequestedSize(of: previous)
    }

    /// 見張りが新しい子を起こした ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// **この番号を、乗り換えないと決めた世代 (``abandonedPIDs``) と手放した世代 (``relinquishedPIDs``) の
    /// 覚えから外す。** 番号は使い回されるので、起動に失敗した子の番号が残っていると、同じ番号を得た新しい子の
    /// 目録を ``adopt(_:)`` が黙って捨て、手放した番号が残っていると、新しい子を生まれたときから手放した扱いに
    /// して頼みを読まない。
    func expectGeneration(pids: [Int32]) {
        abandonedPIDs.subtract(pids)
        relinquishedPIDs.subtract(pids)
    }

    /// 見張りが、いま映している世代を手放したと知らされた ([#2983])。**頼みを下ろし、その世代の頼みを
    /// 次の乗り換えまで読まない。**
    ///
    /// 受け取れない知らせ (``releaseInheritedRequests()``) の経路は台が自分で気付いたが、次の 3 つは
    /// 台を通らない: 作り直した子が窓へ倒れた回・子が消えた回・乗り換えの合図が来ないまま次の保存が来て
    /// 映っている世代を畳んだ回。どれも畳まれた世代はもう絵を書かず、頼みを読み直す契機
    /// (``readNumbers(from:in:)`` は新しい枚数のときだけ読む) が来ないので、窓がカーソルを捕まえたまま・
    /// 隠したままになる。**最後の絵と入力の写しの寸法は残す** (ADR-0032 決定 6)。寸法を変える材料
    /// (新しい子の目録) が、この口には無い。
    ///
    /// **生きて書き続ける世代へ誤って当たると、その世代は次の乗り換えまで頼めない** — 捕まえは押し直す
    /// まで戻らない (``SketchSurface/followPointerLock(requested:)``)。呼ぶのは、見張りが畳む・居なくなったと
    /// 決めた世代についてだけである。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    ///
    /// **`pids` は手放す世代の子の番号** ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    /// 映している世代の目録が番号を名乗れば、手放す世代のときだけ下ろす — 映っている生きた世代に誤って
    /// 当てない。番号を名乗らない世代 (古いライブラリ) は照合できないので下ろす。まだ採っていない目録も、
    /// 手放した番号のものは生まれたときから手放した扱いにする。
    func relinquishSource(pids: [Int32]) {
        relinquishedPIDs.formUnion(pids)
        let matches = source?.pid.map { pids.contains($0) } ?? true
        if matches { releaseInheritedRequests() }
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
        releaseInheritedRequests()
        switch failure {
        case .cannotDecode: onGenerationUndeliverable?(.unreadableManifest, nil)
        case .cannotRead: onGenerationUndeliverable?(.unreadableFile, nil)
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
        //
        // **ただし付いているのがファイルを選ばせるシートなら、それを取り消して問いへ進む** — 黙って × が効かない
        // 窓にしない (#3062)。問いのシートが付いている間は、今までどおり受け流す
        if sender.attachedSheet != nil {
            guard !isAskingToClose, cancelOpenSelectionDialog() else { return false }
        }
        isAskingToClose = true
        presentQuestion(question, sender) { [weak self] confirmed in
            self?.isAskingToClose = false
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
    /// 面は引けたが、絵にできない (道具の GPU が面から質感を作れない)。版の形とは関係が無い。**台は何も言っていない。**
    case unusableSurface
}
