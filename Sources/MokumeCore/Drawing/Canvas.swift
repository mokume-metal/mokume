// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
import simd

/// 絵を描く面。
///
/// ## 座標の約束
///
/// **原点は左上、単位は画素、縦軸は下向き。** そして**整数の座標は画素の中心に落ちる**。
///
/// 最後の約束が要るのは、輪郭の内側かどうかを画素の中心で判定するため。整数の座標を
/// そのまま画面の座標へ写すと、`x = 10` に引いた太さ 1 の線は 9.5 から 10.5 までを
/// 覆い、両端がちょうど画素の中心に乗る。どちらが塗られるかは境界の扱いに委ねられ、
/// 引いた場所とは違う画素が 1 つ塗られる。半画素ずらしておくと 10 から 11 までを覆い、
/// 中心 10.5 の画素だけがはっきり塗られる。
///
/// ## 描き方
///
/// <!-- example: 組めない Canvas を直に回す例で、投げられる場所に置かれる (draw() の中には貼れない) -->
/// ```swift
/// try canvas.draw {
///     canvas.background(.display(red: 0.1, green: 0.1, blue: 0.12))
///     canvas.fill(.display(red: 1, green: 0.4, blue: 0.2))
///     canvas.circle(400, 300, 200)
/// }
/// ```
///
/// 図形は溜められ、``draw(_:)`` を抜けるときにまとめて描かれる。
@MainActor
public final class Canvas {
    /// 幅 (画素)。**出す細かさ**で、スケッチが書く座標もこの中にある。
    public let width: Float
    /// 高さ (画素)。**出す細かさ。**
    public let height: Float

    /// 実際に刻む幅 (画素)。細かさが 1 なら ``width`` と同じ。
    public var pixelWidth: Int { target.width }
    /// 実際に刻む高さ (画素)。
    public var pixelHeight: Int { target.height }

    /// 描く先。**細かさに従う**ので、``output`` より小さいことがある。
    let target: RenderTarget

    /// 出す先。**すべての出口が受け取るのはこの 1 枚**である ([ADR-0023] 決定 2)。
    ///
    /// 細かさが 1 なら `target` と同じものを指す — 置き場も段も 1 つも増えない。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    public let output: RenderTarget

    /// 拡大の段。細かさが 1 なら `nil` で、**フレームは段の存在を一切払わない**。
    let upscaleStage: UpscaleStage?

    /// いまの絵が前のフレームの結果に依っているか。意味の説明は ``Sketch`` 側が正本。
    public var usesFrameHistory: Bool { upscaleStage?.kind.usesFrameHistory ?? false }

    /// 拡大が使う段の枠の数。立っていなければ 0。
    var upscalePassCount: Int {
        guard upscaleStage != nil else { return 0 }
        // 時間方向は、混ぜる 1 枠と次のフレームのために控える 1 枠
        return usesFrameHistory ? 2 : 1
    }
    let gpu: RenderDevice
    let pipeline: ShapePipeline

    /// 描画先の座標へ落とす行列。半画素のずらしを含む。
    private let projection: simd_float4x4
    private let projectionBuffer: any MTLBuffer

    /// 溜めている頂点と、その置き場。
    var vertices: [ShapeVertex] = []
    private var vertexBuffer: (any MTLBuffer)?
    private var vertexCapacity = 0

    /// 平面の置き場所。列は自分の区間を指す。
    ///
    /// **添字 0 は常に何も動かさない置き場所**で、畳めない列 (字・画像・その場で並べた
    /// 頂点) はここを指す。毎フレーム置き直すので、溜め場を捨てても消えない。
    var flatInstances: [FlatInstance] = [.identity]
    private var flatInstanceBuffer: (any MTLBuffer)?
    private var flatInstanceCapacity = 0

    /// いま開いている平面の雛形。
    ///
    /// **同じ形・同じ様式が続く間は、頂点を置き直さずに置き場所だけを足す。** 形か様式が
    /// 変わったら (あるいは畳めないものが来たら) 閉じて開き直す。立体の ``openSolid``
    /// と対になる。
    var openFlat: OpenFlat?

    /// 雛形そのものを組み立てている最中か。
    ///
    /// **雛形の頂点も `appendTriangle` を通る**ので、そこで「畳めない頂点が来た」と
    /// 判定されないよう区別する。形を組み立てるコードを畳む側と畳まない側で 2 本に
    /// 増やさないための旗である。
    private var buildingFlatTemplate = false

    /// 保持する形を記録している最中か。**記録の間は畳まない。**
    ///
    /// 保持した形は自分で畳む仕組みを持つ ([#241](https://github.com/mokume-metal/mokume/issues/241)) —
    /// 記録するのは頂点と区間だけで、置き場所は持ち歩かない。記録の中で畳むと、形自身の
    /// 座標へ寄せた頂点だけが残り、**どこへ置くかが記録から落ちる**。
    var recordingShape = false

    /// 畳む相手を待っている図形。**今までどおり置かれた 1 つ目**である。
    ///
    /// 同じ形が 2 つ目に来たら、ここに控えた周から雛形を積み直して畳む。1 つ目から
    /// 雛形を開かないのは、**平面が元から 1 つの列にまとまる**ためで、図形ごとに列を
    /// 割ると畳む前より遅くなる場面 (矩形と円を交互に置く絵) が出る。
    private var pendingFlat: PendingFlat?

    /// 畳む相手を待っている図形ひとつぶん。
    private struct PendingFlat {
        var key: FlatKey
        /// 形自身の座標での周。雛形を積み直すのに要る。
        var outline: Outline
        /// この図形の置き場所。畳んだときは 1 つ目の置き場所になる。
        var placement: FlatInstance
        /// 溜め場の中でこの図形が占めている区間。**抜けるのは末尾にいる間だけ。**
        var vertexStart: Int
        var vertexEnd: Int
        /// 置いた時点の列の数。**列が閉じていたら抜けない** (閉じた列の区間が動く)。
        var batchCount: Int
    }

    /// 開いている平面の雛形ひとつぶん。
    struct OpenFlat {
        /// 何を並べているか。**これが変わったら閉じる。**
        var key: FlatKey
        /// 輪郭の頂点が始まる位置 (並び全体での番号)。塗りしか無ければ並びの終わり。
        var strokeStart: Int
        /// 置き場所の並びの中で、この雛形が始まる位置。
        var instanceStart: Int
    }

    /// 平面を畳む鍵。**これが等しい図形どうしだけが 1 つの雛形に収まる。**
    ///
    /// 変換も色も入っていない — どちらも置き場所が持つためである。円の分割数は半径から
    /// 決まる (``segmentCount(forRadius:)``) ので、寸法が入った時点で分割数も一致する。
    struct FlatKey: Equatable {
        var form: FlatForm
        var hasFill: Bool
        var hasStroke: Bool
        var strokeWeight: Float
        var strokeCap: StrokeCap
        var strokeJoin: StrokeJoin
        /// 塗りに貼る絵があるか。読み取り位置が寸法から決まるので鍵に入る。
        var textured: Bool
    }

    /// 畳める図形の形。
    ///
    /// **中心 (あるいは角) と寸法から組み立てられる図形だけがここに居る。** 三角形・
    /// 四角形・線・点は「形自身の座標」の基準点が最初の点になり、引き算を挟むぶん
    /// 畳まないときの絵と食い違いうる。畳める頂点数も小さいので、実需が出るまで
    /// 足さない ([ADR-0008](docs/decisions/0008-mechanism-needs-demonstrated-harm.md))。
    enum FlatForm: Equatable {
        case rect(width: Float, height: Float)
        case ellipse(radiusX: Float, radiusY: Float)
        case arc(radiusX: Float, radiusY: Float, start: Float, sweep: Float)
    }

    /// 溜めている立体の頂点と、その置き場。
    ///
    /// 平面とは別の並びにする — 頂点の中身が違う (奥行きと面の向きを持つ) ためで、
    /// **順序は列が持つ**ので、別の並びにしても呼び出し順は崩れない。
    var solidVertices: [SolidVertex] = []
    /// 立体の置き場所。列は自分の区間を指す。
    var solidInstances: [SolidInstance] = []
    /// いま開いている立体の列。
    ///
    /// **同じ形が続く間は、頂点を置き直さずに置き場所だけを足す。** 形が変わったら
    /// (あるいは列を分ける設定が変わったら) 閉じて開き直す。
    var openSolid: OpenSolid?
    /// 1 つの列に入れる置き場所の上限。
    ///
    /// **仕組みの都合ではなく規律である。** 無制限にすると「まとめきれずに列を分ける」
    /// 経路が普段は絶対に通らないものになり、検査できない分岐が残る (#297 の
    /// 気をつけること)。検査からはここを下げて、その経路を必ず踏ませる。
    var instanceCapacity = Canvas.defaultInstanceCapacity
    /// 上限の既定。
    static let defaultInstanceCapacity = 8192

    /// 開いている立体の列ひとつぶん。
    struct OpenSolid {
        /// 何の頂点を並べているか。**これが変わったら列を閉じる。**
        var source: SolidSource
        /// 頂点の並びの中での区間。
        var vertexStart: Int
        var vertexCount: Int
        /// 置き場所の並びの中で、この列が始まる位置。
        var instanceStart: Int
        /// 置き場所を**外の置き場**から取るなら、その置き場と個数。
        ///
        /// `nil` なら溜め場の並び (いつもの経路)。粒だけがここを使う — 置き場所を
        /// 埋めるのが GPU なので、CPU の溜め場を通らない。
        var external: ExternalInstances?
        /// 半透明の塗りの置き場所を 1 つでも足したか。
        ///
        /// 塗りを変えても列は閉じないので、1 つの列に不透明と半透明が同居する。
        /// 半透明の形は奥の面が手前の面を通して見えるので、1 つでも居れば列ごと
        /// 両面で描く (``Batch/cullMode``)。
        var hasTranslucentInstance = false
    }

    /// 溜め場ではなく、外の置き場から置き場所を取る指定。
    struct ExternalInstances {
        var buffer: any MTLBuffer
        /// 置き場所の上限 (置き場の大きさ)。**実際に描く数は GPU が `arguments` に書く。**
        var count: Int
        /// 描く引数 (`MTLDrawPrimitivesIndirectArguments`)。GPU が書くので、描く側は
        /// 個数を読まずにそのまま indirect draw へ渡す。
        var arguments: any MTLBuffer
    }

    /// 立体の頂点が何から来たか。
    enum SolidSource: Equatable {
        /// 組み込みの形。同じ寸法なら頂点を置き直さない。
        case mesh(SolidShape)
        /// その場で並べた頂点・線と点・背景。置き場所は 1 つ (何も動かさない)。
        case freeform
        /// 保持した形の区間。**呼ぶたびに番号が変わる**ので、続けて置いても
        /// 別の列になる (同じ形かどうかを値の比較で調べない)。
        case retained(serial: Int)
        /// 読み込んだモデル。同じモデルが続く間は頂点を置き直さない。
        case model(identity: Int)
    }

    /// 読み込んだモデルの控え。**同じファイル・同じ整え方なら読み直さない。**
    var modelCache: [ModelRequest: Model] = [:]
    /// モデルを読むたびに増える番号。
    var nextModelIdentity = 0
    /// 面の無いモデルを置いたことを知らせたか。
    var warnedEmptyModel = false

    /// 保持した形を置くたびに増える番号。
    var retainedSerial = 0
    /// 置けない置き場所を知らせたか。
    var warnedBadPlacement = false
    private var solidVertexBuffer: (any MTLBuffer)?
    private var solidVertexCapacity = 0

    /// いま開いている列が、どちらの並びから描かれるか。
    var openSource = VertexSource.flat

    /// 使い回している立体の形と、最後に使った時刻。
    var solidMeshes: [SolidShape: SolidMesh] = [:]
    var solidMeshUse: [SolidShape: Int] = [:]
    var solidMeshClock = 0
    /// 立体の形を組み立てた回数 (作ってから通算)。
    ///
    /// **畳めているかではなく、作り直していないかを数える値。** 絵は同じでも毎フレーム
    /// 組み立て直していれば確保が積み上がるので、絵ではなく数で確かめる。
    var solidMeshesBuilt = 0
    /// 使い回しの表に置いておく形の数。超えたら古い順に半分捨てる。
    static let solidMeshCacheLimit = 64
    /// 一周を割る数の既定。
    public static let defaultSolidDetail = 24

    /// 置けない寸法を知らせたか。
    var warnedBadSolidSize = false

    /// いま効いている光。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// 上限を持たない — 固定の枠を持つと、超えた光が黙って捨てられる。列が「置き場の
    /// どこから何個か」を持つ形にしてあるので、数はいくつでも同じ仕組みで届く。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var activeLights: [Light] = []
    /// 列ごとに焼き付けた光を並べたもの。列は自分の区間を指す。
    ///
    /// 列が閉じた時点の光を**写して**持つ。参照で持つと、あとから光を足したときに
    /// 既に置いた立体の明るさまで変わる (記録した列だけで絵が決まらなくなる)。
    private var lightStorage: [Light] = []
    /// 光の置き場。
    private var lightBuffer: (any MTLBuffer)?
    private var lightCapacity = 0
    /// 列ごとの「光がどこから何個か」の置き場。
    private var lightingBuffer: (any MTLBuffer)?
    private var lightingCapacity = 0
    /// フレームの外で光が置かれたことを知らせたか。
    var warnedLightOutsideFrame = false

    /// いま効いている材質。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var currentMaterial = Material.default
    /// 列ごとの材質の置き場。列 1 つにつき 1 区画。
    private var materialBuffer: (any MTLBuffer)?
    private var materialCapacity = 0
    /// フレームの外で材質が書かれたことを知らせたか。
    var warnedMaterialOutsideFrame = false
    /// 受け取れない材質の値を知らせたか。
    var warnedBadMaterial = false
    /// 受け取れない露出を知らせたか。
    var warnedBadExposure = false

    /// いま置かれている周囲。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// 光と同じく「置く」ものなので、積んだスタイルには入れない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var activeSurroundings: Surroundings?
    /// いま組み立てている列が**周囲そのものを出す**なら、その周囲。
    ///
    /// 背景の面だけが立てる旗で、置いてある周囲とは別に持つ — 背景に出す周囲と
    /// 映り込む周囲は、別々に選べる (片方だけ呼んでもよい)。
    var backdrop: Surroundings?
    /// 列ごとの周囲の置き場。列 1 つにつき 1 区画。
    private var surroundingsBuffer: (any MTLBuffer)?
    private var surroundingsCapacity = 0
    /// フレームの外で周囲が置かれたことを知らせたか。
    var warnedSurroundingsOutsideFrame = false
    /// 受け取れない周囲を知らせたか。
    var warnedBadSurroundings = false
    /// 受け取れない揺らぎの設定を知らせたか。
    var warnedBadNoise = false

    /// 影を落とすか。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shadowsEnabled = false
    /// 焼き付ける範囲の一辺。`nil` なら面から導く。
    var shadowRangeValue: Float?
    /// 焼き付け先の一辺の画素数。
    var shadowDetailValue = ShadowMap.defaultDetail
    /// 縁の破綻を抑える量。
    ///
    /// 斜めに当たる面ほど、焼いた 1 画素の中で奥行きが大きく変わる。**自分の影が
    /// 自分の上に縞として出る**のを抑えるための余裕で、大きくしすぎると影が浮く。
    var shadowBiasValue: Float = 0.0025

    /// 揺らぎの種と細かさ。
    ///
    /// **描画の状態として持つ。** 断片からも同じ値が引けるよう uniforms を通って
    /// 送られるためで、置き場が 2 つに割れると CPU と断片で別の模様が出る ([#366])。
    ///
    /// [#366]: https://github.com/mokume-metal/mokume/issues/366
    var noiseSettings = ValueNoise()
    /// 焼き付け先。**同じ細かさなら作り直さない** (同 決定 4)。
    private var shadowMap: ShadowMap?
    /// 焼き付け先を作った回数 (作ってから通算)。
    ///
    /// **作り直していないかを数える値。** 毎フレーム宣言してよい形にした以上、
    /// 宣言のたびに確保していないことは絵では分からない。
    private(set) var shadowMapsBuilt = 0
    /// 焼き上がりを待つ仕掛けを積んだ回数 (作ってから通算)。
    ///
    /// **仕掛けが入っていることを数える値。** 抜けていても絵は普段どおり出て、
    /// GPU が混んだときだけ稀に前のフレームが混ざる ([#341]) ので、
    /// 抜けたことに絵で気付く道が無い。積む 1 行と同じ場所で数え、
    /// **その行を消したら数も減る**ようにしてある。
    ///
    /// [#341]: https://github.com/mokume-metal/mokume/issues/341
    private(set) var shadowBarriersEncoded = 0
    /// 溜めた計算。描く前に流し、フレームの終わりに空になる。
    var pendingComputations: [ComputeDispatch] = []
    /// この面が作った計算。観測へ失敗を載せるために持つ。
    var computations: [Computation] = []

    /// このフレームにかける効果の並び。**フレームを越えない** (ADR-0021 決定 4)。
    var pendingEffects: [Effect] = []
    /// 作った効果の断片。保存の拾い直しのために持ち続ける。
    var effectShaders: [EffectShader] = []
    /// 効果のパイプライン。**頼まれてはじめて作る。**
    var effectPipelineStorage: EffectPipeline?
    /// 積んだ待つ仕掛けの数。**積む 1 行と同じ場所で数える。**
    var effectBarriersEncoded = 0
    /// 検査から「途中で失敗した段」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 段の失敗は資源が枯れたときにしか起きず、検査から自然には作れない。一方で
    /// **途中で失敗したときに何が出るか**は、この Issue の完了条件そのものなので、
    /// ここに 1 つだけ穴を空けてある (`failureForTesting` と同じ形)。公開はしない。
    var failEffectPassForTesting: Int?
    var warnedEffectFailed = false
    /// 通した段の数。
    var effectPassesEncoded = 0
    /// このフレームで使った段の枠の数。**効果と拡大が同じ採番から取る。**
    ///
    /// 引数のテーブルは枠ごとに別のものでなければならない — 1 枚を使い回して番地を
    /// 書き換えると、まだ走っていない枠の束ね先まで変わる (#391 で実際に踏んだ)。
    /// 採番を 2 系統に分けると、効果と拡大が同じ番号を取り合う。
    var stagePassesUsed = 0
    var warnedUpscaleFailed = false

    /// 粒の置き場所を誰が埋めるか。**製品では GPU 側 (速い経路)。**
    ///
    /// 公開しない — 利用者が選ぶものではなく、速い経路を照らす物差しを検査から
    /// 差し替えるための口である。
    var particleRoute: ParticleRoute = .instanced
    var warnedParticlesOutsideFrame = false
    /// 計算のパイプライン。**最初に計算を作るときだけ組む** — 使わないスケッチに
    /// 組み立て器と引数のテーブルを持たせないため。
    private var computePipelineStorage: ComputePipeline?
    /// 計算の口を開いた回数・閉じた回数 (作ってから通算)。
    ///
    /// **開きっぱなしを数えるための組。** 開いたまま返る経路があると、そのフレームの
    /// コマンドは投入できず、症状は「絵が止まる」としてしか出ない。数が食い違わない
    /// ことを検査が見る。書き込むのは `Canvas+Compute` の流す経路だけ。
    var computeEncodersOpened = 0
    var computeEncodersClosed = 0
    /// 計算のあとに次の段が待つ仕掛けを積んだ回数 (作ってから通算)。
    ///
    /// 影の側 (``shadowBarriersEncoded``) と同じ理由で持つ — 抜けていても絵は普段どおり
    /// 出て、GPU が混んだときだけ稀に書き終わる前の並びが読まれる。積む 1 行と同じ場所で
    /// 数え、**その行を消したら数も減る**。
    var computeBarriersEncoded = 0
    /// フレームの外で計算を頼んだことを知らせたか。
    var warnedComputeOutsideFrame = false
    /// 束ねられる本数を超えたことを知らせたか。
    var warnedTooManyComputeBuffers = false
    /// 影の行列を置く領域。
    private var shadowMatrixBuffer: (any MTLBuffer)?
    /// フレームの外で影の設定を書いたことを知らせたか。
    var warnedShadowOutsideFrame = false
    /// 受け取れない影の値を知らせたか。
    var warnedBadShadow = false
    /// 光の無いところで材質を書いたことを知らせたか。
    private var warnedMaterialWithoutLight = false
    /// 映す先が無いまま金属を上げたことを知らせたか。
    private var warnedMetalWithoutSurroundings = false

    /// いま効いている視点。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// `nil` の間は面に合わせた既定を使う。既定を実体で持たないのは、面の大きさが
    /// 変わったときに古い既定が残らないようにするため。
    var cameraStorage: Camera?
    /// フレームの外で視点が書かれたことを知らせたか。
    var warnedCameraOutsideFrame = false
    /// 成り立たない視点・投影を知らせたか。
    var warnedBadCamera = false

    /// いま `draw(_:)` の中か。
    ///
    /// シーンの記述 (光・視点) は、フレームの外で書かれてもどのフレームにも属さない。
    /// 黙って捨てず警告するために、内と外を知る必要がある ([ADR-0021] 決定 4)。
    private(set) var isDrawing = false

    /// 対になっていない ``beginDraw()`` / ``endDraw()`` を知らせたか。
    private var warnedAlreadyDrawing = false
    private var warnedNotDrawing = false
    /// 描き切る前の描き場所を置いたことを知らせたか。
    private(set) var warnedPlacingWhileDrawing = false

    /// いま描き切っている最中か。**入れ子の描き場所で戻ってくるのを止める。**
    private var isFlushing = false

    /// このフレームで描き切った回数。**奥行きを引き継ぐかの判定に使う。**
    private var passesThisFrame = 0

    /// このフレームで置いた描き場所。
    ///
    /// **置いた時点の絵を守るために覚えている。** 溜めてから描くので、置いたあとに
    /// その描き場所が描き換わると、先に置いた場所まで最新の絵に化ける。
    private(set) var placedGraphics: Set<ObjectIdentifier> = []

    /// 自分を置いた面。**自分の絵が変わる前に、そちらを先に描き切らせる。**
    ///
    /// 弱く持つ — 描き場所は利用者が持つもので、置いた側が寿命を延ばす筋合いが無い。
    private(set) var placers: [WeakCanvas] = []

    /// 弱く持つ面ひとつぶん。
    struct WeakCanvas {
        weak var canvas: Canvas?
    }

    /// このフレームで塗り直す色。`nil` なら前の内容の上に描き足す。
    private var pendingBackground: LinearRGBA?

    // MARK: - 描く状態

    var currentFill = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    var currentStroke = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    var currentStrokeWeight: Float = 1
    var transform = Transform.identity
    private var transformStack: [Transform] = []
    private var currentRectMode = ShapeMode.corner
    private var currentEllipseMode = ShapeMode.center
    var currentStrokeCap = StrokeCap.round
    var currentStrokeJoin = StrokeJoin.miter
    var hasFill = true
    /// これから置く形が影を落とすか。
    var castsShadow = true
    /// これから置く形が影を受けるか。
    var receivesShadow = true
    var hasStroke = true
    private var styleStack: [Style] = []
    var currentBlendMode = BlendMode.blend
    var currentClip: MTLScissorRect?
    /// このフレームで画素を読める状態にしたか。フレームごとに戻る。
    var hasLoadedPixels = false

    private var warnedReversedArc = false
    var warnedVertexOutsideShape = false
    var warnedBadVertex = false

    // MARK: 文字

    /// 字形を焼いて溜める面。**図形もここの白い区画を読む** (``GlyphAtlas``)。
    let atlas: GlyphAtlas
    /// いま列が読んでいる面。面を広げる・画像を描くと差し替わる。
    var currentTexture: any MTLTexture
    /// いま効いている塗り。`nil` なら組み込み。
    var currentShader: Shader?
    /// いま塗りが読む数の並び。`nil` なら読まない。
    var currentNumbers: Numbers?
    /// 渡されていないときに読ませる並び。**1 個の 0。**
    ///
    /// 何も束ねない口を作らないために置く — 束ねずに走らせると、断片が読んだ瞬間に
    /// 絵の乱れではなく異常終了になる。
    private var emptyNumbers: Numbers
    /// この面が作った塗り。観測へ失敗を載せるために持つ。
    var shaders: [Shader] = []
    /// 図形が指す、白い区画の中の点。面を広げるたびに取り直す。
    var whiteUV: SIMD2<Float>
    /// 引き当てた書体の控え。同じ指定で作り直さないために持つ。
    private var typefaces: [TypefaceRequest: Typeface] = [:]

    var currentFontName: String?
    var currentTextSize: Float = 12
    var currentTextStyle = TextStyle.normal
    var currentHorizontalTextAlign = HorizontalTextAlign.left
    var currentVerticalTextAlign = VerticalTextAlign.baseline
    /// 行送りの指定。`nil` は自動 (大きさから決める)。
    var currentTextLeading: Float?
    var currentTextWrap = TextWrap.word

    // MARK: 画像

    var currentImageMode = ShapeMode.corner
    /// 画像に掛ける色。既定は掛けない (白・不透明)。
    var currentTint = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    /// これから置く**塗り**に貼る絵。`nil` なら貼らない。
    ///
    /// **描き方なのでフレームを越える** ([ADR-0021] 決定 4) — 塗り・線・混ぜ方と
    /// 同じ族である。効く先は塗りだけで、輪郭・端点・角・線と点・字・周囲は
    /// 焼き場の白い区画を読み続ける。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var currentPicture: Picture?
    var warnedMissingFont = false
    var warnedAtlasFull = false

    // MARK: - 組み立て中の形

    /// 並べている途中の頂点。``beginShape(_:)`` から ``endShape(_:)`` までの間だけ中身を持つ。
    ///
    /// **平面と立体で同じものを溜める** ([ADR-0021] 決定 5)。奥行き・面の向き・頂点ごとの
    /// 色は「頂点の性質」であって、形の種類ごとの対応表ではない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shapePoints: [BuildingVertex] = []
    /// 並べ終えた穴。
    var shapeHoles: [[BuildingVertex]] = []
    /// 穴を並べている最中なら、その点。
    var holePoints: [BuildingVertex]?
    var shapeKind = VertexKind.polygon
    var isBuildingShape = false
    /// この形が奥行きを持つか。**奥行きを渡す形で頂点を 1 つでも置いたら立体になる。**
    var shapeHasDepth = false
    /// いま効いている面の向き。`nil` は未指定 (形から求める)。
    var currentNormal: SIMD3<Float>?
    var currentCurveDetail = 20
    var currentCurveTightness: Float = 0
    /// 通過点を結ぶ曲線の制御点。4 つ揃うごとに 1 区間を引く。
    var curveGuides: [SIMD2<Float>] = []

    /// 閉じた列。**同じ列は単一の混ぜ方でしか描かれない。**
    ///
    /// 混ぜ方を変える操作がその時点で列を閉じるので、既に置いた図形が後の設定で
    /// 描かれることがない。閉じ忘れると絵は「たまに」おかしくなる — 設定を変えない
    /// 単純なスケッチでは一生出ないので、規律として持つ。
    var batches: [Batch] = []

    /// 閉じた列ひとつぶん。
    ///
    /// **切り抜き以外は保持した形の区間と同じもの**なので、``Shape/Run`` をそのまま
    /// 使う。切り抜きだけが別なのは、切り抜きが描画先の座標で効く — つまり形と一緒に
    /// 持ち運べない — ためである。
    ///
    /// 落とす行列を**列が持ち歩く**のは、記録した列だけで絵が決まるようにするため
    /// ([ADR-0021] 決定 2・3)。描くときに「いまの見る位置」を読み直すと、1 フレームの
    /// 中で視点を変えたときに全部が最後の視点で描かれる。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    struct Batch {
        var run: Shape.Run
        var clip: MTLScissorRect?
        /// この列を描画先の座標へ落とす行列。
        var matrix: simd_float4x4
        /// この列に効く光が、置き場のどこから何個あるか。
        var lightRange: Range<Int>
        /// この列を描く材質。**閉じた時点のもの**が入る (光と同じ理由)。
        var material: Material
        /// この列を見ている場所。艶が見る向きで変わるので、材質と対で持ち歩く。
        var viewer: SIMD4<Float>
        /// この列に効く周囲。**閉じた時点のもの**が入る (光と同じ理由)。
        var surroundings: PackedSurroundings
        /// この列が影を落とす側か。焼き付けるときに、この旗で選り分ける。
        var castsShadow: Bool
        /// この列の置き場所が、置き場のどこから何個あるか。
        ///
        /// 畳めない列は**何も動かさない置き場所を 1 つ**指す (平面なら添字 0)。
        var instanceStart: Int = 0
        var instanceCount: Int = 1
        /// 置き場所をどこから読むか。`nil` なら溜め場を写した置き場。
        var instances: (any MTLBuffer)?
        /// 描く個数を GPU が書いた引数。`nil` なら `instanceCount` で描く (いつもの経路)。
        ///
        /// 粒だけがここを使う — 生きている粒の数は CPU が知らないので、数えた GPU が
        /// 書いた引数をそのまま indirect draw に渡す。
        var indirectArguments: (any MTLBuffer)?
        /// 輪郭の頂点が始まる位置 (並び全体での番号)。**平面だけが使う。**
        ///
        /// 頂点関数はここより手前に塗りの色を、ここから後ろに輪郭の色を掛ける。
        /// 畳んでいない列は塗りしか無い扱いでよい — 置き場所の 2 色がどちらも白で、
        /// どちらを掛けても値が変わらないためである。
        var strokeStart: Int = .max
        /// 裏を向いた面をどう扱うか。
        ///
        /// 既定は両面を描く (`.none`)。**閉じた組み込みの形の、不透明な列だけ**が裏面を
        /// 捨てる (`.back`) — 閉じた形では表の面が必ず裏の面を隠すので、捨てても絵は
        /// 変わらず、断片の仕事 (影の読み取りを含む) が裏面のぶんだけ減る
        /// ([#756](https://github.com/mokume-metal/mokume/issues/756))。動きうるのは輪郭の
        /// 縁で表と裏が同じ奥行きを争っていた画素だけで、それは表の色に確定する
        /// (台帳の `shadows` で 1 画素・2 階調が動いた実測が #756 の PR にある)。
        ///
        /// 裏面が絵に出うるものは全部 `.none` に居続ける: 片面の形 (`plane`)・自分で並べた
        /// 頂点・保持した形・読み込んだモデル (閉じているか分からない)・半透明の置き場所を
        /// 含む列・貼る絵 (透けた画素から奥が見える)・重ねる混ぜ方・利用者の断片 (透明を
        /// 返したり画素を捨てたりできる)。**判定は列を閉じる側 (`closeSolidBatch`) が
        /// 1 箇所で行い**、描く側はこの値を掛けるだけにする。
        var cullMode: MTLCullMode = .none

        /// どちらの並びから描くか。**区間が持っているものをそのまま読む** —
        /// 保持した形が持ち歩くのと同じ値なので、2 つ持つと食い違いうる
        var source: VertexSource { run.source }
    }

    /// 列がどちらの並びから描かれるか。
    enum VertexSource {
        /// 奥行きを持たない図形・字・画像。
        case flat
        /// 奥行きを持つ立体。
        case solid
    }

    /// 混ぜ方の番号を置いた領域。列ごとに番地をずらして指す。
    private let blendModeBuffer: any MTLBuffer
    /// フレームを通して変わらない値 (時刻・面の大きさ) の置き場。
    private let uniformsBuffer: any MTLBuffer
    /// 列ごとの、利用者が渡した値の置き場。列 1 つにつき 1 区画。
    private var valuesBuffer: (any MTLBuffer)?
    private var valuesCapacity = 0
    /// 列ごとの、描画先の座標へ落とす行列の置き場。列 1 つにつき 1 区画。
    private var matrixBuffer: (any MTLBuffer)?
    private var matrixCapacity = 0
    /// 1 区画の大きさ (バイト)。定数の受け渡しの境界に揃える。
    private static let valuesStride = 256
    /// 1 区画に収まる値の数 (float 換算)。**塗りへ渡せる値の上限**でもある。
    ///
    /// 上限を超える宣言は読み込みの入口 (`Canvas.loadShader` / `makeShader`) で断る
    /// ([#348](https://github.com/mokume-metal/mokume/issues/348))。
    static let valueSlotCapacity = valuesStride / MemoryLayout<Float>.stride

    /// いまのフレームの時刻 (秒)。利用者の断片から読める。
    var time: Float = 0

    /// 1 フレームの長さ (秒)。**動くものの積分はこれで進む。**
    ///
    /// 既定を 60 分の 1 にしてあるのは、`Canvas` を直に回す経路 (検査・台帳のシーン)
    /// でも動きが進むようにするためである。0 を既定にすると、時計を差さない経路では
    /// 何も動かず、しかも絵は出るので気付けない。
    var deltaTime: Float = 1.0 / 60

    /// これまでに描き切ったフレームの数。**時計ではなく番号**なので、同じ入力からは
    /// 何度走らせても同じ列になる。
    private(set) var framesDrawn = 0
    /// 定数の受け渡しは 16 バイト境界に揃える。
    private static let blendModeStride = 16

    /// これから描くものに効く設定の一式。
    ///
    /// 面の大きさや溜めている頂点は含まない — **積んで戻せるのは「これから描くものに
    /// 効く設定」だけ**であり、既に置いた図形や面そのものは戻らない。
    private struct Style {
        var fill: LinearRGBA
        var stroke: LinearRGBA
        var strokeWeight: Float
        var strokeCap: StrokeCap
        var strokeJoin: StrokeJoin
        var hasFill: Bool
        var hasStroke: Bool
        var rectMode: ShapeMode
        var ellipseMode: ShapeMode
        var blendMode: BlendMode
        var clip: MTLScissorRect?
        var fontName: String?
        var textSize: Float
        var textStyle: TextStyle
        var horizontalTextAlign: HorizontalTextAlign
        var verticalTextAlign: VerticalTextAlign
        var textLeading: Float?
        var textWrap: TextWrap
        var imageMode: ShapeMode
        var tint: LinearRGBA
        /// 塗りに貼る絵。
        var picture: Picture?
        /// 材質も積む。**フレームを越えないことと、積めることは別の話である** —
        /// 変換も同じくフレームを越えないが積める。入れ子で書けないほうが不便になる
        var material: Material
        /// 影を落とす側か。
        var castsShadow: Bool
        /// 影を受ける側か。
        var receivesShadow: Bool
    }

    private var currentStyle: Style {
        get {
            Style(
                fill: currentFill, stroke: currentStroke, strokeWeight: currentStrokeWeight,
                strokeCap: currentStrokeCap, strokeJoin: currentStrokeJoin,
                hasFill: hasFill, hasStroke: hasStroke,
                rectMode: currentRectMode, ellipseMode: currentEllipseMode,
                blendMode: currentBlendMode, clip: currentClip,
                fontName: currentFontName, textSize: currentTextSize,
                textStyle: currentTextStyle,
                horizontalTextAlign: currentHorizontalTextAlign,
                verticalTextAlign: currentVerticalTextAlign,
                textLeading: currentTextLeading, textWrap: currentTextWrap,
                imageMode: currentImageMode, tint: currentTint,
                picture: currentPicture,
                material: currentMaterial,
                castsShadow: castsShadow, receivesShadow: receivesShadow)
        }
        set {
            currentFill = newValue.fill
            currentStroke = newValue.stroke
            currentStrokeWeight = newValue.strokeWeight
            currentStrokeCap = newValue.strokeCap
            currentStrokeJoin = newValue.strokeJoin
            hasFill = newValue.hasFill
            hasStroke = newValue.hasStroke
            currentRectMode = newValue.rectMode
            currentEllipseMode = newValue.ellipseMode
            currentFontName = newValue.fontName
            currentTextSize = newValue.textSize
            currentTextStyle = newValue.textStyle
            currentHorizontalTextAlign = newValue.horizontalTextAlign
            currentVerticalTextAlign = newValue.verticalTextAlign
            currentTextLeading = newValue.textLeading
            currentTextWrap = newValue.textWrap
            currentImageMode = newValue.imageMode
            currentTint = newValue.tint
            // 列を閉じる必要は無い。塗りを置く手前で必ず useFillTexture() を通るので、
            // 面が実際に変わるのはそのときで、そこで閉じられる
            currentPicture = newValue.picture
            // 材質と影の扱いが変わるなら、戻す前に列を閉じる (置いた立体を後の設定で
            // 描かない)
            if currentMaterial != newValue.material || castsShadow != newValue.castsShadow
                || receivesShadow != newValue.receivesShadow
            {
                closeBatch()
                currentMaterial = newValue.material
                castsShadow = newValue.castsShadow
                receivesShadow = newValue.receivesShadow
            }
            // 混ぜ方と切り抜きが変わるなら列を閉じてから戻す
            blendMode(newValue.blendMode)
            if !Self.sameClip(currentClip, newValue.clip) {
                closeBatch()
                currentClip = newValue.clip
            }
        }
    }

    /// 描画先を指定して作る。描く細かさと出す細かさは同じになる。
    public convenience init(target: RenderTarget, gpu: RenderDevice) throws(RenderFailure) {
        try self.init(output: target, gpu: gpu, pixelDensity: 1, upscale: .spatial)
    }

    /// 出す先と、描く細かさを指定して作る。
    ///
    /// `pixelDensity` が 1 なら描く先と出す先は**同じ 1 枚**で、拡大の段は立たない。
    /// 1 より小さければ、その割合の描く先を自分で確保し、間を拡大の段で埋める
    /// ([ADR-0015] 決定 1・5)。
    ///
    /// - Throws: 細かさが 0 以下か 1 を超えるとき・拡大の段を組めないときに
    ///   ``RenderFailure``。**組み立てのときに投げる** (ADR-0020 決定 5)。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    public init(
        output: RenderTarget, gpu: RenderDevice, pixelDensity: Float, upscale: Upscale
    ) throws(RenderFailure) {
        guard pixelDensity > 0, pixelDensity <= 1, pixelDensity.isFinite else {
            throw .invalidPixelDensity(pixelDensity)
        }
        self.output = output
        // **近いほうへ丸め、1 画素は必ず残す。** 出す先と同じ大きさになったら段は
        // 立てない — 等倍の拡大は絵を変えないのに、置き場と 1 段ぶんの費用だけ増える
        let drawn = Self.drawnSize(of: output, at: pixelDensity)
        let target =
            drawn == (output.width, output.height)
            ? output
            : try RenderTarget(gpu: gpu, width: drawn.width, height: drawn.height)
        self.target = target
        self.upscaleStage =
            target === output
            ? nil : try UpscaleStage(gpu: gpu, kind: upscale, from: target, to: output)
        self.gpu = gpu
        self.width = Float(output.width)
        self.height = Float(output.height)
        self.pipeline = try ShapePipeline(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        self.emptyNumbers = try Numbers(gpu: gpu, count: 1)
        self.projection = Self.makeProjection(width: self.width, height: self.height)

        let atlas = try GlyphAtlas(gpu: gpu)
        self.atlas = atlas
        self.currentTexture = atlas.texture
        self.whiteUV = atlas.whiteUV

        var matrix = self.projection
        let buffer = try gpu.makeReadableBuffer(byteCount: MemoryLayout<simd_float4x4>.size)
        buffer.contents().copyMemory(
            from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)
        self.projectionBuffer = buffer

        // 混ぜ方の番号は変わらないので、全部並べて置いておき、列ごとに番地で指す。
        // 列ごとに書き換えると、まだ描いていない列の値まで変わってしまう
        let modes = BlendMode.allCases
        let modeBuffer = try gpu.makeReadableBuffer(
            byteCount: modes.count * Self.blendModeStride)
        for mode in modes {
            let slot = modeBuffer.contents()
                .advanced(by: Int(mode.rawIndex) * Self.blendModeStride)
                .assumingMemoryBound(to: UInt32.self)
            slot.pointee = mode.rawIndex
        }
        self.blendModeBuffer = modeBuffer

        // 時刻と面の大きさ。フレームごとに書き換わるので 1 区画だけ持つ
        self.uniformsBuffer = try gpu.makeReadableBuffer(byteCount: Self.valuesStride)
    }

    /// 出す先の大きさと細かさから、描く先の大きさを決める。
    private static func drawnSize(of output: RenderTarget, at density: Float)
        -> (width: Int, height: Int)
    {
        guard density != 1 else { return (output.width, output.height) }
        return (
            max(1, Int((Float(output.width) * density).rounded())),
            max(1, Int((Float(output.height) * density).rounded()))
        )
    }

    /// これから置く頂点が読む面を決める。**変わるなら列を閉じる。**
    ///
    /// 閉じ忘れると、既に置いた図形や字が後から差し替わった面を読む。
    func useTexture(_ texture: any MTLTexture) {
        if texture === currentTexture { return }
        closeBatch()
        currentTexture = texture
    }

    /// 図形と字が読む面 (字形の置き場) へ戻す。
    func useGlyphTexture() {
        useTexture(atlas.texture)
    }

    /// **塗り**が読む面へ切り替える。貼る絵が束ねてあればその面、無ければ焼き場。
    ///
    /// 塗りを置く手前で必ずこれを通すので、直前に画像や字を描いて面が変わっていても
    /// 戻る。輪郭・端点・角・線と点はこれを通さず ``useGlyphTexture()`` のままなので、
    /// **貼る絵は塗りにしか効かない**。
    func useFillTexture() {
        guard let picture = currentPicture else { return useGlyphTexture() }
        picture.prepare()
        useTexture(picture.texture)
    }

    /// 描画先の座標へ落とす行列を作る。
    ///
    /// 左上原点・縦軸下向きに写し、**半画素ずらして整数の座標を画素の中心へ**落とす
    /// (型の説明を参照)。
    static func makeProjection(width: Float, height: Float) -> simd_float4x4 {
        // x: 0…width → -1…1 を、半画素 (1/width) だけ右へ寄せる
        // y: 0…height → 1…-1 を、半画素 (1/height) だけ下へ寄せる
        simd_float4x4(
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, -2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1 / width - 1, 1 - 1 / height, 0, 1))
    }

    // MARK: - 状態

    public func fill(_ color: LinearRGBA) {
        currentFill = color
        hasFill = true
    }

    /// 図形の内側を塗らない。
    public func noFill() { hasFill = false }

    public func stroke(_ color: LinearRGBA) {
        currentStroke = color
        hasStroke = true
    }

    /// 線を引かない。図形の輪郭も出なくなる。
    public func noStroke() { hasStroke = false }

    public func strokeWeight(_ weight: Float) { currentStrokeWeight = max(0, weight) }

    // 溜めている列をその場で閉じる (混ぜ方と同じ理由)。
    //
    // 面の外へ出た指定を面の内側へ収めるのは、この世代の GPU が範囲外の切り抜きを
    // 受け取ると検証で落ちるためである。指定をそのまま渡さない。
    public func clip(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
        let left = min(max(0, Int(box.x)), Int(width))
        let top = min(max(0, Int(box.y)), Int(height))
        let right = min(max(left, Int(box.x + box.width)), Int(width))
        let bottom = min(max(top, Int(box.y + box.height)), Int(height))
        closeBatch()
        currentClip = MTLScissorRect(
            x: left, y: top, width: right - left, height: bottom - top)
    }

    public func noClip() {
        guard currentClip != nil else { return }
        closeBatch()
        currentClip = nil
    }

    /// 描くものを、下にある絵とどう混ぜるか。
    ///
    /// **溜めている列をその場で閉じる。** 既に置いた図形が後の混ぜ方で描かれないように
    /// するためで、閉じ忘れは「設定を変えたときだけ絵が崩れる」形で現れる。
    public func blendMode(_ mode: BlendMode) {
        guard mode != currentBlendMode else { return }
        closeBatch()
        currentBlendMode = mode
    }

    /// 落とす行列に、このフレームの揺らしを足す。
    ///
    /// **見る窓ではなく行列を動かす。** 窓の原点は画素の単位へ丸められる (実測) ので、
    /// 画素の内側を揺らせない。行列なら切り取りの立方体の上で足せる。
    ///
    /// 足すのは切り取りの立方体の座標なので、割る前の高さぶんを掛けて足す — 立体は
    /// 遠いほど `w` が大きく、定数を足すと奥ほど揺れなくなる。
    ///
    /// 空間方向では揺らさない (``UpscaleStage/jitter`` が 0)。
    private func jittered(_ matrix: simd_float4x4) -> simd_float4x4 {
        guard let offset = upscaleStage?.jitter, offset != .zero else { return matrix }
        var shift = matrix_identity_float4x4
        shift.columns.3.x = offset.x * 2 / Float(pixelWidth)
        // 縦は落とす行列が向きを裏返しているので、面の下向きは立方体の上では逆になる
        shift.columns.3.y = -offset.y * 2 / Float(pixelHeight)
        return shift * matrix
    }

    /// 切り抜きを、実際に刻む画素へ写す。
    ///
    /// 切り抜きは利用者が出す細かさの座標で指定するので、細かく刻んでいるときは
    /// そのままでは面からはみ出す。**丸めたあとで面の内側へ収める** — この世代の
    /// GPU は範囲外の切り抜きを受け取ると検証で落ちる。
    private func scissor(_ clip: MTLScissorRect?) -> MTLScissorRect {
        guard let clip else {
            return MTLScissorRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        }
        guard pixelWidth != Int(width) || pixelHeight != Int(height) else { return clip }
        let scaleX = Float(pixelWidth) / width
        let scaleY = Float(pixelHeight) / height
        let left = min(max(0, Int((Float(clip.x) * scaleX).rounded(.down))), pixelWidth)
        let top = min(max(0, Int((Float(clip.y) * scaleY).rounded(.down))), pixelHeight)
        let right = min(
            max(left, Int((Float(clip.x + clip.width) * scaleX).rounded(.up))), pixelWidth)
        let bottom = min(
            max(top, Int((Float(clip.y + clip.height) * scaleY).rounded(.up))), pixelHeight)
        return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 切り抜きが同じか。`MTLScissorRect` は素では比べられない。
    private static func sameClip(_ a: MTLScissorRect?, _ b: MTLScissorRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.x == rhs.x && lhs.y == rhs.y
                && lhs.width == rhs.width && lhs.height == rhs.height
        default: return false
        }
    }

    /// 溜めている頂点を、いまの混ぜ方の列として閉じる。
    ///
    /// 位置は**その並びの中で**数える。平面と立体は別の並びに溜まるので、それぞれの
    /// 最後の列の終わりが次の列の始まりになる。
    func closeBatch() {
        if openSource == .solid { return closeSolidBatch() }
        // **雛形は列と一緒に閉じる。** 開いたままにすると、次に来た同じ形が「もう閉じた
        // 列の頂点」を指す置き場所を足してしまう
        let template = openFlat
        openFlat = nil
        let start = batches.last(where: { $0.source == .flat })
            .map { $0.run.start + $0.run.count } ?? 0
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    shader: currentShader,
                    values: currentShader?.packedValues ?? [], surfaces: snapshotSurfaces(),
                    numbers: currentNumbers,
                    source: openSource, start: start, count: count),
                clip: currentClip,
                matrix: jittered(openSource == .flat ? projection : viewProjection),
                // 平面は光を受けない。立体は**閉じた時点に効いていた光**で描かれる
                lightRange: openSource == .flat ? 0..<0 : bakeActiveLights(),
                material: .default,
                viewer: SIMD4(0, 0, -1, 0),
                surroundings: bakeSurroundings(),
                castsShadow: false,
                // 畳んでいない列は、何も動かさない置き場所 (添字 0) を 1 つ通る
                instanceStart: template?.instanceStart ?? 0,
                instanceCount: template.map { flatInstances.count - $0.instanceStart } ?? 1,
                strokeStart: template?.strokeStart ?? .max))
    }

    /// 断片へ渡す面を、いま列に写し取る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// 並びは宣言と同じ名前順。**描き場所を渡していたら、置いたことを知らせる** —
    /// 貼る口 (``texture(_:)``) と同じで、描き切る前の面を読んだときに黙っていると、
    /// 出るのは前のフレームの絵になる。
    private func snapshotSurfaces() -> [any MTLTexture] {
        guard let shader = currentShader, !shader.surfaces.isEmpty else { return [] }
        return shader.orderedSurfaces.map { surface in
            if case .graphics(let graphics) = surface { note(placing: graphics) }
            return surface.texture
        }
    }

    /// 開いている雛形を閉じる。**畳めない頂点を置く前に呼ぶ。**
    ///
    /// 字・画像・その場で並べた頂点が雛形の列へ紛れ込むと、置き場所の数だけ**それらも
    /// 繰り返し描かれる**。雛形を組み立てている最中は、その頂点自身がここを通るので
    /// 何もしない。
    func closeFlatTemplate() {
        guard openFlat != nil, !buildingFlatTemplate else { return }
        closeBatch()
    }

    /// 開いている立体の列を閉じる。
    ///
    /// 頂点の区間と置き場所の区間を**両方**持って閉じる。頂点は形ごとに 1 組しか
    /// 無いので、「最後の列の終わりが次の始まり」という数え方はできない。
    private func closeSolidBatch() {
        guard let open = openSolid else { return }
        openSolid = nil
        let instanceCount = open.external?.count ?? (solidInstances.count - open.instanceStart)
        guard open.vertexCount > 0, instanceCount > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    shader: currentShader,
                    values: currentShader?.packedValues ?? [], surfaces: snapshotSurfaces(),
                    numbers: currentNumbers,
                    source: .solid,
                    start: open.vertexStart, count: open.vertexCount),
                clip: currentClip,
                matrix: jittered(viewProjection),
                lightRange: bakeActiveLights(),
                material: currentMaterial.receiving(shadow: receivesShadow),
                viewer: viewer,
                surroundings: bakeSurroundings(),
                castsShadow: castsShadow,
                instanceStart: open.external == nil ? open.instanceStart : 0,
                instanceCount: instanceCount,
                instances: open.external?.buffer,
                indirectArguments: open.external?.arguments,
                cullMode: cullMode(for: open)))
        warnIfMaterialCannotShow()
    }

    /// 閉じようとしている立体の列が、裏を向いた面を捨ててよいか (``Batch/cullMode``)。
    ///
    /// **捨ててよいのは、裏面が絵に出ようのない列だけ**である。閉じた組み込みの形で、
    /// 置き場所が全部不透明で、混ぜ方が普通の重ね方で、貼る絵も利用者の断片も無い —
    /// どれか 1 つでも欠けると、裏面が絵の一部になりうる (半透明の奥・透けた画素・
    /// 足し合わせへの寄与・断片が捨てる画素の奥) ので両面で描く。**迷う側は両面**で、
    /// 捨てないことは遅くなるだけで絵を間違えない。
    private func cullMode(for open: OpenSolid) -> MTLCullMode {
        guard case .mesh(let shape) = open.source, shape.isClosed,
            !open.hasTranslucentInstance,
            currentBlendMode == .blend,
            currentPicture == nil,
            currentShader == nil
        else { return .none }
        return .back
    }

    /// 効きようのない材質を、初回だけ知らせる ([ADR-0020] 決定 5)。
    ///
    /// **黙って無視しないための口である。** どちらも式としては正しく振る舞っていて、
    /// 絵だけが「書いたのに効かない」「真っ黒」になる — 利用者からは自分のコードを
    /// 疑うしかない形の失敗なので、起きた場所で知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnIfMaterialCannotShow() {
        switch Material.unusableReason(
            currentMaterial, lights: activeLights, surroundings: activeSurroundings)
        {
        case nil:
            return
        case .noLight:
            guard !warnedMaterialWithoutLight else { return }
            warnedMaterialWithoutLight = true
            Diagnostics.warn(
                "材質を書いていますが、光も周囲も 1 つも置いていません。"
                    + "どちらも無い立体は塗り 1 色で出るので、材質はどれも効きません")
        case .metalWithoutSurroundings:
            guard !warnedMetalWithoutSurroundings else { return }
            warnedMetalWithoutSurroundings = true
            Diagnostics.warn(
                "金属を上げていますが、映す先がありません。金属は周りを映すことでしか"
                    + "見えないので、surroundings() で周囲を置くか ambientLight() を"
                    + "置かないと、艶だけが残って暗くなります")
        }
    }

    /// いま効いている周囲を、この列の形へ詰める。
    ///
    /// **周囲そのものを出す列が優先する。** その列は光も材質も見ないので、置いてある
    /// 周囲ではなく背景に出す周囲を持ち歩く。
    private func bakeSurroundings() -> PackedSurroundings {
        if let backdrop { return backdrop.packed(isBackdrop: true) }
        guard openSource == .solid, let activeSurroundings else { return .none }
        return activeSurroundings.packed()
    }

    /// 平面を溜める側へ戻る。**立体の列が開いていれば閉じる。**
    ///
    /// 立体の列を開いたまま平面を溜めると、呼び出し順どおりの重なりが崩れる
    /// ([ADR-0021] 決定 2)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    func beginFlat() {
        // **平面の頂点はどれもここを通る。** 畳めない頂点が開いている雛形へ紛れ込むのを
        // 止める場所を、1 つに保つ
        closeFlatTemplate()
        guard openSource == .solid else { return }
        closeBatch()
        openSource = .flat
    }

    /// いま効いている光を置き場へ写し、その区間を返す。
    private func bakeActiveLights() -> Range<Int> {
        guard !activeLights.isEmpty else { return 0..<0 }
        let start = lightStorage.count
        lightStorage.append(contentsOf: activeLights)
        return start..<lightStorage.count
    }

    /// 線の端の形。
    public func strokeCap(_ cap: StrokeCap) { currentStrokeCap = cap }

    /// 線の折れ目の形。
    public func strokeJoin(_ join: StrokeJoin) { currentStrokeJoin = join }

    /// 矩形に渡す座標の読み方。
    public func rectMode(_ mode: ShapeMode) { currentRectMode = mode }

    /// 楕円と円弧に渡す座標の読み方。
    public func ellipseMode(_ mode: ShapeMode) { currentEllipseMode = mode }

    // MARK: - 変換

    public func translate(_ x: Float, _ y: Float) { transform.translate(x: x, y: y) }

    public func rotate(_ radians: Float) { transform.rotate(by: radians) }

    public func scale(_ x: Float, _ y: Float) { transform.scale(x: x, y: y) }

    public func shearX(_ radians: Float) { transform.shearX(by: radians) }

    public func shearY(_ radians: Float) { transform.shearY(by: radians) }

    public func applyMatrix(_ other: Transform) { transform.concatenate(other) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てない — 戻す先は残る。
    public func resetMatrix() { transform.reset() }

    public func pushMatrix() { transformStack.append(transform) }

    public func popMatrix() {
        guard let restored = transformStack.popLast() else { return }
        transform = restored
    }

    /// いまのスタイルを積んでおく。
    public func pushStyle() { styleStack.append(currentStyle) }

    public func popStyle() {
        guard let restored = styleStack.popLast() else { return }
        currentStyle = restored
    }

    /// 変換とスタイルの両方を積んでおく。
    public func push() {
        pushMatrix()
        pushStyle()
    }

    public func pop() {
        popMatrix()
        popStyle()
    }

    // MARK: - 図形

    public func background(_ color: LinearRGBA) {
        discardPending()
        pendingBackground = color
    }

    /// 溜めているものを捨てる。
    ///
    /// **塗り直しは「このフレームをここから描き直す」こと**なので、平面の頂点も
    /// 立体の頂点も、閉じた列も、**開いたままの列と置き場所も**まとめて捨てる。
    /// 1 つでも残すと、次に閉じる列が「もう無い頂点」を指す — 消えたはずのものが
    /// 出る、あるいは何も出ない、という形で現れる (#323)。
    func discardPending() {
        vertices.removeAll(keepingCapacity: true)
        solidVertices.removeAll(keepingCapacity: true)
        solidInstances.removeAll(keepingCapacity: true)
        // **何も動かさない置き場所は置き直す。** 畳めない列がこれを指すので、
        // 空のまま次の列を閉じると、束ねる先の無い添字が残る
        flatInstances.removeAll(keepingCapacity: true)
        flatInstances.append(.identity)
        batches.removeAll(keepingCapacity: true)
        openSolid = nil
        openFlat = nil
        pendingFlat = nil
        buildingFlatTemplate = false
        openSource = .flat
        // **置いた記録も一緒に落とす。** 置いた四角ごと捨てたのだから、その絵を
        // 守るために描き切らせる相手はもう居ない
        placedGraphics.removeAll(keepingCapacity: true)
    }

    /// このフレームに溜めたものを、**塗り直しの予定ごと**落とす。
    ///
    /// `discardPending()` との違いは背景 1 つ。塗り直し (`background`) はこの直後に
    /// 予定を置き直すので**そちらでは落とせない**が、フレームが終わるときには予定も
    /// 一緒に落ちなければ次のフレームがその色で塗られる (#342)。
    private func discardFrame() {
        discardPending()
        pendingBackground = nil
        // 溜めた計算もフレームを越えない。描けなかったフレームの頼みが次のフレームで
        // もう一度走ると、進み方が観測の有無で変わる
        pendingComputations.removeAll(keepingCapacity: true)
    }

    /// 計算のパイプライン。**要るときだけ組む。**
    func computePipeline() throws(RenderFailure) -> ComputePipeline {
        if let computePipelineStorage { return computePipelineStorage }
        let pipeline = try ComputePipeline(gpu: gpu)
        computePipelineStorage = pipeline
        return pipeline
    }

    /// 組み立てに失敗している計算の理由。
    var computationFailures: [String] {
        computations.compactMap { computation in
            computation.failure.map { "computation \(computation.name): \($0)" }
        }
    }

    /// 矩形。座標の読み方は ``rectMode(_:)`` が決める。
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
        guard box.width > 0, box.height > 0 else { return }
        let w = box.width
        let h = box.height
        // 周は**形自身の座標**で作り、左上の角を置き場所として渡す。畳まないときは
        // 角を足し戻すだけなので、絵は 1 ビットも変わらない (足す順が入れ替わるだけ)
        draw(
            Outline(
                points: [
                    SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h),
                ], isClosed: true),
            folding: .rect(width: w, height: h), at: SIMD2(box.x, box.y))
    }

    /// 正方形。座標の読み方は ``rectMode(_:)`` が決める。
    public func square(_ a: Float, _ b: Float, _ extent: Float) {
        rect(a, b, extent, extent)
    }

    /// 円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) {
        ellipse(a, b, diameter, diameter)
    }

    /// 楕円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentEllipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return }
        // 周は**形自身の座標**で作り、中心を置き場所として渡す
        draw(
            Outline(
                points: Self.arcPoints(
                    center: SIMD2(0, 0), radiusX: radiusX, radiusY: radiusY,
                    from: 0, sweep: 2 * .pi),
                isClosed: true, fanCenter: SIMD2(0, 0)),
            folding: .ellipse(radiusX: radiusX, radiusY: radiusY),
            at: SIMD2(box.x + radiusX, box.y + radiusY))
    }

    /// 円弧。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// 塗りは中心を含む扇形で、輪郭も扇の周 (2 本の半径と弧) を回る。
    public func arc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float
    ) {
        let box = Self.resolveBox(a, b, c, d, mode: currentEllipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return }
        guard stop > start else {
            warnReversedArcOnce()
            return
        }
        let sweep = min(stop - start, 2 * .pi)
        let arcPoints = Self.arcPoints(
            center: SIMD2(0, 0), radiusX: radiusX, radiusY: radiusY,
            from: start, sweep: sweep)
        // 一周ぶんなら中心は周に含めない (楕円と同じ形になる)
        let isFullTurn = sweep >= 2 * .pi
        draw(
            Outline(
                points: isFullTurn ? arcPoints : [SIMD2(0, 0)] + arcPoints,
                isClosed: true, fanCenter: SIMD2(0, 0)),
            folding: .arc(
                radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep),
            at: SIMD2(box.x + radiusX, box.y + radiusY))
    }

    /// 三角形。
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3)], isClosed: true))
    }

    /// 四角形。頂点は与えた順に結ばれる。
    public func quad(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
        _ x3: Float, _ y3: Float, _ x4: Float, _ y4: Float
    ) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3), SIMD2(x4, y4)],
                isClosed: true))
    }

    // 線。塗りは持たない。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2)], isClosed: false, fills: false))
    }

    /// 点。大きさは線の太さ、形は端点の形 (``strokeCap(_:)``) が決める。
    public func point(_ x: Float, _ y: Float) {
        draw(Outline(points: [SIMD2(x, y)], isClosed: false, fills: false))
    }

    // MARK: - 周をひとつの道具にする

    /// 図形の周。**塗りと輪郭はここから出る**ので、図形ごとに輪郭を書かずに済む。
    ///
    /// 点は変換をかける前の座標で持つ — 変換は最後に 1 度だけ掛ける。輪郭の太さは
    /// 画面の画素で測るので、変換の前に帯を作ると拡大で太さが変わってしまう。
    struct Outline {
        /// 周を回る点。
        var points: [SIMD2<Float>]
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 扇で塗れる図形の中心。`nil` なら最初の点から扇状に分ける。
        var fanCenter: SIMD2<Float>?
        /// 塗りを持つか。線と点は持たない。
        var fills: Bool

        init(
            points: [SIMD2<Float>], isClosed: Bool, fanCenter: SIMD2<Float>? = nil,
            fills: Bool = true
        ) {
            self.points = points
            self.isClosed = isClosed
            self.fanCenter = fanCenter
            self.fills = fills
        }

        /// 形自身の座標で作った周を、置き場所ぶんずらす。**畳まないときの経路。**
        func moved(by offset: SIMD2<Float>) -> Outline {
            Outline(
                points: points.map { $0 + offset }, isClosed: isClosed,
                fanCenter: fanCenter.map { $0 + offset }, fills: fills)
        }
    }

    /// 周から、塗りと輪郭を出す。
    private func draw(_ outline: Outline) {
        if outline.fills, hasFill { fillInterior(outline) }
        if hasStroke, currentStrokeWeight > 0 { strokeOutline(outline) }
    }

    /// 形自身の座標で作った周を、置き場所へ置く。**同じ形が続く間は畳む。**
    ///
    /// 畳めるときは頂点を 1 組も積まず、置き場所を 1 つ足すだけで済む。畳めないときは
    /// 周を置き場所ぶんずらして今までどおり積む — 足す順が入れ替わるだけなので、
    /// **絵は 1 ビットも変わらない**。
    private func draw(_ outline: Outline, folding form: FlatForm, at anchor: SIMD2<Float>) {
        let key = FlatKey(
            form: form,
            hasFill: outline.fills && hasFill,
            hasStroke: hasStroke && currentStrokeWeight > 0,
            strokeWeight: currentStrokeWeight,
            strokeCap: currentStrokeCap,
            strokeJoin: currentStrokeJoin,
            textured: currentPicture != nil)
        guard key.hasFill || key.hasStroke else { return }

        // **貼る絵と輪郭が同居する図形は畳まない。** 塗りは絵の面を、輪郭は字形の面を
        // 読むので、1 つの図形の途中で列が割れる (`useTexture`)。1 つの雛形に収まらない
        //
        // 保持する形を記録している最中も畳まない (`recordingShape`)
        guard !(key.textured && key.hasFill && key.hasStroke), !recordingShape else {
            return draw(outline.moved(by: anchor))
        }

        // 開いている雛形と同じ形なら、置き場所を足すだけで済む
        if let open = openFlat, open.key == key {
            if flatInstances.count - open.instanceStart < instanceCapacity {
                flatInstances.append(placement(at: anchor))
                return
            }
            // 上限に達したら**同じ形のまま**列を開き直す。ここで畳まない経路へ落とすと、
            // 上限をまたいだ図形だけ組み立て方が変わってしまう
            openFlatTemplate(key: key, outline: outline)
            flatInstances.append(placement(at: anchor))
            return
        }

        // **2 つ目が来てから畳む。** 1 つ目で雛形を開くと、矩形と円を交互に置いた絵で
        // 図形の数だけ列が分かれる — 平面は元から 1 つの列にまとまるので、それは
        // 畳む前より遅い ([#424](https://github.com/mokume-metal/mokume/issues/424))
        if let waiting = pendingFlat, waiting.key == key,
            waiting.vertexEnd == vertices.count, waiting.batchCount == batches.count
        {
            // 1 つ目の頂点を溜め場から抜き、雛形として積み直す。抜けるのは**まだ列が
            // 閉じていない末尾**にいるときだけで、上の 2 つの条件がそれを見ている
            vertices.removeLast(vertices.count - waiting.vertexStart)
            pendingFlat = nil
            openFlatTemplate(key: key, outline: outline)
            flatInstances.append(waiting.placement)
            if flatInstances.count - openFlat!.instanceStart < instanceCapacity {
                flatInstances.append(placement(at: anchor))
            } else {
                openFlatTemplate(key: key, outline: outline)
                flatInstances.append(placement(at: anchor))
            }
            return
        }

        // 畳む相手がまだいない。**今までどおり置いて**、次に同じ形が来るのを待つ
        closeFlatTemplate()
        let batchesBefore = batches.count
        let vertexStart = vertices.count
        draw(outline.moved(by: anchor))
        guard batches.count == batchesBefore, vertices.count > vertexStart else {
            pendingFlat = nil
            return
        }
        pendingFlat = PendingFlat(
            key: key, outline: outline, placement: placement(at: anchor),
            vertexStart: vertexStart, vertexEnd: vertices.count, batchCount: batches.count)
    }

    /// 雛形を 1 つ積んで開く。**開いていた列は閉じる。**
    private func openFlatTemplate(key: FlatKey, outline: Outline) {
        beginFlat()
        closeBatch()
        // 読む面は雛形を積み始める前に決める。積んでいる途中で変わると、雛形が
        // 2 つの列に割れる
        if key.textured, key.hasFill { useFillTexture() } else { useGlyphTexture() }

        // **雛形の頂点は白で、変換を掛けずに積む。** 色も変換も置き場所が持つので、
        // ここで焼き込むと二重に掛かる。組み立て自体は畳まないときとまったく同じ経路
        let savedTransform = transform
        let savedFill = currentFill
        let savedStroke = currentStroke
        transform = .identity
        currentFill = Self.unchangedTint
        currentStroke = Self.unchangedTint
        buildingFlatTemplate = true
        if key.hasFill { fillInterior(outline) }
        let strokeStart = vertices.count
        if key.hasStroke { strokeOutline(outline) }
        buildingFlatTemplate = false
        transform = savedTransform
        currentFill = savedFill
        currentStroke = savedStroke

        openFlat = OpenFlat(
            key: key, strokeStart: strokeStart, instanceStart: flatInstances.count)
    }

    /// 掛けても値の変わらない色。雛形の頂点はこれで積む。
    private static let unchangedTint = LinearRGBA(
        premultipliedRed: 1, green: 1, blue: 1, alpha: 1)

    /// いまの変換と塗りから、置き場所を 1 つ作る。
    private func placement(at anchor: SIMD2<Float>) -> FlatInstance {
        let columns = transform.matrix.columns
        return FlatInstance(
            linear: SIMD4(columns.0.x, columns.0.y, columns.1.x, columns.1.y),
            offset: transform.apply(x: anchor.x, y: anchor.y),
            fill: currentFill, stroke: currentStroke)
    }

    /// 周の内側を塗る。
    ///
    /// 貼る絵があれば、**周の囲みの箱**を 0…1 に写した読み取り位置を付ける。組み込みの
    /// 図形はどれも周だけで表されているので、ここ 1 箇所で全部に効く。
    private func fillInterior(_ outline: Outline) {
        let points = outline.points
        guard points.count >= 3 else { return }
        let pivot = outline.fanCenter ?? points[0]
        let center = transform.apply(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return }

        // 箱は**周そのもの**から作る。扇の中心は周の内側にあるので、含めても広がらない
        let uvOf = currentPicture == nil ? nil : Self.boxUV(of: points)

        func place(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ bSource: SIMD2<Float>,
            _ c: SIMD2<Float>, _ cSource: SIMD2<Float>)
        {
            appendTriangle(
                a, b, c, colors: (currentFill, currentFill, currentFill),
                uvs: uvOf.map { ($0(pivot), $0(bSource), $0(cSource)) })
        }

        var previous = transform.apply(x: ring[0].x, y: ring[0].y)
        var previousSource = ring[0]
        for point in ring.dropFirst() {
            let current = transform.apply(x: point.x, y: point.y)
            place(center, previous, previousSource, current, point)
            previous = current
            previousSource = point
        }
        if outline.fanCenter != nil, outline.isClosed {
            let first = transform.apply(x: ring[0].x, y: ring[0].y)
            place(center, previous, previousSource, first, ring[0])
        }
    }

    /// 周を太さのある帯でなぞる。
    func strokeOutline(_ outline: Outline) {
        let half = currentStrokeWeight / 2
        let points = outline.points

        // 点が 1 つだけなら、端点の形そのものを置く
        if points.count == 1 {
            appendCap(at: points[0], towards: points[0] + SIMD2(1, 0), half: half, isolated: true)
            return
        }
        guard points.count >= 2 else { return }

        let segmentCount = outline.isClosed ? points.count : points.count - 1
        for index in 0..<segmentCount {
            appendBand(points[index], points[(index + 1) % points.count], half: half)
        }

        if outline.isClosed {
            for index in 0..<points.count {
                appendJoin(at: points[index], half: half)
            }
        } else {
            for index in 1..<(points.count - 1) {
                appendJoin(at: points[index], half: half)
            }
            appendCap(at: points[0], towards: points[1], half: half, isolated: false)
            let last = points.count - 1
            appendCap(at: points[last], towards: points[last - 1], half: half, isolated: false)
        }
    }

    /// 線分 1 本を帯にする。
    private func appendBand(_ a: SIMD2<Float>, _ b: SIMD2<Float>, half: Float) {
        let delta = b - a
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return }
        let normal = SIMD2(-delta.y / length * half, delta.x / length * half)
        let p1 = transform.apply(x: a.x + normal.x, y: a.y + normal.y)
        let p2 = transform.apply(x: b.x + normal.x, y: b.y + normal.y)
        let p3 = transform.apply(x: b.x - normal.x, y: b.y - normal.y)
        let p4 = transform.apply(x: a.x - normal.x, y: a.y - normal.y)
        appendTriangle(p1, p2, p3, color: currentStroke)
        appendTriangle(p1, p3, p4, color: currentStroke)
    }

    /// 折れ目を埋める。
    ///
    /// 帯は線分ごとに独立して置くので、曲がったところに楔形の隙間が空く。そこを
    /// 埋める形が角の形である。**隙間を埋める向きだけを見て、内側か外側かを判定しない** —
    /// 埋める図形は内側でも帯に重なるだけで、絵は変わらない。
    private func appendJoin(at vertex: SIMD2<Float>, half: Float) {
        switch currentStrokeJoin {
        case .round:
            appendDisc(at: vertex, radiusX: half, radiusY: half, color: currentStroke)
        case .bevel, .miter:
            // 削ぐ形は正方形の一部で近似する。尖らせる形は鋭角で極端に伸びるため、
            // 限界を持たない実装では削ぐ形へ倒す (限界の設計は輪郭が育ってから)
            appendSquare(at: vertex, half: half, color: currentStroke)
        }
    }

    /// 端を仕上げる。
    private func appendCap(
        at end: SIMD2<Float>, towards neighbour: SIMD2<Float>, half: Float, isolated: Bool
    ) {
        switch currentStrokeCap {
        case .square where !isolated:
            return  // 線の長さちょうどで切る
        case .round:
            appendDisc(at: end, radiusX: half, radiusY: half, color: currentStroke)
        case .square, .project:
            appendSquare(at: end, half: half, color: currentStroke)
        }
    }

    /// 円板を置く (丸い端点と丸い角)。
    private func appendDisc(
        at center: SIMD2<Float>, radiusX: Float, radiusY: Float, color: LinearRGBA
    ) {
        let points = Self.arcPoints(
            center: center, radiusX: radiusX, radiusY: radiusY, from: 0, sweep: 2 * .pi)
        let hub = transform.apply(x: center.x, y: center.y)
        var previous = transform.apply(x: points[0].x, y: points[0].y)
        for point in points.dropFirst() {
            let current = transform.apply(x: point.x, y: point.y)
            appendTriangle(hub, previous, current, color: color)
            previous = current
        }
        let first = transform.apply(x: points[0].x, y: points[0].y)
        appendTriangle(hub, previous, first, color: color)
    }

    /// 正方形を置く (四角い端点と削いだ角)。
    private func appendSquare(at center: SIMD2<Float>, half: Float, color: LinearRGBA) {
        let a = transform.apply(x: center.x - half, y: center.y - half)
        let b = transform.apply(x: center.x + half, y: center.y - half)
        let c = transform.apply(x: center.x + half, y: center.y + half)
        let d = transform.apply(x: center.x - half, y: center.y + half)
        appendTriangle(a, b, c, color: color)
        appendTriangle(a, c, d, color: color)
    }

    /// 弧の上の点を返す。円と楕円は「一周ぶんの弧」であり、別の道具にはしない。
    static func arcPoints(
        center: SIMD2<Float>, radiusX: Float, radiusY: Float, from start: Float, sweep: Float
    ) -> [SIMD2<Float>] {
        let full = segmentCount(forRadius: max(radiusX, radiusY))
        let segments = max(1, Int((Float(full) * sweep / (2 * .pi)).rounded(.up)))
        let step = sweep / Float(segments)
        // 一周は最後の点が最初と重なるので落とす
        let count = sweep >= 2 * .pi ? segments : segments + 1
        return (0..<count).map { index in
            let angle = start + step * Float(index)
            return SIMD2(
                center.x + radiusX * cos(angle), center.y + radiusY * sin(angle))
        }
    }

    /// 4 つの数を、左上の角と大きさへ読み替える。
    static func resolveBox(_ a: Float, _ b: Float, _ c: Float, _ d: Float, mode: ShapeMode)
        -> (x: Float, y: Float, width: Float, height: Float)
    {
        switch mode {
        case .corner: return (a, b, c, d)
        case .corners: return (min(a, c), min(b, d), abs(c - a), abs(d - b))
        case .center: return (a - c / 2, b - d / 2, c, d)
        case .radius: return (a - c, b - d, c * 2, d * 2)
        }
    }

    /// 円を近似する多角形の辺の数。
    ///
    /// 多角形と真円の隔たりがいちばん大きいのは辺の中央で、その差は
    /// `r(1 − cos(π/n))`。これを 0.25 画素以下に収める `n` を選ぶ。
    ///
    /// **式が返す値をそのまま使う。** 下限 3 は多角形が成立する最小の辺数であって、
    /// 精度の判断ではない — 精度は式が持っている。かつては下限 32 を掛けていたが、
    /// 根拠がどこにも無く、直径 12 の円 (式は 11 を返す) に 3 倍の頂点を組み立てて
    /// いた。10,000 個置くと 40fps まで落ちる ([#423])。
    ///
    /// **上限 1024 は品質の判断ではなく、暴走の歯止めである。** 式は大きな半径で
    /// `n ≈ π√(2r)` に漸近するので、半径 10⁹ のような値が紛れ込むと 1 個の円に
    /// 14 万辺を割いてしまう。上限 `n` に対して保証が届く半径は `r = n²/(2π²)` で、
    /// 1024 なら約 53,000 — 面より桁違いに大きい円まで保証の内側に居る。
    ///
    /// かつての上限 128 は「大きすぎる円に 128 辺を超えて割いても見た目は変わらない」
    /// を根拠にしていたが、実際には変わっていた。半径 20000 の円は、画面に映る
    /// 800 列のうち 677 列で 1 画素以上・最大 6 画素ずれる ([#429] で実測)。
    ///
    /// 拡大縮小の変換は考えない。拡大した円が粗くなるのは受け入れる。
    ///
    /// [#423]: https://github.com/mokume-metal/mokume/issues/423
    /// [#429]: https://github.com/mokume-metal/mokume/issues/429
    static func segmentCount(forRadius radius: Float) -> Int {
        let tolerance = 0.25
        let cap = 1024
        // 隔たりが許容誤差に届かない円は、いちばん粗い多角形で足りる
        guard radius.isFinite, Double(radius) > tolerance else { return 3 }
        // **倍精度で解く。** 半径が大きいほど `1 − tolerance/r` は 1 に貼り付き、
        // 単精度では引き算で桁が落ちる — 半径 20000 で 629 ではなく 628 を返し、
        // 上限とは別に保証を 0.2% 外していた ([#429])
        let radians = acos(max(-1, 1 - tolerance / Double(radius)))
        // 角度が潰れるのは半径が大きすぎるとき。いちばん**細かい**側へ倒す
        // (かつては 3 を返し、半径 10⁷ の円が三角形になっていた)
        guard radians > 0 else { return cap }
        return min(cap, max(3, Int((Double.pi / radians).rounded(.up))))
    }

    /// 角度が逆向きの円弧を、初回だけ知らせる。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    private func warnReversedArcOnce() {
        guard !warnedReversedArc else { return }
        warnedReversedArc = true
        Diagnostics.warn(
            "arc(): 終わりの角度は始まりより大きくしてください。この呼び出しは何も描きません")
    }

    // MARK: - 文字の下ごしらえ

    /// 4 つの数を、いまの読み方で矩形として読む。
    ///
    /// 文字の流し込みもここを通す — 矩形と別の読み方を持つと、同じ 4 つの数が
    /// API ごとに違う場所を指すことになる。
    func resolveRect(_ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> (x: Float, y: Float, width: Float, height: Float)
    {
        Self.resolveBox(a, b, c, d, mode: currentRectMode)
    }

    /// 文字を塗る色。塗りを止めていれば `nil`。
    var textFillColor: LinearRGBA? { hasFill ? currentFill : nil }

    /// いま指定されている書体。同じ指定なら作り直さない。
    var typeface: Typeface {
        let request = TypefaceRequest(
            name: currentFontName, size: currentTextSize, style: currentTextStyle)
        if let found = typefaces[request] { return found }
        let face = Typeface(request: request)
        typefaces[request] = face
        return face
    }

    /// 焼いてある字形を引く。入りきらなければ面を広げる。
    ///
    /// **面を広げると、そこを読む列が変わる。** 既に置いた字は前の面を指しているので、
    /// 広げる前に列を閉じ、前の面はその列が抱えたまま残す。
    func glyphEntry(for resolved: ResolvedGlyph) -> GlyphAtlas.Entry? {
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: currentTextSize, style: currentTextStyle,
            glyph: resolved.glyph)
        if let entry = atlas.entry(for: key, font: resolved.font) { return entry }

        guard atlas.canGrow else {
            warnAtlasFullOnce()
            return nil
        }
        closeBatch()
        do {
            try atlas.grow(gpu: gpu)
        } catch {
            return nil
        }
        currentTexture = atlas.texture
        whiteUV = atlas.whiteUV
        return atlas.entry(for: key, font: resolved.font)
    }

    /// 字形 1 つを四角として置く。
    ///
    /// **半画素ぶん戻して置く。** 整数の座標は画素の中心を指すので (``makeProjection``)、
    /// そのまま四角の縁に使うと縁の画素が半分だけ覆われ、焼いた絵が滲む。縁を画素の
    /// 境目へ寄せると、焼いた画素と描く画素がちょうど 1 対 1 になる。
    func appendGlyphQuad(
        _ entry: GlyphAtlas.Entry, penX: Float, baseline: Float, color: LinearRGBA
    ) {
        useGlyphTexture()
        // **色を持つ字形には塗りの色を掛けない。** 焼き場の値に頂点の色を掛けるのが
        // 合成の唯一の式なので、掛けても変わらない色 — 白 — を積めば、字形の色が
        // そのまま出る。塗りの透明度だけは効かせたいので、白をその透明度で乗算した
        // 値にする (乗算済みの白 α は 4 成分すべて α)。
        //
        // 「どちらの式を使うか」を描画側へ伝える道が要らないのはこのためで、
        // 判断は積む側でここだけに閉じている (#271)
        let color = entry.isColored ? Self.whiteScaled(byAlphaOf: color) : color
        let shift: Float = -0.5
        let left = penX + entry.offset.x + shift
        let top = baseline + entry.offset.y + shift
        let right = left + entry.size.x
        let bottom = top + entry.size.y

        let topLeft = transform.apply(x: left, y: top)
        let topRight = transform.apply(x: right, y: top)
        let bottomRight = transform.apply(x: right, y: bottom)
        let bottomLeft = transform.apply(x: left, y: bottom)
        let uvMin = entry.uvMin
        let uvMax = entry.uvMax

        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(topRight, SIMD2(uvMax.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(bottomLeft, SIMD2(uvMin.x, uvMax.y), color)
    }

    /// 塗りの透明度だけを持つ白 (乗算済み)。掛けても字形の色を変えない。
    private static func whiteScaled(byAlphaOf color: LinearRGBA) -> LinearRGBA {
        let alpha = color.alpha
        return LinearRGBA(
            premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
    }

    private func appendGlyphVertex(
        _ position: SIMD2<Float>, _ uv: SIMD2<Float>, _ color: LinearRGBA
    ) {
        beginFlat()
        vertices.append(ShapeVertex(position: position, uv: uv, color: color))
    }

    /// 画像を四角として置く。
    ///
    /// **字形と同じく半画素ぶん戻して置く** — 整数の座標は画素の中心を指すので、
    /// そのまま四角の縁に使うと縁が半分だけ覆われ、等倍で置いた絵が滲む。
    func appendImageQuad(
        _ picture: Picture, x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
        picture.prepare()
        useTexture(picture.texture)

        let shift: Float = -0.5
        let left = x + shift
        let top = y + shift
        let right = left + width
        let bottom = top + height

        let topLeft = transform.apply(x: left, y: top)
        let topRight = transform.apply(x: right, y: top)
        let bottomRight = transform.apply(x: right, y: bottom)
        let bottomLeft = transform.apply(x: left, y: bottom)

        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(topRight, SIMD2(uvMax.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(bottomLeft, SIMD2(uvMin.x, uvMax.y), color)
    }

    /// 復号した中身から絵を作る。
    func makeImage(_ decoded: ImageFile.Decoded) throws(ImageFailure) -> Image {
        do {
            return try Image(
                width: decoded.width, height: decoded.height, pixels: decoded.pixels, gpu: gpu)
        } catch {
            throw .unplaceable(width: decoded.width, height: decoded.height)
        }
    }

    /// 焼き場が埋まったことを、初回だけ知らせる。
    private func warnAtlasFullOnce() {
        guard !warnedAtlasFull else { return }
        warnedAtlasFull = true
        Diagnostics.warn(
            "text(): 字形を焼く場所が上限まで埋まりました。これ以上の新しい字は描かれません")
    }

    func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: LinearRGBA
    ) {
        appendTriangle(a, b, c, colors: (color, color, color))
    }

    /// 頂点ごとに色の違う三角形を置く。
    ///
    /// 3 つが同じ色なら 1 色の三角形と区別が付かないので、色を 1 つ受ける形はこれの
    /// 呼び分けである — **頂点ごとの色のために別の経路を作らない** ([ADR-0021] 決定 5)。
    ///
    /// `uvs` は**塗りだけが渡す**読み取り位置 (0…1)。渡さなければ焼き場の白い区画を
    /// 読む — 白を掛けても色は変わらないので、**貼る絵を束ねていないときの絵は
    /// 1 ビットも変わらない**。輪郭・端点・角はここを渡さない側に居続ける。
    func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
        colors: (LinearRGBA, LinearRGBA, LinearRGBA),
        uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? = nil
    ) {
        // **図形は白い区画を読む。** 直前に画像を描いていたら、その面を読んだままに
        // なるので戻す (変わらなければ何も起きない)
        beginFlat()
        if uvs != nil { useFillTexture() } else { useGlyphTexture() }
        let uv = uvs ?? (whiteUV, whiteUV, whiteUV)
        vertices.append(ShapeVertex(position: a, uv: uv.0, color: colors.0))
        vertices.append(ShapeVertex(position: b, uv: uv.1, color: colors.1))
        vertices.append(ShapeVertex(position: c, uv: uv.2, color: colors.2))
    }

    /// 塗りに貼る絵があるなら、囲みの箱を 0…1 に写す関数を返す。
    ///
    /// **変換を掛ける前の座標から作る。** 描画先の座標から作ると、回した図形の上を
    /// 絵が滑る (図形は回ったのに絵は画面に貼り付いたままになる)。
    static func boxUV(of points: [SIMD2<Float>]) -> (SIMD2<Float>) -> SIMD2<Float> {
        var lowest = SIMD2<Float>(repeating: .infinity)
        var highest = SIMD2<Float>(repeating: -.infinity)
        for point in points {
            lowest = simd_min(lowest, point)
            highest = simd_max(highest, point)
        }
        let span = highest - lowest
        // **潰れた軸は 0 に倒す。** 幅の無い図形を 0 で割ると、読み取り位置が数でなく
        // なって面のどこも指さなくなる
        return { point in
            SIMD2(
                span.x > 0 ? (point.x - lowest.x) / span.x : 0,
                span.y > 0 ? (point.y - lowest.y) / span.y : 0)
        }
    }

    // MARK: - 描き切る

    /// 1 フレーム分を描く。
    ///
    /// `body` の中で呼んだ図形が溜められ、抜けるときにまとめて描画先へ落ちる。
    /// **返った時点で GPU はまだ描いていることがある。** 待つのは結果に触る口
    /// (画素の読み出し・数の並びの読み書き) と、次の描き切りの書く直前で、どちらも
    /// 自分で待つ。だから呼ぶ側は待ちを意識しなくてよい (#727)。
    public func draw(_ body: () -> Void) throws(RenderFailure) {
        beginFrame()
        body()
        try endFrame()
    }

    /// 描き場所として 1 フレーム分を描き始める。
    ///
    /// ``endDraw()`` と対で使う。手本と同じ名前・同じ対の形にしてある。
    ///
    /// <!-- example: 文脈 var trail: Canvas! -->
    /// <!-- example: 文脈 let x: Float = 200 -->
    /// <!-- example: 文脈 let y: Float = 150 -->
    /// ```swift
    /// trail.beginDraw()
    /// trail.circle(x, y, 20)
    /// trail.endDraw()
    /// ```
    public func beginDraw() {
        guard !isDrawing else { return warnAlreadyDrawing() }
        beginFrame()
    }

    /// 描き場所へ描き切る。**投げない。**
    ///
    /// 毎フレーム呼ばれるので、1 段の失敗でフレームごと落とさない ([ADR-0020]
    /// 決定 5)。描き切れなかったときは前の絵がそのまま残り、理由が知らされる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func endDraw() {
        guard isDrawing else { return warnNotDrawing() }
        do {
            try endFrame()
        } catch {
            Diagnostics.warn("endDraw(): 描き切れませんでした: \(error.headline)")
        }
    }

    /// フレームの始まり。**3 つの入口が同じここを通る** — 描き方が入口ごとに
    /// 分かれると、描き場所でだけ成り立たない性質が生まれる。
    private func beginFrame() {
        currentClip = nil
        currentNumbers = nil
        // 効果もフレームを越えない (ADR-0021 決定 4)。毎フレーム書き直す
        pendingEffects.removeAll(keepingCapacity: true)
        transform = .identity
        transformStack.removeAll(keepingCapacity: true)
        hasLoadedPixels = false
        // 光もフレームを越えない (同 決定 4)。ここで空に戻る
        activeLights.removeAll(keepingCapacity: true)
        activeSurroundings = nil
        lightStorage.removeAll(keepingCapacity: true)
        passesThisFrame = 0

        isDrawing = true
    }

    /// フレームの終わり。溜めたものを描き切り、シーンの記述を戻す。
    private func endFrame() throws(RenderFailure) {
        // **シーンの記述はフレームを越えない** (ADR-0021 決定 4)。視点は**描き終えて
        // から**既定へ戻す — 始まりで戻すと、フレームの外から読んだときだけ「もう
        // 効かない視点」が返る。列を閉じるのに視点が要るので、戻すのは flush の後
        defer {
            cameraStorage = nil
            currentMaterial = .default
            shadowsEnabled = false
            shadowRangeValue = nil
            castsShadow = true
            receivesShadow = true
            // **溜めたものもフレームを越えない。** 描き切りは 6 箇所から投げるので、
            // 片付けを成功経路の末尾だけに置くと、描けなかったフレームの図形が次の
            // フレームでもう一度描かれる (#342)。`defer` は投げても走るので、どの
            // 経路を通ってもここでフレームの境目に落ちる
            discardFrame()
        }
        isDrawing = false
        framesDrawn += 1

        try flush()
    }

    private func warnAlreadyDrawing() {
        guard !warnedAlreadyDrawing else { return }
        warnedAlreadyDrawing = true
        Diagnostics.warn("beginDraw(): まだ endDraw() を呼んでいません。この呼び出しは効きません")
    }

    private func warnNotDrawing() {
        guard !warnedNotDrawing else { return }
        warnedNotDrawing = true
        Diagnostics.warn("endDraw(): beginDraw() を呼ぶ前でした。この呼び出しは効きません")
    }

    // MARK: - 置いた時点の絵を守る

    /// 描き場所を置いたことを、両側に覚えさせる。
    func note(placing graphics: Canvas) {
        guard graphics !== self else { return }
        // **描き切る前に置いたら知らせる。** 出るのは前のフレームの絵で、しかも
        // 「それらしい絵」なので、黙っていると自分のコードを疑うしかない
        // ([ADR-0020] 決定 5)
        if graphics.isDrawing, !warnedPlacingWhileDrawing {
            warnedPlacingWhileDrawing = true
            Diagnostics.warn(
                "image(): endDraw() を呼ぶ前の描き場所を置きました。出るのは描き切る前の絵です")
        }
        placedGraphics.insert(ObjectIdentifier(graphics))
        graphics.note(placedBy: self)
    }

    private func note(placedBy canvas: Canvas) {
        guard !placers.contains(where: { $0.canvas === canvas }) else { return }
        placers.append(WeakCanvas(canvas: canvas))
    }

    /// 自分の絵が変わる前に、自分を溜めている面を描き切らせる。
    private func settlePlacersBeforeChange() {
        guard !placers.isEmpty else { return }
        // **先に空にする。** 描き切らせた先から置き直されることがあるので、
        // 走らせたあとに消すと、そのフレームの記録まで一緒に落ちる
        let waiting = placers
        placers.removeAll(keepingCapacity: true)
        for entry in waiting { entry.canvas?.settle(before: self) }
    }

    /// この描き場所を溜めているなら、いま描き切る。
    ///
    /// **描き切っている最中なら何もしない。** 描き場所どうしが互いを置き合うと
    /// ここへ戻ってくるので、1 周したところで止める。
    private func settle(before graphics: Canvas) {
        guard !isFlushing, placedGraphics.contains(ObjectIdentifier(graphics)) else { return }
        do {
            // 効果はフレームの終わりに立つ段なので、途中の描き切りでは通さない
            try flush(applyingEffects: false)
        } catch {
            Diagnostics.warn("置いた描き場所が変わる前の描き切りに失敗しました: \(error.headline)")
        }
    }

    /// 直前のフレームで描画を呼んだ回数。
    ///
    /// **畳めているかを数えるための値。** 絵が同じでも畳まれていなければ保持は目的を
    /// 果たしていないので、絵ではなく回数で確かめる。
    private(set) var drawCallsInLastFrame = 0

    /// 直前のフレームで積んだ平面の頂点の数。
    ///
    /// **平面が畳めているかは、描画の呼び出し回数では数えられない。** 平面は元から
    /// 1 つの列にまとまるので、畳んでも畳まなくても回数は変わらない — 変わるのは
    /// 組み立てて積む頂点の数のほうで、それが #424 で律速だったものである。
    private(set) var flatVerticesInLastFrame = 0

    /// 検査から「描けなかったフレーム」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 描画の失敗は環境か資源が枯れたときにしか起きず、検査から自然には作れない。
    /// 一方で**描けなかったときに何が起きるか**は回帰検査を置くべき場所そのものなので
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))、ここに 1 つだけ
    /// 穴を空けてある。公開はしない。
    var failureForTesting: RenderFailure?

    /// - Parameters:
    ///   - applyingEffects: 効果を通すか。**フレームの終わりだけ通す** —
    ///     フレームの途中の描き切り (`loadPixels()`) で通すと、効果のかかった絵の上に
    ///     続きが描かれ、しかもフレームの終わりにもう一度かかる。
    ///   - mirroringPixels: 描き終えた絵を画素の写しへ読み戻す blit を末尾に積むか。
    ///     **画素を読む直前の描き切りだけ** `true` — 読まないフレームは 1 バイトも払わない
    ///     ([#753])。
    ///
    /// [#753]: https://github.com/mokume-metal/mokume/issues/753
    func flush(applyingEffects: Bool = true, mirroringPixels: Bool = false)
        throws(RenderFailure)
    {
        // **自分の絵が変わる直前がここ。** 自分を溜めている面を先に描き切らせると、
        // その面には「置いた時点の絵」が残る。`beginDraw()` ではなくここに置くのは、
        // 描き切りが要る経路が対の外にもある (画素の読み出し) ため
        settlePlacersBeforeChange()
        isFlushing = true
        defer { isFlushing = false }
        if let failureForTesting { throw failureForTesting }
        // **書く前に待つ。** ここから先は GPU 可視メモリへ CPU が書く (頂点・列ごとの値・
        // 効果の値・置き場の取り直し)。前の描き切りがまだそこを読んでいるかもしれない
        // ので、投入済みのものが全部終わるのを待つ — 全部終わっていれば何もせず返る。
        // 待つ位置をここ (書く直前) にしたので、末尾では待たない。利用者の `draw()` の
        // CPU 仕事が前のフレームの GPU と重なる ([#727])。詰まっていたら 1 バイトも
        // 書かずに投げ、このフレームは捨てる (`draw(_:)` の `defer` が片付ける)
        //
        // [#727]: https://github.com/mokume-metal/mokume/issues/727
        try gpu.settle()
        closeBatch()
        // 段の枠の採番は描き切りごとに 0 から。**1 本のコマンドの中でだけ衝突しない
        // ことが要る**ので、コマンドと同じ寿命で数える
        stagePassesUsed = 0
        // **奥行きはフレームで 1 つ。** 途中の描き切りをまたいで引き継ぎ、塗り直しを
        // 頼まれたときだけ消す (そのフレームをそこから描き直すという意味なので)
        let pass = target.makeRenderPass(
            clearColor: pendingBackground,
            continuingFrame: passesThisFrame > 0 && pendingBackground == nil,
            keepingDepth: !applyingEffects)
        passesThisFrame += 1
        let commands = try gpu.beginCommands()

        // **CPU が画素へ書いたものがあれば、描く前に描画先へ戻す。** 描画先は GPU 専用の
        // 面なので、`pixels` への書き込みは写しに載っている。書いていないフレームは
        // 何も積まない (#753)
        try target.encodePixelWriteBack(into: commands)

        // **描くより前に、頼まれた計算を流す** (ADR-0023 決定 3 — 計算はフレームの
        // 前置き)。頼まれていなければ口も開かないので、計算を使わないスケッチは
        // ここで何も払わない
        try encodeComputations(into: commands)

        // **画面へ描く前に、光から見た奥行きを焼く。** 同じコマンドに順に積んでも
        // **この世代では順に実行されない** — encoder をまたぐ依存は自動では張られず、
        // 明示しなければ焼き付けと画面が重なる。待つ仕掛けは焼く側が積む
        // (`bakeShadow`)。当初ここに「順に流すので待つ仕掛けは要らない」と書いていた
        // のが [#341] の出どころなので、消さずに理由を残す。
        //
        // [#341]: https://github.com/mokume-metal/mokume/issues/341
        let bakedShadow = try bakeShadow(into: commands)

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }

        if !vertices.isEmpty || !solidVertices.isEmpty {
            let buffer = try vertexBufferHolding(vertices.count)
            vertices.withUnsafeBytes { source in
                buffer.contents().copyMemory(
                    from: source.baseAddress!, byteCount: source.count)
            }
            let instanceBuffer = try solidInstanceBufferHolding(max(solidInstances.count, 1))
            solidInstances.withUnsafeBytes { source in
                guard let base = source.baseAddress, source.count > 0 else { return }
                instanceBuffer.contents().copyMemory(from: base, byteCount: source.count)
            }
            let flatInstanceBuffer = try flatInstanceBufferHolding(flatInstances.count)
            flatInstances.withUnsafeBytes { source in
                guard let base = source.baseAddress, source.count > 0 else { return }
                flatInstanceBuffer.contents().copyMemory(from: base, byteCount: source.count)
            }

            let solidBuffer = try solidVertexBufferHolding(solidVertices.count)
            solidVertices.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                solidBuffer.contents().copyMemory(from: base, byteCount: source.count)
            }
            // 光の置き場。列は自分の区間を指す
            let lightsBuffer = try lightBufferHolding(max(lightStorage.count, 1))
            lightStorage.withUnsafeBytes { source in
                guard let base = source.baseAddress, source.count > 0 else { return }
                lightsBuffer.contents().copyMemory(from: base, byteCount: source.count)
            }
            pipeline.argumentTable.setAddress(
                lightsBuffer.gpuAddress, index: ShapePipeline.lightsBufferIndex)

            // 列ごとの行列を並べて置く。**列が閉じた時点の見る位置**がそのまま入る
            let matrices = try matrixBufferHolding(batches.count)
            for (index, batch) in batches.enumerated() {
                var matrix = batch.matrix
                let slot = matrices.contents().advanced(by: index * Self.valuesStride)
                slot.copyMemory(from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)
                // 行列のすぐ後ろに、輪郭の頂点が始まる番号を置く。**立体は行列しか
                // 読まない**ので、同じ区画に足しても効かない
                var strokeStart = UInt32(min(batch.strokeStart, Int(UInt32.max)))
                slot.advanced(by: MemoryLayout<simd_float4x4>.size)
                    .copyMemory(from: &strokeStart, byteCount: MemoryLayout<UInt32>.size)
            }
            // **見る窓は実際に刻む画素で測る。** 落とす行列は出す細かさで書かれた
            // 座標を -1…1 へ正規化するので、窓を狭めればそのまま細かく刻まれる。
            //
            encoder.setViewport(
                MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(pixelWidth), height: Double(pixelHeight),
                    znear: 0, zfar: 1))

            // 時刻と面の大きさは、フレームの中で変わらない。**大きさは実際に刻む
            // 画素**である — 断片が受け取る位置 (`position`) がその数で来るので、
            // 割って出す 0…1 の位置がここと食い違うと面からはみ出す
            uniformsBuffer.contents().assumingMemoryBound(to: Float.self)
                .update(
                    from: [time, 0, Float(pixelWidth), Float(pixelHeight), shadowBiasValue],
                    count: 5)
            // 影の行列と設定。**フレームに 1 つ**で、列ごとには変わらない
            // **置き場所は断片側の詰め方で決まる。** 4x4 の行列は 16 バイト境界へ
            // 揃うので、その前の 1 つの数 (縁の余裕) の後ろに詰め物が入る
            var matrix = bakedShadow?.matrix ?? matrix_identity_float4x4
            uniformsBuffer.contents().advanced(by: 32)
                .copyMemory(from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)
            let shadowTexel = 1 / Float(bakedShadow?.map.detail ?? 1)
            uniformsBuffer.contents().advanced(by: 96)
                .assumingMemoryBound(to: Float.self)
                .update(from: [bakedShadow == nil ? 0 : 1, shadowTexel, 0, 0], count: 4)
            // 揺らぎの種と細かさ。**断片が種を受け取る**ので、利用者が値として
            // 配線しなくても CPU の `noise()` と同じ模様が出る。種と枚数は整数の
            // まま送る (`Float` を経由すると大きな種で丸めが起きる)
            uniformsBuffer.contents().advanced(by: 112)
                .assumingMemoryBound(to: UInt32.self)
                .update(from: [noiseSettings.seed, UInt32(noiseSettings.octaves)], count: 2)
            uniformsBuffer.contents().advanced(by: 120)
                .assumingMemoryBound(to: Float.self)
                .update(from: [noiseSettings.falloff, 0], count: 2)
            // **焼いていなくても、読む先は必ず束ねる。** 束ねない口を作ると、断片が
            // 触った瞬間に何が起きるかが土台任せになる
            pipeline.argumentTable.setTexture(
                (bakedShadow?.map.texture ?? currentTexture).gpuResourceID,
                index: ShapePipeline.shadowTextureIndex)
            pipeline.argumentTable.setAddress(
                uniformsBuffer.gpuAddress, index: ShapePipeline.uniformsBufferIndex)

            // 列ごとの値を並べて置く。**列が閉じた時点の値**がそのまま入っている
            let lighting = try lightingBufferHolding(batches.count)
            for (index, batch) in batches.enumerated() {
                let slot = lighting.contents().advanced(by: index * Self.valuesStride)
                    .assumingMemoryBound(to: UInt32.self)
                slot.update(
                    from: [UInt32(batch.lightRange.lowerBound), UInt32(batch.lightRange.count)],
                    count: 2)
                // 見ている場所は 16 バイト境界から (断片の側も詰め物を空けている)
                var viewer = batch.viewer
                lighting.contents().advanced(by: index * Self.valuesStride + 16)
                    .copyMemory(from: &viewer, byteCount: MemoryLayout<SIMD4<Float>>.size)
            }

            // 列ごとの材質。**列が閉じた時点のもの**がそのまま入る
            let materials = try materialBufferHolding(batches.count)
            for (index, batch) in batches.enumerated() {
                var packed = batch.material.packed
                materials.contents().advanced(by: index * Self.valuesStride)
                    .copyMemory(from: &packed, byteCount: PackedMaterial.expectedStride)
            }

            // 列ごとの周囲。**列が閉じた時点のもの**がそのまま入る
            let surroundings = try surroundingsBufferHolding(batches.count)
            for (index, batch) in batches.enumerated() {
                var packed = batch.surroundings
                surroundings.contents().advanced(by: index * Self.valuesStride)
                    .copyMemory(from: &packed, byteCount: PackedSurroundings.expectedStride)
            }

            let values = try valuesBufferHolding(batches.count)
            for (index, batch) in batches.enumerated() {
                // **区画に収まることは入口で保証されている** (`Canvas.loadShader` /
                // `makeShader` が `valueSlotCapacity` を超える宣言を断る・#348)。ここで
                // 切り詰めないのは、黙って切り詰めると断片の `Values` に「宣言したのに
                // 一度も書かれない欄」が残り、絵が永久に間違ったまま出るためである
                let slot = values.contents().advanced(by: index * Self.valuesStride)
                    .assumingMemoryBound(to: Float.self)
                if batch.run.values.isEmpty {
                    slot.update(repeating: 0, count: 4)
                } else {
                    slot.update(from: batch.run.values, count: batch.run.values.count)
                }
            }
            // **どちら回りを表とするかを明示する。** 断片は表裏を見て面の向きを裏返す
            // (両面) ので、ここが黙っていると「表」の意味が土台の既定に委ねられる。
            // 形は外向きに巻いてあり (`SolidMeshBuilder`)、縦軸を下向きへ戻す補正が
            // 画面での巻き方を反転させるので、時計回りが表になる
            encoder.setFrontFacing(.clockwise)

            for (index, batch) in batches.enumerated() {
                let run = batch.run
                // 並びごとに、頂点の落とし方と奥行きの扱いを切り替える。**平面は奥行きを
                // 書かない**ので、あとから来た立体の前後関係を汚さない (ADR-0021 決定 2)
                switch batch.source {
                case .flat:
                    encoder.setRenderPipelineState(run.shader?.state ?? pipeline.state)
                    encoder.setDepthStencilState(pipeline.flatDepthState)
                    pipeline.argumentTable.setAddress(
                        buffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
                    // **口は立体と共用する。** 同じ列で平面と立体の両方を描くことは
                    // 無いので、置き場所の口を 2 つ持つ理由が無い
                    pipeline.argumentTable.setAddress(
                        flatInstanceBuffer.gpuAddress
                            + UInt64(batch.instanceStart * MemoryLayout<FlatInstance>.stride),
                        index: ShapePipeline.instanceBufferIndex)
                case .solid:
                    // **平面と同じ断片が効く。** 頂点の落とし方だけが違う
                    encoder.setRenderPipelineState(run.shader?.solidState ?? pipeline.solidState)
                    encoder.setDepthStencilState(pipeline.solidDepthState)
                    pipeline.argumentTable.setAddress(
                        solidBuffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
                    // **置き場所は列の先頭からを渡す。** そうすれば断片の側は 0 から
                    // 数えるだけで済み、列ごとの下駄を持ち歩かなくてよい
                    pipeline.argumentTable.setAddress(
                        (batch.instances ?? instanceBuffer).gpuAddress
                            + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
                        index: ShapePipeline.instanceBufferIndex)
                }
                // 裏を向いた面を描くかは列が決めている (`Batch.cullMode`)。表の向きは
                // 上で 1 度だけ決めてあるので、ここは捨て方を掛けるだけ
                encoder.setCullMode(batch.cullMode)
                pipeline.argumentTable.setAddress(
                    matrices.gpuAddress + UInt64(index * Self.valuesStride),
                    index: ShapePipeline.projectionBufferIndex)
                pipeline.argumentTable.setAddress(
                    values.gpuAddress + UInt64(index * Self.valuesStride),
                    index: ShapePipeline.valuesBufferIndex)
                pipeline.argumentTable.setAddress(
                    lighting.gpuAddress + UInt64(index * Self.valuesStride),
                    index: ShapePipeline.lightingBufferIndex)
                pipeline.argumentTable.setAddress(
                    materials.gpuAddress + UInt64(index * Self.valuesStride),
                    index: ShapePipeline.materialBufferIndex)
                pipeline.argumentTable.setAddress(
                    surroundings.gpuAddress + UInt64(index * Self.valuesStride),
                    index: ShapePipeline.surroundingsBufferIndex)
                encoder.setScissorRect(scissor(batch.clip))
                pipeline.argumentTable.setAddress(
                    blendModeBuffer.gpuAddress
                        + UInt64(Int(run.mode.rawIndex) * Self.blendModeStride),
                    index: ShapePipeline.blendModeBufferIndex)
                // **必ず何かを束ねる。** 渡されていない列には 1 個の 0 を束ねる —
                // 束ねずに走らせると、読んだ断片が絵の乱れではなく異常終了になる
                pipeline.argumentTable.setAddress(
                    (run.numbers ?? emptyNumbers).storage.gpuAddress,
                    index: ShapePipeline.numbersBufferIndex)
                pipeline.argumentTable.setTexture(
                    run.texture.gpuResourceID, index: ShapePipeline.textureIndex)
                // 利用者が宣言した面。**口は毎回すべて束ねる** — 渡していない口には
                // 読む面を束ねる。束ねずに走らせると、宣言より多く読んだ断片が
                // 絵の乱れではなく異常終了になる (数の並びと同じ扱い)
                for slot in 0..<ShapePipeline.surfaceCapacity {
                    let surface = slot < run.surfaces.count ? run.surfaces[slot] : run.texture
                    pipeline.argumentTable.setTexture(
                        surface.gpuResourceID, index: ShapePipeline.surfaceTextureIndex + slot)
                }
                encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
                if let arguments = batch.indirectArguments {
                    // **個数は GPU が書いた引数から読む。** 計算の段の末尾の仕掛け
                    // (`encodeComputeBarrier`) が頂点段の前で待つので、引数の読み出しは
                    // 書き終わった後になる
                    encoder.drawPrimitives(
                        primitiveType: .triangle, indirectBuffer: arguments.gpuAddress)
                } else {
                    encoder.drawPrimitives(
                        primitiveType: .triangle,
                        vertexStart: run.start, vertexCount: run.count,
                        instanceCount: batch.instanceCount)
                }
            }
        }

        drawCallsInLastFrame = vertices.isEmpty && solidVertices.isEmpty ? 0 : batches.count
        flatVerticesInLastFrame = vertices.count
        encoder.endEncoding()

        // **描き終えた絵に効果を通す。** 段はすべて出力段の手前に立つので、画面も
        // 書き出しも観測も同じ 1 枚を受け取る (ADR-0023 決定 2)
        if applyingEffects { applyEffects(into: commands) }

        // **拡大は出口の直前・段の最後。** 効果は描く細かさの上で働き、その結果を
        // 出す細かさへ広げる。順を逆にすると、効果の半径が出す細かさで測られて
        // 細かさを変えるたびに効き方が変わる
        if applyingEffects { applyUpscale(into: commands) }

        // **画素を読む直前の描き切りなら、描き終えた絵を写しへ読み戻す blit を末尾に積む。**
        // 別のコマンドにすると投入が 1 本増えるので、同じコマンドの末尾に置く (#753)
        if mirroringPixels { try target.encodePixelReadback(into: commands) }

        // **投入して、待たない。** 直後の片付けで列が抱えていた参照 (面・数の並び・
        // 断片・外の置き場所) が落ちるので、GPU が終わるまで抱えておく側へ渡す —
        // この世代のコマンドはリソースを保持しないため、渡さないと利用者が `draw()` の
        // 中で作って手放した絵を、GPU が読んでいる途中で解放することになる (#727)
        let submission = gpu.commit(
            commands, retaining: [HeldFrame(batches: batches, effects: pendingEffects)])
        if mirroringPixels { target.markPixelsMirrored(through: submission) }

        // **描き切ったらその場で片付ける。** 片付けをフレームの頭に置くと、フレームの
        // 途中で描き切ったときに溜めたものが残り、同じ図形が 2 度描かれる。
        // ここは**描き切れたときだけ**の片付けで、投げたときは `draw(_:)` の
        // `defer` が同じことをする (#342) — 途中の描き切り (`loadPixels()`) が
        // 一時的に失敗しただけなら、溜めたものはフレーム末尾の描き切りに残す
        discardFrame()
    }

    /// 描き切りが GPU に読ませる参照のうち、この型が所有していないもの。
    ///
    /// 列 (`Batch`) は面・数の並び・断片・外の置き場所を抱え、効果は断片を抱える。
    /// どちらも描き切りの直後に空になるので、GPU が終わるまで生かしておく入れ物と
    /// して ``RenderDevice/commit(_:retaining:)`` へ渡す。頂点や列ごとの値の置き場は
    /// この型が持ち続けるので、ここには要らない。
    private final class HeldFrame {
        let batches: [Batch]
        let effects: [Effect]
        init(batches: [Batch], effects: [Effect]) {
            self.batches = batches
            self.effects = effects
        }
    }

    /// 列ごとの値を置く領域。足りなければ取り直す。
    private func valuesBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = valuesBuffer, valuesCapacity >= count { return buffer }
        let capacity = max(count, max(valuesCapacity * 2, 16))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.valuesStride)
        valuesBuffer = buffer
        valuesCapacity = capacity
        return buffer
    }

    /// 頂点を置く領域。足りなければ取り直す。
    /// 立体の置き場所の置き場。
    private var solidInstanceBuffer: (any MTLBuffer)?
    private var solidInstanceCapacity = 0

    /// 立体の頂点を置く領域。足りなければ取り直す。
    private func solidVertexBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = solidVertexBuffer, solidVertexCapacity >= count { return buffer }
        let capacity = max(count, max(solidVertexCapacity * 2, 1024))
        let buffer = try gpu.makeReadableBuffer(
            byteCount: capacity * MemoryLayout<SolidVertex>.stride)
        solidVertexBuffer = buffer
        solidVertexCapacity = capacity
        return buffer
    }

    /// 立体の置き場所を置く領域。足りなければ取り直す。
    private func solidInstanceBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = solidInstanceBuffer, solidInstanceCapacity >= count { return buffer }
        let capacity = max(count, max(solidInstanceCapacity * 2, 256))
        let buffer = try gpu.makeReadableBuffer(
            byteCount: capacity * MemoryLayout<SolidInstance>.stride)
        solidInstanceBuffer = buffer
        solidInstanceCapacity = capacity
        return buffer
    }

    /// 平面の置き場所を置く領域。足りなければ取り直す。
    private func flatInstanceBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = flatInstanceBuffer, flatInstanceCapacity >= count { return buffer }
        let capacity = max(count, max(flatInstanceCapacity * 2, 256))
        let buffer = try gpu.makeReadableBuffer(
            byteCount: capacity * MemoryLayout<FlatInstance>.stride)
        flatInstanceBuffer = buffer
        flatInstanceCapacity = capacity
        return buffer
    }

    /// 光を置く領域。足りなければ取り直す。
    private func lightBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = lightBuffer, lightCapacity >= count { return buffer }
        let capacity = max(count, max(lightCapacity * 2, 8))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * MemoryLayout<Light>.stride)
        lightBuffer = buffer
        lightCapacity = capacity
        return buffer
    }

    /// 列ごとの「光がどこから何個か」を置く領域。足りなければ取り直す。
    private func lightingBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = lightingBuffer, lightingCapacity >= count { return buffer }
        let capacity = max(count, max(lightingCapacity * 2, 16))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.valuesStride)
        lightingBuffer = buffer
        lightingCapacity = capacity
        return buffer
    }

    /// 光から見た奥行きを焼く。焼かなかったら `nil`。
    ///
    /// 焼くのは**落とす側の列だけ**。分けられないと、自己遮蔽の強い形を置いた作品が
    /// 「影を切る」以外の逃げ道を失う。
    private func bakeShadow(
        into commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> (map: ShadowMap, matrix: simd_float4x4)? {
        guard let matrix = shadowMatrix, !solidVertices.isEmpty else { return nil }
        let casting = batches.filter(\.castsShadow)
        guard !casting.isEmpty else { return nil }

        let map = try shadowMapHolding(shadowDetailValue)
        let solidBuffer = try solidVertexBufferHolding(solidVertices.count)
        solidVertices.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else { return }
            solidBuffer.contents().copyMemory(from: base, byteCount: source.count)
        }
        let instanceBuffer = try solidInstanceBufferHolding(max(solidInstances.count, 1))
        solidInstances.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else { return }
            instanceBuffer.contents().copyMemory(from: base, byteCount: source.count)
        }
        let matrixBuffer = try shadowMatrixBufferHolding()
        var value = matrix
        matrixBuffer.contents().copyMemory(
            from: &value, byteCount: MemoryLayout<simd_float4x4>.size)

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: map.makeRenderPass())
        else {
            throw .encoderUnavailable
        }
        encoder.setRenderPipelineState(pipeline.shadowState)
        encoder.setDepthStencilState(pipeline.solidDepthState)
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0, width: Double(map.detail), height: Double(map.detail),
                znear: 0, zfar: 1))
        encoder.setFrontFacing(.clockwise)
        pipeline.argumentTable.setAddress(
            solidBuffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
        pipeline.argumentTable.setAddress(
            matrixBuffer.gpuAddress, index: ShapePipeline.projectionBufferIndex)
        pipeline.argumentTable.setAddress(
            emptyNumbers.storage.gpuAddress, index: ShapePipeline.numbersBufferIndex)
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
        for batch in casting {
            pipeline.argumentTable.setAddress(
                (batch.instances ?? instanceBuffer).gpuAddress
                    + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
                index: ShapePipeline.instanceBufferIndex)
            // 画面と同じ捨て方で焼く。閉じた形では光から見た最も近い面も必ず表なので、
            // 裏面を捨てても焼き付く奥行きは変わらない
            encoder.setCullMode(batch.cullMode)
            encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
            if let arguments = batch.indirectArguments {
                // 粒は影の側でも GPU が書いた個数で描く (本描画と同じ)
                encoder.drawPrimitives(
                    primitiveType: .triangle, indirectBuffer: arguments.gpuAddress)
            } else {
                encoder.drawPrimitives(
                    primitiveType: .triangle,
                    vertexStart: batch.run.start, vertexCount: batch.run.count,
                    instanceCount: batch.instanceCount)
            }
        }
        encodeShadowBarrier(on: encoder)
        encoder.endEncoding()
        return (map, matrix)
    }

    /// 焼き上がりを待つ仕掛けを積む。**焼いた面を画面のパスが読む前に置く。**
    ///
    /// この世代のコマンド構造は encoder をまたぐ依存を自動では張らないので、同じ
    /// コマンドに順に積んだだけでは焼き付けと画面が重なりうる。重なると画面は
    /// 書き終わる前の焼き付け先を読み、**前のフレームの影が混ざる** ([#341])。
    ///
    /// - `afterStages`: 奥行きを書くのは断片段
    /// - `beforeQueueStages`: 焼いた面を読むのも断片段
    /// - `visibilityOptions`: `.device` を渡す。既定の「流さない」側にすると
    ///   実行順だけ揃えて**中身が見えない**ことになる
    ///
    /// [#341]: https://github.com/mokume-metal/mokume/issues/341
    private func encodeShadowBarrier(on encoder: any MTL4RenderCommandEncoder) {
        encoder.barrier(
            afterStages: .fragment, beforeQueueStages: .fragment, visibilityOptions: .device)
        shadowBarriersEncoded += 1
    }

    /// 焼き付け先。**同じ細かさなら作り直さない** ([ADR-0021] 決定 4)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    private func shadowMapHolding(_ detail: Int) throws(RenderFailure) -> ShadowMap {
        if let shadowMap, shadowMap.detail == detail { return shadowMap }
        let map = try ShadowMap(gpu: gpu, detail: detail)
        shadowMap = map
        shadowMapsBuilt += 1
        return map
    }

    /// 影の行列を置く領域。
    private func shadowMatrixBufferHolding() throws(RenderFailure) -> any MTLBuffer {
        if let shadowMatrixBuffer { return shadowMatrixBuffer }
        let buffer = try gpu.makeReadableBuffer(byteCount: Self.valuesStride)
        shadowMatrixBuffer = buffer
        return buffer
    }

    /// 列ごとの周囲を置く領域。足りなければ取り直す。
    private func surroundingsBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = surroundingsBuffer, surroundingsCapacity >= count { return buffer }
        let capacity = max(count, max(surroundingsCapacity * 2, 16))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.valuesStride)
        surroundingsBuffer = buffer
        surroundingsCapacity = capacity
        return buffer
    }

    /// 列ごとの材質を置く領域。足りなければ取り直す。
    private func materialBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = materialBuffer, materialCapacity >= count { return buffer }
        let capacity = max(count, max(materialCapacity * 2, 16))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.valuesStride)
        materialBuffer = buffer
        materialCapacity = capacity
        return buffer
    }

    /// 列ごとの行列を置く領域。足りなければ取り直す。
    private func matrixBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = matrixBuffer, matrixCapacity >= count { return buffer }
        let capacity = max(count, max(matrixCapacity * 2, 16))
        let buffer = try gpu.makeReadableBuffer(byteCount: capacity * Self.valuesStride)
        matrixBuffer = buffer
        matrixCapacity = capacity
        return buffer
    }

    private func vertexBufferHolding(_ count: Int) throws(RenderFailure) -> any MTLBuffer {
        if let buffer = vertexBuffer, vertexCapacity >= count { return buffer }
        let capacity = max(count, max(vertexCapacity * 2, 1024))
        let buffer = try gpu.makeReadableBuffer(
            byteCount: capacity * MemoryLayout<ShapeVertex>.stride)
        vertexBuffer = buffer
        vertexCapacity = capacity
        return buffer
    }
}
