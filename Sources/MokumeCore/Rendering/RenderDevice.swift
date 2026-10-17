// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

// `@MainActor` はターゲットの既定隔離 (`Package.swift` の `.defaultIsolation`) と同じ意味で、
// 付けなくても隔離は変わらない。**明示しているのは release のテストビルドのため**である —
// `swift test -c release` では、この型を外から読むターゲット (`frame-rate-probe` や
// `@testable import` する検査) が module を deserialize する際に暗黙の既定隔離を見失い、
// `isolated deinit` が「隔離されていないクラスに付いている」として compile を止める
// (#761)。debug と製品の release では出ない。明示すれば取り込み側にも隔離が伝わる。

/// GPU 側の一式を束ねる — デバイス・コマンドの発行口・コマンドの置き場・リソースの常駐。
///
/// ## なぜ常駐をここに集めるのか
///
/// この世代の Metal では、コマンドが触るリソースを常駐させるのは呼び出し側の責務で、
/// 常駐していないリソースを読むと結果が未定義になる。**常駐の管理を各所に散らすと
/// 「バインドしたのに描かれない」形の、症状からは原因の見えない失敗になる。**
/// そこで確保したリソースは必ずここを通し、常駐の集合をこの型が持つ。
///
/// 集合は**寿命で 2 つに分けてある** — 確保したものが全部入る `residencySet` と、
/// 表示に差し出す面だけが入る `drawableResidency` である。差し出す面の環は Metal
/// 側が持っていて、面の大きさが変わると環ごと作り直される。混ぜると、古い面だけを
/// 畳む手が無い ([#357](https://github.com/mokume-metal/mokume/issues/357))。
///
/// ## 使い方
///
/// **作って、`gpu:` を取る初期化子へ手渡す。** コマンドの発行そのものは外へ開いていない
/// ので、外から書けるのはこの形である。1 枚だけ描く経路はこれで足りる。
///
/// ```swift
/// import Foundation
///
/// func renderOnce(to url: URL) throws {
///     let gpu = try RenderDevice()
///     let target = try RenderTarget(gpu: gpu, width: 1200, height: 800)
///     let canvas = try Canvas(target: target, gpu: gpu)
///     try canvas.draw {
///         canvas.background(26, 26, 31)
///         canvas.fill(255, 102, 51)
///         canvas.circle(600, 400, 240)
///     }
///     try target.writePNG(to: url)
/// }
/// ```
///
/// 描くのは 1 フレームだけで、``Canvas/draw(_:)`` を抜けた時点で GPU は描き終えている
/// ([#727](https://github.com/mokume-metal/mokume/issues/727))。フレームを回す経路は
/// ``Sketch`` が土台ごと持つので、この形を書くのは 1 枚だけ描くときと、絵を回す道具を
/// 自分で書くときである。
// 以下は**面に出さない** (`///` ではなく `//`)。名指しているコマンドの口 —
// `withCommands(_:)` / `commitAndWait(_:)` / `commit(_:retaining:)` / `settle()` — は
// どれも internal なので、外の読者には「待つほうと待たないほうのどちらを使うか」という
// 選択そのものが成立しない。ADR-0020 決定 4 (説明文の正本は利用者が最初に触る層に置く)
// の言う「利用者」は、この規律に関してはパッケージの中の実装者である。`///` に置いたまま
// にすると、同 決定 6 が名指した害 (呼べないものが「呼んでよい」顔で並ぶ) が、例から
// 散文へ移るだけになる (#563)。
//
// `commitAndWait(_:)` は GPU の完了まで呼び出し元を止める。1 枚だけ描く経路と検証で
// 使う形で、フレームを回す経路は待たない `commit(_:retaining:)` を使う (#727)。
//
// ## 待たない投入が守る 2 つのこと
//
// 1. **CPU が GPU 可視メモリに触る (書く・GPU の結果を読む) 直前には、それを読む・書く
//    投入が終わっている。** 触る側が直前に待つ — 投入済みの全部 (`settle()`)、環に
//    載った置き場ならそのスロットを読む投入だけ (`waitForSubmission(_:)`・#754)。
//    数の並びと画像への書き込みはその場で触らず、控えを描き切りが GPU 側のコピーで
//    届ける (`PendingUploads`・#749)
// 2. **GPU 上でも、投入したコマンドは投入順に実行される。** この世代は別々に投入した
//    コマンドの間の順序を自動では保証しない (encoder の間と同じ・#341)。投入のたびに
//    「直前の番号を GPU 側で待つ」を積んで、順序を明示する
//
// 投入したコマンドが読むリソースは、**投入した側が参照を手放しても**終わるまで生きて
// いなければならない (この世代のコマンドはリソースを保持しない)。手放す予定のものは
// `commit(_:retaining:)` に渡し、この型が完了まで抱える。
@MainActor public final class RenderDevice {
    /// GPU が完了するのを待つ上限 (秒)。
    ///
    /// 待ちが返らないときに永久に止まらないための上限で、**検証がこの値そのものを
    /// 物差しにできるよう**定数で持つ (壁時計の絶対値をテストに書かない)。
    public static let waitLimitSeconds = 5

    /// 面の一辺に取れる画素数の上限。
    ///
    /// **`MTLDevice` から引ける口が無いので定数で持つ。** 世代ごとに分けていないのは
    /// ADR-0001 原則 5 (macOS / Apple Silicon 専用) による — Apple Silicon はどの世代も
    /// 16384 なので、分岐は「起こりえない場合」を書き足すことにしかならない。
    ///
    /// `nonisolated` にしてあるのは ``RenderFailure/description`` から読むためである。
    /// あちらはプロトコルの証人なので隔離の外に居る。
    ///
    /// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
    nonisolated static let maxTextureSide = 16384

    /// 面の一辺として置ける範囲。**1 以上、``maxTextureSide`` 以下。**
    ///
    /// 上の端と下の端を同じ 1 つで持つ。寸法を検める口 (``checkTextureSize(width:height:)`` と、
    /// `ImageFailure` で断る `createImage`) はどれもこれを読む — 端ごとに別の場所で見ると、
    /// 片方の端だけが漏れる ([#1642](https://github.com/mokume-metal/mokume/issues/1642))。
    nonisolated static let textureSides = 1...maxTextureSide

    /// 面の寸法を検める。**外から任意の寸法が入る口の関所** (#885・#1642)。
    ///
    /// descriptor を組む前に呼ぶ。負の寸法は `MTLTextureDescriptor` の符号なしの幅へ写せず、
    /// 組む時点で落ちる — だから関所は ``makeTexture(descriptor:)`` の中だけでは足りず、
    /// 寸法を受け取った口 (`RenderTarget`・`SharedFrameSurface`) が先にここを通る。
    /// ``makeTexture(descriptor:)`` 自身も同じここを通す。
    nonisolated static func checkTextureSize(width: Int, height: Int) throws(RenderFailure) {
        guard textureSides.contains(width), textureSides.contains(height) else {
            throw .invalidSize(width: width, height: height)
        }
    }

    /// この実行環境で描画の土台を組み立てられるか。
    ///
    /// **GPU があるかだけでは足りない。** 仮想化された実行環境には、GPU としては
    /// 見えるのにこの世代のコマンド構造に対応していないものがあり、そこでは
    /// コマンドの発行口が作れない。[ADR-0009] 決定 2 により旧世代へのフォールバック
    /// 経路は持たないので、そういう環境では描画そのものが成立しない。
    ///
    /// 判定を「実際に必要なところまで試す」形にしてあるのは、GPU の有無だけを見て
    /// 「使える」と答えると、GPU を要する検証がスキップされずに失敗するため。
    ///
    /// 隔離の外から呼べる形にしてあるのは、検査の実行可否を決める前提条件として
    /// 隔離の外で評価されるため。問い合わせは GPU を持ち出さないので状態を跨がない。
    ///
    /// **同じプロセスで GPU の完了を待つのが一度 ``waitLimitSeconds`` を越えた後は、`false` を
    /// 返す。** そのとき発行口は作らずに答える。答えない GPU に使い捨ての発行口を足すことも、
    /// 止まった発行口を溜める側に数える ([#2052])。土台の初期化子も、同じ時点から
    /// ``RenderFailure/gpuNotResponding`` で断る。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor-and-toolchain.md
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    public nonisolated static var isAvailable: Bool {
        isAvailable(on: MTLCreateSystemDefaultDevice(), through: .process)
    }

    /// ``isAvailable`` の中身。発行口の関所を差し替えられる形で、検査はここを呼ぶ。
    nonisolated static func isAvailable(on device: (any MTLDevice)?, through gate: CommandQueueGate) -> Bool {
        guard let device else { return false }
        return (try? gate.makeQueue(on: device)) != nil
    }

    let device: any MTLDevice

    /// 発行口を作る関所 (``CommandQueueGate``)。製品の経路ではプロセスで 1 つのもの
    /// (``CommandQueueGate/process``) で、合図の待ちが期限を越えたら、ここに印を立てる ([#2052])。
    ///
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    let queueGate: CommandQueueGate

    /// **このファイルの外へ出さない** ([#845])。別のファイルから掴めると、
    /// ``commit(_:retaining:writing:)`` を通らずに投入する口が書ける。そうして投入された置き場は
    /// 番号が書き戻されず、巻き戻す側が「もう終わっている」と読んで待たない (#222 と同じく、
    /// 絵が黙って壊れる)。投入はすべて漏斗を通すこと。
    ///
    /// [#845]: https://github.com/mokume-metal/mokume/issues/845
    private let queue: any MTL4CommandQueue

    /// CPU が書いて、まだ GPU 側へ届けていない数の並びと画像 (#749)。届けるのは描き切り。
    let pendingUploads = PendingUploads()

    /// 未投入の計算を持ちうる面。**面をまたいで、計算を頼んだ順に効かせるための名簿**
    /// (`PendingComputations`・#1870)。溜めは面ごと、描き切りも面ごとなので、別の面で
    /// 後から頼んだ計算が先に走らないよう、頼む側が相手を引く。
    let pendingComputationHolders = PendingComputations()

    /// シェーダの原文を読み、組み立てる係。
    ///
    /// **転送メソッドを置かない。** ここに `makeShapeLibrary` などを残すと「組み立てには
    /// 描画の土台の状態が要る」という読みが残るが、投入と待ちに要るものは 1 つも使わない
    /// ([#959](https://github.com/mokume-metal/mokume/issues/959))。呼ぶ側はここを通る。
    ///
    /// **触るたびに作り直さず、1 つを持ち続ける。** 組んだものを持ち主どうしで分け合う
    /// 場所があちらで、分け合う範囲がこの GPU 1 つだからである。作り直すと、抱えたものが
    /// 触るたびに消えて同じ原文を組み直す
    /// ([#728](https://github.com/mokume-metal/mokume/issues/728))。
    let shaders: ShaderLibraries

    /// 利用者の断片 (``Shader``・``EffectShader``・``Computation``) の保存を、裏で組むか ([#2365])。
    ///
    /// **立てるのは窓・共有面の経路だけ** (``SketchApplication`` が、時計と出口を決める同じ所で
    /// 決める)。既定は立てない — 書き出し・検査・利用者が直に回す面は、保存の次のフレームの頭で
    /// その場で組む ([#1830] の約束のまま)。立てると、組み上がるまでは前の断片で描き、組み上がった
    /// 後の最初のフレームの頭で差し替える (``ShaderBox`` の「裏で組む」)。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    var rebuildsShadersInBackground = false

    /// いまのフレームは、断片の組み上がりを待つか。**観測のフレームでランタイムが立てる**
    /// ([#2365])。観測が返す絵と目録は、保存した中身で描いたものでなければならない
    /// ([ADR-0018] 決定 3)。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    var waitsForShaderRebuilds = false

    /// 断片の持ち主が読む、いま裏で組むか。
    var shaderRebuildsRunInBackground: Bool {
        rebuildsShadersInBackground && !waitsForShaderRebuilds
    }

    /// コマンドの置き場ひとつぶん。
    ///
    /// 置き場は巻き戻して使い回すが、**巻き戻してよいのは、そこへ積んだコマンドを
    /// GPU が終えてから**である。だから「最後にここから投入した番号」を憶えておく。
    private struct Slot {
        /// **`nil` は「投入されずに捨てたコマンドが載っていたので手放した」。**
        ///
        /// 捨てたコマンドの載った置き場は、巻き戻しても使えない — 検証層を載せた実行では
        /// 次の `reset()` か `beginCommandBuffer` が表明で落ちる (encoder が開いていなくても
        /// 落ちる)。巻き戻す字面そのものを書けなくするために、手放して空にしておき、次に
        /// 回ってきたときに作り直す ([#1180](https://github.com/mokume-metal/mokume/issues/1180))。
        var allocator: (any MTL4CommandAllocator)?
        /// この置き場から最後に投入したコマンドの番号。まだ無ければ 0。
        var submission: UInt64 = 0
    }

    /// 置き場の環。
    ///
    /// 1 本を毎回巻き戻す形は、**待たない経路が 1 つでもあると壊れる** — 表示の経路
    /// (``commit(_:signalling:)``) は GPU の完了を待たないので、次の
    /// ``withCommands(_:)`` がまだ実行中のコマンドの載った置き場を巻き戻していた
    /// ([#222](https://github.com/mokume-metal/mokume/issues/222))。環にして 1 周ぶん
    /// 遅らせ、それでも終わっていなければ待つ。
    private var slots: [Slot]
    /// 次に使う置き場。
    private var nextSlot = 0
    /// 組み立て中のコマンドが、どの置き場に載っているか。
    ///
    /// 投入のときに番号を書き戻す先を引くために持つ。同時に複数本を組み立てても
    /// 取り違えないよう、コマンドそのものを鍵にする。
    ///
    /// **消す口は 2 つで、どちらかを必ず通る** — 投入 (``recordSubmission(_:of:)``) と、
    /// 投入されずに組み立ての口を抜けたとき (``forgetUnsubmitted(_:)``)。かつては前者しか
    /// 無く、組み立ての途中で投げた 1 回で記録が残り、以後その土台は塗った面を作れなく
    /// なっていた ([#1180](https://github.com/mokume-metal/mokume/issues/1180))。
    private var slotOfOpenCommands: [ObjectIdentifier: Int] = [:]

    /// 環の既定の本数。
    ///
    /// 描画・読み戻し・表示で 1 フレームあたり 2〜3 本使うので、3 本あれば
    /// 巻き戻す番が回ってくる頃には 1 フレームぶん前の仕事になっている。**正しさは
    /// 本数に依らない** (足りなければ待つ) ので、ここは速さのための値である。
    static let defaultSlotCount = 3

    /// この土台が持つ置き場の本数。
    ///
    /// **フレームごとに書く置き場の環 (``FrameRing``) も同じ本数にする。** 置き場を
    /// 1 本にした土台 (検査用) ではコマンドの環が既に全部を直列にするので、データ側
    /// だけ深くしても意味がない。1 つの値から引けば、どちらの環も同じ深さを名乗る。
    var slotCount: Int { slots.count }

    /// 診断: 置き場が空くのを待った回数。
    ///
    /// **「実行中の置き場を巻き戻さなかった回数」は数えない。** かつてそういう診断
    /// (`resetsWhileInFlight`) を ``beginCommands()`` の待ちの**あと**に置いていたが、
    /// 判定は ``waitForSlot(_:)`` と同じ合図を 1 行あとで読むので、`waitForSlot` の
    /// 事後条件の自己申告以上にはならなかった — 0 が「待ちが守った」と「そもそも
    /// 危なくなかった」を分けないので、それを `== 0` で読んでいた 6 本の検査のうち
    /// 3 本は、待ちを丸ごと外しても緑のままだった ([#790])。数えるのは**実際に待った
    /// 回数**だけにして、事後条件のほうは検査が外から見る (`CommandAllocatorTests`)。
    ///
    /// [#790]: https://github.com/mokume-metal/mokume/issues/790
    private(set) var slotWaits = 0
    /// 診断: 組み立てたコマンドを投入せずに捨てた回数 (``forgetUnsubmitted(_:)`` が動いた数)。
    ///
    /// **検査の前提を見る見張りであって、片付けが正しい証拠ではない。** 数えているのは
    /// 片付けそのものなので、これが増えたことは「捨てた後も塗った面を作れる」「捨てた
    /// 置き場を次に使っても落ちない」を何も保証しない ([#790] と同じ線)。検査がこれを読む
    /// のは、**組み立てを始めた後で投げた**ことを確かめるためだけで、正しさは作れた面と
    /// 読めた絵のほうで見る ([#1180])。
    ///
    /// [#790]: https://github.com/mokume-metal/mokume/issues/790
    /// [#1180]: https://github.com/mokume-metal/mokume/issues/1180
    private(set) var abandonedCommands = 0
    /// 診断: ``settle()`` を頼まれた回数。GPU 可視メモリに触る経路が待ちを要求した数。
    private(set) var settleCalls = 0
    /// 診断: ``settle()`` が実際に止まった回数 (頼まれた時点で GPU が終わっていなかった)。
    private(set) var blockingWaits = 0
    /// 診断: 名指しの待ち (``waitForSubmission(_:)``) が実際に止まった回数。
    ///
    /// ``blockingWaits`` と分けてある。**あちらは「投入済みの全部」を待った回数**で、
    /// 環が効いているフレームでは 0 のままでなければならない ([#754])。こちらは
    /// 「名指しした投入 1 本」を待った回数で、環が浅い (置き場が 1 本の土台・CPU が
    /// GPU を追い越した) ときと、出口へ渡す絵がまだ組み上がっていないとき ([#927])
    /// に増える。
    ///
    /// [#754]: https://github.com/mokume-metal/mokume/issues/754
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    private(set) var ringWaits = 0
    /// 診断: 投入の結末が届くのを実際に待った回数 (``droppedWork(after:through:)`` が眠った数)。
    ///
    /// 合図を待つ上の 3 つとは別に数える。合図が進んでも結末は遅れて届くことがあり、投げる読む口
    /// はその分だけ余計に待つ ([#1932])。読み 1 回につき高々 1 回である (CPU が書いた画素を書き戻した
    /// まま読み戻していない写しを読むときだけ、読み戻しの前にもう 1 回判定する)。
    ///
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    private(set) var outcomeWaits = 0

    /// GPU が積んだ仕事を打ち切ったことの記録。
    ///
    /// **合図は打ち切りでも進む。** だから上の 4 つ (待った回数) が正常に増えていても、絵が
    /// 描き上がっているとは限らない — 打ち切られた仕事は 1 画素も書き残さないのに、待ちは
    /// 成立し、空の絵がそのまま読める ([#1065])。区別が付くのはこの記録だけである。
    ///
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    private let commandFaults = CommandFaultLog()

    /// 診断: GPU が積んだ仕事の実行を打ち切った回数。
    var commandFaultCount: Int { commandFaults.count }

    /// 診断: 最後に打ち切られた理由。
    var lastCommandFault: String? { commandFaults.last }

    /// 検査から「GPU が仕事を打ち切った」の記録を作るための差し込み。製品の経路からは呼ばない。
    ///
    /// **打ち切りを故意に起こす検査は置かない** ([#1065] の完了条件 4)。起こすには 1 本の
    /// コマンドを数百 ms 走らせることになり、同じ GPU で並行する検査を巻き添えにしうる。
    /// 一方で、画素の表明が落ちたときに記録された打ち切りを名乗ることは [#1812] の完了条件
    /// なので、記録の側にだけ 1 つ穴を空けてある (``failSettleForTesting`` と同じ形)。
    /// 知らせ (`Diagnostics.warn`) は出さない。公開はしない。
    ///
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    /// [#1812]: https://github.com/mokume-metal/mokume/issues/1812
    func recordCommandFaultForTesting(_ reason: String) {
        _ = commandFaults.note(reason)
    }

    /// 検査から「次の投入を GPU が打ち切った」ことにする差し込み。製品の経路では常に `nil`。
    ///
    /// 次の ``commit(_:retaining:writing:)`` が取って空に戻す。その投入は GPU では普通に走り、**結末の
    /// ハンドラが届けるときに、理由をこれへ差し替える** — 結末は本物と同じく Metal 側の糸から遅れて
    /// 届くので、投げる読む口が「届くまで待ってから判定する」([#1932] の完了条件 2) ことまで
    /// 検査から見える。``recordCommandFaultForTesting(_:)`` は番号を持たない記録だけを作るので、
    /// 投げる読む口の範囲には入らない。
    ///
    /// 打ち切りを故意に起こさない理由は ``recordCommandFaultForTesting(_:)`` と同じ ([#1065] の
    /// 完了条件 4)。知らせ (`Diagnostics.warn`) は出さない — 検査の記録に「GPU が仕事を捨てた」の
    /// 行が混ざると、本物の打ち切りを数える人が読み違える ([#1930] は run の記録でこの行を数えた)。
    /// 公開はしない。
    ///
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    /// [#1930]: https://github.com/mokume-metal/mokume/issues/1930
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    var dropsNextSubmissionForTesting: String?

    /// 検査から「次の投入の結末の知らせが届かない」を作る差し込み。製品の経路では常に `false`。
    ///
    /// 次の ``commit(_:retaining:writing:)`` が取って下ろす。その投入は GPU で普通に走り、完了の
    /// 合図も進むが、**結末のハンドラは記録へ何も書かない** — 知らせが 1 本欠けたときに、投げる読む
    /// 口が欠けた番号で止まり続けないこと ([#1932] の反証 8) を検査から見るための穴である。
    /// 公開はしない。
    ///
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    var losesNextOutcomeForTesting = false

    /// 検査から「次の投入の結末の知らせが遅れて届く」を作る差し込み。製品の経路では常に `false`。
    ///
    /// 次の ``commit(_:retaining:writing:)`` が取って下ろす。その投入が正常に終わったとき、結末を記録へ
    /// 書かずに抱え、``releaseHeldOutcomesForTesting()`` で書く ([#2743])。結末は完了の合図より遅れて
    /// 届くので、出口へ配る口は、配る時点で届いていない絵を持ち越す。その持ち越しを、間合いに頼らずに
    /// 起こすための穴である (``losesNextOutcomeForTesting`` は届かないままなので、待つ側しか見えない)。
    /// 打ち切られた投入は抱えない。公開はしない。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    var holdsNextOutcomeForTesting = false

    /// ``holdsNextOutcomeForTesting`` で抱えた結末を、いま記録へ書く。検査からだけ呼ぶ。
    func releaseHeldOutcomesForTesting() {
        commandFaults.releaseHeldForTesting()
    }

    /// 投げる読む口が、範囲の結末が届くのを待つ上限 (``droppedWork(after:through:)``)。
    ///
    /// 製品の経路では ``waitLimitSeconds`` のまま。**検査だけが縮める** — 届かない結末を作る検査
    /// (``losesNextOutcomeForTesting``) が、毎回 5 秒待たずに済むように。
    var outcomeWaitLimit: Duration = .seconds(RenderDevice.waitLimitSeconds)

    /// 完了の合図が進むのを待つ上限 (``signalReached(_:while:)``)。
    ///
    /// 製品の経路では ``waitLimitSeconds`` のまま。**検査だけが縮める** — 答えの来ない投入
    /// (``addUnansweredSubmissionForTesting()``) を待つ検査が、毎回 5 秒待たずに済むように。
    /// ``outcomeWaitLimit`` と同じ形である。
    var signalWaitLimit: Duration = .seconds(RenderDevice.waitLimitSeconds)

    /// 検査が足した、答えの来ない投入の数 (``addUnansweredSubmissionForTesting()``)。製品の経路では常に 0。
    private var unansweredSubmissionsForTesting = 0

    /// 検査から「GPU が答えない」を作る差し込み。製品の経路からは呼ばない。
    ///
    /// **番号だけを 1 つ進め、GPU には何も投入しない。** 合図はその番号へ決して届かないので、次の
    /// 待ちは本物の期限切れになる (``signalWaitLimit`` まで待つ)。期限切れの枝 ([#2052] — 期限を越えた
    /// プロセスでは、新しい発行口を作らない) を、GPU を詰まらせずに通すための穴である。待ちの期限切れは、
    /// GPU が 5 秒答えないときにしか起きないので、検査から自然には作れない (``failSettleForTesting`` と
    /// 同じ事情)。あちらは待つ前に投げるので、待ちそのものは通らない。
    ///
    /// **これを呼んだ土台へは、以後投入しない。** 投入は、直前の番号を GPU 側で待つ命令を積む
    /// (``orderAfter(_:)``)。届かない番号を待つと、発行口が GPU の上で止まる。それを作る前に、
    /// ``commit(_:retaining:writing:)`` が落とす。
    ///
    /// この差し込みで起きた期限切れは、知らせ (`Diagnostics.warn`) を出さない。検査の記録に「GPU が
    /// 答えなかった」の行が混ざると、本物の止まりを探す人が読み違える (#2052 は、その行で
    /// 起きた時刻を割り出した。``dropsNextSubmissionForTesting`` と同じ線)。公開はしない。
    ///
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    func addUnansweredSubmissionForTesting() {
        submissionCount += 1
        unansweredSubmissionsForTesting += 1
    }

    /// 完了の知らせを main actor へ渡す前に合体する器 ([#1594])。
    ///
    /// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
    private let completionNotices = CoalescedNotices()

    /// 診断: 届いた完了の知らせの数 (投入の結末を受け取るハンドラが呼ばれた数)。
    var arrivedNoticeCount: Int { completionNotices.arrived }

    /// 診断: main actor へ積んだまま、まだ走っていない完了の知らせの数。
    ///
    /// **main actor を譲らずにフレームを回しても、1 を超えない** ([#1594])。投入ごとに 1 本
    /// 積んでいた頃は、譲るまでフレームに比例して溜まった。
    ///
    /// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
    var queuedNoticeCount: Int { completionNotices.queued }

    /// 診断: 完了の知らせが main actor で**実際に走った**回数。
    ///
    /// **器の数え (``queuedNoticeCount``) とは別に、走った側で数える** (#1594 の反証 3)。
    /// 器の数えは器が積めと言った数で、ハンドラが器の答えを無視して毎回積んでも 1 のままに
    /// 見える。走った回数は積まれた `Task` の数そのものなので、そちらを取り違えない。
    private(set) var noticeRuns = 0

    /// 投入に添えるお願いを組む。**投入ごとに作る。**
    ///
    /// **1 つを作って使い回すと、ハンドラが 1 度も呼ばれない。** 実測では、打ち切られた
    /// 仕事 (絵が空で返る) に対して ``commandFaultCount`` が 0 のままだった — 使い回す
    /// 側と作り直す側を同じ木で入れ替えて確かめている。呼ばれていないことは症状からは
    /// 分からず、「打ち切りが起きていない」と区別が付かないので、ここは節約しない。
    /// 払うのは投入ごとに置き場 1 つとハンドラ 1 つである。
    ///
    /// ハンドラは Metal 側の糸から呼ばれるので、`@MainActor` のこの型ではなく**錠で
    /// 守った器だけを掴む**。自分を掴むのは弱い参照だけで、状態へ触るのは main actor へ
    /// 渡してからである。
    ///
    /// **`@Sendable` を字面で書く。** 書かないとこのクロージャの隔離が輸入された型の
    /// 注釈次第になり、main actor 隔離として推論された日には Metal 側の糸から呼ばれた
    /// 瞬間に落ちる。書けばコンパイラが掴んだものを検査する。
    ///
    /// **知らせは合体する** ([#1594])。main actor へ積むのは、積んだまま走っていない知らせが
    /// 無いときの 1 本だけで、走るときに届いている最大の番号まで刈る (``CoalescedNotices``)。
    /// 投入ごとに 1 本積むと、main actor を譲らずにフレームを回す経路では 1 本も走れず、
    /// フレームに比例して溜まり続けた。
    ///
    /// **結末は番号ごとに記す** ([#1932])。投げる読む口は、返す絵が拠った範囲の結末が届くのを
    /// 待ち、その中に打ち切りがあれば投げる (``droppedWork(after:through:)``)。
    ///
    /// - Parameters:
    ///   - submission: この投入の番号。終わったらここまでを刈る。
    ///   - wrote: この投入が書く描画先の識別子。打ち切られたら記録に添える (投げる読む口が、自分の
    ///     面へ書いた投入の打ち切りだけを持ち越すため・``CommandFaultLog/Drop/wrote``)。
    ///   - droppedForTesting: 検査がこの投入を打ち切ったことにした理由
    ///     (``dropsNextSubmissionForTesting``)。製品の経路では常に `nil`。
    ///   - losesOutcomeForTesting: 検査がこの投入の結末を届かないことにしたか
    ///     (``losesNextOutcomeForTesting``)。製品の経路では常に `false`。
    ///   - holdsOutcomeForTesting: 検査がこの投入の結末を遅らせたか (``holdsNextOutcomeForTesting``)。
    ///     製品の経路では常に `false`。
    ///
    /// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    private func makeCommitOptions(
        finishing submission: UInt64, wrote: [ObjectIdentifier], droppedForTesting: String?,
        losesOutcomeForTesting: Bool, holdsOutcomeForTesting: Bool
    ) -> MTL4CommitOptions {
        let options = MTL4CommitOptions()
        options.addFeedbackHandler {
            @Sendable [commandFaults, completionNotices, weak self] (feedback: any MTL4CommitFeedback) in
            // **結末を記してから知らせを積む** (#2199)。知らせは main actor で記帳の取り消しを照会する
            // (`releaseOnNotice`) ので、先に積むと、記す前に走って結末を「まだ」と読み、取り消しが次の照会
            // まで遅れる。頭で照会しない口 (止まっている間の追い付き・出す先を読む口) は、知らせの照会に頼る。
            //
            // 検査が知らせを落としたことにした投入は、記録へ何も書かない。遅らせた投入は、正常に
            // 終わっていれば記録へ書かずに抱える (検査が後で書く)
            if holdsOutcomeForTesting, feedback.error == nil, droppedForTesting == nil {
                commandFaults.holdForTesting(submission)
            } else if !losesOutcomeForTesting {
                if let reason = feedback.error.map(CommandFaultLog.reason(of:)) ?? droppedForTesting {
                    if commandFaults.note(reason, droppedAt: submission, wrote: wrote),
                        droppedForTesting == nil
                    {
                        Diagnostics.warn(
                            "The GPU dropped the work it had queued, so this frame was never finished: \(reason)"
                                + " — this notice will not be repeated")
                    }
                } else {
                    // 打ち切りの後に正常に終わった投入があれば、GPU はもう回復している。以後の
                    // 待ちの期限切れを打ち切りのせいにしない (#1343)
                    commandFaults.noteFinished(submission)
                }
            }
            // **抱えている資源を手放す契機は、完了そのものが持つ。** 実測では、成功した
            // 投入でもハンドラは毎回呼ばれる (50 回の投入に対し 50 回)
            if completionNotices.arrive(submission) {
                Task { @MainActor in
                    // **印は自分の生死によらず下ろす。** `self?.…(take())` の形では、自分が
                    // 居ないと `take()` が評価されず、積んだ印が残る (#1594 の反証 4)
                    let newest = completionNotices.take()
                    self?.releaseOnNotice(upTo: newest)
                }
            }
        }
        return options
    }

    /// 完了の知らせを受けて刈る。**番号と合図の、進んでいるほうまで刈る。**
    ///
    /// 番号だけを見ると、知らせが 1 本届かなかったときにその後ろが全部残る。合図だけを
    /// 見ると、合図はコマンドバッファの**後**にキューが進めるので、最後の投入を刈り
    /// 残す競走になる (それはこの Issue が直そうとしている状態そのものである)。
    /// 片方が遅れてももう片方が埋めるので、両方の大きいほうを取る。
    ///
    /// **`submission` は、合体した知らせが走る時点で届いている最大の番号である** ([#1594])。
    /// 先に積んだ知らせの番号のままにすると、合図が知らせより遅れたときに、合体して捨てた
    /// 後の投入を刈り残す — 最後の投入の分が残れば、上の保持環が 1 フレームぶん戻る。
    ///
    /// [#1076]: https://github.com/mokume-metal/mokume/issues/1076
    /// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
    private func releaseFinished(upTo submission: UInt64) {
        releaseFinished(through: max(submission, completion.signaledValue))
    }

    /// 合体した完了の知らせが main actor で走った。走った回数を数えてから刈る。
    private func releaseOnNotice(upTo submission: UInt64) {
        noticeRuns += 1
        releaseFinished(upTo: submission)
        // 結末の届いた取り消しを刈る。打ち切られていたら、止まっている間でも印だけは先に戻す (#2199)
        revokeDroppedDeliveries()
    }

    /// 投入したコマンドが読むリソースを、終わるまで抱えておく列。
    ///
    /// **番号の順に並ぶ。** 番号 n までが終わったと分かったら、先頭から n 以下のものを
    /// 落とす。投入した側が参照を手放しても、ここが抱えている間は解放されない。
    private var held: [(submission: UInt64, resources: [AnyObject])] = []

    /// 診断: 完了を待って抱えているリソースの数。
    var heldResourceCount: Int { held.reduce(0) { $0 + $1.resources.count } }

    /// 持ち主が死んだリソースを、常駐から外す番が来るまで並べておく列。
    ///
    /// **上の列と同じ形で番号順に並ぶ。** あちらが「終わるまで抱える」なら、こちらは
    /// 「終わったら外す」で、契機は同じ ``releaseFinished(through:)`` である。
    private var retired: [(submission: UInt64, allocation: any MTLAllocation)] = []

    /// 診断: 常駐から外す番を待っているリソースの数。
    var retiredResourceCount: Int { retired.count }

    /// 投入したコマンドがすべて終わっているか。**問い合わせるだけで待たない。**
    var isIdle: Bool { completion.signaledValue >= submissionCount }

    /// 番号 `submission` までの投入が終わっているか。**問い合わせるだけで待たない。** 投入した
    /// 後で GPU だけが読む置き場を、読み終わってから使い回すかを決めるのに使う (#1656)。
    func hasFinished(_ submission: UInt64) -> Bool { completion.signaledValue >= submission }

    /// 常駐させるリソースの集合。この型を通して確保したものがすべて入る。
    let residencySet: any MTLResidencySet

    /// 表示に差し出す面だけを入れる集合。
    ///
    /// **畳めるように分けてある。** 面の環は Metal 側が持ち、面の大きさが変わると
    /// 環ごと作り直されるので、古い面は集合から外さないと残り続ける — 実測では 60 回
    /// リサイズしただけで 120 件・85.2 MiB が常駐したままになった ([#357])。上の集合と
    /// 混ぜると、外すときに確保したものまで巻き添えになる。
    ///
    /// [#357]: https://github.com/mokume-metal/mokume/issues/357
    let drawableResidency: any MTLResidencySet

    /// GPU の完了を知るための合図。投入のたびに 1 つ進める。
    private let completion: any MTLSharedEvent
    /// これまでに投入した本数。**写しが「どこまで映したか」を照らす物差し**にもなる
    /// (``RenderTarget/pixels``)。
    private(set) var submissionCount: UInt64 = 0

    /// 既定の GPU で作る。
    ///
    /// 同じプロセスで GPU の完了を待つのが一度 ``waitLimitSeconds`` を越えた後は、作らずに
    /// ``RenderFailure/gpuNotResponding`` で断る。``init(device:)`` も同じである。
    public convenience init() throws(RenderFailure) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw .deviceUnavailable
        }
        try self.init(device: device)
    }

    /// GPU を指定して作る。
    public convenience init(device: any MTLDevice) throws(RenderFailure) {
        try self.init(device: device, slotCount: RenderDevice.defaultSlotCount)
    }

    /// 置き場の本数と、発行口の関所を指定できる入口 (検査用)。
    ///
    /// 1 本にすると「待たない経路の直後に必ず同じ置き場が回ってくる」形になり、
    /// 環が実際に待っていることを検査から確かめられる。
    ///
    /// 関所は、待ちの期限切れの後を見る検査だけが自前のものを渡す (``CommandQueueGate`` の説明)。
    init(
        device: any MTLDevice, slotCount: Int, queueGate: CommandQueueGate = .process
    ) throws(RenderFailure) {
        self.device = device
        self.queueGate = queueGate
        self.shaders = ShaderLibraries(device: device)

        // **発行口は関所を通して作る** (#2052)。GPU が一度答えなくなったプロセスでは作らずに断る
        let queue = try queueGate.makeQueue(on: device)
        self.queue = queue

        var slots: [Slot] = []
        for _ in 0..<max(1, slotCount) {
            guard let allocator = device.makeCommandAllocator() else {
                throw .commandAllocatorUnavailable
            }
            slots.append(Slot(allocator: allocator))
        }
        self.slots = slots

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "mokume.residency"
        let residencySet: any MTLResidencySet
        do {
            residencySet = try device.makeResidencySet(descriptor: residencyDescriptor)
        } catch {
            throw .residencySetUnavailable(reason: error.localizedDescription)
        }
        self.residencySet = residencySet
        queue.addResidencySet(residencySet)

        residencyDescriptor.label = "mokume.residency.drawable"
        let drawableResidency: any MTLResidencySet
        do {
            drawableResidency = try device.makeResidencySet(descriptor: residencyDescriptor)
        } catch {
            throw .residencySetUnavailable(reason: error.localizedDescription)
        }
        self.drawableResidency = drawableResidency
        queue.addResidencySet(drawableResidency)

        guard let completion = device.makeSharedEvent() else {
            throw .synchronizationUnavailable
        }
        self.completion = completion
    }

    /// **実行中のものが終わる前に土台を畳まない。**
    ///
    /// 投入は GPU の完了を待たずに返る (``commit(_:retaining:writing:)``) ので、最後の投入の直後に
    /// この型が手放されると、発行口・合図・常駐の集合・抱えているリソースが GPU の実行中に
    /// 消える。実測では、それが同じ GPU の**別の**発行口に積まれた仕事まで巻き添えにした —
    /// 合図は進むのに絵が空のまま読める形で、しかも負荷のかかったときだけ出る (#727 の
    /// 検査で 3 本が同時に落ちた)。畳む前に待てば、投入した側は寿命を気にしなくてよい。
    ///
    /// 詰まっていたら諦めて畳む。ここで投げる先は無いので、警告だけ残す。**諦めたことは
    /// プロセスに残る** — 待ちが期限を越えると ``signalReached(_:while:)`` が関所に印を立て、以後この
    /// プロセスでは新しい土台を作らない ([#2052])。畳んだ後に次の土台が答えない GPU へ発行口を
    /// 足し、止まった発行口が溜まって機械ごと止まったのが #2052 である。
    ///
    /// **発行口は解放せず、関所へ返す** ([#2054])。待ちを済ませてから手放しても、発行口を解放した
    /// 直後に同じプロセスの別の土台へ投入した仕事が、GPU の hang や page fault で打ち切られた。
    /// 関所は、後から何本かが手放されるまで解放を遅らせる (``CommandQueueGate/retire(_:)``)。
    /// 返す前に常駐の集合を発行口から外す。付けたままだと、遅らせている間、この土台の資源まで
    /// 生き延びる。**待ちが期限を越えたときは外さない** — 実行中のコマンドが踏んでいる集合を外すと、
    /// その結果が未定義になる (``releaseResidency(of:)`` と同じ)。
    ///
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    /// [#2054]: https://github.com/mokume-metal/mokume/issues/2054
    isolated deinit {
        var finished = isIdle
        if !finished {
            finished = signalReached(submissionCount, while: .takingDown)
            if !finished, unansweredSubmissionsForTesting == 0 {
                Diagnostics.warn(
                    "Waited \(Self.waitLimitSeconds) seconds for the GPU with no answer, and the drawing foundation is being taken down anyway")
            }
        }
        if finished {
            queue.removeResidencySet(residencySet)
            queue.removeResidencySet(drawableResidency)
        }
        queueGate.retire(queue)
    }

    // MARK: - リソース

    /// リソースを常駐させる。確保したリソースは必ずここを通す。
    ///
    /// 常駐は集合への追加だけでは効かず、追加のあとに確定させる必要がある。
    /// 呼ぶたびに確定させるので、確保の直後に 1 回呼べばよい。
    func makeResident(_ allocation: any MTLAllocation) {
        residencySet.addAllocation(allocation)
        residencySet.commit()
        residencySet.requestResidency()
    }

    /// 常駐から外す。**寿命が実行より短いリソースだけが通る。**
    ///
    /// 確保したものは基本ずっと生きるので、外す口はふつう要らない。要るのは**外から来る
    /// リソース**である — 別のプロセスが持つ面を引いて使う側は、相手が入れ替わるたびに
    /// 新しい面を引く。外さないと、見張っている間ずっと死んだ面が積み上がる。
    ///
    /// **GPU が空になってから外す。** 実行中のコマンドが踏んでいるリソースを常駐から
    /// 外すと、そのコマンドの結果が未定義になる (``releaseDrawableResidency()`` と同じ)。
    func releaseResidency(of allocations: [any MTLAllocation]) throws(RenderFailure) {
        guard !allocations.isEmpty else { return }
        try settle()
        for allocation in allocations { residencySet.removeAllocation(allocation) }
        residencySet.commit()
    }

    /// 常駐から外す番を待たせる。**待たずに返る** ([#738])。
    ///
    /// 上の口との違いは待ち方だけである。あちらは呼んだその場で全完了を待つので、
    /// **呼べるのは待ってよい場所からだけ**になる — 持ち主が死ぬ瞬間 (`deinit`) は
    /// 待ってよい場所ではない。こちらは番号を控えて並べるだけで、実際に外れるのは、
    /// そのとき投入済みだったコマンドが終わってからである。
    ///
    /// **確保したものは、持ち主が死んでも常駐の集合が抱えている。** 集合が参照を持つので、
    /// ここを通さない限り解放されない — 症状は「絵は正しいのにメモリが減らない」だけで、
    /// 原因からは遠い。フレームごとに絵を読む・計算を作り直す書き方はこれで積み続ける。
    ///
    /// ## 読む側は、持ち主ごと抱える
    ///
    /// 番号は**呼んだ時点の**投入の数で決まる。だから、まだ投入していない仕事 (溜めた列・
    /// 保持した形) が面や置き場を**生で**持っていると、持ち主が先に死んだ時点で、その仕事が
    /// 読む前に外れる番が付く ([#1079]・[#1178])。溜める側は面を持ち主と組で持つ
    /// (``HeldTexture``・``Canvas/ExternalInstances``) — そうすれば持ち主が死ぬのは読む側が
    /// 手放した後になり、ここで付く番号は必ず読む投入以降になる。**番号の決め方を
    /// 遅らせる直し方は採らない**: 溜める期間はフレームの外 (`setup()` の描画) にも、
    /// フレームをまたぐ形にも及ぶので、どこまで遅らせても覆えない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    /// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
    func retire(_ allocation: any MTLAllocation) {
        // **組み立て中のコマンドは、まだ番号を持っていない。** 開いている最中に死んだ
        // ものは、その 1 本が投入されて終わるまで外せないので 1 つ先の番号で待たせる
        let after = slotOfOpenCommands.isEmpty ? submissionCount : submissionCount + 1
        retired.append((after, allocation))
    }

    /// 表示に差し出す面を常駐させる。差し出す面へ書く前に呼ぶ。
    ///
    /// **既に入っていれば何もしない。** 集合なので入れ直しても数は増えないが、確定
    /// (``MTLResidencySet/commit()``) は毎フレーム払う必要がないため。面の環は大きさが
    /// 同じ限り有界で、実測では 120 フレーム回しても現れる面は 2 種類だった。
    func makeDrawableResident(_ texture: any MTLTexture) {
        guard !drawableResidency.containsAllocation(texture) else { return }
        drawableResidency.addAllocation(texture)
        drawableResidency.commit()
        drawableResidency.requestResidency()
    }

    /// 差し出す面の常駐を畳む。面の大きさが変わって環が作り直されたときに呼ぶ。
    ///
    /// **GPU が空になってから外す。** 実行中のコマンドが踏んでいる面を常駐から外すと、
    /// そのコマンドの結果が未定義になる。畳むのは面の大きさが変わったときだけなので、
    /// この待ちが毎フレームの経路に乗ることはない。
    func releaseDrawableResidency() throws(RenderFailure) {
        guard drawableResidency.allocationCount > 0 else { return }
        try settle()
        drawableResidency.removeAllAllocations()
        drawableResidency.commit()
    }

    /// 描画先にできるテクスチャを確保して常駐させる。
    ///
    /// **大きすぎる寸法は、渡す前にここで断る。** 上限を超えた descriptor に Metal は
    /// `nil` を返さず、検証層がアサーションで**プロセスを終了させる** — だから下の
    /// `guard let` では捕まえられず、`throws(RenderFailure)` を宣言していても投げる前に
    /// 死ぬ。利用者から見ると `try` を書いても書かなくても結果が同じになっていた
    /// ([#885](https://github.com/mokume-metal/mokume/issues/885))。
    ///
    /// **外から任意の寸法が入る口 (描き場所・絵・窓の大きさ) は、いずれもここへ集まる。**
    /// 3 つを個別に守ると、面を作る道が 1 本増えるたびに守り忘れが生まれる。見る範囲は
    /// ``textureSides`` の 1 つで、下の端 (1 を割る寸法) は descriptor を組む前に
    /// ``checkTextureSize(width:height:)`` が同じ範囲で断る。
    func makeTexture(descriptor: MTLTextureDescriptor) throws(RenderFailure) -> any MTLTexture {
        try Self.checkTextureSize(width: descriptor.width, height: descriptor.height)
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return texture
    }

    /// GPU 専用 (`.private`) の色の面を確保して常駐させ、**透明な黒で塗っておく**。
    ///
    /// GPU 専用の面の初期値は未定義で、CPU から読める置き場 (作られた時点で 0) とは違う。
    /// 塗り直しを頼まずに描き足す最初のフレーム (`background(_:)` を周囲で置く絵) や、
    /// 前のフレームの控えを最初のフレームから読む段 (時間方向の拡大) は、その未定義の
    /// 値を読む — 台帳の `surroundings` がこれで実際に動いた (#753)。作った時点で
    /// 1 度塗れば、置き場に載せていた頃と同じ「透明な黒から始まる」になる。
    ///
    /// 塗る仕事は投入するだけで待たない。続く投入は GPU 側で順に並ぶ。
    ///
    /// **コマンドを組み立てている最中には呼べない。** 塗るのに自分のコマンドを 1 本
    /// 開くので、開いたまま環を 1 周すると同じ置き場をもう一度開くことになる (検証層が
    /// 止める。層が無ければ未定義)。組み立ての最中に作る面 (効果の控え) は、全画素を
    /// 書く段しか通らないので塗らずに作る (``StageImage``)。
    ///
    /// **断るときは ``RenderFailure/commandsAlreadyOpen`` を投げる。** これは呼び出し順の
    /// 誤りであって資源の不足ではないので、資源枯渇の case を借りない — 借りていた頃の
    /// 文面は「走ったままのスケッチを閉じてから試す」で、踏んだ人を必ず間違った方向へ
    /// 送っていた ([#792](https://github.com/mokume-metal/mokume/issues/792))。
    func makeClearedTexture(descriptor: MTLTextureDescriptor) throws(RenderFailure)
        -> any MTLTexture
    {
        guard slotOfOpenCommands.isEmpty else { throw .commandsAlreadyOpen }
        let texture = try makeTexture(descriptor: descriptor)
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        attachment.storeAction = .store
        try withCommands { commands throws(RenderFailure) in
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                throw .encoderUnavailable
            }
            encoder.endEncoding()
            commit(commands)
        }
        return texture
    }

    /// CPU から読める領域を確保して常駐させる。
    func makeReadableBuffer(byteCount: Int) throws(RenderFailure) -> any MTLBuffer {
        // **頼む前に上限を見る。** 上限を超える長さをそのまま頼むと、検証層を有効にした
        // 実行 (検査がそうしている) では `nil` ではなく**異常終了**で返ってくる —
        // 「確保に失敗した」として扱えず、そこで走っている検査ごと落ちる
        guard byteCount > 0, byteCount <= device.maxBufferLength else {
            throw .bufferUnavailable(byteCount: byteCount)
        }
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw .bufferUnavailable(byteCount: byteCount)
        }
        makeResident(buffer)
        return buffer
    }

    /// 領域の上にテクスチャを載せるときの、1 行あたりのバイト数。
    ///
    /// 行の先頭が揃っていないとテクスチャを載せられない。**幅を切り上げるのではなく
    /// 行の間隔を広げる**ので、どんな幅でも載せられる — 幅を切り上げると、利用者の
    /// 指定した大きさと描かれる大きさが食い違う。
    /// **揃え方は形式ごとに違う**ので、載せる形式を渡す。既定は作業空間のもの。
    func alignedBytesPerRow(
        _ natural: Int, for pixelFormat: MTLPixelFormat = RenderTarget.pixelFormat
    ) -> Int {
        let alignment = device.minimumLinearTextureAlignment(for: pixelFormat)
        guard alignment > 1 else { return natural }
        return (natural + alignment - 1) / alignment * alignment
    }

    /// CPU から読める領域の上にテクスチャを載せて確保する。
    ///
    /// こうして作ったテクスチャへ描くと、結果は**同じメモリ**に現れる。写しを取らずに
    /// CPU から読めるのはこのためで、統一メモリの機械でしか成立しない ([ADR-0009])。
    ///
    /// **同じメモリでも、常駐は置き場とテクスチャで別々に数えられる。** 置き場を通した
    /// だけでは足りず、載せたテクスチャも通す — 通し忘れると検証レイヤが「どの residency
    /// set にも入っていない」と言う ([#351])。絵は普段どおり出てしまうので、症状からは
    /// 見つからない。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor.md
    /// [#351]: https://github.com/mokume-metal/mokume/issues/351
    func makeBufferBackedTexture(
        descriptor: MTLTextureDescriptor, bytesPerRow: Int
    ) throws(RenderFailure) -> (texture: any MTLTexture, storage: any MTLBuffer) {
        let storage = try makeReadableBuffer(byteCount: bytesPerRow * descriptor.height)
        guard
            let texture = storage.makeTexture(
                descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return (texture, storage)
    }

    // MARK: - コマンド

    /// コマンドを 1 本組み立てる。**コマンドを開く口はこれしか無い。**
    ///
    /// 環から次の置き場を取り (そこへ積んだ前回のコマンドが終わっていなければ待つ)、
    /// 開いたコマンドを `assemble` に渡す。**投入は `assemble` の中で行う** — 投入の形は
    /// 呼び出し側ごとに違う (抱えるものを渡す・表示の合図を出す・終わるまで待つ) ので、
    /// この口に持たせるとその 3 通りをここの引数で表すことになる。
    ///
    /// ## 投入されずに抜けたら、この口が畳む
    ///
    /// `assemble` が投げても、投入し忘れて返っても、抜けるときに
    /// ``forgetUnsubmitted(_:)`` が記録を消し、置き場を手放す。**呼び出し側は何も書かない。**
    ///
    /// かつては開く口 (`beginCommands()`) が外に開いていて、記録を消すのは投入だけだった。
    /// 開いてから投入するまでの間で投げる経路が 7 か所にあり、そのどれか 1 回で記録が残ると、
    /// 以後その土台では ``makeClearedTexture(descriptor:)`` が永久に断り
    /// (`RenderTarget(gpu:)` も作れない)、検証層を載せた実行ではその置き場が次に回ってきた
    /// ときにプロセスが落ちた ([#1180])。呼び出し側ごとに `defer` を書く形は採らない —
    /// 8 か所目を足す人が書き忘れても、症状は「一時的な失敗の後で、関係の無い面が作れない」
    /// になり、原因から遠い。
    ///
    /// ## 捨てたコマンドは閉じずに、置き場ごと手放す
    ///
    /// 閉じて (`endCommandBuffer()`) 巻き戻す形は使えない。**投げた時点で encoder が開いて
    /// いるかを、この型は知らない** — 開いたまま閉じると検証層の表明で落ち、閉じずに同じ
    /// 置き場を使うと、encoder の有無によらず次の巻き戻しか開き直しで落ちる。置き場ごと手放して
    /// 作り直す形だけが、encoder の開閉・手放す順を問わず黙った (#1180 の実測)。手放す置き場は
    /// 捨てたコマンドを開く前に巻き戻し済み (= その前の投入は終わっている) なので、走っている
    /// 仕事を置き去りにしない。
    ///
    /// [#1180]: https://github.com/mokume-metal/mokume/issues/1180
    func withCommands<Value>(
        _ assemble: (any MTL4CommandBuffer) throws(RenderFailure) -> Value
    ) throws(RenderFailure) -> Value {
        let commands = try beginCommands()
        defer { forgetUnsubmitted(commands) }
        return try assemble(commands)
    }

    /// コマンドを 1 本開く。**呼んでよいのは ``withCommands(_:)`` だけ** (片付けがそこにある)。
    ///
    /// 環から次の置き場を取り、**そこへ積んだ前回のコマンドが終わっていなければ待つ**。
    private func beginCommands() throws(RenderFailure) -> any MTL4CommandBuffer {
        let index = nextSlot
        nextSlot = (nextSlot + 1) % slots.count

        try waitForSlot(index)
        let allocator: any MTL4CommandAllocator
        if let reusable = slots[index].allocator {
            reusable.reset()
            allocator = reusable
        } else {
            // 捨てたコマンドの載っていた置き場は手放してある。**作れなければ空のまま残す** —
            // 次にこの置き場が回ってきたときにもう一度作る
            guard let fresh = device.makeCommandAllocator() else {
                throw .commandAllocatorUnavailable
            }
            slots[index].allocator = fresh
            allocator = fresh
        }
        // 終わった番号のぶんは、ここで手放す。settle を 1 度も呼ばない経路 (表示だけを
        // 繰り返す) でも、抱えたものが際限なく溜まらない
        releaseFinished(through: completion.signaledValue)

        guard let commands = device.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        commands.beginCommandBuffer(allocator: allocator)
        slotOfOpenCommands[ObjectIdentifier(commands)] = index
        return commands
    }

    /// 組み立ての口を抜けるとき、**投入されていなければ**記録を消して置き場を手放す。
    ///
    /// **「投げたかどうか」ではなく「記録が残っているかどうか」で決める。** 投入した後に
    /// 投げる経路 (``commitAndWait(_:)`` の待ちが期限切れになる) では、記録は投入が既に
    /// 消している。投げたことを印にすると、そこで手放すのは**いま GPU が読んでいる**
    /// コマンドの載った置き場になる。
    private func forgetUnsubmitted(_ commands: any MTL4CommandBuffer) {
        guard let index = slotOfOpenCommands.removeValue(forKey: ObjectIdentifier(commands))
        else { return }
        slots[index].allocator = nil
        abandonedCommands += 1
    }

    /// 合図の待ちが期限を越えたときに投げる失敗。**合図を待つ 3 つの待ち口はすべてここを通る。**
    /// 結末が届くのを待つ ``droppedWork(after:through:)`` は通らない (合図は届いているので、
    /// `.timedOut` の「描きすぎ」は当たらない)。
    ///
    /// 直近に届いた結末が打ち切りなら ``RenderFailure/workDropped(reason:)``、そうでなければ
    /// ``RenderFailure/timedOut(seconds:)``。打ち切りの後に待ちが越えると、`.timedOut` の文面
    /// は「描きすぎ」と言い切ってしまい、読んだ人は形や光を減らす方向へ切り分ける — 本当の
    /// 原因は打ち切りの側にある ([#1343](https://github.com/mokume-metal/mokume/issues/1343))。
    ///
    /// 記録を引数で受けるのは、GPU を打ち切らせずに判定を検査できるようにするためである
    /// (打ち切りは検査から自然には作れない)。
    static func waitFailure(faults: CommandFaultLog) -> RenderFailure {
        if let reason = faults.unresolved { return .workDropped(reason: reason) }
        return .timedOut(seconds: waitLimitSeconds)
    }

    /// 完了の合図が `value` まで進むのを待つ。**越えたら `false`。**
    ///
    /// 持っているのは**期限そのものと、秒からミリ秒への変換**だけである。畳んだのは
    /// この 2 つが 4 箇所に書かれていたからで、1 箇所だけ直し漏れると **1000 倍長く待つ
    /// = 期限が無いのと同じ**になる。しかも症状は「固まった」だけで、期限を持っている
    /// つもりのコードが持っていないことは読んでも分からない
    /// ([#959](https://github.com/mokume-metal/mokume/issues/959))。期限は ``signalWaitLimit``
    /// (製品では ``waitLimitSeconds``) から読む。
    ///
    /// **越えたら、発行口の関所 (``queueGate``) に印を立てる** ([#2052])。以後このプロセスでは、
    /// 新しい土台も、``isAvailable`` の使い捨ても、発行口を作らない。GPU の待ちは 4 つ (`deinit`・
    /// ``settle()``・``waitForSlot(_:)``・``waitForSubmission(_:)``) で、どれもここを通るので、印を
    /// 立てる場所はここ 1 つで足りる。結末が届くのを待つ ``droppedWork(after:through:)`` は通らない。
    /// あちらは合図が届いた後の待ちで、GPU は答えている。
    ///
    /// **期限切れの文言は持たない。** 4 つの呼び出し側で文言が違い、`Diagnostics.warn` は標準
    /// エラーへ直に書いて控えを持たないので、畳んで壊しても確かめる手段が無い (#958 で
    /// 同じ線を引いた)。投げるか投げないか (`deinit` だけ投げない) も呼ぶ側に残す。ここが言うのは
    /// 印を立てたことだけで、言うのはプロセスで 1 回である。
    ///
    /// **その 1 行は、描きすぎの場合もあると名乗る。** 同じ期限切れで、呼ぶ側は `.timedOut` の
    /// 「1 フレームが描きすぎ」を出す。重い 1 フレームと答えない GPU は、ここからは見分けられない。
    /// 片方だけを言い切ると、2 行が食い違って読んだ人を迷わせる (#1343 と同じ線・#2052 の反証)。
    /// `wait` は、どの待ちだったかを関所に控えるためにある (``CommandQueueGate/closure``)。
    ///
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    private func signalReached(_ value: UInt64, while wait: CommandQueueGate.Wait) -> Bool {
        let milliseconds = UInt64((signalWaitLimit / .milliseconds(1)).rounded(.up))
        guard !completion.wait(untilSignaledValue: value, timeoutMS: milliseconds) else { return true }
        if queueGate.close(after: wait, limit: signalWaitLimit), unansweredSubmissionsForTesting == 0 {
            Diagnostics.warn(Self.closingNotice(after: wait, limit: signalWaitLimit))
        }
        return false
    }

    /// 関所に印を立てた時に出す 1 行。**どちらの場合もありうると名乗り、起こし直すよう促す**
    /// (上の ``signalReached(_:while:)``)。
    static func closingNotice(after wait: CommandQueueGate.Wait, limit: Duration) -> String {
        "Waiting for the GPU went past \(limit) while \(wait.phrase). That can be one frame drawing too much or a GPU"
            + " that stopped answering, and the two look the same from here, so from now on this process sets up no"
            + " new drawing foundation — start it again to set one up"
    }

    /// 指定した置き場から投入したコマンドが終わるまで待つ。
    ///
    /// **#222 の不変条件 (実行中の置き場を巻き戻さない) を守っているのは、この待ち
    /// 1 つだけである。** 待てなければ投げるので、``beginCommands()`` の
    /// `reset()` へ進めるのは「この置き場へ積んだ投入は終わっている」ときだけになる。
    ///
    /// **その事後条件を確かめる者は、この型の中には置けない。** 判定に使える合図は
    /// ここが待っているのと同じ `completion` で、この世代には allocator の実行状態を
    /// 別経路で問う口が無いためである。見張りは検査が外から掛ける —
    /// `CommandAllocatorTests` の「置き場を取り直す口は、その置き場を読む投入が
    /// 終わってから巻き戻す」が、置き場を 1 本にして ``withCommands(_:)`` を呼び、
    /// 組み立ての最初の文で ``isIdle`` を見る ([#790])。
    ///
    /// [#790]: https://github.com/mokume-metal/mokume/issues/790
    private func waitForSlot(_ index: Int) throws(RenderFailure) {
        let pending = slots[index].submission
        guard pending > 0, completion.signaledValue < pending else { return }

        slotWaits += 1
        guard signalReached(pending, while: .allocator) else {
            Diagnostics.warn(
                "Waited \(Self.waitLimitSeconds) seconds for a command allocator to free up, with no answer")
            throw Self.waitFailure(faults: commandFaults)
        }
    }

    /// 検査から「GPU の完了を待てなかった」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 待ちが期限切れになるのは GPU が 5 秒返らないときだけなので、検査から自然には
    /// 作れない。一方で**待てなかった後に何を書かないか**は [#934] の完了条件そのもの
    /// なので、ここに 1 つだけ穴を空けてある (`Canvas.failureForTesting` と同じ形)。
    /// 公開はしない。
    ///
    /// [#934]: https://github.com/mokume-metal/mokume/issues/934
    var failSettleForTesting: RenderFailure?

    /// 投入したコマンドがすべて終わるまで待つ。**GPU 可視メモリに触る直前に呼ぶ。**
    ///
    /// 待たない経路も番号を進めているので、最後の番号まで待てば「この GPU に積んだものが
    /// 全部終わった」ことになる。全部終わっていれば何もせずに返るので、呼ぶ側は
    /// 「待つかもしれない」ことだけを知っていればよい。終わった番号ぶんの抱えている
    /// リソースはここで手放す。
    func settle() throws(RenderFailure) {
        settleCalls += 1
        defer { releaseFinished(through: completion.signaledValue) }
        if let failSettleForTesting { throw failSettleForTesting }
        guard submissionCount > 0, completion.signaledValue < submissionCount else { return }

        blockingWaits += 1
        guard signalReached(submissionCount, while: .finishing) else {
            // **黙って捨てない。** 詰まったことが分からないと、症状 (絵が止まる・
            // 観測が遅い) から原因へ辿る手がかりが 1 つも残らない
            Diagnostics.warn(
                "Waited \(Self.waitLimitSeconds) seconds for the GPU to finish, with no answer")
            throw Self.waitFailure(faults: commandFaults)
        }
    }

    /// 番号 `submission` の投入が終わるまで待つ。
    ///
    /// ``settle()`` との違いは待つ範囲だけである。あちらは投入済みの**全部**を待ち、
    /// こちらは**名指しした 1 本**を待つ。環にした置き場は「そのスロットを最後に読んだ
    /// 投入」さえ終わっていれば CPU が書いてよいので、その先に積まれた新しいフレームの
    /// 仕事まで待つ理由が無い ([#754])。
    ///
    /// **緩めてよいのは、どの投入が書いたかを自分で憶えているものだけである。** いま
    /// 名指しできるのは 2 つ — フレームごとに書く置き場の環 (#754) と、出口へ渡す絵
    /// ([#927])。数の並びと画像 (粒を含む) は、書く口が待たずに控えを積み、描き切りが
    /// 環に載った置き場から GPU 側のコピーで届ける ([#749]) ので、ここにもどこにも
    /// 待ちを持たない。字形の面は今までどおり ``settle()`` で全完了を待つ — どの投入に
    /// 属するかを名乗れないものは、いつ読まれ終わるかも名乗れない。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    /// [#754]: https://github.com/mokume-metal/mokume/issues/754
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    func waitForSubmission(_ submission: UInt64) throws(RenderFailure) {
        // 終わった番号ぶんの抱えているリソースは、待ちの有無によらずここで手放す。
        // 描き切りが settle を通らなくなったので、手放す契機をこちらにも置く
        defer { releaseFinished(through: completion.signaledValue) }
        guard submission > 0, completion.signaledValue < submission else { return }

        ringWaits += 1
        guard signalReached(submission, while: .frameSlot) else {
            Diagnostics.warn(
                "Waited \(Self.waitLimitSeconds) seconds for a frame slot to free up, with no answer")
            throw Self.waitFailure(faults: commandFaults)
        }
    }

    /// 投げられない口のための ``settle()``。詰まっていたら理由を残して進む。
    ///
    /// フレームごとに呼ばれる口は投げない ([ADR-0020] 決定 5) ので、そこから待つときは
    /// この形を使う。5 秒返らない GPU は壊れているので、ここで凝らない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// **文は呼ぶ側が完全な形で持つ。** かつては「\(何)の前に」という骨組みへ動詞句を
    /// 流し込んでいたが、その形は語順の違う言語で組み替えられない (ADR-0038 決定 3)。
    func settleQuietly(orWarn note: String) {
        do {
            try settle()
        } catch {
            Diagnostics.warn("\(note): \(error.headline)")
        }
    }

    /// 投げられない口のための ``waitForSubmission(_:)``。詰まっていたら理由を残して進む。
    ///
    /// ``settleQuietly(orWarn:)`` と同じ作法で、待つ範囲だけが違う。出口へ絵を渡す経路と
    /// 絵を読み戻す口は毎フレーム走るので投げられない ([ADR-0020] 決定 5) が、待つべき
    /// 投入は名指しできる ([#927])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    func waitForSubmissionQuietly(_ submission: UInt64, orWarn note: String) {
        do {
            try waitForSubmission(submission)
        } catch {
            Diagnostics.warn("\(note): \(error.headline)")
        }
    }

    // MARK: - 打ち切られた投入が届けたはずの中身を取り戻す (#2199)

    /// 結末を待っている投入と、その結末を知らせる持ち主 (弱く持つ)。
    struct PendingSettlement {
        let submission: UInt64
        weak var observer: (any SettlementObserver)?
    }

    /// 投入の後で記帳を進め、その投入の結末を待っている持ち主。**番号の順とは限らない。**
    ///
    /// **結末が届けば外す** (``revokeDroppedDeliveries()``)。正常な経路では、結末が届くたびに刈られて
    /// 伸びない。**置き場は持ち回る** — 毎フレーム預けて外すので、容量を捨てない ([ADR-0023] 決定 5 の
    /// 「毎フレーム走る経路は資源を増やさない」と同じ線で、CPU の確保も増やさない)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private var settlements: [PendingSettlement] = []
    /// ``revokeDroppedDeliveries()`` が持ち回る置き場。照会の答えと、結末の届いた持ち主。
    private var settlementOutcomes: [Bool?] = []
    private var settledObservers: [(submission: UInt64, observer: (any SettlementObserver)?, dropped: Bool)] = []
    /// 持ち主へ結末を知らせている最中か。知らせの中から照会し直しても、置き場を二重に使わない。
    private var isSettling = false

    /// 照会を止めている深さ。**描き切りの間は照会しない** (``holdRevocations()``)。
    private var revocationHolds = 0

    /// 診断: 打ち切られたと確かめられた投入を、持ち主へ知らせた数 (作ってから通算)。
    private(set) var droppedDeliveriesRevoked = 0

    /// 診断: 結末を待っている預けの数。**正常な経路では、結末が届くたびに刈られる。**
    var pendingRevocationCount: Int { settlements.count }

    /// 番号 `submission` の投入の結末を、届いた後で `observer` へ知らせる ([#2199])。
    /// **投入の後で記帳した直後に呼ぶ** — 記帳を進めた持ち主が、打ち切られたら何を戻すかを知っている。
    ///
    /// 知らせるのは、結末が届いた後の最初の ``revokeDroppedDeliveries()`` である。同じ持ち主が同じ投入を
    /// 続けて預けたら 1 つにまとめる (影と拡大を 1 本の描き切りに載せる面)。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func awaitSettlement(of submission: UInt64, by observer: any SettlementObserver) {
        if let last = settlements.last, last.submission == submission, last.observer === observer {
            return
        }
        settlements.append(PendingSettlement(submission: submission, observer: observer))
    }

    /// 番号 `submission` の投入が届けた控えを下ろし ([#1183] の作法で投入の後に)、投入に載せて届けた
    /// 持ち主には結末を待たせる ([#2199])。控えを届けた投入の後で呼ぶ口はここ 1 つにする (描き切りと、
    /// 計算と控えの早い投入)。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func noteUploaded(_ uploaded: EncodedUploads, by submission: UInt64) {
        // **届けたものが無くても刈る。** 逃げ道で直接書いた持ち主や手放された持ち主は、ここで降ろす
        defer { pendingUploads.dropFinishedOwners() }
        for item in uploaded {
            // 逃げ道で直接書いた分は投入に載っていないので、結末を待たせない
            let delivered = item.owner.markUploaded(
                through: item.generation, by: item.direct ? nil : submission)
            if delivered { awaitSettlement(of: submission, by: item.owner) }
        }
    }

    /// 描き切りの間、照会を止める ([#2199])。描き切りは頭で照会してから、描く先を変えるかを数える。
    /// その後で入れ子の描き切り (置いた側に写させる) の頭が照会すると、数えた後で書き込み待ちが立ち、
    /// 数えと食い違う。**止めた深さは ``releaseRevocations()`` で戻す。**
    func holdRevocations() { revocationHolds += 1 }

    /// ``holdRevocations()`` を 1 段戻す。
    func releaseRevocations() { revocationHolds -= 1 }

    /// 届いている結末を**待たずに**照らし、結末の届いた投入を持ち主へ知らせる ([#2199])。打ち切られたと
    /// 確かめられた投入なら、持ち主が記帳を取り消す。
    ///
    /// **描き切りの頭で呼ぶ** (`Canvas.flush`・計算と控えの早い投入・写しを読む口)。取り消すのは印だけで
    /// (届けていない控えを立て直す・焼いた指紋を忘れる・書き込み待ちを立て直す・拡大の後に変わった印を
    /// 立てる・写しの「映した」を下ろす)、届け直すのはその後の普段の経路である。作った面の塗りだけは、
    /// 持ち主がその場で塗り直す。完了の知らせ (``releaseOnNotice(upTo:)``) でも呼び、正常に終わった投入の
    /// 分を刈る。
    ///
    /// 結末がまだ届いていない投入は残し、次に呼ばれたときに問い直す。だから打ち切りから結末が届く
    /// までのフレームは、古い中身のまま描く (案 A' の代償)。描き切りの間 (``holdRevocations()``) と、
    /// コマンドを組み立てている最中は照会しない。
    ///
    /// **打ち切りの無い経路では確保しない。** 置き場は持ち回り、預けは値として並べる。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func revokeDroppedDeliveries() {
        guard !settlements.isEmpty, revocationHolds == 0, !isSettling, slotOfOpenCommands.isEmpty
        else { return }
        isSettling = true
        defer { isSettling = false }
        commandFaults.outcomes(of: settlements.lazy.map(\.submission), into: &settlementOutcomes)
        // **知らせる前に預け先を片付ける。** 持ち主が知らせの中で預け直しても、ここは触らない
        var kept = 0
        for index in settlements.indices {
            if let dropped = settlementOutcomes[index] {
                let settled = settlements[index]
                settledObservers.append((settled.submission, settled.observer, dropped))
            } else {
                settlements[kept] = settlements[index]
                kept += 1
            }
        }
        settlements.removeSubrange(kept...)
        for settled in settledObservers {
            if settled.dropped { droppedDeliveriesRevoked += 1 }
            settled.observer?.submissionSettled(settled.submission, dropped: settled.dropped)
        }
        settledObservers.removeAll(keepingCapacity: true)
    }

    /// 番号 `submission` の投入が絵を届けられなかったかを、**待たずに**答える ([#2735])。結末がまだ届いて
    /// いなければ `nil`、打ち切られた・結末を失ったなら `true`。
    ///
    /// 絵を渡す口 (道具の窓の出し直し・共有の面の名乗り) が使う。``droppedWork(after:through:)`` と違って
    /// 眠らないので、毎フレーム main actor で呼べる。**確かめられないものは届けられなかった側へ倒す** —
    /// ``revokeDroppedDeliveries()`` の照会 (正常の側へ倒す) とは逆で、倒し違えても絵を 1 回余計に出すか、
    /// 1 枚名乗りを見送るだけで済む (``CommandFaultLog/undelivered(_:)``)。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    func undelivered(_ submission: UInt64) -> Bool? {
        commandFaults.undelivered(submission)
    }

    /// ``droppedWork(after:through:)`` の**待たない**形 ([#2743])。範囲の結末がまだ全部届いていなければ
    /// `nil` を返し、眠らない。答えの倒し方は ``CommandFaultLog/settledDrops(after:through:)``。
    ///
    /// 出口へ絵を配る口 (`SketchRuntime`) が使う。配る時点で結末が届いていなければ、配るのを次の
    /// フレームへ持ち越す — 毎フレームの経路で待ちを増やさないためである (ADR-0023 決定 5 と同じ線)。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    func settledDrops(after floor: UInt64, through last: UInt64) -> [CommandFaultLog.Drop]? {
        guard last > floor else { return [] }
        return commandFaults.settledDrops(after: floor, through: last)
    }

    /// 番号が `floor` より大きく `last` 以下の投入のうち、GPU が打ち切ったもの (番号の昇順)。
    /// **その範囲の結末が届くまで待つ** ([#1932])。
    ///
    /// 投げる読む口 (`RenderTarget` の `readPixels()`・`encodeForDisplay(scale:)` と、それを通る口) が、
    /// 返す絵の拠った範囲を判定するのに使う。**合図が進んでも結末はまだ届いていないことがある**ので、
    /// ``settle()`` や ``waitForSubmission(_:)`` を待ち終えた後でも、ここで結末を待つ。届いてから
    /// 判定するので、同じ打ち切りには毎回同じ答えを返す ([#1065] の完了条件 5 が「たまに投げる」を
    /// 退けた理由に当たらない)。
    ///
    /// **待つ上限 (``outcomeWaitLimit``) までに届かなかった結末は、打ち切りとして答える**
    /// (``CommandFaultLog/lostReason(after:)``)。合図は待ち終えているので、仕事は終わっていて、
    /// 欠けたのは知らせである。``waitFailure(faults:)`` は使わない — あれは合図が来なかったときの
    /// 名乗りで、`.timedOut` の「描きすぎ」は、合図が届いた後のここでは読んだ人を間違った方向へ
    /// 送る (#1932 の反証 9)。欠けた番号は記録の上で先へ進めるので、以後の読みはそこで止まらない。
    ///
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    ///
    /// - Parameter limit: 待つ上限。省けば ``outcomeWaitLimit``。`.zero` なら待たずに、届いていない結末を
    ///   届かなかったものとして答える — 塞がずに閉じる口が、見に来続けて上限を過ぎたときに使う
    ///   (`SketchRuntime.closePlugins(_:)`・[#2743])。待っていないので ``outcomeWaits`` には数えない。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    func droppedWork(
        after floor: UInt64, through last: UInt64, waitingUpTo limit: Duration? = nil
    ) -> [CommandFaultLog.Drop] {
        guard last > floor else { return [] }
        let limit = limit ?? outcomeWaitLimit
        let answer = commandFaults.drops(after: floor, through: last, waitingUpTo: limit)
        if answer.waited, limit > .zero { outcomeWaits += 1 }
        if answer.lost {
            Diagnostics.warn(
                "Waited \(outcomeWaitLimit) for the GPU to report how its finished work ended, with no answer — treating that work as dropped")
        }
        return answer.drops
    }

    /// 共有しているメモリへ**書く前**の待ち。待てたかを返す。
    ///
    /// **`false` を返したら書かない。** 待ちが期限切れになったことは、GPU がそのメモリを
    /// 使い終えた証拠ではない — 書けば、走っているかもしれない仕事の足元で入力が変わる
    /// ([#934])。5 秒返らない GPU は壊れているのでここで凝らないのは
    /// ``settleQuietly(orWarn:)`` と同じだが、**投げないことと書いてよいことは別**である。
    ///
    /// 読む側はこちらを使わない。読みは取りやめようが無い (何かを返さねばならない) ので、
    /// 古い値が返ることを警告で名乗るところまでが限界になる。
    ///
    /// **毎フレーム書く口はこれを通らない。** 数の並びと画像は控えを積むだけで、描き切りが
    /// GPU 側のコピーで届ける ([#749])。ここを通るのは、控えに載せられないほど大きい
    /// 書き込みの逃げ道と、読み戻しの口 (描き切りを通らない) と、字形の面である。
    ///
    /// **`@discardableResult` は付けない。** 返り値を捨てるには `_ =` と書くことになり、
    /// 「待たずに書いた」経路が字面に残る。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    /// [#934]: https://github.com/mokume-metal/mokume/issues/934
    func settleBeforeWriting(orWarn note: String) -> Bool {
        do {
            try settle()
            return true
        } catch {
            Diagnostics.warn("\(note): " + error.headline)
            return false
        }
    }

    /// 番号 `finished` までの投入が終わったときの後片付け。
    ///
    /// **2 つを 1 か所で行う** — 終わるまで抱えていたリソースを手放すことと、持ち主が
    /// 死んだリソースを常駐から外すこと ([#738])。契機が同じ (「番号 n まで終わった」) なので、
    /// 呼ぶ場所を分けると片方だけを呼ぶ経路ができる。
    ///
    /// 呼ばれるのは 4 か所である — ``settle()`` / ``beginCommands()`` /
    /// ``waitForSubmission(_:)`` と、投入の結末を受け取るハンドラ ([#1076])。
    /// **前の 3 つは消せない。** ハンドラの知らせは main actor へ渡してから効くので、
    /// main actor を明け渡さずに回り続ける経路 (フレームを連続で進める道具や検査) では
    /// 着地できず、``held`` が伸びる。あちらは「溜まらないための刈り」で、こちらは
    /// 「誰も頼まなくても畳めるようにするための刈り」である。
    ///
    /// **``held`` から辿れるものの `deinit` は、``settle()`` と
    /// ``waitForSubmission(_:)`` を呼んではならない。** どちらも `defer` でここを呼ぶので、
    /// `held.removeSubrange` の最中に再入し、同じ配列への排他アクセスが重なる。いま
    /// 成立しているのは ``retire(_:)`` が待たずに返る形だからである (#738)。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1076]: https://github.com/mokume-metal/mokume/issues/1076
    private func releaseFinished(through finished: UInt64) {
        if let last = held.lastIndex(where: { $0.submission <= finished }) {
            held.removeSubrange(...last)
        }
        guard let last = retired.lastIndex(where: { $0.submission <= finished }) else { return }
        for entry in retired[...last] { residencySet.removeAllocation(entry.allocation) }
        residencySet.commit()
        retired.removeSubrange(...last)
    }

    /// 番号 `previous` の投入を GPU 側で待つ命令を積む。
    ///
    /// この世代は別々に投入したコマンドの間の順序を自動では保証しない。CPU が毎回
    /// 待っていた間はそれで偶然成り立っていたが、待たなくなると「前のフレームが描画先を
    /// 読み終える前に次のフレームが消す」が起きうる。投入の直前にこれを積めば、GPU 上の
    /// 順序が投入順のまま保たれる。
    ///
    /// **待つ番号を引数で受け取る。** かつては `submissionCount` を「直前の番号」として
    /// 直に読んでいたが、番号を振る場所が動くと**その投入が自分自身の合図を待つ**形に
    /// 化ける (症状は GPU が 5 秒返らず空の絵が読める — #1063 とまったく同じ顔になる)。
    /// 字面に出しておけば、黙って化けることがない。
    private func orderAfter(_ previous: UInt64) {
        guard previous > 0 else { return }
        queue.waitForEvent(completion, value: previous)
    }

    /// 投入に振った番号の合図を出し、置き場へ書き戻す。
    ///
    /// **待つ経路も待たない経路も必ずここを通す。** 通さない経路があると、その置き場は
    /// 「終わったかどうか分からないまま巻き戻してよい」ことになってしまう。漏斗は
    /// ``commit(_:retaining:writing:)`` 1 つで、番号もそこで 1 か所だけ進む。
    ///
    /// **開く側の漏斗は ``withCommands(_:)`` である。** ここを通らずに組み立ての口を抜けた
    /// コマンドは、あちらが記録を消して置き場を手放す (#1180)。
    ///
    /// **番号を振るのはここではない。** 結末を受け取るお願いは投入と同時に渡す必要が
    /// あり、そのハンドラが「どこまで終わったか」を名乗るのに番号が要るので、振るのは
    /// 投入の手前である ([#1076])。
    ///
    /// [#1076]: https://github.com/mokume-metal/mokume/issues/1076
    private func recordSubmission(_ submission: UInt64, of commands: any MTL4CommandBuffer) {
        queue.signalEvent(completion, value: submission)
        if let index = slotOfOpenCommands.removeValue(forKey: ObjectIdentifier(commands)) {
            slots[index].submission = submission
        }
    }

    /// 組み立てたコマンドを投入する。**GPU の完了を待たない。**
    ///
    /// フレームを回す経路はこれで投入し、次に GPU 可視メモリへ触る直前に ``settle()``
    /// で待つ。その間の CPU の仕事 (次のフレームの頂点組み立て) が GPU と重なる。
    ///
    /// - Parameters:
    ///   - resources: このコマンドが読むもののうち、投入した側がすぐ手放す参照。
    ///     終わるまでこの型が抱える。
    ///   - surfaces: **このコマンドが中身を書き換える描画先** (図形・背景・書き戻し・効果・拡大・
    ///     塗り)。読み戻しや出力段のように読むだけなら渡さない。投げる読む口が、自分の面へ書いた投入の
    ///     打ち切りだけを持ち越し、自分の面へ書く新しい投入で下ろすのに使う ([#1932])。
    /// - Returns: 振った番号。
    ///
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    @discardableResult
    func commit(
        _ commands: any MTL4CommandBuffer, retaining resources: [AnyObject] = [],
        writing surfaces: [RenderTarget] = []
    ) -> UInt64 {
        // 答えの来ない番号 (検査の差し込み) の後ろに積むと、GPU 側がその番号を待って発行口ごと
        // 止まる。止める前に落とす (`addUnansweredSubmissionForTesting()`・#2052)
        precondition(
            unansweredSubmissionsForTesting == 0,
            "Submitted work after a submission that never answers — the queue would wait on it forever")
        commands.endCommandBuffer()
        // **増やす前に積む。** 順番が逆だと、この投入が自分自身の合図を待つ
        orderAfter(submissionCount)
        // **番号は投入の手前で振る。** お願いは投入と同時に渡すので、ハンドラが名乗る
        // 番号がその時点で決まっていなければならない (#1076)
        submissionCount += 1
        let submission = submissionCount
        let droppedForTesting = dropsNextSubmissionForTesting
        dropsNextSubmissionForTesting = nil
        let losesOutcomeForTesting = losesNextOutcomeForTesting
        losesNextOutcomeForTesting = false
        let holdsOutcomeForTesting = holdsNextOutcomeForTesting
        holdsNextOutcomeForTesting = false
        // **結末を受け取るお願いを添える。** 添えなければ Metal は打ち切りを捨てるので、
        // 描き上げられなかった仕事も「終わった」としか見えない (#1065)
        queue.commit(
            [commands],
            options: makeCommitOptions(
                finishing: submission, wrote: surfaces.map(ObjectIdentifier.init),
                droppedForTesting: droppedForTesting, losesOutcomeForTesting: losesOutcomeForTesting,
                holdsOutcomeForTesting: holdsOutcomeForTesting))
        recordSubmission(submission, of: commands)
        for surface in surfaces { surface.noteWritten(by: submission) }
        // **投入した本体も、終わるまで抱える。** 記録の実体は置き場 (allocator) にあるが、
        // 本体の寿命を GPU の実行より短くしない — 投入した側は直後に手放すので、
        // ここで抱えなければ実行中に消える
        held.append((submission, resources + [commands]))
        return submission
    }

    /// **投入済みのコマンドが読んでいるかもしれないもの**を、それが終わるまで抱える
    /// ([#1830] の 2 回目の反証 2)。待たずに返る。
    ///
    /// ``commit(_:retaining:writing:)`` が抱えるのは、投入するときに分かっているものだけである。投入の
    /// **後で**持ち主が差し替えるもの — 保存し直した断片を組み直して入れ替えた古いパイプラインの
    /// 状態 — は、投入したときには参照を手放す予定が無いので誰も抱えていない。この世代のコマンドは
    /// 読む相手を保持しない (Apple の「Understanding the Metal 4 core API」はリソースについてそう
    /// 書き、パイプラインの状態については書いていない。書いていないものは保持しないものとして
    /// 扱う) ので、前のフレームがまだ走っている間に手放すと、GPU が読んでいる途中で解放しうる。
    ///
    /// 番号は ``retire(_:)`` と同じ決め方で、組み立て中のコマンドがあればその 1 本の後まで待つ。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    func holdUntilSubmittedWorkFinishes(_ objects: [AnyObject]) {
        guard !objects.isEmpty else { return }
        let after = slotOfOpenCommands.isEmpty ? submissionCount : submissionCount + 1
        held.append((after, objects))
    }

    /// 組み立てたコマンドを投入し、GPU が終わるまで待つ。
    ///
    /// ``commit(_:retaining:writing:)`` と ``settle()`` の合成。1 枚だけ描く経路と、読み戻すために
    /// その場で結果が要る経路のための形。
    func commitAndWait(
        _ commands: any MTL4CommandBuffer, writing surfaces: [RenderTarget] = []
    ) throws(RenderFailure) {
        commit(commands, writing: surfaces)
        try settle()
    }
}

extension RenderDevice {
    /// 表示に使う面が空くのを待つよう予約する。差し出す面へ書く前に呼ぶ。
    func waitForDrawable(_ drawable: any MTLDrawable) {
        queue.waitForDrawable(drawable)
    }

    /// 組み立てたコマンドを投入し、**GPU の完了を待たずに**表示の合図を出す。
    ///
    /// 待たないのは、待てば表示のたびに CPU が止まり、フレームレートが GPU の
    /// 往復に縛られるため。差し出す面の同期は Metal 側の合図で足りる。
    ///
    /// **待たなくても番号は進める。** 進めないと、この経路で使った置き場だけが
    /// 「いつ終わったか分からない」まま環へ戻り、次の巻き戻しが実行中のコマンドを
    /// 踏む ([#222](https://github.com/mokume-metal/mokume/issues/222))。
    ///
    /// - Returns: 振った番号。差し出した側が結末を待つのに使う ([#2735])。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    @discardableResult
    func commit(_ commands: any MTL4CommandBuffer, signalling drawable: any MTLDrawable) -> UInt64 {
        // **投入の並びは ``commit(_:retaining:writing:)`` が持つ。** かつてはここにも同じ 5 行が
        // 書かれていた — 並びに 1 段足して片方だけ直すと、そのコマンドが抱えられないまま
        // GPU の実行中に消える。負荷のかかったときだけ出る形である (#222 が踏んだ)
        let submission = commit(commands)
        queue.signalDrawable(drawable)
        return submission
    }
}

/// 投入の後で記帳を進め、その投入の結末を待つ持ち主 ([#2199])。
///
/// 記帳 (届けた・焼いた・書き戻した・拡大した・映した・塗った) は結末を見ずに進むので、投入を GPU が
/// 打ち切ると、届いていない中身を届いたものとして使い続ける。持ち主は記帳した投入の番号を覚えて
/// ``RenderDevice/awaitSettlement(of:by:)`` で預け、結末が届いたらここで受ける。
///
/// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
@MainActor protocol SettlementObserver: AnyObject {
    /// 番号 `submission` の投入の結末が届いた。`dropped` なら打ち切られたと確かめられたので、その投入で
    /// 進めた記帳を取り消す。**まだその番号の記帳が生きているかは持ち主が見る** — 後の投入が同じ記帳を
    /// 進め直していれば、取り消さない。`dropped` が偽でも呼ぶので、番号ごとに覚えた分はここで手放す。
    func submissionSettled(_ submission: UInt64, dropped: Bool)
}
