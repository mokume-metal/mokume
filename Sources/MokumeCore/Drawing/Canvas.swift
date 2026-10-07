// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
import simd

/// 絵を描く面。
///
/// ## 座標の約束
///
/// **原点は左上、単位は画素、縦軸は下向き。** 整数の座標は画素の**角**を指し、
/// **塗りと線で乗る場所が違う** ([ADR-0039] 決定 2):
///
/// - **塗りの縁は、整数の座標で画素の境目に乗る。** `rect(10, 20, 4, 8)` はちょうど
///   4×8 画素を塗り、`circle(24, 24, 20)` は画素の角 (24, 24) を中心に上下左右が対称に
///   塗られる。立体・字形・画像も同じ
/// - **線・輪郭・点の中心は、整数の座標で画素の中心に乗る。** `x = 10` に引いた太さ 1 の
///   線は 10 から 11 までを覆い、画素 1 列だけがはっきり塗られる
///
/// 線だけを画面で半画素寄せているのは、そのまま角に置くと太さ 1 の線が 2 列の画素を
/// 半分ずつ塗って滲むためである。**寄せは経路によらない** — 距離関数で描く基本図形も、
/// 三角形で描く図形も、畳んだ図形も、保持した形も、立体の輪郭も、同じ場所に乗る。
///
/// **線の載り方は手本 (p5.js) と違う。** p5.js は線を寄せないので、`line(10, 0, 10, 100)`
/// の太さ 1 の線は座標 10 の境目をまたぎ、2 列の画素に半分ずつ薄く乗る。mokume は
/// 1 列に濃く乗せる。光の総量は同じで、置き場が半画素違う。**手本には寄せない** —
/// 手本に倣うのは名前と引数の順序までで、同じ画素が出ることは約束しない ([ADR-0020] 決定 1)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
///
/// ## 描き方
///
/// <!-- example: 組めない Canvas を直に回す例で、投げられる場所に置かれる (draw() の中には貼れない) -->
/// ```swift
/// try canvas.draw {
///     canvas.background(26, 26, 31)
///     canvas.fill(255, 102, 51)
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

    /// 描く画素 1 つが描画先の座標でいくらか (x, y)。細かさ 1 では描く先と出す先が同じ
    /// 1 枚なので、幅を幅で割ってちょうど 1 になる。
    ///
    /// 基本図形の頂点関数が縁の被覆を描く画素で測るために読み (`FlatFrame`・#1488)、
    /// 置く側が 1 画素より細い塗りを判定するのにも使う (`FormInstance.mayHaveThinFill`・#1477)。
    var unitsPerDrawnPixel: SIMD2<Float> {
        SIMD2(width / Float(pixelWidth), height / Float(pixelHeight))
    }

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

    /// フレームごとに CPU が書く置き場の環。
    ///
    /// **描き切り 1 回につきスロットを 1 つ進める** (フレームではなく描き切り単位 —
    /// 画素の読み出しはフレームの途中でも描き切りを起こすので、投入 1 本 = スロット
    /// 1 つが対応の正しい粒度である)。効果の段の置き場も同じ環に載る (同じ投入が読む)。
    let frameRing: FrameRing

    let pipeline: ShapePipeline

    /// 描画先の座標へ落とす行列。整数の座標を画素の角へ落とす。
    let projection: simd_float4x4

    /// 溜めている頂点と、その置き場。
    var vertices: [ShapeVertex] = []
    private let vertexStorage: GrowableBuffer
    /// 平面の頂点ごとの被覆の置き場 (``coverageSpans``)。区間が無いフレームは 1 つだけ書く。
    private let coverageStorage: GrowableBuffer

    /// 平面の置き場所。列は自分の区間を指す。
    ///
    /// **添字 0 は常に何も動かさない置き場所**で、畳めない列 (字・画像・その場で並べた
    /// 頂点) はここを指す。毎フレーム置き直すので、溜め場を捨てても消えない。
    var flatInstances: [FlatInstance] = [.identity]
    private let flatInstanceStorage: GrowableBuffer

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
    var buildingFlatTemplate = false

    /// 保持する形を記録している最中か。**記録の間は畳まない。**
    ///
    /// 保持した形は自分で畳む仕組みを持つ ([#241](https://github.com/mokume-metal/mokume/issues/241)) —
    /// 記録するのは頂点と区間だけで、置き場所は持ち歩かない。記録の中で畳むと、形自身の
    /// 座標へ寄せた頂点だけが残り、**どこへ置くかが記録から落ちる**。
    ///
    /// **立体も同じ答えを取る** ([#1297])。組み込みの形・読み込んだモデル・組み立ての中で
    /// 置き直した保持した形は、置き場所に変換と塗りを持たせて描くが、記録の間は置き場所を
    /// 頂点へ焼いて積む (``SolidInstance/placing(_:)``)。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    var recordingShape = false

    /// 保持する形を記録している間に、輪郭が積んだ平面の頂点の区間。
    ///
    /// 輪郭は画面で半画素寄せる ([ADR-0039] 決定 2) が、記録の間は置く場所の変換が
    /// 決まっていないので寄せられない。**区間を覚えておき、置くときに行列を掛けた直後に
    /// 寄せる** (`Shape.strokeRanges`)。記録を終えると `createShape` が抜く。
    ///
    /// 不透明の線の区間は、片を引く素材も持つ (``StrokeRange``・#1829・#1920)。置くときに
    /// 半透明の色を掛けるなら、そこで引いて区間を差し替える。
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    var recordedStrokeRanges: [StrokeRange] = []

    /// 保持する形を記録している間に、楕円・弧の塗りが積んだ平面の頂点の区間 (``RingFillRange``・#1645)。
    ///
    /// 周は記録のときの拡大で刻んであるので、**区間を刻み直す素材を覚えておき、置くときの拡大で
    /// 刻み直す** (`Shape.fillRanges`)。記録を終えると `createShape` が抜く。
    var recordedFillRanges: [RingFillRange] = []

    /// 保持する形を記録している間に積んだ立体の線の元 (``SolidStrokePiece``)。
    ///
    /// 立体の線の帯は視点に合わせて組むので、記録したときの視点で組んだ帯は置いた先で
    /// 合わない。**線の元を覚えておき、置くときに組み直す** (`Shape.solidStrokes`)。
    /// 記録を終えると `createShape` が抜く。
    var recordedSolidStrokes: [SolidStrokePiece] = []

    /// 保持する形を記録している間に、**GPU で組める**組み込み立体の線を覚えたもの
    /// (``RetainedGPUStroke``・#1756)。記録を終えると `createShape` が抜く。
    var recordedGPUStrokes: [RetainedGPUStroke] = []

    /// 保持した形の線を、組めるものは GPU で組むか。**検査が偽にして、CPU で組む物差しを作る。**
    var placesRetainedStrokesOnGPU = true

    /// 立体の線を組み直している間、頂点を積む代わりに位置と形自身の座標を受け取る先。
    ///
    /// 組み直しは即時に描くときと**同じ関数** (網の骨・帯・円板・正方形・折れ目) を通す。向き・
    /// 幅・寄せの式や、画面で重なる点のまとめ方を 2 か所に書くと、片方だけ直した誤りが保持した
    /// 形でだけ現れる (#1547・#1893)。
    var solidStrokeCapture: [(position: SIMD3<Float>, shape: SIMD3<Float>)]?

    /// いま組んでいる立体の線の被覆 (細い線を広げたとき 1 未満・#1637)。線の頂点が
    /// ``SolidVertex/stroke`` に名乗る。
    var solidStrokeCoverage: Float = 1
    /// いま組んでいる立体の線が、点 1 つの線か。記録する部品が覚える (``SolidStrokePiece/isLonePoint``)。
    var solidStrokeIsLonePoint = false

    /// 平面の頂点のうち、被覆が 1 でない区間 (#1637)。**頂点の番号で、番号の順に並ぶ。**
    ///
    /// 描く画素で 1 画素より細い線を 1 画素の帯へ広げたとき、太さの割合を頂点の色ではなく
    /// ここで運ぶ (``ThinStroke``)。頂点の大きさを増やさないためで、区間が無いフレームは
    /// 何も払わない。区間があるフレームだけ、頂点ごとの被覆の並びを組んで写す
    /// (``uploadGeometry(reusing:)``)。
    var coverageSpans: [CoverageSpan] = []
    /// 畳みの雛形を組んでいる間、細い線を測る置き場所の変換 (雛形の鍵 ``FlatKey/strokeLinear``)。
    /// 細くならない雛形では `nil`。
    var templateStrokeMatrix: simd_float4x4?
    /// 保持した形の細い輪郭を組み直した回数 (検査用・``thinVertices(_:placedBy:cache:stroke:)``)。控えが
    /// 効いていれば、同じ大きさで置き続けても増えない。
    var thinStrokesRebuilt = 0
    /// 開いている列に、細い線を広げた (被覆が 1 未満の) 頂点を積んだか (#1637)。列を閉じるときに
    /// ``Batch/thinCoverage`` へ移して下ろす。
    var openBatchHasThinCoverage = false

    /// 畳む相手を待っている図形。**今までどおり置かれた 1 つ目**である。
    ///
    /// 同じ形が 2 つ目に来たら、ここに控えた周から雛形を積み直して畳む。1 つ目から
    /// 雛形を開かないのは、**平面が元から 1 つの列にまとまる**ためで、図形ごとに列を
    /// 割ると畳む前より遅くなる場面 (矩形と円を交互に置く絵) が出る。
    var pendingFlat: PendingFlat?

    /// 平面の基本図形の置き場所。列は自分の区間を指す ([#752])。
    ///
    /// 矩形・楕円・扇形・線・点はここに載る。頂点は 1 つも積まない — 形も寸法も置き場所が
    /// 持ち、断片が距離関数で描く (`Canvas+Form.swift`)。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    var formInstances: [FormInstance] = []
    private let formInstanceStorage: GrowableBuffer
    /// いま開いている基本図形の列。
    var openForm: OpenForm?

    /// 畳む相手を待っている図形ひとつぶん。
    struct PendingFlat {
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
    /// 変換も色も入っていない — どちらも置き場所が持つためである。**ただし円の分割数は入る。**
    /// 分割数は画面に出る半径で決まる (``segmentCount(forRadius:scale:)``) ので、寸法が同じでも
    /// 置き場所の拡大が違えば違う。**鍵に入れるのは拡大そのものではなく整数の分割数**で、
    /// 拡大が少し違うだけの置き場所は、同じ分割になる限り 1 つの雛形に畳まれる ([#1645])。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    ///
    /// **効く相手は基本図形の全部ではない。** 矩形・楕円・扇形・線・点は [#752] で距離
    /// 関数の経路 (`FormInstance`) へ移り、素のままではここへ来ない — 境目は
    /// `formAllowed(fills:)` (`Canvas+Form.swift`) で、そこが断るときだけ三角形を積む
    /// 経路へ落ちる。だからこの鍵が畳むのは次の 2 つだけである:
    ///
    /// - **貼る絵** (`texture()`) が効いた塗りを持つ図形。輪郭も持つものは 1 つの図形の
    ///   途中で読む面が割れるので、`draw(folding:at:outline:)` が畳まずに落とす
    /// - **利用者の断片** (`shader()`) が効いている間の図形 (塗りも輪郭も畳める)
    ///
    /// 字・画像・任意多角形は元からここへ来ない。**「基本図形の畳み」と読むと外れる** —
    /// #424 が置いた当時はそれで正しかったが、いまはスプライトを大量に置く書き方
    /// (貼る絵 + 矩形を数千) が実需で、それがこの機構を残している相手である ([#770])。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    /// [#770]: https://github.com/mokume-metal/mokume/issues/770
    struct FlatKey: Equatable {
        var form: FlatForm
        var hasFill: Bool
        var hasStroke: Bool
        var strokeWeight: Float
        var strokeCap: StrokeCap
        var strokeJoin: StrokeJoin
        /// 楕円・弧の周を、一周でいくつに刻むか。矩形は周を刻まないので 0。
        var ringSegments: Int
        /// 輪郭の円板 (丸い端・丸い折れ目・周の刻み) の周を、一周でいくつに刻むか。円板を置かない
        /// 輪郭 (丸めない矩形・輪郭の無い図形) は 0 で、拡大の違いで雛形を割らない。
        var discSegments: Int
        /// 置き場所の変換で描く画素 1 画素より細くなる線を持つなら、その変換 (#1637)。細い線は
        /// 置き場所の大きさごとに広げ方が違うので、**回転を除いて同じ変換の置き場所だけを畳む**
        /// (``ThinFold``)。細くならなければ `nil` で、変換の違う置き場所も同じ雛形に畳む
        /// (これまでどおり)。
        var strokeLinear: ThinFold?
        /// 塗りに貼る絵の面。**どの絵かまで鍵に入る。** 読み取り位置が寸法から決まる
        /// うえ、面そのものが列を分けるためである。有無しか持たないと、雛形を開いた
        /// 後に絵を差し替えても畳み続けて、2 枚目以降が前の絵で描かれる ([#1298])。
        ///
        /// 貼る絵は**塗りにしか効かない**ので、塗りを持たない図形はここが常に `nil` で、
        /// 絵を差し替えても列は割れない。
        ///
        /// [#1298]: https://github.com/mokume-metal/mokume/issues/1298
        var texture: HeldTexture?
    }

    /// 細い線を持つ雛形の鍵 (#1637)。**比べるのは回転に依らない部分** (``rotationFreeKey(_:)``)
    /// だけで、雛形を組むのは最初の置き場所の 2x2 (``linear``) である。片は描く画素の空間で
    /// 組むので、回転だけが違う置き場所には同じ雛形が合う。
    struct ThinFold: Equatable {
        var key: SIMD4<Float>
        var linear: SIMD4<Float>

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
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

        /// 周を刻む円の半径 (大きいほうの軸)。矩形は周を刻まないので `nil`。
        var ringRadius: Float? {
            switch self {
            case .rect: nil
            case .ellipse(let radiusX, let radiusY), .arc(let radiusX, let radiusY, _, _):
                max(radiusX, radiusY)
            }
        }

        /// 輪郭が円板を置くか。**規則は ``Canvas/strokePlacesDiscs(pointCount:isClosed:hasJoinCurveSteps:cap:join:)``
        /// の 1 つ**で、ここは周の形 (点の数・閉じているか・刻みか) を渡すだけである。楕円・弧の周は
        /// 点がどれも刻みで、矩形の周は 4 つの角 (刻みでない) で閉じる。
        func placesDiscs(cap: StrokeCap, join: StrokeJoin) -> Bool {
            switch self {
            case .rect:
                Canvas.strokePlacesDiscs(
                    pointCount: 4, isClosed: true, hasJoinCurveSteps: false, cap: cap, join: join)
            case .ellipse, .arc:
                Canvas.strokePlacesDiscs(
                    pointCount: 3, isClosed: true, hasJoinCurveSteps: true, cap: cap, join: join)
            }
        }
    }

    /// 分割数の直前の問い合わせ (半径と拡大 → 分割数)。**畳める図形が続くと、置き場所ごとに同じ
    /// 問いを繰り返す**ので、答えを引き直す `acos` を払わずに済む ([#1645])。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    struct SplitQuery {
        private var radius: Float = -1
        private var scale: Float = 0
        private var segments = 3

        mutating func count(forRadius radius: Float, scale: Float) -> Int {
            // 数でない値は等しくならないので、毎回引き直す
            if radius == self.radius, scale == self.scale { return segments }
            segments = Canvas.segmentCount(forRadius: radius, scale: scale)
            self.radius = radius
            self.scale = scale
            return segments
        }
    }

    /// 溜めている立体の頂点と、その置き場。
    ///
    /// 平面とは別の並びにする — 頂点の中身が違う (奥行きと面の向きを持つ) ためで、
    /// **順序は列が持つ**ので、別の並びにしても呼び出し順は崩れない。
    var solidVertices: [SolidVertex] = []
    /// 溜めている「立体の頂点を読む順」。値は ``solidVertices`` の番号そのもので、
    /// 列は自分の区間を指す (``Shape/solidIndices``)。
    ///
    /// **空でよい。** 添字を書かなかった形は、これまでどおり並べた順にそのまま描く。
    var solidIndices: [UInt32] = []
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

    /// 開いている列が、置き場所の上限に達したか。
    ///
    /// **上限を跨いだときだけ通る経路なので、判定を場所ごとに書くと 1 本だけ
    /// off-by-one していても絵に出ない** ([#894])。数えるのは「その列を開いてから
    /// 積んだ数」で、**達したら**閉じる — 超えてから閉じると、その列は上限より
    /// 1 つ多く抱えている。
    ///
    /// [#894]: https://github.com/mokume-metal/mokume/issues/894
    func isBatchFull(_ count: Int, since start: Int) -> Bool {
        count - start >= instanceCapacity
    }

    /// 開いている立体の列ひとつぶん。
    struct OpenSolid {
        /// 何の頂点を並べているか。**これが変わったら列を閉じる。**
        var source: SolidSource
        /// 頂点の並びの中での区間。
        var vertexStart: Int
        var vertexCount: Int
        /// 読む順の並び (``solidIndices``) の中で、この列が始まる位置。
        /// **`nil` が「添字を使わない」**を表す。
        ///
        /// 長さを持たないのは、この列の添字が常に並びの末尾に積まれるからである
        /// (置き場所と同じ数え方で、閉じるときに `solidIndices.count` との差を取る)。
        /// 既定値を持たせないのは、列を開く場所が増えた日に**黙って非添字へ倒れない**
        /// ようにするためで、倒れた列は三角形の並びとして描かれて絵だけが崩れる。
        var indexStart: Int?
        /// 置き場所の並びの中で、この列が始まる位置。
        var instanceStart: Int
        /// 置き場所を**外の置き場**から取るなら、その置き場と個数。
        ///
        /// `nil` なら溜め場の並び (いつもの経路)。粒だけがここを使う — 置き場所を
        /// 埋めるのが GPU なので、CPU の溜め場を通らない。
        var external: ExternalInstances?
        /// GPU で広げる線。閉じた列へそのまま渡し、骨と配置を所有する。
        var strokeGeometry: SolidStrokeGeometry?
        var strokePlacement: SolidStrokePlacement?
        /// 裏面が絵に出うるスタイルで、置き場所を 1 つでも足したか
        /// (``Canvas/placementMayShowBackFaces``)。1 つでも居れば列ごと両面で描き
        /// (``Batch/cullMode``)、組み込みの形と向きの求まったモデルの列なら、置き場所ごとに
        /// 裏 → 表の順で描く (``Batch/backFaceParts``)。
        ///
        /// **形を置いたときに記録する。** 塗りの不透明度も貼る絵も、変えただけでは列を閉じない
        /// (`fill`・`noTexture()`・`pop()`) ので、1 つの列に置いたときのスタイルが違う形が
        /// 同居し、閉じる時点のスタイルはもう置いたときのものではない。閉じる時点を読むと、
        /// 置いた後で外した絵の列が裏面を捨て、透けた画素から見えるはずの奥の面が消える
        /// ([#1564](https://github.com/mokume-metal/mokume/issues/1564))。
        var mayShowBackFaces = false
        /// 置き場所で置く組み込みの形・読み込んだモデルの、巻き方の向き (``SolidWinding``)。
        ///
        /// 列を閉じるとき、形全体を 1 つの部品 (``SolidPart``) にするのに使う。組み込みの形は
        /// 外向き、モデルは形から求めた向き。**裏面が絵に出うる置き場所を初めて足したときに求める**
        /// (`nil` はまだ求めていない)。求まらなければ部品にしない。
        var meshWinding: SolidWinding?
        /// 裏面が絵に出うる置き場所の、列の中での番号 (列の先頭から数える・置いた順)。
        ///
        /// **裏 → 表の 2 回で描くのは、印の付いた置き場所だけである。** 同じ列に不透明の置き場所が
        /// 同居しても、そちらは今までどおり 1 回で描く (続けて並んだ印の無い置き場所は 1 回の
        /// 呼び出しにまとめる)。印を付けるのは、組み込みの形・モデルをその場で置くとき (置いた
        /// スタイル) と、保持した形を置き場所で置くとき (置き場所の色) である
        /// (``Canvas/placementShowsBackFaces(_:styled:)``)。
        var backFaceInstances: [Int] = []
        /// 列に並べた部品 (``SolidPart``)。区間はこの列の描く単位で数える。
        ///
        /// **置き場所で置く組み込みの形の列は持たない** — 閉じるときに形全体を 1 つの部品にする
        /// (``meshWinding``)。持つのは、頂点を焼いて並べる列 (保持した形の中・線を持つ保持した形を
        /// 置いたとき) と、保持した形を置き場所で置く列である。部品の境目は記録した形 1 つずつで、
        /// 1 つの `createShape` に複数の形を記録しても、形どうしは記録した順のまま描く。
        var parts: [SolidPart] = []
        /// この列の置き場所が形を鏡映するか (``SolidInstance/isMirrored``)。
        ///
        /// **列の置き場所はどれも同じ符号を持つ。** 表の巻き方は列ごとに 1 つ
        /// (``Batch/frontFacing``) なので、符号が変わったら列を閉じる — 鏡映した置き場所と
        /// 鏡映していない置き場所を同じ列に同居させると、どちらかの手前の面が捨てられる
        /// ([#1446](https://github.com/mokume-metal/mokume/issues/1446))。その場で並べる列は
        /// 何も動かさない置き場所 1 つで描くので、いつも `false` である。
        var isMirrored = false
        /// いま組み立てている形の点番号が、この列のどの頂点になったか。
        ///
        /// **添字の列だけが使い、列と一緒に消える。** ``appendSolidVertex`` は貼る面の
        /// 切り替えで列を閉じうる (貼る絵と輪郭が両方効いていると、原始形ごとに 2 回
        /// 閉じる) ので、表を形の寿命で持つと 2 枚目以降の面が**閉じた列の頂点**を
        /// 指してでたらめになる。列に紐づけておけば、最悪でも共有が効かずに
        /// 3 点/三角形へ落ちるだけで、絵は必ず正しい。
        var sharedSlots: [Int: UInt32] = [:]
        /// 読み込んだモデルの塗りの頂点を持つ GPU の置き場 (``SolidFillGeometry``)。持っていれば、
        /// 列は溜め場ではなくここから頂点を読む。閉じた列へそのまま渡し、所有させる。
        var fillGeometry: SolidFillGeometry?
    }

    /// 溜め場ではなく、外の置き場から置き場所を取る指定。
    ///
    /// **置き場を持ち主 (``Numbers``) ごと持つ。** 生の置き場だけを持つと、粒を手放した後に
    /// フレームの途中で読み戻し (``read(_:)``) が走ったとき、同じフレームの描き切りが
    /// 読む前に置き場が常駐から外れる — 読み戻しが積んだ計算を先に流して、計算が抱えて
    /// いた持ち主を降ろすからである ([#1079]。面の側は ``HeldTexture`` が同じ役を持つ)。
    ///
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    struct ExternalInstances {
        var instances: Numbers
        /// 置き場所の上限 (置き場の大きさ)。**実際に描く数は GPU が `arguments` に書く。**
        var count: Int
        /// 描く引数 (`MTLDrawPrimitivesIndirectArguments`)。GPU が書くので、描く側は
        /// 個数を読まずにそのまま indirect draw へ渡す。
        var arguments: Numbers
    }

    /// 立体の頂点が何から来たか。
    enum SolidSource: Hashable {
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

    /// 読み込んだ絵の復号結果の控え。**同じファイルの中身が変わっていなければ復号し直さない。**
    ///
    /// 控えるのは**復号したところまで**で、``Image`` そのものではない ([#886])。絵は可変
    /// なので (``Image/set(_:_:_:)``・``Image/write(_:)``・``Image/fill(_:)``)、同じものを
    /// 配ると「読んで塗り替える」書き方が 2 フレーム目から元の絵を失う。読み込みは
    /// **常にファイルの中身を返す**、を保ったまま探索と復号だけを省く。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    var imageCache = BoundedCache<ImageRequest, DecodedImage>(
        budget: Canvas.imageCacheBudget, weight: \.bytes)
    /// いま控えている画素の総量 (バイト)。
    var imageCacheBytes: Int { imageCache.total }
    /// 控えに置いておく画素の総量 (バイト)。超えたら、収まるまで古い順に捨てる。
    ///
    /// **数ではなく量で切る。** 絵は 16 画素四方のことも 4096 画素四方のこともある —
    /// 枚数で切ると、同じ上限が 8 KiB にも 2 GiB にもなる。上限を持つこと自体は
    /// [ADR-0023] 決定 5 (名前を組み立てて読む書き方で際限なく増えない) の要求である。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    static let imageCacheBudget = 64 << 20
    /// 絵を復号した回数 (作ってから通算)。
    ///
    /// **控えが効いているかを、絵ではなく数で確かめる値。** 絵は同じでも毎フレーム復号し
    /// 直していれば費用は払っているので、``solidMeshesBuilt`` と同じ形で数える。
    var imagesDecoded: Int { imageCache.made }

    /// 読み込んだモデルの控え。**同じファイル・同じ整え方なら読み直さない。**
    ///
    /// **量で切る** (``modelCacheBudget``)。モデル 1 つの重さは、三角形 1 枚の 1 KB に
    /// 満たないものから数百 MB まで開く — 件数で切ると、同じ上限が KB にも GB にもなる
    /// (絵と同じ理由)。重さは ``modelCacheWeight(_:)`` が見積もる。
    ///
    /// 控えが要るのは、`draw()` の中で `loadModel` を呼ぶ書き方で毎フレーム読み直さない
    /// ためである。上限が要るのは、名前を組み立てて読む書き方 (動きを書き出した連番の
    /// OBJ) で、読んだモデルが全部残るためである ([#1593]・[ADR-0023] 決定 5)。
    ///
    /// [#1593]: https://github.com/mokume-metal/mokume/issues/1593
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var modelCache = BoundedCache<ModelRequest, Model>(
        budget: Canvas.modelCacheBudget, weight: Canvas.modelCacheWeight)
    /// 控えに置いておくモデルの重さの合計 (見積もりのバイト数)。画像の控えとは別に持つ。
    static let modelCacheBudget = 64 << 20
    /// モデル 1 つの重さの見積もり (バイト)。
    ///
    /// **モデルが持つ大きなものは点の並びだけである。** 三角形ごとに 3 点を持ち、頂点を
    /// 共有しないので、点の数 × 点 1 つの大きさでほぼ決まる (#1593 の実測と 1% 以内で合う)。
    /// 1 件あたりの固定分 (名前・鍵・表の枠) を足すのは、面の無いモデルを大量に読んでも
    /// 重さ 0 で際限なく溜まらないためである。
    nonisolated static func modelCacheWeight(_ model: Model) -> Int {
        model.mesh.points.count * MemoryLayout<SolidMesh.Point>.stride + 1024
    }
    /// 保持した形を置くたびに増える番号。
    var retainedSerial = 0
    /// 立体の頂点の置き場。**写した回数 (``GrowableBuffer/writes``) を検査が読む** (#1790)。
    let solidVertexStorage: GrowableBuffer
    private let solidIndexStorage: GrowableBuffer

    /// いま開いている列が、どちらの並びから描かれるか。
    var openSource = VertexSource.flat

    /// 使い回している立体の形。**量で切る** (``solidCacheBudget``)。
    ///
    /// 件数では切らない。形 1 つの大きさは細かさで開く — 箱は 1.7 KB、既定の細かさ (24) の
    /// 輪環は 166 KB、細かさ 128 の輪環は 4.7 MB ある。件数で切ると、同じ上限が 100 KB にも
    /// 300 MB にもなる。
    var solidMeshes = BoundedCache<SolidShape, SolidMesh>(
        budget: Canvas.solidCacheBudget, weight: Canvas.solidMeshWeight)
    /// 立体の形を組み立てた回数 (作ってから通算)。
    ///
    /// **畳めているかではなく、作り直していないかを数える値。** 絵は同じでも毎フレーム
    /// 組み立て直していれば確保が積み上がるので、絵ではなく数で確かめる。
    var solidMeshesBuilt: Int { solidMeshes.made }
    /// 球の形を、同じ細かさの単位球から位置だけ作った回数 (作ってから通算・#1751)。
    /// **三角関数を引き直さずに済んだ回数**で、`solidMeshesBuilt` との差が引き直した回数になる。
    var spheresFromUnit = 0
    /// 立体の形の控えと稜線の控えに、**それぞれ**置いておく重さの合計 (見積もりのバイト数)。
    /// 超えたら古い順に 1 件ずつ捨てる。
    ///
    /// 既定の細かさでいちばん重い形 (輪環・166 KB) を 64 種並べても収まる大きさにしてある
    /// (件数 64 で切っていた頃に当たっていた並びは、既定の細かさなら今も当たる)。
    static let solidCacheBudget = 16 << 20
    /// 形 1 つの重さの見積もり (バイト)。点の並びと、1 件あたりの固定分。
    nonisolated static func solidMeshWeight(_ mesh: SolidMesh) -> Int {
        mesh.points.count * MemoryLayout<SolidMesh.Point>.stride + 256
    }
    /// 稜線 1 つの重さの見積もり (バイト)。溶接した点と辺の並びと、1 件あたりの固定分。
    nonisolated static func solidEdgesWeight(_ net: SolidEdges) -> Int {
        net.points.count * MemoryLayout<SIMD3<Float>>.stride
            + net.edges.count * MemoryLayout<(Int, Int)>.stride + 256
    }
    /// 形から取り出した稜線の控え。**線を引いたときにだけ作る** — 塗りだけの形は
    /// 稜線を求めない。**量で切る** (``solidCacheBudget``)。
    ///
    /// **読み込んだモデルの稜線もここに載る** (鍵はモデルの番号)。モデルの控え
    /// (``modelCache``) から追い出されたモデルを読み直すと番号が変わるので、前の番号の稜線は
    /// 二度と当たらない。件数で切ると、それが大きなモデル 64 個分まで予算の外に残る
    /// ので、量で切る。上限を超える長さの連番に線を引いて回すと、毎回溶接し直す。
    ///
    /// 球は通常の半径なら、半径1の稜線を共有する (#1606)。他の形と溶接の計算範囲の
    /// 端にある球は寸法も鍵に持ち、予算に収まらなければ古いものから作り直す。
    var solidEdges = BoundedCache<SolidSource, SolidEdges>(
        budget: Canvas.solidCacheBudget, weight: Canvas.solidEdgesWeight)
    /// 同じ稜線の GPU 上の骨。列も所有し、控えの追い出しと描画の寿命を分ける。
    var solidStrokeGeometry = BoundedCache<SolidSource, SolidStrokeGeometry>(
        budget: Canvas.solidCacheBudget, weight: { $0.buffer.length + 256 })
    /// 読み込んだモデルの塗りの頂点の、GPU 上の置き場 (#1749)。列も所有し、控えの追い出しと
    /// 描画の寿命を分ける (線の骨 ``solidStrokeGeometry`` と同じ作法)。
    ///
    /// **1 つで予算の半分を超えるモデルは持たない** (``modelFill(for:isDerived:textured:mesh:)``)
    /// — 追い出し合って毎フレーム作り直すと、溜め場へ写すより重くなる。検査は予算を 0 に
    /// して、持たない経路 (以前の経路) を物差しにする。
    var modelFills = BoundedCache<SolidMeshRangeKey, SolidFillGeometry>(
        budget: Canvas.modelFillBudget, weight: { $0.buffer.length + 256 })
    /// ``modelFills`` の予算 (バイト)。頂点 1 つは 96 バイトで、CPU 側の控え
    /// (``modelCache``、点 1 つ 48 バイト・予算 64 MiB) に収まるモデルを全部持てる大きさにする。
    static let modelFillBudget = 128 << 20
    /// 今回の描き切りで積んだ塗りの頂点。列が切れても同じ頂点範囲を指せる。
    var solidMeshRanges: [SolidMeshRangeKey: Range<Int>] = [:]
    /// 一周を割る数の既定。
    public static let defaultSolidDetail = 24

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
    var lightStorage: [Light] = []
    /// 光の置き場。
    private let lightStorageBuffer: GrowableBuffer
    /// 列ごとの「光がどこから何個か」の置き場。
    private let lightingStorage: GrowableBuffer

    /// 列ごとの材質の置き場。列 1 つにつき 1 区画。
    private let materialStorage: GrowableBuffer

    /// いま置かれている周囲。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// 光と同じく「置く」ものなので、積んだスタイルには入れない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var activeSurroundings: Surroundings?
    /// 列ごとの周囲の置き場。列 1 つにつき 1 区画。
    private let surroundingsStorage: GrowableBuffer

    /// 影を落とすか。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shadowsEnabled = false
    /// この面で影を 1 度でも有効にしたか。**フレームを越える** — 区切りで落とす側を写すか
    /// (``keepCasters(into:)``) を決める印で、影を使わないスケッチの区切りに写しを払わせない
    /// ([#1656])。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    var shadowsEverEnabled = false
    /// 焼き付ける範囲の一辺。`nil` なら面から導く。**フレームを越えない** (同 決定 4)。
    var shadowRangeValue: Float?
    /// 焼き付け先の一辺の画素数。**フレームを越えない** (同 決定 4)。
    ///
    /// 焼き付け先は重い下ごしらえだが、**それは越える理由にならない** — 決定 4 は
    /// 「重いから越える」という例外を作らないと定め、代わりに**同じ宣言なら実体を
    /// 作り直さない**ことで釣り合わせている (`shadowMapHolding`)。
    var shadowDetailValue = ShadowMap.defaultDetail
    /// 縁の破綻を抑える量。**フレームを越えない** (同 決定 4)。
    ///
    /// 斜めに当たる面ほど、焼いた 1 画素の中で奥行きが大きく変わる。**自分の影が
    /// 自分の上に縞として出る**のを抑えるための余裕で、大きくしすぎると影が浮く。
    var shadowBiasValue = ShadowMap.defaultBias

    /// 揺らぎの種と細かさ。
    ///
    /// **描画の状態として持つ。** 断片からも同じ値が引けるよう、列を閉じた時点の値が列ごとの値
    /// (``Batch/noise``・[#1855]) を通って送られるためで、置き場が 2 つに割れると CPU と断片で別の模様が
    /// 出る ([#366])。
    ///
    /// **描き場所は作った面と同じ値を読み書きする** (``noiseStore``・[#1503])。`Canvas` に
    /// 置いたのは断片へ届けるためで、面ごとに分けるためではない — 種と細かさはスケッチに 1 つ。
    ///
    /// [#366]: https://github.com/mokume-metal/mokume/issues/366
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    var noiseSettings: ValueNoise {
        get { noiseStore.settings }
        set { noiseStore.settings = newValue }
    }
    /// 揺らぎの種と細かさの置き場。**描き場所は、作った面と同じ 1 つを指す**
    /// (``createGraphics(_:_:)``・[#1503])。
    ///
    /// 参照を共有するのは時刻の置き場 (``timebase``) と同じ理由である。作ったときに写すと
    /// 描き場所を作った後に決めた種が届かず、描き始めに写すと描き場所から作った描き場所が、
    /// 間の描き場所を描かなかったフレームで古い値を読む。共有すれば、本体で決めても
    /// 描き場所で決めても同じ 1 つを書き換え、後に書いたものが効く。
    ///
    /// 直に作った面 (``init(target:gpu:)``) は自分の置き場を持つ。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    var noiseStore = NoiseStore()

    /// 揺らぎの種と細かさ。**面どうしで共有するための参照型**で、値の意味は
    /// ``noiseSettings`` の説明が持つ。
    final class NoiseStore {
        var settings = ValueNoise()
        /// この置き場を読む面 (弱く持つ)。書き換える前に開いた列を閉じさせる相手で
        /// (``Canvas/changeNoise(_:)``)、作った面と描き場所が載る (``createGraphics(_:_:)``)。
        /// 直に作った面だけなら空のまま
        private(set) var readers: [WeakCanvas] = []

        func add(reader canvas: Canvas) {
            readers.removeAll { $0.canvas == nil }
            guard !readers.contains(where: { $0.canvas === canvas }) else { return }
            readers.append(WeakCanvas(canvas: canvas))
        }
    }

    /// 揺らぎの種と細かさを書き換える。**置いた図形は、置いた時点の種で引く** ([#1503])。
    ///
    /// 断片の種は列ごとに、列を閉じた時点の値が届き (``Batch/noise``)、CPU の `noise()` は呼んだ
    /// 時点の種を読む。置き場を共有する面はどれも同じ種を読むので、**書き換える前に、置き場を読む
    /// 面の開いた列を閉じる。** 閉じた列は書き換える前の設定を持ち歩くので、置いた図形の断片は、
    /// 同じ時点で引いた CPU の値と同じ種で引かれる (#366 の約束)。
    ///
    /// **描き切らない** ([#1855] の案 D)。以前は種を描き切り 1 回ぶんの値に詰めていたので、書き換える
    /// 前に置き場を読む面を描き切っていた。それがフレームの途中の区切りになり (影・計算・書いた値が
    /// 割れる・``loadPixels()`` の説明)、形の組み立ての途中では組み立てた区間を失わせていた (空の形)。
    /// 列を閉じるだけなら、絵は分けずに描いたときと変わらず、組み立ての区間も壊れない — 組み立ての
    /// 中で閉じた列は、そのまま形の区間になる。組み立ての出口が外の設定へ戻すときも同じで、組み立て
    /// より前に置いた図形は入口で閉じた列の設定 (外の設定) で引かれる。
    ///
    /// **閉じるのは揺らぎを読みうる列 (利用者の断片で塗る列) だけ** (``openRunReadsNoise``)。組み込みの
    /// 塗りと基本図形の列は揺らぎを引かないので、閉じると書き換えの数だけ列が割れ、畳み (#424) も
    /// 外れる。**閉じるのはフレームの中か外かを問わない。** 持ち越しの区間 (`setup()` など) で置いた
    /// 図形も、置いた時点の設定で次のフレームに描かれる。同じ値の書き直しでは閉じない (毎フレーム同じ
    /// 種を決め直す書き方で、描く回数を増やさない)。描き切っている最中の面は閉じない — 列を積んでいる
    /// 最中に並びを変えない。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    func changeNoise(_ change: (inout ValueNoise) -> Void) {
        var next = noiseSettings
        change(&next)
        guard next != noiseSettings else { return }
        var readers = [self]
        for entry in noiseStore.readers {
            if let reader = entry.canvas, reader !== self { readers.append(reader) }
        }
        for reader in readers where !reader.isFlushing && reader.openRunReadsNoise {
            reader.closeBatch()
        }
        noiseSettings = next
    }
    /// 焼き付け先。**同じ細かさなら作り直さない** (同 決定 4)。
    ///
    /// 読めるのは検査が焼いた奥行きを直に確かめるため ([#1474] — どちらの面を焼いたかは、
    /// 既定の縁の余裕の下では絵にほとんど出ない)。
    ///
    /// [#1474]: https://github.com/mokume-metal/mokume/issues/1474
    private(set) var shadowMap: ShadowMap?
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
    /// 影を実際に焼いた回数 (作ってから通算)。
    private(set) var shadowBakesEncoded = 0
    /// 前のフレームで焼いた面をそのまま読んだ回数 (作ってから通算)。
    ///
    /// **焼き直していないことを数える値。** 焼き直しても絵は同じなので、省略が
    /// 効いているかは絵では分からない。
    private(set) var shadowBakesReused = 0
    /// 溜めた計算。描く前に流し、フレームの終わりに空になる。
    var pendingComputations: [ComputeDispatch] = []
    /// この面が作った計算。観測へ失敗を載せるために持つ。**弱く持つ** (``Canvas/shaders``)。
    var computations: [Weak<Computation>] = []

    /// このフレームにかける効果の並び。**フレームを越えない** (ADR-0021 決定 4)。
    var pendingEffects: [Effect] = []
    /// このフレームで力を積んだ粒と、最初に積む前に積んであった力の数 ([#1622])。
    ///
    /// **閉じ忘れたフレームを描かずに捨てるとき、そのフレームで積んだ力だけを落とす**ために
    /// 持つ (``Particles/dropForces(after:)``)。力は粒の側に「次に進めるまで」積まれるので、
    /// 控えが無いと、捨てたフレームの力が次のフレームで効く。粒は弱く持つ。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    var forcesThisFrame: [(particles: Weak<Particles>, before: Int)] = []
    /// このフレームで頼んだ粒の進めのうち、まだ投入していないものと、その回の寿命を減らす量
    /// ([#1710])。
    ///
    /// **計算を投入したときに粒へ足し (``commitParticleAdvances()``)、投入せずにフレームを捨てた
    /// ら落とす。** 粒の上書きの注意は寿命を減らした量の累計で測る (``Particles/consumed``) ので、
    /// 走らなかった進めを数えると、累計が GPU の寿命の先へ行く。溜めた計算
    /// (``pendingComputations``) と同じ所で投入し、同じ所で落とす。粒は弱く持つ。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    var particleAdvancesThisFrame: [(particles: Weak<Particles>, amount: Double)] = []
    /// 効果のパイプライン。**頼まれてはじめて作る。**
    var effectPipelineStorage: EffectPipeline?
    /// 描く先に効果を通した絵があり、効果を通す前の絵が控え (``EffectPipeline/carry()``) に
    /// あるか ([#1469])。**立っていれば、次のフレームの最初の描き切りが控えから戻す**
    /// (塗り直すなら戻さない)。
    ///
    /// 立てるのも下ろすのも投入の後だけ ([#1183] と同じ作法)。組み立ての途中で投げた
    /// コマンドは捨てられるので、その前に書き換えると描く先の中身と食い違う。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    var carriesPictureBeforeEffects = false
    /// 描く先が、最後に拡大した後に変わったか ([#1882])。**細かさを下げた面の出す先は、描く先を
    /// 拡大の段が広げて書いた絵**で、拡大が積まれるのはフレームの終わりの描き切りだけである。
    /// 途中の描き切り (フレームの中でも、止まっている間でも) はその後に描く先だけを変えるので、立って
    /// いる間、出す先は変わる前の絵を映している。出す先を読む口と置く口が読む前に広げ直して下ろす
    /// (``catchUpOutput()``)。**立てるのは、描き切りが描く先を変えたとき**で、変えたかは描き切りの頭の
    /// 1 か所で数える (図形・絵・背景を描く・書いた画素を書き戻す・フレームの最初の描き切りで効果を通す
    /// 前の絵を戻す。``flush(applyingEffects:mirroringPixels:)``・[#2103])。
    ///
    /// 立てるのも下ろすのも投入の後だけ ([#1183] と同じ作法)。**下ろすのは、拡大が積めたときだけ**
    /// — フレームの終わりの拡大は失敗しても投げない (``applyUpscale(into:)``) ので、積めなかった
    /// フレームの終わりは立てる。**描く先へ戻していない画素の書き込みはここに入れない** — 写しの
    /// 書き込み待ちが同じことを表す (``needsOutputEnlargement``)。
    ///
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    var targetChangedSinceUpscale = false
    /// 置く口の追い付き (``catchUpOutputForPlacing(by:)``) を、この面が次に描き切るまで見送るか ([#2042])。
    ///
    /// **追い付けなかったら立てる** (拡大が投げた・置く側自身の写しを取れなかった)。立てないと、断片の
    /// 面を読む線や字では三角形ごとに追い付きをやり直し、そのたびに環を進めてコマンドを組み直す
    /// (注意は 1 度しか出ないので、遅くなる理由が見えない)。下ろすのは描く先が変わったとき
    /// (``flush(applyingEffects:mirroringPixels:)``) と、追い付けたとき (``catchUpOutput(writingBackPixels:)``)。
    /// 見送っている間に置いた先には古い絵が出て、コールバックを配った直後の追い付きと出す先を読む口は
    /// これまでどおりやり直す。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    var placingCatchUpDeferred = false
    /// 書き戻した画素のうち変わった画素を、効果を通す前の絵へ写した回数 (作ってから通算・[#1524])。
    /// **止まっている間に画素を書かなかったフレームでは増えない**ことを検査が見る。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    var effectChangesKeptEncoded = 0
    /// 止まっている間に描き切った図形・絵・背景を、効果を通す前の絵へも描いた回数 (作ってから
    /// 通算・[#1524])。**止まっている間に描き切らなかったフレームでは増えない**ことを検査が見る。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    var effectCarryDrawsEncoded = 0
    /// 描く先へのパスが、奥行きを読み込んだ (`.load`) 回数と書き出した (`.store`) 回数 (作ってから
    /// 通算・[#1888])。**奥行きを引き継がない描き切りは、どちらも増やさない**ことを検査が数える
    /// (走るフレームと、止まっている間に描き切らせないスケッチの費用は、直す前と変わらない)。
    ///
    /// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
    var depthLoadsEncoded = 0
    var depthStoresEncoded = 0
    /// 描き終えた絵を控えへ写した回数 (作ってから通算)。**効果を頼まないフレームでは
    /// 増えない**ことを検査が見る。積む 1 行と同じ場所で数える。
    var effectCarriesEncoded = 0
    /// 控えから描く先へ戻した回数 (作ってから通算)。戻すのは効果を通したフレームの次の
    /// 1 回だけで、塗り直すフレームでは戻さない。**戻しても絵は同じなので、戻しすぎは
    /// 絵では分からない** — 数で見る。
    var effectCarryRestoresEncoded = 0
    /// 積んだ待つ仕掛けの数。**積む 1 行と同じ場所で数える。**
    var effectBarriersEncoded = 0
    /// 検査から「途中で失敗した段」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 段の失敗は資源が枯れたときにしか起きず、検査から自然には作れない。一方で
    /// **途中で失敗したときに何が出るか**は、この Issue の完了条件そのものなので、
    /// ここに 1 つだけ穴を空けてある (`failureForTesting` と同じ形)。公開はしない。
    ///
    /// **穴は本物の失敗が起きる位置 (番地表を引く直前) に空ける。** 前へずらすと、
    /// 口を開いた後に投げる経路を検査が踏まなくなる ([#1184] はそこで見逃した)。
    ///
    /// [#1184]: https://github.com/mokume-metal/mokume/issues/1184
    var failEffectPassForTesting: Int?
    /// 通した段の数。
    var effectPassesEncoded = 0
    /// このフレームで使った段の枠の数。**効果と拡大が同じ採番から取る。**
    ///
    /// 引数のテーブルは枠ごとに別のものでなければならない — 1 枚を使い回して番地を
    /// 書き換えると、まだ走っていない枠の束ね先まで変わる (#391 で実際に踏んだ)。
    /// 採番を 2 系統に分けると、効果と拡大が同じ番号を取り合う。
    var stagePassesUsed = 0

    /// 粒の置き場所を誰が埋めるか。**製品では GPU 側 (速い経路)。**
    ///
    /// 公開しない — 利用者が選ぶものではなく、速い経路を照らす物差しを検査から
    /// 差し替えるための口である。
    var particleRoute: ParticleRoute = .instanced
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
    /// 面をまたぐ順のための早い投入 (``submitPendingComputations()``) を試した回数 (作ってから
    /// 通算)。**失敗したフレームの間は増えない**ことを検査が数で見る (#1870)。
    var earlySubmissionsAttempted = 0
    /// 早い投入に失敗したときの ``framesDrawn``。同じ番号のうちは、同じ試みを繰り返さない
    /// (環の待ちは最長 5 秒。頼むたびに試すと、頼んだ数だけ止まる)。番号どうしで比べるので、
    /// フレームの境目で戻す手は要らない — 閉じ忘れを捨てる道も番号を進める。
    var earlySubmissionFailedFrame: Int?
    /// 早い投入を失敗させる差し込み (検査用)。製品の経路では `nil`。環の待ちが期限切れになる
    /// のは GPU が 5 秒返らないときだけなので、検査から自然には作れない。
    var failEarlySubmissionForTesting: RenderFailure?
    /// 計算のあとに次の段が待つ仕掛けを積んだ回数 (作ってから通算)。
    ///
    /// 影の側 (``shadowBarriersEncoded``) と同じ理由で持つ — 抜けていても絵は普段どおり
    /// 出て、GPU が混んだときだけ稀に書き終わる前の並びが読まれる。積む 1 行と同じ場所で
    /// 数え、**その行を消したら数も減る**。
    var computeBarriersEncoded = 0
    /// 最後に積んだ「投入の最後の口」の仕掛けが待たせる、後の段 (検査が読む)。
    ///
    /// **段の抜けは絵にも数にも出ない** — 抜けていても普段は間に合い、GPU が混んだときだけ稀に
    /// 書き終わる前の並びが読まれる。だから積んだ段そのものを控える (#1687)。
    var lastComputeBarrierQueueStages: MTLStages = []
    /// 控えを届けるコピーのあとに、続く段が待つ仕掛けを積んだ回数 (作ってから通算)。
    /// 計算の側と同じ理由で持つ。
    var uploadBarriersEncoded = 0
    /// 1 品で控えの置き場へ写してよいバイト数の上限。**超えたものは待って直接書く。**
    ///
    /// 控えの置き場は環のスロットの数だけ同じ大きさで取り直すので、巨大な画像を毎フレーム
    /// 送ると、今まで送れていた絵が置き場を取れずに描き切りごと落ちる。そういう品にだけ
    /// 今までの形 (待ってから書く) を残す。検査が差し替える。
    var uploadByteLimit = 64 << 20
    /// 影の行列を置く領域。
    private let shadowMatrixStorage: GrowableBuffer
    /// 焼いていないフレームに影の口へ束ねる 1 画素の奥行きの面。
    private var unbakedShadowTexture: (any MTLTexture)?

    /// いま効いている視点。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// `nil` の間は面に合わせた既定を使う。既定を実体で持たないのは、面の大きさが
    /// 変わったときに古い既定が残らないようにするため。
    var cameraStorage: Camera?

    /// いまフレームの中か (``draw(_:)`` の閉包の中か、``beginDraw()``〜``endDraw()`` の間)。
    ///
    /// シーンの記述 (光・視点) は、フレームの外で書かれてもどのフレームにも属さない。
    /// 黙って捨てず警告するために、内と外を知る必要がある ([ADR-0021] 決定 4)。
    ///
    /// **置いたもの (図形・絵・背景・画素) はここだけを見ない** — フレームの外でも、持ち越しを
    /// 約束する区間 (``carriesOver``) と形の組み立ての中では置ける (``canPlace``)。`setup()` だけで
    /// 1 枚を描く書き方は、区間の中なので最初のフレームに出る ([ADR-0021] 決定 4 の追補
    /// (2026-09-27))。
    private(set) var isDrawing = false

    /// いまのフレームを ``beginDraw()`` が開いたなら、そのフレームが**属する本体のフレームの番号**
    /// (``Timebase/frameForOpening``)。``draw(_:)`` が開いたフレームとフレームの外では `nil`。
    ///
    /// **閉じ忘れうるのは `beginDraw()` が開いたフレームだけ** — ``draw(_:)`` が開いたフレームは、
    /// 閉包を抜けるときに同じ呼び出しが閉じる。本体のフレームが始まる所が閉じ忘れを捨てる相手を
    /// 選ぶのも、この印である (``dropFrameLeftOpen(before:)``・[#1834])。番号を持つのは、描き場所が
    /// 閉じ忘れたまま**本体のフレームの境目を越えたか**を見分けるためである ([#1622])。同じ本体の
    /// フレームの中で `beginDraw()` を重ねただけなら、境目は越えていない (``leftOpenAcrossBoundary``)。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private(set) var beginDrawFrame: Int?

    /// 変換とスタイルが意味を持つ文脈にいるか。**フレームの中と、形を組み立てている間。**
    ///
    /// 組み立て (``createShape(_:)``) の中は、形自身の座標で記録する文脈である — そこで
    /// 書いた変換とスタイルの積み降ろしは**形に焼き付く**ので、どのフレームにも属さない
    /// まま意味を持つ ([ADR-0021] 決定 4 の 2026-09-15 の改訂・[#1172])。`setup()` で
    /// 組み立てると中の `push()` / `translate()` が落ち、9 枚の葉が 1 か所へ重なっていた。
    ///
    /// **シーンの記述 (視点・光・囲み・影・材質・粒・計算) はここを見ない。** あちらは
    /// 形に焼き付かずフレームに属するので、記録の間はフレームの中でも外でも断る
    /// (``admits(_:)``・[#1529])。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    var isShaping: Bool { isDrawing || recordingShape }

    /// 持ち越しを約束する区間にいるか ([ADR-0021] 決定 4 の追補 (2026-09-27)・[#1672])。
    ///
    /// **置いたもの (図形・絵・背景・画素の書き込み) をフレームの外に置いてよいのは、次の
    /// フレームを約束する主体が約束した区間だけである。** 本体では約束するのがランタイムで、
    /// 区間は `setup()` と止まっている間のコールバックである。立てるのは ``SketchRuntime`` だけで、
    /// 自分の面にだけ、その 2 つの呼び出しの間だけ立て、抜けるときに必ず下ろす。描き場所
    /// (`createGraphics`) では約束するのが作者で、区間は ``beginDraw()``〜``endDraw()`` そのもの
    /// なので、ここは立たない。
    ///
    /// 下ろすときに、区間の中で置いた量を覚える (``carriedOverAmount``)。フレームの頭の検め
    /// (``beginFrame()``) が、区間の外で置いたものと見分けるのに読む。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    ///
    /// **入るときに、時刻の置き場の描き場所のうち、前のフレームに属したまま閉じ忘れたフレームを
    /// 捨てる** ([#1834])。区間は次に描くフレームに属するので、そのフレームが始まる所として本体の
    /// 頭と同じ規則で捨てる (止まっている間は、頭が来ない)。区間の中で開いたものは次に描くフレームに
    /// 属するので捨てない (``dropFrameLeftOpen(before:)``)。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    var carriesOver = false {
        didSet {
            if !oldValue, carriesOver, !isDrawing, timebase.owner === self {
                let next = timebase.frame + 1
                for entry in timebase.layers { entry.canvas?.dropFrameLeftOpen(before: next) }
            }
            guard oldValue, !carriesOver else { return }
            let amount = pendingAmount
            if amount > 0 { carriedOverAmount = amount }
        }
    }

    /// 持ち越しの区間を出たときに、溜め場に残っていた量 (``pendingAmount``)。区間で何も置いて
    /// いなければ `nil`。**フレームの頭の検めの印** (``beginFrame()``)。
    ///
    /// 区間を出るとき (``carriesOver`` を下ろすとき) に書き、フレームの頭が読んで下ろす。
    /// **有無ではなく量を覚える** — 区間で置いた後に、区間の外で守りの無い口から積み足すと、
    /// 有無の印ではその積み足しを持ち越しと取り違える。溜め場は置けば増え、捨てれば空に戻る
    /// だけなので、頭で覚えた量より増えていれば区間の外で置いたものである。
    ///
    /// 口ごとに立てる形は取らない — 口を 1 つ書き落とした日に、そこだけ印が漏れる
    /// (``hasPendingDrawing`` と同じ理由)。
    var carriedOverAmount: Int?

    /// 書いたものが、この面の次の描き切りに載る区間にいるか。**フレームの中と、持ち越しの区間。**
    ///
    /// 画素の書き込みと、描き場所を置いた記録 (``note(placing:)``) はここを見る。形の組み立て
    /// (``createShape(_:)``) の中は入らない — 組み立ての中で置いた図形は形へ抜かれて溜め場に
    /// 残らないが、画素は形に載らず面へ直に書かれ、置いた記録も守る絵が無いまま残るからである。
    ///
    /// **描き場所で、閉じ忘れたまま本体のフレームの境目を越えたフレームは、ここに来ない** — 本体の
    /// 次のフレームの頭が描かずに捨て、描き場所はフレームの外に居る ([#1622]・[#1834])。以前は
    /// 越えたフレームを番号で見分けてここで断っていたが、読む口・他の面からの描き切り・数の並びの
    /// 読みは見ていなかった。越えた状態を作らないので、口ごとに見分ける印は要らない。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    var writesToSurface: Bool { isDrawing || carriesOver }

    /// 置いてよいか。**フレームの中・形を組み立てている間・持ち越しの区間** ([#1672])。
    ///
    /// ``isShaping`` と同じ形で、持ち越しの区間 (``carriesOver``) を足したもの。図形が溜め場に
    /// 入る口はどれも、副作用より前にこれを見て、外なら ``OutsideFrame/placing`` を 1 度言って
    /// 何もしない。区間の外で置いたものは、描き場所では次の描き切りが来ないので永遠に溜まり
    /// ([#1592])、直に使う `Canvas` ではいつの絵に出るかを呼び手が知らない。
    ///
    /// **守りの漏れはフレームの頭が拾う。** 口を 1 つ書き落としても、そこで置いたものは区間の
    /// 印を持たないまま溜め場に残り、次のフレームの頭で debug 組みが止まる (``beginFrame()``)。
    ///
    /// [#1592]: https://github.com/mokume-metal/mokume/issues/1592
    var canPlace: Bool { writesToSurface || recordingShape }

    /// いま描き切っている最中か。**入れ子の描き場所で戻ってくるのを止める。**
    private var isFlushing = false

    /// このフレームで描き切った回数。**フレームの最初の描き切りかの判定に使う** (効果を通す前の絵を
    /// 戻すのはそこ)。奥行きを引き継ぐかは数えず、``depthIsHeld`` が持つ。
    private(set) var passesThisFrame = 0

    /// 奥行きの面が、前の描き切りが書き出した奥行きを持っているか ([#1888])。**引き継ぐ奥行きが
    /// あるときだけ立つ** — 次の描き切りは、立っていれば読み込み、立っていなければ消して始める。
    ///
    /// 立てるのは、奥行きを残す描き切り (フレームの最後でない・``flush(applyingEffects:mirroringPixels:)``
    /// の `applyingEffects` が偽) が何かを描いたとき。**フレームの最後の描き切りは奥行きを捨てる**ので、
    /// 立てない。以前は「このフレームで描き切ったか」(``passesThisFrame``) で決めていたので、
    /// - 止まっている間の最初の描き切りは、前のフレームの最後のパスが捨てた奥行きを読み込み、
    /// - 止まっている間や `setup()` で描き切らせた立体の奥行きは、次のフレームの最初のパスが消して
    ///   始める (フレームの頭で数が 0 に戻る) ので失われた。
    ///
    /// **フレームの頭では触らない** — 区間で描き切った奥行きを、次のフレームの最初のパスが受け取る。
    /// 下ろすのはフレームの終わりと、閉じ忘れたフレームを捨てるとき (``abandonFrame()``)。フレームの
    /// 終わりは描き切りが投げても引き継ぎを切る — 次のフレームの奥行きは、成功したフレームの後と
    /// 同じくフレームごとに作り直す。
    ///
    /// 周囲の背景 (`background(.sky)`) は引き継いだ奥行きを手放さない。置き換える列は奥行きを
    /// 比べずに書く (``Batch/replacesSurface``・[#1685]) ので、引き継いだ奥行きに板が落ちない。
    ///
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    /// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
    private var depthIsHeld = false

    /// 描き切りの印。**溜めた計算と列を投入するか捨てると、必ず変わる** ([#1651])。
    ///
    /// 溜めた列を投入して空にするのは ``discardFrame()`` で、呼ばれるのは描き切れたとき (描き切った
    /// 回数が進む) と、フレームを閉じるか捨てるとき (``framesDrawn`` が進む) である。塗り直し
    /// (`background()`) も溜めた列を捨てるが、印は変えない。粒はその組をまだ読まれていないと
    /// 見なして 1 組を余分に足すだけで、絵は変わらない。
    /// ``framesDrawn`` は戻らず、描き切った回数が 0 へ戻るのは ``framesDrawn`` が進んだ後の
    /// フレームの頭だけなので、同じ印は 2 度現れない。読み戻し (``read(_:)``) は計算だけを流して列を残すので、印を変えない。
    /// 粒が、呼び出しごとの置き場の組を使い回してよいかを見るのに読む。
    ///
    /// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
    var settleMark: SettleMark { SettleMark(frame: framesDrawn, pass: passesThisFrame) }

    /// ``settleMark`` の値。
    struct SettleMark: Equatable {
        let frame: Int
        let pass: Int
    }

    /// 置いた描き場所のうち、まだ描き切っていないもの。
    ///
    /// **置いた時点の絵を守るために覚えている。** 溜めてから描くので、置いたあとに
    /// その描き場所が描き換わると、先に置いた場所まで最新の絵に化ける。
    ///
    /// 記録するのは**置くたび** — 画像として置いたときと、貼った塗りや保持した形がその
    /// 面を読むように切り替えたとき (``useTexture(_:)``)、断片の面として読む図形を積んだ
    /// とき (``notePaintPlacement()``・[#1653]) である。落とすのは描き切り (フレームの終わり)・
    /// 描き場所が描き換わる直前 (置いた時点の絵の写しへ差し替えたとき・[#1656]) と塗り直し
    /// (``discardPending()``) で、落とした後に同じ面のまま置いた形も、置いた時点で記録し直される
    /// ([#1543])。
    ///
    /// [#1543]: https://github.com/mokume-metal/mokume/issues/1543
    /// [#1653]: https://github.com/mokume-metal/mokume/issues/1653
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    private(set) var placedGraphics: Set<ObjectIdentifier> = []

    /// 自分を置いた面。**自分の絵が変わる前に、そちらへ置いた時点の絵を写させる**
    /// (``settlePlacersBeforeChange()``)。
    ///
    /// 弱く持つ — 描き場所は利用者が持つもので、置いた側が寿命を延ばす筋合いが無い。
    private(set) var placers: [WeakCanvas] = []

    /// 置いた描き場所の絵の写しのうち、溜めた列がいま読んでいるもの ([#1656])。
    ///
    /// 写しは置いた側が持つ。**描き切りか捨てるまで使い回さない** — 溜めた列が読む前に、同じ
    /// 写しへ別の時点の絵を写すことになる。描き切りの末尾 (``discardFrame()``) で空き
    /// (``placedPictureCopiesFree``) へ戻す。空きから使い回す写しへ書くコマンドは、前にそれを
    /// 読んだ描き切りより後に投入され、**写す前に待ち合わせを置いて**前の読みが終わるのを待つ
    /// (``copyPlacedPicture(_:)``。この世代は encoder をまたぐ依存を自動では張らない・#341)。
    ///
    /// **写しの数には上限がある** (``placedPictureCopyLimit``)。空きと使用中を合わせて上限に
    /// 達し、使い回せる空きも無ければ、写さずに置いた側を描き切らせる (区切りになる)。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    private var placedPictureCopiesInUse: [PlacedPictureCopy] = []
    /// 置いた側 1 つが持つ写しの上限 (使用中と空きの合計)。1 フレームに「置く → 描き換える」を
    /// 上限より多く繰り返した分は、写さずに置いた側を描き切らせる。描き場所 1 枚ぶんの rgba16Float
    /// (1920×1080 で約 16.6MB) を、繰り返す回数だけ抱え続けないための線である。
    static let placedPictureCopyLimit = 4

    /// 使い回せる写し。**最後のフレームの境目までの 1 フレームに使わなかったものは手放す**
    /// (``leaveFrame()``)。描き場所を置かなくなった後まで、その大きさの写しを抱え続けない。
    private var placedPictureCopiesFree: [PlacedPictureCopy] = []
    /// 写しを作った回数 (作ってから通算)。**同じ大きさなら作り直していないことを検査が見る。**
    private(set) var placedPictureCopiesMade = 0
    /// 置いた時点の絵を写した回数 (作ってから通算)。**置いた側を描き切らせる代わりに写したこと
    /// を検査が見る。**
    private(set) var placedPicturesCopied = 0
    /// 写しの上限に達して、置いた側を描き切らせた回数 (作ってから通算)。**検査が読む。**
    private(set) var placedPictureCopyLimitReached = 0

    /// 弱く持つ面ひとつぶん。
    struct WeakCanvas {
        weak var canvas: Canvas?
    }

    /// このフレームで塗り直す色。`nil` なら前の内容の上に描き足す。
    private var pendingBackground: LinearRGBA?

    // MARK: - 初回だけ言う注意

    /// 言った注意の控え。**種類ごとの旗を持たない** ([#734])。
    ///
    /// 書き換えるのは ``warnOnce(_:_:)`` だけで、外からは読むことしかできない —
    /// 「言った」を直に立てられると、注意を出さずに黙らせる道ができてしまう。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    private(set) var warnings = WarningLog<Warning>()

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    ///
    /// 文面はここに書く — 鍵に持たせると、値を差し込む文面 (寸法・書体の名前) が
    /// 鍵の一部になり、値が違うだけで**同じ注意を何度も言う**ようになる。
    func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    // MARK: - 描く状態

    /// これから描くものに効く設定の一式。**フィールドの並びは ``Style`` の宣言にしか無い。**
    ///
    /// 丸ごと戻すときは ``currentStyle`` を通す — 列を閉じる条件はそこにある。
    var style = Style()
    var transform = Transform.identity
    private var transformStack: [Transform] = []
    private var styleStack: [Style] = []

    /// 積んだ履歴を取り出して空にする。**戻すのは ``restore(_:)``。**
    ///
    /// 形の組み立てが、記録の間だけ積み降ろしを切り離すために使う ([#1172]) — 記録の中の
    /// `pop()` が記録より前に積んだ段を取らず、記録の中で積んだまま抜けた段が、あとの
    /// `pop()` に拾われないようにする。**2 本まとめて出し入れする**のは、積んだ事実が
    /// 変換とスタイルのどちらに属するかによらないためである ([ADR-0021] 決定 4 の追補)。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
    func takeStacks() -> (transforms: [Transform], styles: [Style]) {
        let taken = (transforms: transformStack, styles: styleStack)
        transformStack.removeAll(keepingCapacity: true)
        styleStack.removeAll(keepingCapacity: true)
        return taken
    }

    /// 取り出しておいた積み履歴へ戻す。
    func restore(_ stacks: (transforms: [Transform], styles: [Style])) {
        transformStack = stacks.transforms
        styleStack = stacks.styles
    }
    /// このフレームで画素を読める状態にしたか。フレームごとに戻る。
    var hasLoadedPixels = false
    /// 直前の、画素を読む前の描き切りが失敗したか。次に描き切れたときに戻る。
    ///
    /// **読む口に描き切りをやり直させないための印** ([#1368])。失敗した描き切りは溜めたものを
    /// フレームの終わりへ残すので、溜めたか (``hasPendingDrawing``) だけを見ていると読むたびに
    /// やり直す — GPU が詰まっていれば、1 画素読むごとに待ちの上限まで待つ。同じフレームで
    /// やり直すのは ``loadPixels()`` を呼んだときだけにする。
    ///
    /// **フレームの頭では戻さない。** フレームで最初の読み取りは印を見ずに必ず描き切り
    /// (``hasLoadedPixels``)、描き切れればそこで戻るので、戻す場所を 2 つ持つ理由が無い。
    ///
    /// [#1368]: https://github.com/mokume-metal/mokume/issues/1368
    var pixelLoadFailed = false

    // MARK: 文字

    /// 字形を焼いて溜める面。**図形もここの白い区画を読む** (``GlyphAtlas``)。
    let atlas: GlyphAtlas
    /// 焼き場のいまの頁を作ったフレーム (``framesDrawn`` の値)。まだ替えていなければ `nil`。
    ///
    /// **上限の頁を 1 フレームに 2 枚作らないために持つ** ([#1342])。このフレームで作った
    /// 頁が埋まったなら、このフレームで要る字だけで上限の面が溢れている — 焼き直しても
    /// 同じフレームのうちにまた埋まるので、替え続けると 128 MiB の頁が際限なく並ぶ。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    var atlasPageFrame: Int?
    /// 字形を四角として置くか。**台帳の指紋を採るときだけ下ろす** ([#1559])。
    ///
    /// 字形を画素にするのは OS (CoreGraphics) で、書体の輪郭と送り幅が同じでも、焼いた画素は
    /// OS の版で 1〜3 階調ずれる。文字が主題でない台帳の行にそれを写し込むと、絵が 1 画素も
    /// 変わっていないのに OS の更新で行が動く ([ADR-0019] 決定 3 の改訂 (2026-09-25))。
    ///
    /// **下ろしても組版は変わらない。** 字を引き、送り幅を進めたうえで、置く手前で止める
    /// だけである。作者に見せる口ではないので公開しない。描き場所へは引き継ぐ
    /// (``createGraphics(_:_:)``) — 描き場所に書いた字も、同じ行の絵に載るからである。
    ///
    /// [#1559]: https://github.com/mokume-metal/mokume/issues/1559
    /// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
    var placesGlyphs = true
    /// 置いた字形の四角の数。旗 (``placesGlyphs``) が効いていることを、検査が数で確かめる。
    var glyphQuadsPlaced = 0
    /// いま列が読んでいる面。面を広げる・画像を描くと差し替わる。
    ///
    /// **持ち主と組で持つ** (``HeldTexture``)。閉じた列はこれを写し取るので、ここで持ち主を
    /// 落とすと、列が読む前に面が常駐から外れうる。フレームの終わりに焼き場へ戻す
    /// (``discardFrame()``) — 戻さないと、最後に置いた絵の持ち主を次に面を替えるまで生かす。
    var currentTexture: HeldTexture
    /// 丸い継ぎ目と端の円板の、周のずれの控え。**直前の太さと分割数の 1 件だけ** (#1785・
    /// `appendDisc(at:half:segments:)`)。分割数は画面に出る半径で決まる (#1645)。
    var discOffsets: (half: Float, segments: Int, offsets: [SIMD2<Float>])?
    /// 周の分割数と、円板の分割数の、直前の問い合わせ (``SplitQuery``)。
    var ringSplitMemo = SplitQuery()
    var discSplitMemo = SplitQuery()
    /// いま効いている塗り。`nil` なら組み込み。
    var currentShader: Shader? {
        // 当てた断片が替われば、その面を置いた記録は取り直す (``paintSurfacesNoted``)
        didSet { paintSurfacesNoted = nil }
    }
    /// いまの断片 (``currentShader``) の描き場所の面を、置いた記録に載せ終えたか。載せた時点の
    /// ``placedGraphicsDrops`` を持つ。`nil` なら載せていない。
    ///
    /// **図形を積むたびに記録し直さないための控え** (#1683 の反証 2 回目)。断片の面の記録は
    /// 図形を積む口 (線なら三角形ごと) で取るので、毎回記録すると、描き場所を読む断片で置く
    /// 費用が読まない断片の 4 倍になった (release・線 2 万本)。記録が落ちた (値が今の
    /// ``placedGraphicsDrops`` と違う)・断片が替わった・断片の面が差し替わったときに取り直す。
    /// 読む描き場所が描き始めたときも取り直す (その描き場所が ``placers`` から落とす)。
    var paintSurfacesNoted: Int?
    /// 置いた記録 (``placedGraphics``) から記録を落とした回数。``paintSurfacesNoted`` の鮮度を見る。
    private(set) var placedGraphicsDrops = 0
    /// いま塗りが読む数の並び。`nil` なら読まない。
    ///
    /// **断片 (``currentShader``) と同じくフレームを越える** ([#1470])。並びは断片と一組の
    /// 塗り (`Shape.Paint`) で、中身は `Numbers.set` で差し替える作りなので、1 度渡して
    /// 中身だけを書き換える書き方が自然に生まれる。フレームの頭で外すと、その書き方だけが
    /// 2 枚目から黙って 0 を読む。外すのは ``resetNumbers()`` の 1 つだけ。
    ///
    /// [#1470]: https://github.com/mokume-metal/mokume/issues/1470
    var currentNumbers: Numbers?
    /// 保持した形を置いている間だけ効く、**記録した塗り**。`nil` なら生きている状態を使う。
    ///
    /// 置く時点の ``currentShader`` で塗ると、組み立てるコードを読んでも何色になるかが
    /// 分からない形になる — ``createShape(_:)`` が `fill` / `stroke` について約束して
    /// いることを、断片についても守るための控えである ([#788])。
    ///
    /// [#788]: https://github.com/mokume-metal/mokume/issues/788
    var replayedPaint: Shape.Paint?
    /// 渡されていないときに読ませる並び。**1 個の 0。**
    ///
    /// 何も束ねない口を作らないために置く — 束ねずに走らせると、断片が読んだ瞬間に
    /// 絵の乱れではなく異常終了になる。
    private var emptyNumbers: Numbers
    /// この面が作った塗り。観測へ失敗を載せるために持つ。
    ///
    /// **弱く持つ** ([#738])。強く持つと、利用者が手放した断片まで面と同じだけ生き、
    /// GPU 側の置き場ごと解放されない。手放された断片はもう描かれないので、その失敗を
    /// 観測へ載せる理由も無い。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    var shaders: [Weak<Shader>] = []
    /// この面が作った効果。観測へ失敗を載せるために持つ。**弱く持つ** (``Canvas/shaders``)。
    ///
    /// 控えを置く理由は失敗を読むことにしかない ([#787])。読み手を持たないまま積むと、
    /// 差し替えに失敗した効果が黙って前の絵を出し続ける — それが実際に起きていたので、
    /// 一度は控えごと畳まれた ([#738])。
    ///
    /// [#787]: https://github.com/mokume-metal/mokume/issues/787
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    var effectShaders: [Weak<EffectShader>] = []
    /// 図形が指す、白い区画の中の点。面を広げるたびに取り直す。
    var whiteUV: SIMD2<Float>
    /// 引き当てた書体の控え。同じ指定で作り直さないために持つ。
    ///
    /// **件数で切る** (``typefaceCacheLimit``)。鍵に大きさ (連続値) が入るので、
    /// `textSize` を毎フレーム変える書き方 (脈打つ字) では、フレームごとに鍵が 1 つ増える
    /// ([#1431]・[ADR-0023] 決定 5)。量で切らないのは、書体 1 つの重さが引いた字の種類で
    /// 決まり、`CTFont` の中身は量れないためである。
    ///
    /// **追い出しても、焼いた字形は残る。** 焼き場の頁の鍵 (``GlyphAtlas``) は書体の
    /// 識別名・大きさ・太さと傾き・字形の番号でできた値で、この控えの書体を指していない。
    /// 同じ指定で作り直すと字の引き当てはやり直すが、頁には当たるので焼き直しは起きない。
    /// 使っている最中の書体は、使う側が関数の中で持っているので消えない。
    ///
    /// **上限を超える数の大きさを 1 フレームで使うと、毎フレーム外れる** (ワードクラウドの
    /// ように 64 通りより多くの大きさを並べる書き方)。そのときは毎フレーム書体を作り直し、
    /// 字の引き当てもやり直す。上限が無かった頃は 2 フレーム目から全部当たっていたが、
    /// 代わりに大きさを動かし続ける書き方で際限なく増えていた。費用は `textSize` の説明に書いた。
    ///
    /// [#1431]: https://github.com/mokume-metal/mokume/issues/1431
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var typefaces = BoundedCache<TypefaceRequest, Typeface>(
        budget: Canvas.typefaceCacheLimit, weight: { _ in 1 })
    /// 書体の控えに置いておく件数。1 つの重さは引いた字の種類で決まる (漢字 12 字で約 15 KB・#1431)。
    static let typefaceCacheLimit = 64
    /// 貼る絵を束ねずに読み取り位置を書いた塗りが読む、1×1 の白い絵。
    /// **最初に要ったときに 1 度だけ作る** (``useWrittenUVTexture()``)。
    private var blankPicture: Picture?

    // MARK: - 組み立て中の形

    /// 並べている途中の頂点。``beginShape(_:)`` から ``endShape(_:)`` までの間だけ中身を持つ。
    ///
    /// **平面と立体で同じものを溜める** ([ADR-0021] 決定 5)。奥行き・面の向き・頂点ごとの
    /// 色は「頂点の性質」であって、形の種類ごとの対応表ではない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shapePoints: [BuildingVertex] = []
    /// 並べている途中の「読む順」。空なら、置いた順にそのまま読む。
    ///
    /// 指せるのは ``shapePoints`` の番号だけで、穴の点は指せない (``index(_:)``)。
    var shapeIndices: [Int] = []
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
    ///
    /// **並びは `curveVertex` を続けて呼んでいる間だけ続く。** `curveVertex` 以外で点を置く
    /// 呼び出し (`vertex` / `bezierVertex` / `quadraticVertex`) と、穴の境目 (``beginContour()`` /
    /// ``endContour()``) で空に戻す — 穴の中の曲線は外周の点を並びに含まず、外周と独立に
    /// 始まる ([#1449])。
    ///
    /// [#1449]: https://github.com/mokume-metal/mokume/issues/1449
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
        var clip: ClipRect?
        /// この列を描画先の座標へ落とす行列。**揺らす前のもの**で、時間方向の揺らしは描き切りが
        /// 列ごとの値を置くときに足す (``Canvas/jittered(_:drawingInFrame:)``・[#1913])。
        ///
        /// [#1913]: https://github.com/mokume-metal/mokume/issues/1913
        var matrix: simd_float4x4
        /// この列に効く光が、置き場のどこから何個あるか。
        var lightRange: Range<Int>
        /// この列を描く材質。**閉じた時点のもの**が入る (光と同じ理由)。
        var material: Material
        /// この列を見ている場所。艶が見る向きで変わるので、材質と対で持ち歩く。
        var viewer: SIMD4<Float>
        /// この列を見ている視点の、世界をカメラの側へ移す行列。断片が面の向きを
        /// 視点から見た向きへ移すのに使う (`viewer` と同じく**閉じた時点のもの**)。
        var view: simd_float4x4
        /// この列に効く周囲。**閉じた時点のもの**が入る (光と同じ理由)。
        var surroundings: PackedSurroundings
        /// この列の断片が引く揺らぎの種と細かさ。**閉じた時点のもの**が入る (光と同じ理由・[#1855])。
        ///
        /// 書き換え (``Canvas/changeNoise(_:)``) は面を描き切らず、置き場を共有する面の開いた列を
        /// 閉じてから書き換える。だから置いた図形は置いた時点の設定で引かれ (#1503 の約束)、描き切りに
        /// 1 つの値を詰めていた頃の「書き換えのたびの区切り」が要らない。
        ///
        /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        var noise: ValueNoise
        /// この列が影を落とす側か。焼き付けるときに、この旗で選り分ける。
        var castsShadow: Bool
        /// この列の置き場所が、置き場のどこから何個あるか。
        ///
        /// 畳めない列は**何も動かさない置き場所を 1 つ**指す (平面なら添字 0)。
        var instanceStart: Int = 0
        var instanceCount: Int = 1
        /// 基本図形の列が持つもの (塗り・輪郭・1 画素より細い塗り)。**基本図形の列だけが使う。**
        ///
        /// 断片は有無で特化してあるので、この組がパイプラインを選ぶ ([#771]・[#1477])。
        ///
        /// [#771]: https://github.com/mokume-metal/mokume/issues/771
        /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
        var formFlags: UInt32 = 0
        /// 置き場所をどこから読むか。`nil` なら溜め場を写した置き場。**持ち主ごと持つ**
        /// (``ExternalInstances`` と同じ理由)。
        var instances: Numbers?
        /// 描く個数を GPU が書いた引数。`nil` なら `instanceCount` で描く (いつもの経路)。
        ///
        /// 粒だけがここを使う — 生きている粒の数は CPU が知らないので、数えた GPU が
        /// 書いた引数をそのまま indirect draw に渡す。**引数の `vertexStart` はいつも 0** で、
        /// 頂点の頭は束ねる番地が指す (``vertexBaseShift``)。
        var indirectArguments: Numbers?
        /// 輪郭の頂点が始まる位置 (並び全体での番号)。**平面だけが使う。**
        ///
        /// 頂点関数はここより手前に塗りの色を、ここから後ろに輪郭の色を掛ける。
        /// 畳んでいない列は塗りしか無い扱いでよい — 置き場所の 2 色がどちらも白で、
        /// どちらを掛けても値が変わらないためである。
        var strokeStart: Int = .max
        /// この列に、細い線を広げた (被覆が 1 未満の) 頂点があるか (#1637)。置き換える列は、
        /// これが立つと下地を読む断片で描く (``ShapePipeline/BlendStates/drawing(_:)``)。
        var thinCoverage = false
        /// 裏を向いた面をどう扱うか。
        ///
        /// 既定は両面を描く (`.none`)。**閉じた組み込みの形の、不透明な列だけ**が裏面を
        /// 捨てる (`.back`) — 閉じた形では表の面が必ず裏の面を隠すので、捨てても絵は
        /// 変わらず、断片の仕事 (影の読み取りを含む) が裏面のぶんだけ減る
        /// ([#756](https://github.com/mokume-metal/mokume/issues/756))。動きうるのは輪郭の
        /// 縁で表と裏が同じ奥行きを争っていた画素だけで、それは表の色に確定する
        /// (台帳の `shadows` で 1 画素・2 階調が動いた実測が #756 の PR にある)。影の焼き付けも
        /// 同じ捨て方で焼き、焼き付く奥行きも両面で焼いたときと変わらない — 光から見て最も
        /// 近い面も必ず表だからである ([#1474](https://github.com/mokume-metal/mokume/issues/1474))。
        ///
        /// **どちらが表かは巻き方で決まり、巻き方は鏡映と裏返す投影で裏返る。** 捨て方は
        /// `.back` のまま、表の巻き方 (``frontFacing``) のほうを列ごとに裏返す — そうしないと
        /// 鏡映した箱や上下を逆にした `ortho` の箱では、手前の面が捨てられて奥の面だけが
        /// 写る ([#1446](https://github.com/mokume-metal/mokume/issues/1446))。
        ///
        /// 裏面が絵に出うるものは全部 `.none` に居続ける: 片面の形 (`plane`)・自分で並べた
        /// 頂点・保持した形・読み込んだモデル (閉じているか分からない)・半透明の置き場所を
        /// 含む列・貼る絵 (透けた画素から奥が見える)・重ねる混ぜ方・利用者の断片 (透明を
        /// 返したり画素を捨てたりできる)。**判定は列を閉じる側 (`closeSolidBatch`) が
        /// 1 箇所で行い**、描く側はこの値を掛けるだけにする。
        ///
        /// **絵・混ぜ方・断片・塗りの不透明度は、形を置いたときのものを読む**
        /// (``OpenSolid/mayShowBackFaces``)。後から変えた設定は既に置いた形に効かない —
        /// 絵を貼った形を置いた後で `noTexture()` を呼んでも、その形の列は両面で描く
        /// ([#1564](https://github.com/mokume-metal/mokume/issues/1564))。
        ///
        /// **両面で描くだけでは奥の面は出ない。** 立体は奥行きを書くので、1 回で描くと先に
        /// 積まれた手前の面が後の奥の面を捨てる。裏面が絵に出うる置き場所を持つ列は、
        /// 裏面が絵に出うる部品は、置き場所ごとに裏 → 表の順で描く (``backFaceParts``)。
        /// そのとき、この値の代わりに `.front` → `.back` を掛ける。
        var cullMode: MTLCullMode = .none
        /// 裏 → 表の順で描きうる部品 (``SolidPart``)。区間は列の描く単位 (添字の列なら読む順の
        /// 並び、そうでなければ頂点の並び) の番号で、記録した順に並ぶ。列の位置 (``run``) と同じ
        /// 並びの中の位置なので、列の位置を置き直すときは ``relocate(to:)`` が同じだけずらす。
        ///
        /// **裏 → 表の 2 回で描くのは、裏面が絵に出うる部品だけである。** 部品が立つのは、部品
        /// そのものに印がある (``SolidPart/showsBackFaces``。記録したときのスタイル・焼いた置き場所の
        /// 色) か、その置き場所に印がある (``backFaceInstances``) ときで、置き場所ごとに決まる。
        /// 部品の外の区間と立っていない部品は、今までどおり ``cullMode`` で 1 回で描き、立つ部品の
        /// 無い置き場所が続けば 1 回の呼び出しにまとめる。4 つの条件 (半透明の塗り・貼る絵・重ねる以外の混ぜ方・利用者の断片) の
        /// どれでも同じに扱う。奥行きは読み書きのままで、1 回で描くと先に積まれた手前の面が
        /// 後の奥の面を捨て、奥の面が出るかが形の向き (三角形を積んだ順) で変わっていた
        /// ([#1549](https://github.com/mokume-metal/mokume/issues/1549)・
        /// [#1565](https://github.com/mokume-metal/mokume/issues/1565))。裏 → 表に分ければ、
        /// 凸の形では画素ごとに奥の面が先・手前の面が後に混ざり、光を当てても向きによらない。
        ///
        /// **分けるのは部品 1 つ (組み込みの形 1 つ・モデル 1 つ) の中だけで、置き場所どうし・
        /// 部品どうしは呼び出し順のまま並べ替えない** (ADR-0021 決定 2 の追補)。列ごと (保持した
        /// 形ごと) にまとめて裏 → 表で描くと、作品側が奥から置いた 2 つの半透明の形で、奥の形の
        /// 手前の面が手前の形の裏面に捨てられる。描画パスも足さない — 同じパスの中で描く呼び出し
        /// が増えるだけで、列の数 (``Canvas/drawCallsInLastFrame``) は変わらない。
        ///
        /// **印を付ける所と、描き方を決める所は分かれている。** 印を付けるのは 4 か所 — 組み込みの
        /// 形・モデルをその場で置くとき、保持した形の中で置くとき (どちらも置いたスタイル)、焼いた
        /// 頂点を積むとき、保持した形を置き場所で置くとき (どちらも置き場所の色) — で、判定はどれも
        /// ``Canvas/placementShowsBackFaces(_:styled:)`` を通る。どの区間をどう描くかを決めるのは、
        /// 列を閉じる所 (`closeSolidBatch` の部品の組み立て) と描く所 (`encodeBackThenFront`) である。
        /// 部品も印も持たない列 (部品を足さない口・新しく足した口を含む) は今までどおり 1 回で描く
        /// ので、印の付け漏れが絵を直す前より悪くしない。
        ///
        /// - **凸でない形** (`torus` など) で、同じ側を向いた面どうしが重なる所は、積んだ順が
        ///   残りうる。裏 → 表は「奥の面を先に」を凸の形でしか保証しない (面どうしの並べ替えは
        ///   しない — ADR-0021 決定 2)。
        /// - **巻き方の向きが分からないものは部品にしない。** 向きの求まらない読み込んだモデル
        ///   (閉じていない・巻き方が揃っていない・成分どうしで向きが食い違う) と、自分で並べた頂点
        ///   (`beginShape`・[#1939](https://github.com/mokume-metal/mokume/issues/1939)) である。
        ///   後者は塗りと線を原始形ごとに交互に積む (線が隣の原始形の塗りに隠れないため) ので、
        ///   形の塗りが 1 つの区間にまとまらず、巻き方の向きも利用者が決める。
        /// - **粒は部品にしない。** 板 1 枚で自分の手前の面が自分の奥の面を隠すことが無く、
        ///   GPU が個数を書く経路は置き場所ごとに分けようがない。
        /// - **立体の線の帯は部品の外**で、呼び出し順のまま 1 回で描く (半透明の線の重なりは
        ///   [#1561](https://github.com/mokume-metal/mokume/issues/1561))。
        var backFaceParts: [SolidPart] = []
        /// 裏面が絵に出うる置き場所の、列の中での番号 (``OpenSolid/backFaceInstances``)。
        var backFaceInstances: [Int] = []
        /// 裏 → 表の順で描く部品を 1 つでも持つか (``backFaceParts``)。
        var drawsBackThenFront: Bool {
            guard !backFaceParts.isEmpty else { return false }
            if !backFaceInstances.isEmpty { return true }
            for part in backFaceParts where part.showsBackFaces { return true }
            return false
        }
        /// 画面でどちら回りに見える面を表とするか。
        ///
        /// 形は外向きに巻いてあり (`SolidMeshBuilder`)、縦軸を下向きへ戻す補正が画面での
        /// 巻き方を反転させるので、**いつもは時計回りが表**になる。置き場所の鏡映
        /// (``isMirrored``) と、画面の縦横を裏返す投影 (``Camera/flipsScreen``) はそれぞれ
        /// 巻き方をもう 1 度裏返すので、どちらか一方だけなら反時計回りが表になる
        /// ([#1446](https://github.com/mokume-metal/mokume/issues/1446))。
        ///
        /// **捨て方と、形から求めた向きの裏返しの両方がこれを読む。** 断片は表裏を見て
        /// 求めた向きを裏返す (`Common.metal`) ので、ここが幾何的な表を指していれば、
        /// 鏡映しても裏返した投影でも、見る側を向いた面が見る側から光を受ける。
        /// 決めるのは列を閉じる側 (`closeSolidBatch`) で、平面と基本図形の列は既定のまま
        /// (面の向きを持たず、捨てもしない)。
        var frontFacing: MTLWinding = .clockwise
        /// この列の置き場所が形を鏡映するか (``OpenSolid/isMirrored``)。**影の焼き付けが読む**
        /// — 光から見る行列は画面の投影と別物なので、焼く側の表の巻き方は置き場所の符号
        /// だけで決まる。鏡映していなければ反時計回り、鏡映していれば時計回りが表になり、
        /// どちらも光を向いた面を焼く (``ShadowMap/frontFacing(isMirrored:)``)。
        var isMirrored = false
        /// 立体の列が、何の頂点を並べているか。**影の焼き付けの指紋が読む** — 組み込みの
        /// 形と読み込んだモデルは頂点が出どころから決まるので、頂点の中身を舐めずに
        /// 出どころで代表できる。平面の列は `nil`。
        var solidSource: SolidSource?
        /// GPU で展開する線だけが持つ。投入完了まで HeldFrame が列ごと保持する。
        var strokeGeometry: SolidStrokeGeometry?
        var strokePlacement: SolidStrokePlacement?
        /// 読み込んだモデルの塗りの頂点の置き場 (``OpenSolid/fillGeometry``)。線の骨と同じく、
        /// 投入完了まで HeldFrame が列ごと保持する。
        var fillGeometry: SolidFillGeometry?
        /// 面を置き換える列か (``Canvas/replaceSurface(with:)``・[#1685])。
        ///
        /// 立てた列は**奥行きを比べずに書き** (``ShapePipeline/replaceDepthState``)、書く値は
        /// いちばん奥 (1) にする (見る窓の奥行きの幅を 1…1 に絞って描く)。比べると、先に描いた
        /// 立体 (途中の描き切りで載ったものを含む) の画素で板が落ちる ([#1657])。
        ///
        /// [#1657]: https://github.com/mokume-metal/mokume/issues/1657
        /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
        var replacesSurface = false

        /// 頂点を溜め場ではなく自分の置き場から読むなら、その置き場。
        var ownVertices: (any MTLBuffer)? { strokeGeometry?.buffer ?? fillGeometry?.buffer }

        /// 頂点を溜め場から読む列か。**詰め直すとき (`Canvas.compact(_:)`) に頂点を区画へ写して、
        /// 頭 (`run.start`) を 0 へ置き直すのは、この列だけである。**
        ///
        /// 頭を束ねる番地で指す列 (``addressesVertexHead``) の前提もこの述語で書く — 置き直す条件と
        /// 番地の足し算の条件を別々に書くと、口を足した日に片方だけが変わって黙って食い違う ([#2043])。
        ///
        /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
        var readsPooledVertices: Bool { ownVertices == nil }

        /// 頂点の頭を、描き引数の `vertexStart` ではなく束ねる番地で指す列か (``vertexBaseShift``)。
        /// **描く個数を GPU が書く列 (粒) だけが立つ。**
        ///
        /// **立つ列は、溜め場の頂点を添字なしで読む列でなければならない** (``readsPooledVertices``)。
        /// そういう列だけが、詰め直すときに頭を写した頂点の頭 (0) へ置き直されるので、番地へ足す
        /// `run.start` が持ち越した後も区画の中の頭を指す。自分の置き場を持つ列は頭を置き直されず
        /// (「持ち越した列の下駄は 0」が成り立たない)、添字の列は写す頂点の頭が添字の最小で
        /// `run.start` と一致しない。どちらも今は作る口が無い (粒の列は線・モデルの置き場を持たず、
        /// 添字は `closeSolidBatch` が断る) ので、作った日に描く前に止める ([#2043])。
        ///
        /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
        var addressesVertexHead: Bool {
            guard indirectArguments != nil else { return false }
            precondition(
                readsPooledVertices && !run.isIndexed,
                "a run whose draw arguments the GPU writes must read unindexed pooled vertices")
            return true
        }

        /// 頂点の置き場へ束ねる番地へ足す、列の頭までのバイト数。**描く個数を GPU が書く列 (粒) だけが
        /// 0 でない値を持つ** (``addressesVertexHead``)。
        ///
        /// 引数を GPU が書く列は、頂点の頭を引数の `vertexStart` ではなく**束ねる番地**で指す。
        /// 引数に頭の位置を書かせると、詰め直して頭を置き直した列 (``Canvas/frameCasters``) が、
        /// 置き直す前の位置のまま、詰め直した区画のずれた所を読む ([#2023])。引数の `vertexStart` は
        /// いつも 0 で、列の頭が置き場所と同じく「列の先頭から」数える。**詰め直す列は頭が 0 になる**
        /// ので、持ち越した列の下駄は 0、区画の頭がそのまま束ねる番地になる。
        ///
        /// 引数を CPU が決める列 (その他すべて) は、描く呼び出しの `vertexStart` で頭を指すので 0。
        ///
        /// [#2023]: https://github.com/mokume-metal/mokume/issues/2023
        var vertexBaseShift: UInt64 {
            addressesVertexHead ? UInt64(run.start * MemoryLayout<SolidVertex>.stride) : 0
        }

        /// 列の位置 (``run`` の `start`・`indexStart`) を `relocated` の位置へ置き直し、**位置から導く
        /// 値を同じだけずらす。** 列の位置を置き直す所 (`Canvas.compact(_:)`) は、`run` を直接
        /// 書き換えずにここを通す ([#2043])。
        ///
        /// 位置から導く値は 2 つある。束ねる番地の下駄 (``vertexBaseShift``) は `run.start` を読む
        /// だけなので、置き直した頭で読めば追随する。裏 → 表で描く部品の区間 (``backFaceParts``) は
        /// 溜め場の中の位置で持つので、ここでずらす — 部品が添字の列なら `indexStart` の、そうで
        /// なければ `start` の動いた分だけ。ずらさないと、描く側 (`encodeBackThenFront`) が列の区間の
        /// 外にある部品を黙って読み飛ばす。
        ///
        /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
        mutating func relocate(to relocated: Shape.Run) {
            let vertexShift = relocated.start - run.start
            let indexShift = relocated.indexStart - run.indexStart
            backFaceParts = backFaceParts.map {
                $0.shifted(by: $0.isIndexed ? indexShift : vertexShift)
            }
            run = relocated
        }

        /// どちらの並びから描くか。**区間が持っているものをそのまま読む** —
        /// 保持した形が持ち歩くのと同じ値なので、2 つ持つと食い違いうる
        var source: VertexSource { run.source }
    }

    /// 列がどちらの並びから描かれるか。
    enum VertexSource {
        /// 奥行きを持たない図形・字・画像 (三角形で組み立てるもの)。
        case flat
        /// 奥行きを持つ立体。
        case solid
        /// 平面の基本図形。頂点を持たず、置き場所 (``FormInstance``) が形を持つ。
        ///
        /// 区間の `start` / `count` は頂点ではなく**置き場所の並び**の中の位置である。
        case form
    }

    /// 混ぜ方の番号を置いた領域。列ごとに番地をずらして指す。
    ///
    /// **環に載せない。** 作成時に全部を並べて書いたきり、以後 CPU は触らない。
    private let blendModeBuffer: any MTLBuffer
    /// 「列が字の焼き場を読むか」の 0 と 1 を並べた領域。列ごとに番地で指す
    /// (``ShapePipeline/glyphPageBufferIndex``)。混ぜ方の番号と同じく、作成時に書いたきりである。
    private let glyphPageBuffer: any MTLBuffer
    /// フレームを通して変わらない値 (時刻・面の大きさ) の置き場。
    private let uniformsStorage: GrowableBuffer
    /// 列ごとの、利用者が渡した値の置き場。列 1 つにつき 1 区画。
    private let valuesStorage: GrowableBuffer
    /// 列ごとの、描画先の座標へ落とす行列の置き場。列 1 つにつき 1 区画。
    private let matrixStorage: GrowableBuffer
    /// 計算の頼みごとの、利用者が渡した値の置き場。頼み 1 つにつき 1 区画。
    ///
    /// **塗りの列と同じ形で持つ** ([#932])。値を計算の側に 1 本だけ持たせると、溜めた
    /// 頼みが流す段で最後の値だけを読む。
    ///
    /// [#932]: https://github.com/mokume-metal/mokume/issues/932
    let computeValuesStorage: GrowableBuffer
    /// 大画像の入力変換。最初に必要になったときだけ準備する (#1753)。
    var imageInputPass: ImageInputPass?
    var imageInputUnavailable = false
    /// GPU 準備が使えないときの CPU への逃げ道を検査する。
    var failImageInputForTesting = false
    /// 数の並びと画像へ CPU が書いた控えを、GPU 側で届けるための置き場
    /// (`Canvas+Uploads.swift`・#749)。
    let uploadStorage: GrowableBuffer
    /// 1 区画の大きさ (バイト)。定数の受け渡しの境界に揃える。
    static let valuesStride = 256
    /// 1 区画に収まる値の数 (float 換算)。**塗りと計算へ渡せる値の上限**でもある。
    ///
    /// 上限を超える宣言は作る入口 (`Canvas.loadShader` / `makeShader` /
    /// `loadComputation` / `makeComputation`) で断る
    /// ([#348](https://github.com/mokume-metal/mokume/issues/348)・
    /// [#932](https://github.com/mokume-metal/mokume/issues/932))。
    static let valueSlotCapacity = valuesStride / MemoryLayout<Float>.stride

    /// いまのフレームの時刻 (秒)。利用者の断片から読める。
    ///
    /// **描き場所は作った面と同じ値を読む** (``timebase``・[#1467])。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    var time: Float {
        get { timebase.time }
        set { timebase.time = newValue }
    }

    /// 1 フレームの長さ (秒)。**動くものの積分はこれで進む。**
    ///
    /// 既定を 60 分の 1 にしてあるのは、`Canvas` を直に回す経路 (検査・台帳のシーン)
    /// でも動きが進むようにするためである。0 を既定にすると、時計を差さない経路では
    /// 何も動かず、しかも絵は出るので気付けない。
    ///
    /// **描き場所は作った面と同じ値を読む** (``timebase``・[#1467])。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    var deltaTime: Float {
        get { timebase.step.deltaTime }
        set { timebase.step = .seconds(Double(newValue)) }
    }

    /// 1 フレームの長さ。``deltaTime`` はこれの単精度の写しである。**経過を数に変える側
    /// (`emit` の繰り越し・粒の寿命) が読む** — フレーム番号から導く時計では秒に直さずに
    /// 渡るので、fps によって毎秒 1 個・寿命の 1 枚がずれることが無い (``FrameStep``・
    /// [#1640]・[#1710])。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    var frameStep: FrameStep {
        get { timebase.step }
        set { timebase.step = newValue }
    }

    /// 時刻と刻みの置き場。**描き場所は、作った面と同じ 1 つを指す** (``createGraphics(_:_:)``・
    /// [#1467])。
    ///
    /// 参照を共有するのは、描き場所が作った面の値を**いつ読んでも**同じにするためである。
    /// 作ったときに写すと `setup()` で作った描き場所が 0 のまま止まり、描き始めに写すと
    /// 描き場所から作った描き場所が、間の描き場所を描かなかったフレームで古い値を読む。
    /// 時刻を作るのは今までどおりランタイムの 1 か所で、描き場所の側は読むだけになる。
    ///
    /// 直に作った面 (``init(target:gpu:)``) は自分の置き場を持つ。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    var timebase = Timebase()

    /// 時刻と刻み。**面どうしで共有するための参照型**で、値そのものは ``time`` と
    /// ``deltaTime``・``frameStep`` の説明が持つ。
    final class Timebase {
        var time: Float = 0
        /// 既定は単精度の 60 分の 1 秒 (``deltaTime`` の既定と同じ値)。直に回す面の数え方を
        /// 変えないため、秒のまま持つ
        var step = FrameStep.seconds(Double(Float(1.0 / 60)))
        /// 作った面 (``owner``) が始めたフレームの数。**描き場所の境目の印** — 描き場所は本体の
        /// フレームの中で描かれるので、閉じ忘れたフレームが本体の境目を越えたかをこれで見る
        /// ([#1622])。数えるのは作った面の ``beginFrame()`` だけで、**境目は頭である** (案 丁)。進める
        /// 前に、描き場所 (``layers``) の閉じ忘れたフレームを捨てる ([#1834])。
        ///
        /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        var frame = 0
        /// 作った面 (``owner``) が閉じたフレームの数 (持ち主の ``Canvas/framesDrawn`` と同じ値)。
        /// **粒の `wander` の揺れを決める番号** — 描き場所も同じ値を読むので、描き場所の描き歴に
        /// 依らず、同じ本体のフレームなら同じ揺れになる ([#1909])。進めるのは持ち主だけで、持ち主を
        /// 手放した後は進まない (時刻と刻みも、持ち主のフレームでランタイムが渡すときにしか変わらない)。
        ///
        /// [#1909]: https://github.com/mokume-metal/mokume/issues/1909
        var mainFramesDrawn = 0
        /// この置き場を作った面。**弱く持つ** — 置き場は面が持ち、面を生かす筋合いが無い。
        weak var owner: Canvas?
        /// いま描き場所を ``beginDraw()`` で開くと、そのフレームが属する本体のフレームの番号 ([#1834])。
        ///
        /// 持ち主のフレームの中なら今の番号 (``frame``)。それ以外 — `setup()`・止まっている間の
        /// コールバック・本体のフレームの合間 — なら、次に始まるフレームの番号である。持ち越しの区間
        /// (`setup()` と止まっている間のコールバック) は次に描くフレームに属する (ADR-0021 決定 4 の
        /// 追補 (2026-09-27)) ので、そこで開いて次の `draw()` で閉じる対は、同じフレームの中に居る。
        ///
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        var frameForOpening: Int { owner?.isDrawing == true ? frame : frame + 1 }
        /// この置き場を使う描き場所 (弱く持つ)。**持ち主が本体のフレームを進める前に、閉じ忘れた
        /// フレームを捨てる相手**で、``createGraphics(_:_:)`` が載せる ([#1834])。揺らぎの置き場の
        /// ``NoiseStore/readers`` と同じ形である。
        ///
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        private(set) var layers: [WeakCanvas] = []

        func add(layer canvas: Canvas) {
            layers.removeAll { $0.canvas == nil }
            guard !layers.contains(where: { $0.canvas === canvas }) else { return }
            layers.append(WeakCanvas(canvas: canvas))
        }
    }

    /// これまでに閉じたフレームの数。**時計ではなく番号**なので、同じ入力からは
    /// 何度走らせても同じ列になる。
    ///
    /// 描き切れなかったフレームも、閉じ忘れて捨てたフレーム ([#1622]・[#1834]) も 1 枚に数える
    /// — 番号はフレームの境目の印として読まれる (粒の繰り越し・焼き場の頁)。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private(set) var framesDrawn = 0
    /// 定数の受け渡しは 16 バイト境界に揃える。
    private static let blendModeStride = 16

    /// これから描くものに効く設定の一式。**フィールドの並びはこの宣言にしか書かない** ([#780])。
    ///
    /// 面の大きさや溜めている頂点は含まない — **積んで戻せるのは「これから描くものに
    /// 効く設定」だけ**であり、既に置いた図形や面そのものは戻らない。
    ///
    /// 格納はこれそのもの (``Canvas/style``) で、写し取るのも戻すのも丸ごと 1 つの値で
    /// 行う。以前は `currentFill` などの格納が別に並び、写し取る getter と戻す setter に
    /// 同じ並びがもう 2 回書かれていた — 1 か所落としても型は通り、積み降ろしで
    /// 「その設定だけ戻らない」形で絵がそれらしく壊れる。
    ///
    /// 積み降ろしの外からも写し取れるよう internal に置く。保持した形の組み立ては
    /// 断片と数の並びまで戻す必要があり、そこは積み降ろしが拾わない
    /// (`Canvas.createShape`)。
    ///
    /// [#780]: https://github.com/mokume-metal/mokume/issues/780
    struct Style {
        var fill = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        var stroke = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        var strokeWeight: Float = 1
        var strokeCap = StrokeCap.round
        var strokeJoin = StrokeJoin.miter
        var hasFill = true
        var hasStroke = true
        var rectMode = ShapeMode.corner
        var ellipseMode = ShapeMode.center
        var blendMode = BlendMode.blend
        var clip: ClipRect?
        var fontName: String?
        var textSize: Float = 12
        var textStyle = TextStyle.normal
        var horizontalTextAlign = HorizontalTextAlign.left
        var verticalTextAlign = VerticalTextAlign.baseline
        /// 行送りの指定。`nil` は自動 (大きさから決める)。
        var textLeading: Float?
        var textWrap = TextWrap.word
        var imageMode = ShapeMode.corner
        /// 画像に掛ける色。既定は掛けない (白・不透明)。
        var tint = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        /// これから置く**塗り**に貼る絵。`nil` なら貼らない。
        ///
        /// **描き方なのでフレームを越える** ([ADR-0021] 決定 4) — 塗り・線・混ぜ方と
        /// 同じ族である。効く先は塗りだけで、輪郭・端点・角・線と点・字・周囲は
        /// 焼き場の白い区画を読み続ける。
        ///
        /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
        var picture: Picture?
        /// いま効いている材質。**フレームを越えない** ([ADR-0021] 決定 4)。
        ///
        /// それでも積む。**フレームを越えないことと、積めることは別の話である** —
        /// 変換も同じくフレームを越えないが積める。入れ子で書けないほうが不便になる
        ///
        /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
        var material = Material.default
        /// これから置く形が影を落とすか。
        var castsShadow = true
        /// これから置く形が影を受けるか。
        var receivesShadow = true
    }

    /// いまの設定の一式を、丸ごと写し取る / 戻す口。
    ///
    /// 戻すときは、**置いた立体を後の設定で描かない**よう、材質・影を落とす / 受ける・
    /// 混ぜ方・切り抜きのどれかが変わるなら戻す前に列を閉じる。列が読む設定はこの 5 つ
    /// だけなので、1 度閉じてから丸ごと戻せば足りる (閉じた列は戻す前の値を持つ)。
    ///
    /// 塗りに貼る絵 (``Style/picture``) では閉じない。塗りを置く手前で必ず
    /// `useFillTexture()` を通るので、面が実際に変わるのはそのときで、そこで閉じられる。
    var currentStyle: Style {
        get { style }
        set {
            if style.material != newValue.material
                || style.castsShadow != newValue.castsShadow
                || style.receivesShadow != newValue.receivesShadow
                || style.blendMode != newValue.blendMode
                || style.clip != newValue.clip
            {
                closeBatch()
            }
            style = newValue
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

        // **フレームごとに書く置き場は、この 1 つの環に載る。** 描き切り 1 回につき
        // スロットを 1 つ進め、そのスロットを読む投入だけを待つ (#754)
        let ring = FrameRing(gpu: gpu)
        self.frameRing = ring
        func storage(stride: Int, minimum: Int, label: String) -> GrowableBuffer {
            GrowableBuffer(
                gpu: gpu, ring: ring, stride: stride, minimumCapacity: minimum,
                label: "mokume.\(label)")
        }
        self.vertexStorage = storage(
            stride: MemoryLayout<ShapeVertex>.stride, minimum: 1024, label: "vertices")
        self.coverageStorage = storage(
            stride: MemoryLayout<Float>.stride, minimum: 1, label: "coverages")
        self.solidVertexStorage = storage(
            stride: MemoryLayout<SolidVertex>.stride, minimum: 1024, label: "solidVertices")
        self.solidIndexStorage = storage(
            stride: MemoryLayout<UInt32>.stride, minimum: 4096, label: "solidIndices")
        self.flatInstanceStorage = storage(
            stride: MemoryLayout<FlatInstance>.stride, minimum: 256, label: "flatInstances")
        self.formInstanceStorage = storage(
            stride: MemoryLayout<FormInstance>.stride, minimum: 256, label: "formInstances")
        self.solidInstanceStorage = storage(
            stride: MemoryLayout<SolidInstance>.stride, minimum: 256, label: "solidInstances")
        self.lightStorageBuffer = storage(
            stride: MemoryLayout<Light>.stride, minimum: 8, label: "lights")
        self.lightingStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "lighting")
        self.materialStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "materials")
        self.surroundingsStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "surroundings")
        self.matrixStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "matrices")
        self.valuesStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "values")
        self.computeValuesStorage = storage(
            stride: Self.valuesStride, minimum: 16, label: "computeValues")
        self.uploadStorage = storage(stride: 1, minimum: 1 << 16, label: "uploads")
        // 時刻・面の大きさ・影の行列はフレームに 1 区画。**大きさが変わらなくても
        // 環には載る** — 毎フレーム CPU が書き換えるという性質が同じだからである
        self.uniformsStorage = storage(
            stride: Self.valuesStride, minimum: 1, label: "uniforms")
        self.shadowMatrixStorage = storage(
            stride: Self.valuesStride, minimum: 1, label: "shadowMatrix")

        self.width = Float(output.width)
        self.height = Float(output.height)
        self.pipeline = try ShapePipeline(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        self.emptyNumbers = try Numbers(gpu: gpu, count: 1)
        self.projection = Self.makeProjection(width: self.width, height: self.height)

        let atlas = try GlyphAtlas(gpu: gpu)
        self.atlas = atlas
        self.currentTexture = atlas.held
        self.whiteUV = atlas.whiteUV

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

        let glyphPageBuffer = try gpu.makeReadableBuffer(byteCount: 2 * Self.blendModeStride)
        for flag: UInt32 in [0, 1] {
            glyphPageBuffer.contents()
                .advanced(by: Int(flag) * Self.blendModeStride)
                .assumingMemoryBound(to: UInt32.self)
                .pointee = flag
        }
        self.glyphPageBuffer = glyphPageBuffer

        // **出す先から自分へ辿れるようにする** (#1543)。この面を読む側が、置くたびに
        // 置いたことを記録し直すのに使う (``useTexture(_:)``)
        output.drawer = self
        // 時刻の置き場の持ち主になる。描き場所は作った面の置き場を指し直すので、持ち主は
        // いつも本体の側に居る (``createGraphics(_:_:)``)
        timebase.owner = self
    }

    /// **自分で確保した置き場と面を常駐から退かせる** ([#795])。
    ///
    /// 退かせるのは `Canvas` が直に確保した 3 つ (混ぜ方の番号・字の焼き場を読むかの印・
    /// 焼いていないフレームの影の面) だけである。環に載る置き場・焼き付け先・効果の中間の絵・描く先は、
    /// それぞれ確保した型が自分の `deinit` で退く — 片付ける中身は相手の `private` に
    /// あり、しかも `Canvas` の外にも持ち主が居るため (`PresentPipeline` の置き場)。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit {
        gpu.retire(blendModeBuffer)
        gpu.retire(glyphPageBuffer)
        if let unbakedShadowTexture { gpu.retire(unbakedShadowTexture) }
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
    ///
    /// **描き場所の面を読むなら、そのたびに置いたことを記録し直す** ([#1543])。塗り・立体・
    /// 保持した形・画像のどれも面を切り替えるときはここを通るので、記録する所はこの 1 か所
    /// でよい。貼った時点 (`texture(_:)`) の記録だけに頼ると、描き場所を描き換えて記録が
    /// 落ちた後 (描き切り・塗り直し・次のフレーム) に同じ面のまま置いた形が描き切られず、
    /// 描き換えた後の絵で描かれる。**同じ面が続くときも記録する** — 続けて置く形こそ、
    /// 貼り直さずに塗り続けた形である。
    ///
    /// [#1543]: https://github.com/mokume-metal/mokume/issues/1543
    func useTexture(_ texture: HeldTexture) {
        if let graphics = (texture.owner as? RenderTarget)?.drawer { note(placing: graphics) }
        if texture == currentTexture { return }
        closeBatch()
        currentTexture = texture
    }

    /// 図形と字が読む面 (字形の置き場) へ戻す。
    ///
    /// **既に焼き場の面なら何もしない** (#1785)。線や字は頂点・三角形ごとにここを通るので、
    /// 面の組 (``HeldTexture``) を作って型を確かめて比べる手間が積もる。焼き場の頁は描き
    /// 場所ではないので、``useTexture(_:)`` の描き場所の記録にも当たらない。
    func useGlyphTexture() {
        if currentTexture.texture === atlas.texture { return }
        useTexture(atlas.held)
    }

    /// **塗り**が読む面へ切り替える。貼る絵が束ねてあればその面、無ければ焼き場。
    ///
    /// 塗りを置く手前で必ずこれを通すので、直前に画像や字を描いて面が変わっていても
    /// 戻る。輪郭・端点・角・線と点はこれを通さず ``useGlyphTexture()`` のままなので、
    /// **貼る絵は塗りにしか効かない**。
    func useFillTexture() {
        guard let picture = style.picture else { return useGlyphTexture() }
        picture.prepare()
        useTexture(picture.held)
    }

    /// **読み取り位置を書いた塗り**が読む面へ切り替える。貼る絵が束ねてあればその面。
    ///
    /// 絵が無ければ 1×1 の白い絵を読む ([#1140])。書いた位置は割らずに `Fragment.uv`
    /// へ届くので、焼き場を読ませると 0…1 を越えた位置が字形を拾って塗りが汚れる —
    /// 白い 1 画素なら端を伸ばして読むのでどこを指しても白で、既定の塗りの色は
    /// 変わらない。組み込みの形は絵が無いと読み取り位置を渡さないので、ここへは来ない
    /// (``useFillTexture()`` のまま焼き場を読み、輪郭と同じ列に乗り続ける)。
    ///
    /// [#1140]: https://github.com/mokume-metal/mokume/issues/1140
    func useWrittenUVTexture() {
        if style.picture != nil { return useFillTexture() }
        if blankPicture == nil {
            // 作れないのは GPU が面を出せないときだけで、そのときは焼き場へ倒れる
            // (塗りは汚れうるが、形は消えない)
            let white = SIMD4<Float16>(repeating: 1)
            blankPicture = (try? makeImage(
                ImageFile.Decoded(width: 1, height: 1, pixels: [white]))).map { .loaded($0) }
        }
        guard let blankPicture else { return useGlyphTexture() }
        blankPicture.prepare()
        useTexture(blankPicture.held)
    }

    /// 描画先の座標へ落とす行列を作る。
    ///
    /// 左上原点・縦軸下向きに写す。**ずらしは持たない** — 整数の座標は画素の角に落ち、
    /// 線だけを輪郭の側で半画素寄せる (型の説明を参照)。立体の `Camera.clipAdjustment`
    /// と揃っている必要がある (`screenX` は 2 つを往復して値を出すので、片方だけ変えると
    /// 黙って半画素ずれる)。
    static func makeProjection(width: Float, height: Float) -> simd_float4x4 {
        // x: 0…width → -1…1、y: 0…height → 1…-1
        simd_float4x4(
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, -2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1))
    }

    /// 立体の輪郭の頂点を、画面で (+0.5, +0.5) 画素寄せる量 (切り取り座標。`w` を掛けて足す)。
    ///
    /// 平面の輪郭は描画先の座標で 0.5 を足すが、立体の頂点は投影の後でしか画面の位置が
    /// 決まらない。**単位は出す画素**で、描く細かさ (`pixelDensity`) によらない —
    /// 平面の 0.5 も出す画素で測っているので、揃えないと細かさ < 1 で倍ずれる。
    static func solidStrokeShift(width: Float, height: Float) -> SIMD4<Float> {
        SIMD4<Float>(1 / width, -1 / height, 0, 0)
    }

    // MARK: - 変換

    public func translate(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.translate(x: x, y: y)
    }

    public func rotate(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.rotate(by: radians)
    }

    public func scale(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.scale(x: x, y: y)
    }

    public func shearX(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.shearX(by: radians)
    }

    public func shearY(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.shearY(by: radians)
    }

    public func applyMatrix(_ other: Transform) {
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.concatenate(other)
    }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てない — 戻す先は残る。
    public func resetMatrix() {
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.reset()
    }

    public func pushMatrix() {
        guard isShaping else { return warnOutsideFrame(.transform) }
        transformStack.append(transform)
    }

    public func popMatrix() {
        guard isShaping else { return warnOutsideFrame(.transform) }
        guard let restored = transformStack.popLast() else { return }
        transform = restored
    }

    /// いまのスタイルを積んでおく。
    public func pushStyle() {
        guard isShaping else { return warnOutsideFrame(.style) }
        styleStack.append(currentStyle)
    }

    public func popStyle() {
        guard isShaping else { return warnOutsideFrame(.style) }
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
        paintBackground(color.isFinite ? color : nil)
    }

    /// 面を塗り直す。**`nil` は受け取れない色** (数でない成分・無限の成分) で、区間の外と形の
    /// 組み立ての中の断りを先に言ってから断る ([#1706] の反証 2)。数の形 (`background(r, g, b)`) も
    /// 色の値の形もここを通るので、断る順は形に依らない。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    func paintBackground(_ color: LinearRGBA?) {
        // 塗り直しも置くことである。区間の外では、溜めたものを捨てる前に断る ([#1672])。
        //
        // **見るのは形の組み立てを含まない述語** (``writesToSurface``)。塗り直しは形に焼き付かず、
        // 面を塗る予定として組み立ての外へ残るので、フレームの外の組み立ての中で通すと、
        // 描き場所の次のフレームを知らない色で塗る
        //
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard writesToSurface else { return warnOutsideFrame(.placing) }
        // **形の組み立ての中では塗り直さない** ([#1588])。塗り直しは形に焼き付く先が無く、通すと
        // 溜め場を空にして、組み立てが控えた区間を溜め場の外へ追い出す。区間の外なら上の注意を
        // 先に言う (頂点の仲間と同じ順)
        //
        // [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        guard !recordingShape else { return warnInsideShape(.background) }
        // 数でない成分・無限の成分は、溜めたものを捨てる前に断る (#1706)
        guard let color else { return warnNotANumberColor(.background) }
        replaceSurface(with: .color(color))
    }

    /// 面を置き換える中身。**`background()` の口ごとに 1 つ** ([#1685])。
    ///
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    enum SurfaceContent {
        /// 1 色 (`background(色)`)。
        case color(LinearRGBA)
        /// 視点から見た周囲 (`background(.sky)`)。
        case surroundings(Surroundings)
    }

    /// **面を置き換える関所** ([#1685])。`background()` の口はどれも、入口の断り (区間の外・形の
    /// 組み立て・受け取れない値) を済ませてからここへ来る。
    ///
    /// 置き換えの規則は口によらず 1 つで、違うのは置く中身だけである:
    /// - **呼んだ時点の図形のスタイルを読まない。** 混ぜ方・断片・貼る絵・影を落とすか・光と材質の
    ///   どれも、置き換えには効かない ([#1658])
    /// - **同じフレームの途中の描き切りに左右されない。** 描き切った絵と奥行きも置き換える ([#1657])
    /// - **切り抜きがあれば、その中だけを置き換える** (案 A・[#1648])。中は色も奥行きも置き換わり、
    ///   外に先に置いたものは残る
    ///
    /// 道は 2 つあり、どちらも同じ絵になる:
    /// - **切り抜きが無く、中身が 1 色**なら、溜めたものを捨てて塗り直しを予定する。次の描き切りの
    ///   load 動作が色と奥行きを消す (``RenderTarget/makeRenderPass(clearColor:continuingDepth:keepingDepth:)``)
    ///   — 板を描くより安い
    /// - それ以外は、**置き換える列** (``appendSurfaceReplacement(_:)``) を 1 本積む。load 動作は
    ///   切り抜きを表せず、周囲は 1 色ではないので、列として描くしかない。切り抜きが無ければ、
    ///   列が面全体を覆うので溜めたものは先に捨て、前に予定した塗り直しも打ち消す (下に隠れる
    ///   ものを描く手間を払わない)。列の板はどの視点でも切り取られない位置に置き、書く奥行きは
    ///   load 動作と同じ 1 にするので、絵は視点によらず塗り直しの道と同じになる
    ///   (``Camera/replacementCorners()``)
    ///
    /// [#1648]: https://github.com/mokume-metal/mokume/issues/1648
    /// [#1657]: https://github.com/mokume-metal/mokume/issues/1657
    /// [#1658]: https://github.com/mokume-metal/mokume/issues/1658
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    func replaceSurface(with content: SurfaceContent) {
        if style.clip == nil {
            discardPending()
            if case .color(let color) = content {
                pendingBackground = color
                return
            }
            // **前に予定した塗り直しも打ち消す。** 面全体を置き換えるのだから、前の予定は絵に
            // 出ない。残すと、次の描き切りが奥行きを引き継ぐか・控えを戻すかを古い予定で決める
            pendingBackground = nil
        }
        appendSurfaceReplacement(content)
    }

    /// 置き換える列を 1 本積む ([#1685])。**視点が写す範囲いっぱいの板**で、
    ///
    /// - 混ぜ方は `.replace`、断片は組み込み、面は焼き場の白い区画、光と材質は持たず、影は
    ///   落とさない。**どれも呼んだ時点のスタイルから読まない** — 図形の列を閉じる経路
    ///   (`closeSolidBatch`) を通すと、スタイルを全部拾う
    /// - 奥行きは**比べずに、いちばん奥 (1) を書く** (``Batch/replacesSurface``)。load 動作が消す
    ///   値と同じなので、後から置く立体は塗り直した面と同じく手前に出る
    /// - 切り抜きは呼んだ時点のものを持つ
    ///
    /// 周囲は、板の断片が見ている向きへ周囲を読んで出す (``Surroundings/packed(isBackdrop:)``)。
    ///
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    private func appendSurfaceReplacement(_ content: SurfaceContent) {
        closeBatch()
        let color: LinearRGBA
        let surroundings: PackedSurroundings
        switch content {
        case .color(let value):
            color = value
            surroundings = .none
        case .surroundings(let value):
            // 色は断片が周囲から読み直すので、掛けても変わらない白にしておく
            color = .linear(red: 1, green: 1, blue: 1)
            surroundings = value.packed(isBackdrop: true)
        }
        let corners = currentCamera.replacementCorners()
        let vertexStart = solidVertices.count
        // 面の向きは持たせない。光を受けず、色 (または周囲) をそのまま出す
        for index in [0, 1, 2, 0, 2, 3] {
            solidVertices.append(
                SolidVertex(
                    position: corners[index], shapePosition: nil, normal: .zero, shapeNormal: nil,
                    isDerived: false, uv: whiteUV, color: color))
        }
        let instanceStart = solidInstances.count
        solidInstances.append(.identity)
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: .replace, texture: atlas.held, paint: .builtIn, source: .solid,
                    start: vertexStart, count: 6, indexStart: 0, indexCount: 0),
                clip: style.clip,
                matrix: viewProjection,
                lightRange: 0..<0,
                material: .default,
                viewer: viewer,
                view: viewMatrix,
                surroundings: surroundings,
                noise: noiseSettings,
                castsShadow: false,
                instanceStart: instanceStart,
                instanceCount: 1,
                solidSource: .freeform,
                replacesSurface: true))
    }

    /// 溜めているものを捨てる。
    ///
    /// **塗り直しは「このフレームをここから描き直す」こと**なので、平面の頂点も
    /// 立体の頂点も、閉じた列も、**開いたままの列と置き場所も**まとめて捨てる。
    /// 1 つでも残すと、次に閉じる列が「もう無い頂点」を指す — 消えたはずのものが
    /// 出る、あるいは何も出ない、という形で現れる (#323)。
    ///
    /// - Parameter keepingCasters: 途中の描き切りが既に描いた落とす側 (``frameCasters``) を残すか。
    ///   **形の組み立ての出口の安全網だけが真を渡す** — そこで捨てるのは組み立ての途中で溜めた
    ///   ものだけで、前の無関係な区切りで描いた立体の影まで消す筋合いが無い (#1656)。
    func discardPending(keepingCasters: Bool = false) {
        _ = sweepPending(emptying: true)
        pendingDiscards &+= 1
        // **途中の描き切りが既に描いた落とす側も捨てる** ([#1656])。塗り直しは前に置いた立体ごと
        // 捨てるので、分けずに描いたときも、それより前の立体は影を落とさない。溜めた量
        // (``pendingAmount``) には数えない — 既に描いた列で、区間の外に置いたものではない
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        if !keepingCasters {
            releaseCasterSegments(frameCasters.segments)
            frameCasters.removeAll()
        }
        // 開いている列の種類は溜めたものではなく、次に置くものの向き先である。空かを見る
        // 側 (``hasNothingPending``) は読まない — 形の組み立ては種類を `.solid` のまま抜ける
        openSource = .flat
    }

    /// 溜め場が空か。**区間の外で置いたものが残っていないかを、フレームの頭が見る** ([#1672])。
    ///
    /// 並びは ``discardPending()`` と同じもの (``sweepPending(emptying:)``) を通る (``pendingAmount``)。
    ///
    /// **画素の写しへの書き込みは見ない。** 書く口は画素の窓 (``Pixels``) の 2 つに集まっていて、
    /// 窓自身が書いてよいかを尋ねる。しかも写しへの書き込みは、描き切れなかったフレームと
    /// 閉じ忘れて捨てたフレームでも残る ([#1678] の判断待ち) ので、ここで見ると区間の中で
    /// 書いたものを区間の外と取り違える。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    var hasNothingPending: Bool { pendingAmount == 0 }

    /// 溜め場を捨てた回数 (``discardPending()``)。**形の組み立てが入口と出口で比べる** ([#1588])。
    ///
    /// 組み立ては入口で溜め場の長さを控え、出口でそこから先を形として抜く。記録の途中で捨てると
    /// 控えた長さは溜め場の外を指す。**長さでは見分けない** — 捨てた後も記録が続けば長さは入口より
    /// 戻り、壊れた区間を形として抜いてしまう。番号どうしで比べる。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    private(set) var pendingDiscards = 0

    /// **一番外の形の組み立てが入口で控えた列の位置** ([#1855] の案 E)。組み立ての外では `nil`。
    ///
    /// これより前の列はフレームに置いたもので、ここから後ろは組み立てた列 (出口で形として抜く) である。
    /// 置いた描き場所が組み立ての途中で描き換わるとき、置いた時点の絵の写しへ差し替えるのは前の列
    /// だけにする (``keepPicture(placedFrom:)``)。組み立てた列は描き場所を読み続け、形として持ち歩く —
    /// 後で置けば、置いたときの絵を読む。入れ子の組み立ては書き換えない (内側の列も外側の形に入る)。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    var shapeRecordingRunStart: Int?

    /// 溜め場に溜まっている量。**置けば増え、捨てれば 0 に戻る。** 列を閉じる操作 (`blendMode()`
    /// などが開いた列を閉じる) では増えない。
    ///
    /// 数えるのは溜め場の要素の数と、開いている列・畳む相手の控え・置いた記録の数に、塗り直しの
    /// 予定を足したもの (次の描き切りで面を塗るので、置いたものである)。閉じた列の数は数えない
    /// (``sweepPending(emptying:)``)。
    var pendingAmount: Int { sweepPending(emptying: false) + (pendingBackground == nil ? 0 : 1) }

    /// 溜め場を 1 つずつ通り、空にするか、空かを見る。
    ///
    /// **捨てる (``discardPending()``) のと空かを見る (``hasNothingPending``) が、同じ並びを通る**
    /// ([#1672])。並びを 2 か所に書くと、溜め場を 1 つ足した日に片方だけが知る — 捨て落とせば
    /// 溜まり、見落とせばフレームの頭の検めが黙る。
    ///
    /// - Returns: 見る側 (`emptying: false`) で、溜まっている量 (``pendingAmount``)。捨てる側では 0。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    private func sweepPending(emptying: Bool) -> Int {
        var amount = 0
        func list<Store: RangeReplaceableCollection>(
            _ store: inout Store, resettingTo reset: Store = Store(), counted: Bool = true
        ) {
            if emptying {
                store.removeAll(keepingCapacity: true)
                store.append(contentsOf: reset)
            } else if counted {
                amount += store.count - reset.count
            }
        }
        func open<Value>(_ value: inout Value?) {
            if emptying { value = nil } else if value != nil { amount += 1 }
        }
        func flag(_ value: inout Bool) {
            if emptying { value = false } else if value { amount += 1 }
        }
        list(&vertices)
        list(&coverageSpans, counted: false)
        if emptying { openBatchHasThinCoverage = false }
        list(&recordedStrokeRanges)
        list(&recordedFillRanges)
        list(&recordedSolidStrokes)
        list(&recordedGPUStrokes)
        list(&solidVertices)
        list(&solidIndices)
        list(&solidInstances)
        if emptying { solidMeshRanges.removeAll(keepingCapacity: true) }
        // **何も動かさない置き場所は置き直す。** 畳めない列がこれを指すので、
        // 空のまま次の列を閉じると、束ねる先の無い添字が残る
        list(&flatInstances, resettingTo: [FlatInstance.identity])
        list(&formInstances)
        // 列は数えない。溜めたものを閉じて束ねるだけで、置いたものではない — 数えると、区間の
        // 外で `blendMode()` を書いて列を閉じただけで量が増える。列があれば、束ねた中身が上の
        // どれかに溜まっている (中身の無い列は積まない) ので、空かの判定は変わらない
        list(&batches, counted: false)
        open(&openSolid)
        open(&openFlat)
        open(&openForm)
        open(&pendingFlat)
        flag(&buildingFlatTemplate)
        // **置いた記録も一緒に落とす。** 置いた四角ごと捨てたのだから、その絵を
        // 守るために描き切らせる相手はもう居ない
        if emptying {
            placedGraphics.removeAll(keepingCapacity: true)
            placedGraphicsDrops &+= 1
        } else {
            amount += placedGraphics.count
        }
        return amount
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
        // もう一度走ると、進み方が観測の有無で変わる。**既に GPU へ流れた頼みは取り消せない** —
        // 読み戻し (`read`)・面をまたぐ順 (#1870)・数の並びへの書き込み (#1687) が描き切りを待たずに
        // 投入した分は、このフレームが描けなくても走り終えている。落とすのは溜め場に残った分だけ
        pendingComputations.removeAll(keepingCapacity: true)
        // 頼んだ進めも同じく越えない。投入した進めは投入した所で粒へ足してあり、ここに残るのは
        // 走らなかった進めである (#1710)
        particleAdvancesThisFrame.removeAll(keepingCapacity: true)
        // 力の控えもこのフレームのもの。積んだ力そのものは粒の側で次に進めるまで残る
        forcesThisFrame.removeAll(keepingCapacity: true)
        // **このフレームの数も越えない** ([#1671])。描き切れたときは flush が「直前のフレーム」の
        // 値へ移してから 0 に戻しているが、描き切れなかったフレーム (#342) と閉じ忘れて捨てた
        // フレーム (#1622) では移さないまま残り、次のフレームの数に足されていた。境目の検査
        // (`CanvasTests.frameStateResetsAtEveryBoundary`) が見つけた戻し落とし
        //
        // [#1671]: https://github.com/mokume-metal/mokume/issues/1671
        outlinesAssembledThisFrame = 0
        pointScansThisFrame = 0
        // **書いた画素もフレームを越えない** ([#1678])。書いた画素は置いた図形と同じく次の描き切りで
        // 面に載るので、同じ規則に属する (ADR-0021 決定 4 の追補 (2026-09-27))。写しは描く先が持つ
        // ので、上で図形を落としても書き込み待ちは残り、描かずに捨てたフレーム (#342・#1622) で書いた
        // 画素だけが次の描き切りで面へ戻っていた。描き切れたときは書き戻しを投入して旗が下りた後
        // なので、ここは何もしない
        //
        // [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        target.discardPixelWrites()
        // **写しは、読む列が投入されたか捨てられたので空きへ戻す** ([#1656])。次に写すコマンドは、
        // 読んだ描き切りより後に投入される
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        placedPictureCopiesFree.append(contentsOf: placedPictureCopiesInUse)
        placedPictureCopiesInUse.removeAll(keepingCapacity: true)
        // **読む面も焼き場へ戻す。** 面は持ち主と組で持つので、最後に置いた絵を次に面を
        // 替えるまで生かしてしまう。溜めたものは上で落ちているので、列を閉じずに替えてよい
        currentTexture = atlas.held
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
        computations.compactMap { held in
            guard let computation = held.value else { return nil }
            return computation.failure.map { "computation \(computation.name): \($0)" }
        }
    }

    // MARK: - 描き切る

    /// 1 フレーム分を描く。
    ///
    /// `body` の中で呼んだ図形が溜められ、抜けるときにまとめて描画先へ落ちる。**`draw { }` の
    /// 外で置いた図形・絵・背景と書いた画素は、注意して置かない** — どのフレームに出るかを
    /// 約束する者が居ないからである ([ADR-0021] 決定 4 の追補 (2026-09-27)・[#1672])。
    /// **返った時点で GPU はまだ描いていることがある。** 待つのは結果に触る口
    /// (画素の読み出し・数の並びの読み書き) と、次の描き切りの書く直前で、どちらも
    /// 自分で待つ。だから呼ぶ側は待ちを意識しなくてよい (#727)。
    ///
    /// **開いているフレームの中で呼ぶと、そのフレームの続きとして `body` を走らせる** (注意を
    /// 1 度出す)。フレームを開き直さず閉じもしない — 入れ子で開き直すと、外のフレームの変換や
    /// 光を途中で既定へ戻し、閉じると外の閉包が戻った後にもう一度描き切ることになる。ただし
    /// ``beginDraw()`` で開いたまま閉じ忘れて境目を越えたフレームは、捨ててから始める
    /// (``beginDraw()`` の説明。描き場所の閉じ忘れは、本体のフレームの頭が先に捨てている)。
    ///
    /// **この面の形の組み立て (``createShape(_:)``) の中で開いたフレームは、閉包の終わりでは閉じない**
    /// ([#1855])。``endDraw()`` と同じく 1 度注意して、組み立ての出口 (入れ子なら一番外) で閉じる。閉包の
    /// 中で組み立てたものは形に入り、フレームには描かれない。描き切れなかったときは、出口から投げずに
    /// 理由を知らせる。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    public func draw(_ body: () -> Void) throws(RenderFailure) {
        if isDrawing, !leftOpenAcrossBoundary {
            warnFrameCallInsideFrame("draw")
            body()
            return
        }
        beginFrame()
        body()
        // **自分の形の組み立ての中では、ここで閉じない** ([#1855] の案 G を閉包の終わりにも当てる)。
        // 閉じる描き切りが組み立ての区間を空にし、形が空になっていた (`endDraw()` と同じ場所)
        //
        // [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        guard !recordingShape else { return awaitFrameEndInsideShape() }
        try endFrame()
    }

    /// 描き場所として 1 フレーム分を描き始める。
    ///
    /// ``endDraw()`` と対で使う。手本と同じ名前・同じ対の形にしてある。
    ///
    /// **描き場所 (`createGraphics`) の図形・絵・背景と画素の書き込みは、`beginDraw()` と
    /// `endDraw()` の間でだけ置ける。** 外で置くと 1 度注意して、置かない ([ADR-0021] 決定 4 の
    /// 追補 (2026-09-27)・[#1672])。次のフレームを約束するのは作者で、約束の区間がこの対だから
    /// である。以前は外で置いたものが溜め場に積まれ、描き切りが来ないまま溜まり続けた
    /// ([#1592])。本体の面は違い、`setup()` と止まっている間のコールバックでも置ける — そちらは
    /// ランタイムが次のフレームを約束する。
    ///
    /// <!-- example: 文脈 var trail: Canvas! -->
    /// <!-- example: 文脈 let x: Float = 200 -->
    /// <!-- example: 文脈 let y: Float = 150 -->
    /// ```swift
    /// trail.beginDraw()
    /// trail.circle(x, y, 20)
    /// trail.endDraw()
    /// ```
    ///
    /// **``endDraw()`` を呼ばずに境目を越えたら、閉じていないフレームは描かずに捨て、1 度注意する**
    /// ([ADR-0021] 決定 4 の追補 (2026-09-27) と 2026-10-02 の改訂・[#1622]・[#1834])。捨てる時点は
    /// 面で違う:
    ///
    /// - 描き場所 (`createGraphics`) では、開いたフレームは**属する本体のフレーム**を持つ。本体の
    ///   フレームの中で開けばそのフレーム、`setup()`・止まっている間のコールバック・本体のフレームの
    ///   合間で開けば次に描くフレームである。**本体のフレームが始まる所** (本体の頭と、`noLoop()` で
    ///   止まっている間のコールバックに入る所) で、それより前のフレームに属したまま開いているものを
    ///   捨てる。`setup()` やコールバックで開いて次の `draw()` で閉じる対は、同じフレームの中に居て
    ///   捨てない。捨てた後の描き場所はフレームの外に居る。越えた後に読めば (``get(_:_:)``・
    ///   ``pixels``・``loadPixels()``) 捨てる前の絵が返り、置けば注意して置かない。遅れて呼んだ ``endDraw()`` は、既に捨てたことを言って
    ///   何もしない。この描き場所を置いた面が描き換わっても、数の並びを読んでも、捨てた中身は
    ///   描かれず、頼んだ計算は走らない
    /// - 本体・直に使う面では、自分の次のフレームの頭 (`beginDraw()` か ``draw(_:)``) で捨て、
    ///   描き始め直す
    ///
    /// 捨てたフレームで書いた変換・溜めた図形・開いた形・書いた画素 (``set(_:_:_:)``・``pixels``)・
    /// 頼んだ計算は、次のフレームへ持ち込まない (積んだ力 (``force(_:_:)``) も落とす・[#1678])。
    /// ただし、次の 3 つは取り消せない。どれも**境目を越える前** (同じ本体のフレームの中) に
    /// 起きたもので、越えた後の読みはここに入らない。止まっている間のコールバックの中の読みも、
    /// 止まる前のフレームから見れば越えた後である (区間の入口で捨ててある)。逆に、本体のフレームが
    /// 終わってから次の頭までの間 (`Task` の続き・外から止めている間・`Canvas` を直に回す道具の
    /// 合間) は境目の前で、まだ同じフレームに居る。そこで読んで描き切った分も取り消せない:
    ///
    /// - 捨てたフレームの途中で既に描き切った絵 (``loadPixels()`` など)。面に載っている
    /// - 捨てたフレームで出した粒 (`emit`)。粒の状態の並びへ直に積まれている
    /// - 捨てたフレームで頼んだ計算のうち、境目を越える前に GPU へ流れたもの ([#1870])。同じ本体の
    ///   フレームの中で `endDraw()` を忘れた描き場所の頼みは、本体などほかの面が、読み書きの重なる
    ///   計算を頼んだ時点で先に流れる (頼んだ順に効かせるため)。その頼みが触れる数の並びへ書いた
    ///   時点でも流れる (#1687)。境目を越えた後は捨ててあるので、流れる頼みは残っていない
    ///
    /// 境目を越えていなければ捨てない。注意して何もせず、開いているフレームがそのまま続く:
    ///
    /// - ``draw(_:)`` が開いたフレームの中で呼んだ。そのフレームは ``draw(_:)`` が自分で閉じる
    /// - 描き場所で、同じ本体のフレームの中で `beginDraw()` を重ねた (補助の関数の入れ子など)
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1592]: https://github.com/mokume-metal/mokume/issues/1592
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    public func beginDraw() {
        // 閉じ忘れたまま境目を越えたフレームだけを捨てる。越えていない重ね呼びで捨てると、
        // 本体の面の `draw()` で `canvas.beginDraw()` を呼んだだけで、あるいは補助の関数が
        // 同じフレームで描き場所を開き直しただけで、それまでに描いたものが消える
        if isDrawing, !leftOpenAcrossBoundary {
            if beginDrawFrame == nil {
                warnFrameCallInsideFrame("beginDraw")
            } else {
                warnAlreadyDrawing()
            }
            return
        }
        beginFrame()
        beginDrawFrame = timebase.frameForOpening
    }

    /// 開いているフレームが、``beginDraw()`` で開いたまま閉じ忘れて、境目を越えたか ([#1622])。
    ///
    /// - ``draw(_:)`` が開いたフレームは越えない (閉包を抜けるときに閉じる)
    /// - 時刻の置き場の持ち主 (本体・直に使う面) では、次のフレームを始めること自体が境目で
    ///   ある。`beginDraw()` を重ねれば越えている
    /// - 描き場所では、属する本体のフレーム (``beginDrawFrame``) より後のフレームが始まっていれば
    ///   越えている。始まっていなければ、同じ本体のフレームの中での重ね呼びである。本体のフレームが
    ///   終わってから次の頭までの間も、まだ同じフレームである (境目は頭)。ただし本体のフレームが
    ///   始まる所が先に閉じ忘れを捨てる ([#1834]) ので、描き場所が越えたままここへ来ることは無い
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private var leftOpenAcrossBoundary: Bool {
        guard isDrawing, let opened = beginDrawFrame else { return false }
        return timebase.owner === self || opened < timebase.frame
    }

    /// 描き場所へ描き切る。**投げない。**
    ///
    /// 毎フレーム呼ばれるので、1 段の失敗でフレームごと落とさない ([ADR-0020]
    /// 決定 5)。描き切れなかったときは前の絵がそのまま残り、理由が知らされる。そのフレームは
    /// 描かずに捨てるので、置いた図形も書いた画素も次のフレームへ持ち込まない ([#1678])。頼んだ
    /// 計算も走らせないが、描き切りより前に GPU へ流れた分 (``read(_:)`` の前・数の並びへの書き込みの
    /// 前・別の面のぶつかる頼みの前に頼んだもの) は取り消せない。
    ///
    /// **この面の形の組み立て (``createShape(_:)``) の中で呼ぶと、そこでは閉じない** ([#1855])。1 度
    /// 注意して、組み立ての出口 (入れ子なら一番外) で閉じる。それまでに組み立てたものは形に入り、
    /// フレームには描かれない。**出口までは、この面はまだ描いている扱いである** — 組み立ての残りで
    /// ``beginDraw()`` を呼ぶと、開いたフレームが続いていると注意して何もせず、別の面へ置く
    /// (`image(pg)` など) と、描き切る前の絵 (前のフレームまでの絵) を読む。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    public func endDraw() {
        guard isDrawing else {
            // 捨てたことを名乗るのは 1 度だけ。2 度目からは、`beginDraw()` を書いていない誤りである
            guard droppedAtTheMainFrame else { return warnNotDrawing() }
            droppedAtTheMainFrame = false
            return warnEndDrawAfterFrameDropped()
        }
        // `draw { }` が開いたフレームは、閉包を抜けるときに `draw` が閉じる。ここで閉じると
        // 閉包が戻った後に `draw` がもう一度描き切り、番号も 2 つ進む
        guard beginDrawFrame != nil else { return warnFrameCallInsideFrame("endDraw") }
        // **自分の形の組み立ての中では、ここで閉じない** ([#1855] の案 G)。閉じる描き切りが組み立ての
        // 区間を空にし、形が空になっていた (#1588 の安全網)。1 度注意して、一番外の組み立ての出口で
        // 閉じる (``closeFrameAwaitingShape()``)。それまでに置いたものも形に入る
        //
        // [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        guard !recordingShape else { return awaitFrameEndInsideShape() }
        do {
            try endFrame()
        } catch {
            Diagnostics.warn("endDraw(): could not finish drawing: \(error.headline)")
        }
    }

    /// フレームの始まり。**3 つの入口が同じここを通る** — 描き方が入口ごとに
    /// 分かれると、描き場所でだけ成り立たない性質が生まれる。
    ///
    /// **ここと ``abandonFrame()`` が戻す状態は、境目の検査が 1 つずつ見る**
    /// (`CanvasTests.frameStateResetsAtEveryBoundary`)。`Canvas` の格納を 1 つ足したら、
    /// フレームに属するか持ち越すかをその検査の表に書く — どちらにも無ければ赤になる
    /// ([#1671])。戻し落としは、これまで 1 件ずつ見つかっていた (#925・#1472・#1504・#1591)。
    ///
    /// [#1671]: https://github.com/mokume-metal/mokume/issues/1671
    private func beginFrame() {
        if leftOpenAcrossBoundary {
            // **閉じ忘れたフレームは、描かずに捨てる** ([#1622])。`beginDraw()` / `endDraw()` は
            // 対で開いて閉じる操作で、積む・降ろすと同じく 1 つのフレームの中で釣り合う。直す前の
            // `beginDraw()` は注意だけで帰っていたので、前のフレームで書いた変換が次の描き直しに
            // 積み上がり、閉じ忘れた 1 枚の続きとして描かれた。捨てる場所を入口ではなくここに
            // 置くのは、次のフレームが `draw { }` から来ても同じにするため。描き場所の閉じ忘れは
            // ここへ来る前に、本体のフレームが始まる所が捨てている (``dropFrameLeftOpen(before:)``)
            //
            // [#1622]: https://github.com/mokume-metal/mokume/issues/1622
            warnUnfinishedFrameDropped()
            dropFrameLeftOpen()
        }
        // 閉じ忘れたフレームを捨てた後で見る — 捨てたフレームの中で置いたものは区間の中である
        checkNothingPlacedOutsideTheRegions()
        // 時刻の置き場の持ち主だけが、本体のフレームを数える (``Timebase/frame``)
        if timebase.owner === self {
            // **番号を進める前に、同じ置き場の描き場所の閉じ忘れたフレームを捨てる** ([#1834])。
            // 境目を越えたまま残すと、越えたフレームを読む口・描き切らせる口 (他の面の描き換え・
            // 数の並びの読み・遅れた `endDraw()`) が、捨てるはずの中身を描いた。越えた状態を
            // 作らないので、越えた後の口はどれも今ある「フレームの外」の扱いに落ちる
            // (ADR-0021 決定 4 の 2026-10-02 の改訂)
            //
            // [#1834]: https://github.com/mokume-metal/mokume/issues/1834
            let next = timebase.frame + 1
            for entry in timebase.layers { entry.canvas?.dropFrameLeftOpen(before: next) }
            timebase.frame = next
            // **保存し直した断片は、本体のフレームの頭で読み直す** ([#1830])。main actor を譲らずに
            // フレームを回す経路 (ランタイムの `advance()` も、面を直に回すループも) でも、次の
            // フレームに届くのはここで取るからである。描き場所 (持ち主でない面) のフレームでは
            // 取らない — 描き場所は本体のフレームの中で描かれるので、そこで取ると外のフレームの
            // 途中で組み直し、1 つのフレームの中で古い断片と新しい断片が混ざる
            // (``FileWatcher`` の「扱うのは、印を取った側」)
            //
            // [#1830]: https://github.com/mokume-metal/mokume/issues/1830
            FileWatcher.takeChanges()
        }
        // **組み立て中の形もフレームを越えない** (ADR-0021 決定 4 の追補 (2026-09-27)・
        // [#1591])。頭で捨てるのは、`setup()` や止まっている間のコールバックで開いたまま
        // 抜けた形に、このフレームの点を積ませないため (終わりの側は `abandonFrame()`)
        //
        // [#1591]: https://github.com/mokume-metal/mokume/issues/1591
        discardShapeLeftOpen()
        style.clip = nil
        // 効果もフレームを越えない (ADR-0021 決定 4)。毎フレーム書き直す
        pendingEffects.removeAll(keepingCapacity: true)
        transform = .identity
        // **積んだ履歴もフレームを越えない** (同 決定 4 の追補・[#925])。積むのは変換と
        // スタイルの 2 つで、どちらの寿命に属する状態を積んだかによらず、積んだ事実は
        // フレームに属する — 片方だけ残すと `push()` が半分だけ効く形になる
        //
        // [#925]: https://github.com/mokume-metal/mokume/issues/925
        transformStack.removeAll(keepingCapacity: true)
        styleStack.removeAll(keepingCapacity: true)
        hasLoadedPixels = false
        // 光もフレームを越えない (同 決定 4)。ここで空に戻る
        activeLights.removeAll(keepingCapacity: true)
        activeSurroundings = nil
        lightStorage.removeAll(keepingCapacity: true)
        passesThisFrame = 0

        isDrawing = true
        beginDrawFrame = nil
        droppedAtTheMainFrame = false
        // **自分を置いた面には、断片の面の記録を取り直させる** (``paintSurfacesNoted``)。控えを
        // 持つ面は、自分を読む図形を積んでも記録を飛ばすので、描き始めた後に置いた図形の
        // 「描き切る前に置いた」の注意が出なくなる。自分を置いた面はどれも ``placers`` に居る
        for entry in placers { entry.canvas?.paintSurfacesNoted = nil }
    }

    /// 閉じ忘れたフレームを、**描かずに捨てる** ([#1622])。注意は呼ぶ側が言う (捨てる時点で
    /// 起きたことが違う)。
    ///
    /// 番号は進める。番号はフレームの境目の印で、粒の繰り越し (#1468) と焼き場の頁 (#1342) が
    /// 読む — 進めないと、捨てたフレームと次のフレームが同じ 1 枚に数えられる。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    private func dropFrameLeftOpen() {
        framesDrawn += 1
        // 持ち主なら本体のフレームの数も進める (粒の `wander` の揺れ・[#1909])。描き場所を本体の
        // 頭で捨てるときは進めない — 数えるのは持ち主のフレームだけである
        //
        // [#1909]: https://github.com/mokume-metal/mokume/issues/1909
        if timebase.owner === self { timebase.mainFramesDrawn += 1 }
        // 捨てたフレームで積んだ力も落とす。出した粒 (`emit`) は状態の並びへ直に積まれて
        // いて (#934 で持ち越す)、取り消せない
        for (particles, before) in forcesThisFrame {
            particles.value?.dropForces(after: before)
        }
        leaveFrame()
    }

    /// **本体のフレーム `frame` が始まる所で、それより前のフレームに属したまま描き場所が開いている
    /// なら、描かずに捨てる** ([#1834])。捨てる規則はこの 1 つである。
    ///
    /// 本体のフレームが始まる所は 2 つある。持ち主の頭 (``beginFrame()``。`frame` は新しい番号) と、
    /// 持ち主が持ち越しの区間に入るとき (``carriesOver``。`frame` は次に描くフレームの番号) である。
    /// 止まっている間のコールバックは次に描くフレームに属するので、`noLoop()` で止まっていて頭が
    /// 来なくても、止まる前のフレームに属したものは区間に入る前に捨てる。属するフレームは開いた
    /// ときに決まる (``Timebase/frameForOpening``) ので、`setup()` や止まっている間のコールバックで
    /// 開いて次の `draw()` で閉じる対・ある回のコールバックで開いて別の回で閉じる対は、同じ
    /// フレームの中に居て捨てない。本体のフレームが終わってから次の頭までの間も、まだ同じフレーム
    /// である (境目は頭)。
    ///
    /// 捨てた後はフレームの外に居る。描き切りの終わり (``endFrame()``) と同じ所へ落ちるので、
    /// 越えた後に読めば捨てる前の絵が返り、置けば注意して置かない。遅れて呼んだ ``endDraw()`` は
    /// 既に捨てたことを言う (``droppedAtTheMainFrame``)。
    ///
    /// **``draw(_:)`` が開いたフレームは捨てない** — 閉包を抜けるときに同じ呼び出しが閉じる
    /// (閉包の中から本体のフレームを回した場合も、そのまま続く)。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private func dropFrameLeftOpen(before frame: Int) {
        // 前に捨てたことを名乗る印は、次の区切りまで (``droppedAtTheMainFrame``)
        droppedAtTheMainFrame = false
        guard isDrawing, let opened = beginDrawFrame, timebase.owner !== self, opened < frame else {
            return
        }
        warnFrameDroppedAtTheMainFrame()
        dropFrameLeftOpen()
        droppedAtTheMainFrame = true
    }

    /// 本体のフレームが始まる所で閉じ忘れたフレームを捨ててから、まだ遅れた ``endDraw()`` を
    /// 名乗っていないか ([#1834])。遅れて呼んだ `endDraw()` が、起きたことを名乗るのに読む。
    ///
    /// 立てるのは ``dropFrameLeftOpen(before:)`` だけである。下ろすのは、1 度名乗ったとき
    /// (``endDraw()``)・次に本体のフレームが始まる所・この描き場所の次のフレームの頭
    /// (``beginFrame()``) で、捨ててから時間が経った `endDraw()` だけの誤りは ``Warning/notDrawing``
    /// として出る。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private(set) var droppedAtTheMainFrame = false

    /// 形の組み立ての中で閉じようとした自分のフレームを、一番外の組み立ての出口まで待たせているか
    /// ([#1855] の案 G)。
    ///
    /// 立てるのは組み立ての中で自分のフレームを閉じる 2 口 — ``endDraw()`` と、組み立ての中で開いた
    /// ``draw(_:)`` の閉包の終わり — だけ (``awaitFrameEndInsideShape()``)。下ろすのは一番外の出口が
    /// フレームを閉じるとき (``closeFrameAwaitingShape()``) と、フレームの外へ出たとき (``leaveFrame()``。
    /// 待たせている間にフレームが捨てられたら、閉じるものはもう無い)。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    private(set) var frameEndAwaitingShape = false

    /// 組み立ての中で自分のフレームを閉じようとした口が、閉じずに出口まで待たせる ([#1855] の案 G)。
    /// 1 度注意する。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    private func awaitFrameEndInsideShape() {
        frameEndAwaitingShape = true
        warnInsideShape(.frameEnd)
    }

    /// 組み立ての中で待たせたフレームを、ここで閉じる ([#1855] の案 G)。**一番外の組み立ての出口が、
    /// 状態を戻した後に呼ぶ** — 閉じる側 (``abandonFrame()``) が既定へ戻した値を、出口が組み立て前の
    /// 値で書き戻さない。
    ///
    /// ``endDraw()`` を通さずに閉じる。待たせた口が `draw { }` の閉包の終わりなら、開いたのは
    /// `draw { }` で、``endDraw()`` は「`draw { }` が閉じる」と断る。どちらの口でも、閉じるのは
    /// ``endDraw()`` と同じく投げない (出口は投げられない) — 描き切れなければ理由を知らせ、前の絵が残る。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    func closeFrameAwaitingShape() {
        guard frameEndAwaitingShape else { return }
        frameEndAwaitingShape = false
        do {
            try endFrame()
        } catch {
            Diagnostics.warn(
                "createShape { }: could not finish drawing the frame closed at the end of the "
                    + "shape: \(error.headline)")
        }
    }

    /// フレームの頭で、**区間の外で置いたものが溜め場に残っていないか**を見る ([#1672])。
    ///
    /// 置いてよいのは区間の中 (``canPlace``) だけで、区間の外では図形が溜め場に入る口がそれぞれ
    /// 断る。**断る口を 1 つ書き落としても、ここで拾う。** 前のフレームは描き切りか捨てる道で
    /// 溜め場を空にして終わるので、頭で何か残っていれば、フレームの外で置いたものである。
    /// 持ち越しの区間で置いたもの (区間を出たときの量 ``carriedOverAmount`` まで) だけが、約束どおり
    /// 残ってよい。
    ///
    /// 口を列挙して守る形は採らない。#1592 の一覧は、合流点 14 か所のうち 2 か所を取りこぼして
    /// いた (#1603 の判断材料)。溜め場の並びは捨てる側と同じもの (``hasNothingPending``) を読む。
    ///
    /// 見つけたら、漏れたものを描かずに捨て (溜めない)、1 度だけ注意する。**止まるのは mokume の
    /// 検査の中だけ** ([#1682]) — 検査の全体がこの 1 行の上で「全検査を通して漏れが 0」を確かめる
    /// (どの検査で置いた図形が漏れても、その検査がここで止まる)。漏れは口の守りの足し忘れ、つまり
    /// mokume の中の不具合でしか起きないので、利用者の作品 (debug 組みを含む) を止めずに名乗る。
    ///
    /// [#1592]: https://github.com/mokume-metal/mokume/issues/1592
    /// [#1603]: https://github.com/mokume-metal/mokume/issues/1603
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    /// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
    private func checkNothingPlacedOutsideTheRegions() {
        defer { carriedOverAmount = nil }
        // 持ち越しの区間の中でフレームを開いた (`setup()` で本体の面の `draw { }` を呼んだ)。
        // 区間はまだ閉じていないので量は覚えていないが、溜まっているものはどれも区間の中で
        // 置いたものである
        guard !carriesOver else { return }
        guard pendingAmount > (carriedOverAmount ?? 0) else { return }
        placementsFoundOutsideRegions += 1
        discardPending()
        pendingBackground = nil
        warnOnce(.placementLeak, Self.placementLeakNotice)
        if stopsOnPlacementOutsideRegions {
            assertionFailure(
                "Something was placed outside a frame and outside setup() and the stopped "
                    + "callbacks, and no guard refused it. Add `guard canPlace else { return "
                    + "warnOutsideFrame(.placing) }` to the function that stores it (#1672)")
        }
    }

    /// フレームの頭の検め (``checkNothingPlacedOutsideTheRegions()``) が、区間の外で置いたものを
    /// 見つけた回数 (作ってから通算)。検め自身を確かめる検査が読む。
    var placementsFoundOutsideRegions = 0

    /// 見つけたときに止まるか。**既定は mokume の検査の中かどうか** (``SelfTest/isRunning``・[#1682])
    /// — 検査の中では立っていて、漏れを作ればその検査が止まる。利用者の作品の中では下りていて、
    /// 注意 (``placementLeakNotice``) だけが出る。検め自身を確かめる検査は、下ろして数を見る。
    ///
    /// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
    var stopsOnPlacementOutsideRegions = SelfTest.isRunning

    /// 置き漏れを見つけたときの注意。**利用者のコードの誤りではなく mokume の不具合**なので、
    /// 直し方ではなく報告を頼む (`RenderFailure` の `workDropped` と同じ書き方)。
    static let placementLeakNotice =
        "Something was placed outside a frame through a path that mokume does not guard, so it "
        + "was dropped without being drawn. This is most likely a fault inside mokume — please "
        + "report it with this message at https://github.com/mokume-metal/mokume/issues (#1672)"


    /// フレームの終わり。溜めたものを描き切り、シーンの記述を戻す。
    private func endFrame() throws(RenderFailure) {
        // **閉じたフレームをもう一度閉じない。** 描き切りと番号の進みが二重になる。入口
        // (`endDraw()`・`draw { }`) が開いているかを見ているが、ここでも守る
        guard isDrawing else { return }
        // **シーンの記述はフレームを越えない** (ADR-0021 決定 4)。視点・変換・切り抜き・
        // 光・周囲と、開いたままの形 (#1591) は**描き終えてから**既定へ戻す (`abandonFrame()`)
        // — 始まりでだけ戻すと、フレームの外 (止まっている間のコールバック・描き場所の
        // `endDraw()` の後) で置いた図形と読んだ座標にだけ、
        // 前のフレームが最後に残したものが効く ([#1472]・[#1504])。列を閉じるのに視点と
        // 切り抜きと光が要り、影の焼き付けも flush の中で光を読むので、戻すのは flush の後
        //
        // 光の置き場 (`lightStorage`) は次のフレームの頭まで空にしなくてよい。置き場を
        // 指しうる列は flush と下の `discardFrame()` が全部捨て、外で閉じる列は光が空なので
        // 区間も常に空になる — 前のフレームの置き場を指す区間は生まれない
        //
        // [#1472]: https://github.com/mokume-metal/mokume/issues/1472
        // [#1504]: https://github.com/mokume-metal/mokume/issues/1504
        //
        // 溜めたものも書いた画素もフレームを越えない。`defer` は投げても走るので、どの経路を
        // 通ってもここでフレームの外に落ちる (``leaveFrame()``)
        defer { leaveFrame() }
        isDrawing = false
        framesDrawn += 1
        if timebase.owner === self { timebase.mainFramesDrawn += 1 }

        // 焼き付けが読むのと同じ光を、描き切りの前に読む (投げても設定の誤りは知らせる)
        warnIfShadowHasNoCaster()
        try flush()
    }

    /// **フレームの外へ出る。** 描き切った後 (``endFrame()`` の `defer`) と、閉じ忘れたフレームを
    /// 描かずに捨てるとき (``dropFrameLeftOpen()``) が、ここ 1 つを通る ([#1834])。
    ///
    /// 出た後の状態を道ごとに並べると、並べ落とした道でだけ「フレームの外」が違う形になる。
    /// 本体の頭で捨てた描き場所は、描き切らずにフレームの外へ出る唯一の道で、描き切りの後と
    /// 同じ外に居なければならない (読む口・置いた面からの描き切りが、捨てる前の絵を読む)。
    /// 頭でだけ戻す状態 (積んだ履歴・効果・光の置き場・描き切った回数) は、どの道の後も同じく
    /// 次のフレームの頭まで残る。描き切った回数をフレームの外で読む口は描き切りの入口だけで、
    /// そこはフレームの外をフレームの最初と取り違えない (``flush(applyingEffects:mirroringPixels:)``)。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private func leaveFrame() {
        isDrawing = false
        // 組み立ての出口まで待たせた `endDraw()` は、閉じるフレームがもう無い (#1855)
        frameEndAwaitingShape = false
        abandonFrame()
        // **溜めたものもフレームを越えない。** 描き切りは 6 箇所から投げるので、片付けを成功経路の
        // 末尾だけに置くと、描けなかったフレームの図形が次のフレームでもう一度描かれる (#342)。
        // 書いた画素も同じで、写しの書き込み待ちを残すと次の描き切りが面へ戻す (#1678)
        discardFrame()
        trimPlacedPictureCopies()
        // **読んだ写しもフレームを越えない** ([#1524] の反証 2-2)。写しはフレームの途中で
        // 読んだ絵のまま残るので、取っておいた窓 (``pixels``) へ止まっている間のコールバックで
        // 書くと、フレームの途中の古い絵へ書いて全面を書き戻していた。ここで下ろせば、止まって
        // いる間の最初の読み書きがフレームの終わりの絵を読み直す (書く口は書く前に読む)
        //
        // [#1524]: https://github.com/mokume-metal/mokume/issues/1524
        hasLoadedPixels = false
    }

    /// フレームの終わりに、**シーンの記述と開いたままの操作を既定へ戻す。** 溜めたものには
    /// 触らない (それは ``discardFrame()``)。
    ///
    /// 通る道は 2 つある。描き切った後 (``endFrame()`` の `defer`) と、閉じ忘れたフレームを
    /// 描かずに捨てるとき (``dropFrameLeftOpen()``・[#1622]・#1834) で、どちらも ``leaveFrame()`` から
    /// 呼ぶ。並びを 1 か所に置くのは、
    /// 戻す状態を境目の関数ごとに手で並べると、並べ落とした状態だけが越えるからである
    /// ([#1671])。
    ///
    /// **描き切る道では、flush の後に呼ぶ** (光と周囲と視点を列が閉じるときに読む・[#1504])。
    /// 捨てる道は描き切らないので、順序の制約は無い。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1671]: https://github.com/mokume-metal/mokume/issues/1671
    private func abandonFrame() {
        // 奥行きの引き継ぎはフレームの終わりで切る。終わりの描き切りは奥行きを捨てるので、
        // 描き切れなかったフレームも含めて、次に引き継ぐ奥行きは無い (#1888)
        depthIsHeld = false
        beginDrawFrame = nil
        cameraStorage = nil
        transform = .identity
        style.clip = nil
        activeLights.removeAll(keepingCapacity: true)
        activeSurroundings = nil
        style.material = .default
        shadowsEnabled = false
        shadowRangeValue = nil
        shadowDetailValue = ShadowMap.defaultDetail
        shadowBiasValue = ShadowMap.defaultBias
        style.castsShadow = true
        style.receivesShadow = true
        // **組み立て中の形もフレームを越えない** ([#1591])。終わりで捨てるのは、`draw()` で
        // 開いたまま抜けた形を、止まっている間のコールバックへ漏らさないため (頭の側は
        // `beginFrame()`)
        //
        // [#1591]: https://github.com/mokume-metal/mokume/issues/1591
        discardShapeLeftOpen()
    }

    /// 同じ本体のフレームの中で ``beginDraw()`` を重ねたことを、初回だけ知らせる。境目を越えて
    /// いないので、開いているフレームがそのまま続く。
    private func warnAlreadyDrawing() {
        warnOnce(
            .alreadyDrawing,
            "beginDraw(): endDraw() has not been called yet for the beginDraw() earlier in this "
                + "frame. This call does nothing, and drawing continues in the frame already open")
    }

    /// 閉じ忘れたまま境目を越えたフレームを捨てたことを、初回だけ知らせる ([#1622])。言うのは
    /// 時刻の置き場の持ち主 (本体・直に使う面) で、描き場所は本体のフレームの頭で捨てたことを
    /// 言う (``warnFrameDroppedAtTheMainFrame()``)。
    ///
    /// **入口の名前を名乗らない。** 捨てるのはフレームの始まり (`beginFrame()`) で、次の
    /// フレームは `beginDraw()` からも `draw { }` からも来る。直す先はどちらでも、閉じ忘れた
    /// 側の `endDraw()` である。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    private func warnUnfinishedFrameDropped() {
        warnOnce(
            .unfinishedFrameDropped,
            "endDraw() was not called for a beginDraw() in an earlier frame, so that frame was "
                + "dropped without being drawn, and drawing starts over from here")
    }

    /// 描き場所の閉じ忘れたフレームを、本体のフレームの頭で捨てたことを、初回だけ知らせる
    /// ([#1834])。鍵は ``warnUnfinishedFrameDropped()`` と共有する (捨てた事情は同じ 1 つ)。
    ///
    /// **「ここから描き始め直す」とは言わない。** 捨てた後の描き場所はフレームの外に居て、次に
    /// 開くのは作者の `beginDraw()` である。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private func warnFrameDroppedAtTheMainFrame() {
        warnOnce(
            .unfinishedFrameDropped,
            "endDraw() was not called for a beginDraw() on this canvas before the main frame moved "
                + "on, so that frame was dropped without being drawn")
    }

    /// ``draw(_:)`` が開いたフレームの中で、フレームを開く・閉じる口を呼んだことを、初回だけ
    /// 知らせる。入口は 3 つで事情は 1 つなので鍵を共有し、文面は口ごとの全文にする。
    private func warnFrameCallInsideFrame(_ name: String) {
        switch name {
        case "beginDraw":
            warnOnce(
                .frameCallInsideDraw,
                "beginDraw(): this canvas is already inside a frame opened by draw { }, which "
                    + "closes it on its own. This call does nothing")
        case "endDraw":
            warnOnce(
                .frameCallInsideDraw,
                "endDraw(): this canvas is inside a frame opened by draw { }, which closes it on "
                    + "its own when the block returns. This call does nothing")
        default:
            warnOnce(
                .frameCallInsideDraw,
                "draw(): this canvas is already inside a frame, so the block runs as part of that "
                    + "frame instead of opening a new one")
        }
    }

    private func warnNotDrawing() {
        warnOnce(
            .notDrawing, "endDraw(): this came before beginDraw(). This call does nothing")
    }

    /// 本体のフレームの頭で捨てた後に、遅れて ``endDraw()`` を呼んだことを、初回だけ知らせる
    /// ([#1834])。**捨てたフレームは描かない** — 描くと、捨てるはずの中身が面に載る。
    ///
    /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
    private func warnEndDrawAfterFrameDropped() {
        warnOnce(
            .endDrawAfterFrameDropped,
            "endDraw(): the frame opened by beginDraw() was already dropped without being drawn, "
                + "because the main frame moved on before endDraw() was called. This call does nothing")
    }

    // MARK: - 置いた時点の絵を守る

    /// 描き場所を置いたことを、両側に覚えさせる。
    ///
    /// **置く口の追い付きもここが持つ** ([#2042])。描き場所の出す先を読む口のうち、面を置く口
    /// (`image(canvas)`・`texture(canvas)`・断片の面・畳む口) はどれもここを通り、置いた時点で相手の
    /// 出す先を描き切れている絵へ追い付かせる。**出す先を読む口の登録簿は、原文を読む検査
    /// (`StoppedUpscaleOutletReadersTests`) が持つ** ([#2104]) — 出す先を読む行はどれも、ここ (置く口)・
    /// 読む口 (``RenderTarget/catchUpWithDrawnPicture()``)・ランタイムの配った後・わざと古い、のどれで
    /// 追い付くかを名乗る。出す先を書く側の関所 (``settlePlacersBeforeChange()`` と、最下層の検算
    /// `RenderTarget.assertPlacersSettledBeforeWriting()`) と対になる読む側の守りで、置く口を足すときは
    /// ここを通し、一覧に名乗りごと足す。ここを通し忘れると、相手の `placers` が空のままなので書く側の
    /// 検算も黙る。
    ///
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    /// [#2104]: https://github.com/mokume-metal/mokume/issues/2104
    func note(placing graphics: Canvas) {
        // **面に載らない区間では記録しない。注意もしない** ([#1672])。記録は置いた時点の絵を
        // 守るためのもので、区間の外では置いたもの自体が断られる (``canPlace``)。`setup()` で
        // 描き場所を貼る (`texture(pg)`) のは描き方を決めるだけで正当なので、黙って飛ばす。
        //
        // **形の組み立ての中も飛ばす** (フレームの中でも外でも)。組み立てた図形は形へ抜かれ、
        // 形を置くときに記録し直す (``useTexture(_:)`` / ``notePaintPlacement()``)。記録すると、
        // 守る絵の無い印が溜め場に残り (#1592 では相手の `placers` も伸びていた)、描いている
        // 最中の描き場所を読む塗りで組み立てただけで、置いていないのに下の注意が出る (#1683)
        //
        // 記録は置いた時点で取る。列を閉じる時点 (フレームの終わりの描き切りを含む) では取らない
        // ので、描き切りの最中を区間に数える必要は無い
        //
        // [#1592]: https://github.com/mokume-metal/mokume/issues/1592
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard writesToSurface, !recordingShape else { return }
        guard graphics !== self else { return }
        // **描き切る前に置いたら知らせる。** 出るのは前のフレームか途中の区切りまでの絵で、しかも
        // 「それらしい絵」なので、黙っていると自分のコードを疑うしかない
        // ([ADR-0020] 決定 5)
        //
        // **読む口は 3 つあるので、どれも名指す** (#1683 の反証)。画像として置く `image()`、
        // 貼る `texture()`、断片の面 (`surfaces`) のどれで読んでもここへ来る。1 つだけを名指すと、
        // 他の口で読んだ人は直す先を探せない
        if graphics.isDrawing {
            warnOnce(
                .placingWhileDrawing,
                "A drawing target was read before its endDraw() was called, through image(), "
                    + "texture() or a shader's surfaces. What comes out is the frame as it stood "
                    + "before it was finished. Call endDraw() on it before placing what reads it")
        }
        // **置いた時点で、相手の出す先を描き切れている絵へ追い付かせる** ([#2042])。置く口はどれも
        // ここを通るので、追い付きもこの 1 か所に置く (口ごとに書かない)。記録より前に通す — 追い付きは
        // 出す先を書く前に、先に置いた分へ置いた時点の絵を写させ、その記録を落とす
        //
        // [#2042]: https://github.com/mokume-metal/mokume/issues/2042
        graphics.catchUpOutputForPlacing(by: self)
        // **記録済みなら相手へは載せ直さない** (#1683 の反証 2 回目)。貼る絵の記録は置くたびに
        // 来るので、相手の `placers` を毎回探さない。こちらの記録と相手の `placers` は組で、
        // 相手が `placers` を空にするときはこちらの記録も落とす (``keepPicture(placedFrom:)``)
        guard placedGraphics.insert(ObjectIdentifier(graphics)).inserted else { return }
        graphics.note(placedBy: self)
    }

    private func note(placedBy canvas: Canvas) {
        guard !placers.contains(where: { $0.canvas === canvas }) else { return }
        placers.append(WeakCanvas(canvas: canvas))
    }

    /// 自分の絵が変わる前に、自分を溜めている面に、置いた時点の絵を持たせる。
    ///
    /// **置いた側を描き切らせない** ([#1656] の案 A2)。描き切らせるとフレームの途中の区切りに
    /// なり、利用者が呼んでいない区切りで絵が割れる (区切りより前の面が、後に置いた立体の影を
    /// 受けない)。代わりに置いた側が、いまの絵を写しへ取って読む面を差し替える
    /// (``keepPicture(placedFrom:)``)。
    ///
    /// **自分の出す先 (``output``) を書く口は、書く前に必ずここを通る** ([#1942])。描き切り
    /// (``flush(applyingEffects:mirroringPixels:)``) のほかに、描き切りの外で出す先を書く口が 4 つある:
    /// 細かさを下げた面の追い付き (``catchUpOutput()``)・細かさ 1 の面の書き戻し
    /// (``writeBackPendingPixels()``)・出力段の書き戻し (``RenderTarget/encodeToImage()`` ほか)・
    /// 出す先を直に塗る ``RenderTarget/fill(with:)``。新しい口を足すときは、書く前にここを通す。
    /// **この列挙は出す先を書く口の登録簿で**、通し忘れは、出す先を書く最下層が呼ぶ検算
    /// (`RenderTarget.assertPlacersSettledBeforeWriting()`) が debug の検査で捕まえる。
    /// 写しを取るのは出す先が実際に変わる口だけで、変えていない口は呼ばない (ADR-0023 決定 5)。
    /// 細かさを下げた面の途中の描き切りは、フレームの中でも外でも出す先を読まれる前に必ず広げ直すので、
    /// 変わる口に数える ([#2042]・[#2103]・``flush(applyingEffects:mirroringPixels:)``)。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    /// [#1942]: https://github.com/mokume-metal/mokume/issues/1942
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    func settlePlacersBeforeChange() {
        guard !placers.isEmpty else { return }
        // **先に空にする。** 描き切らせた先から置き直されることがあるので、
        // 走らせたあとに消すと、そのフレームの記録まで一緒に落ちる
        let waiting = placers
        placers.removeAll(keepingCapacity: true)
        for entry in waiting { entry.canvas?.keepPicture(placedFrom: self) }
    }

    /// この描き場所を溜めているなら、置いた時点の絵を写しへ取り、溜めた列が読む面を差し替える
    /// ([#1656])。
    ///
    /// **描き切っている最中なら何もしない。** 列を積んでいる最中に差し替えない。
    ///
    /// **形を組み立てている途中でも写す** ([#1855] の案 E)。ただし差し替えるのは**組み立ての入口より
    /// 前の列** (``shapeRecordingRunStart``) だけ — 組み立てた形は溜めた列から抜かれて持ち歩かれる
    /// ので、写しへ差し替えると、後で置いたときに描き場所のいまの絵ではなく写しを読み続ける。以前は
    /// 組み立ての途中なら写さずに描き切り、組み立てた区間を失わせていた (空の形・#1588 の安全網)。
    ///
    /// 写しを用意できなかったときと、写しの上限 (``placedPictureCopyLimit``) に達したときは描き切る
    /// (置いた時点の絵を守るほうを取る)。そこでは置いた側にフレームの途中の区切りが入り、組み立ての
    /// 途中なら出口の安全網が空の形を返す。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    private func keepPicture(placedFrom graphics: Canvas) {
        let placed = ObjectIdentifier(graphics)
        guard placedGraphics.contains(placed) else { return }
        // **相手の `placers` から外れたので、こちらの記録も落とす。** 記録が残ったままだと、
        // 次に置いたとき記録済みとして相手へ載せ直さず (``note(placing:)``)、相手が次に変わる
        // 前に写しを取らせてもらえない。差し替えた列はもう写しを読むので、相手に縛られない
        defer {
            placedGraphics.remove(placed)
            placedGraphicsDrops &+= 1
        }
        guard !isFlushing else { return }
        do {
            if try copyPlacedPicture(graphics.output.texture) { return }
            placedPictureCopyLimitReached += 1
        } catch {
            Diagnostics.warn(
                "Could not keep a copy of a drawing target before it changed, so what was "
                    + "placed is drawn out first: \(error.headline)")
        }
        do {
            // 効果はフレームの終わりに立つ段なので、途中の描き切りでは通さない
            try flush(applyingEffects: false)
        } catch {
            Diagnostics.warn(
                "Could not finish drawing before the drawing target changed: \(error.headline)")
        }
    }

    /// 置く口の内側から、自分が溜めている `graphics` の置いた時点の絵を写しへ取る ([#2042])。
    /// **描き切りへは逃げない。**
    ///
    /// 置く口の追い付き (``catchUpOutputForPlacing(by:)``) は、出す先を書く前に置いた側へ写させる。
    /// 置く側自身もそこに居ると、``keepPicture(placedFrom:)`` の逃げ道 (写しの上限・写しの失敗での
    /// 描き切り) が置く口の内側で走り、前置きを済ませてから記録へ来る呼び手を壊す。置く側自身の分は
    /// ここで写しだけを試し、写せなければ追い付きを見送らせる。
    ///
    /// 置く側自身が溜めているのは、追い付きが前に失敗した後に置いた分だけである — 途中の描き切りは、
    /// フレームの中でも外でも、その時点で置いた側へ写させている (``flush(applyingEffects:mirroringPixels:)``・
    /// [#2103])。
    ///
    /// - Returns: 溜めていないか、写しへ差し替えたら `true`。写せなければ `false` で、記録は残す
    ///   (追い付いた後に読む口が、置く口の外から写させる)。
    ///
    /// [#2103]: https://github.com/mokume-metal/mokume/issues/2103
    func keepPictureWithoutFlushing(placedFrom graphics: Canvas) -> Bool {
        let placed = ObjectIdentifier(graphics)
        guard placedGraphics.contains(placed) else { return true }
        // **畳む雛形を組み立てている途中なら写さない。** 写すときに列を閉じるので、組み立て途中の頂点が
        // ふつうの列として閉じ、雛形から抜け落ちる
        guard !isFlushing, !recordingShape, !buildingFlatTemplate else { return false }
        // **写せないと分かっているなら、列を閉じずに返す** (写しは列を閉じてから取る)
        guard canTakePlacedPictureCopy else {
            placedPictureCopyLimitReached += 1
            return false
        }
        do {
            guard try copyPlacedPicture(graphics.output.texture) else {
                placedPictureCopyLimitReached += 1
                return false
            }
        } catch {
            Diagnostics.warn(
                "Could not keep a copy of a drawing target before it changed, so it is placed as "
                    + "it stood before it was drawn out: \(error.headline)")
            return false
        }
        // 相手の `placers` とこちらの記録は組なので、両方から落とす (``settlePlacersBeforeChange()`` と同じ)
        placedGraphics.remove(placed)
        placedGraphicsDrops &+= 1
        graphics.placers.removeAll { $0.canvas === self }
        return true
    }

    /// `source` を読む溜めた列があれば、`source` のいまの絵を写しへ取り、その列が読む面を写しに
    /// 差し替える。
    ///
    /// 先に開いた列を閉じる — 塗りの面は列を閉じる時点で写し取るので、開いたままだと、閉じたときに
    /// 描き換えた後の絵を読む。閉じても絵は変わらない (同じ順に描く列が 2 本に分かれるだけで、
    /// 列が読む光・視点・材質はどれも、変わるときに列を閉じている)。
    ///
    /// **写すコマンドは、相手が描き換えるコマンドより先に投入される** (相手の描き切りの冒頭から
    /// 呼ばれる)。投入の順に頼らず、写す前後に待ち合わせを置く (この世代は encoder をまたぐ依存を
    /// 自動では張らない・#341) — 前は、相手の前の描画 (描画・効果・拡大の段) が書き終わるのと、
    /// 使い回す写しを前に読んでいた描画が読み終わるのを待つ。後は、写しを読む置いた側の描画と、
    /// 相手が描き換える描画が、写し終わるのを待つ。
    ///
    /// **形の組み立ての途中なら、見るのも差し替えるのも組み立ての入口より前の列だけ** ([#1855] の
    /// 案 E・``shapeRecordingRunStart``)。組み立てた列は形として抜かれ、置いたときの絵を読む。
    ///
    /// - Returns: 写しへ差し替えたか、差し替えるものが無かったら `true`。上限に達して写せなければ
    ///   `false` (呼ぶ側は置いた側を描き切らせる)。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    private func copyPlacedPicture(_ source: any MTLTexture) throws(RenderFailure) -> Bool {
        closeBatch()
        // 組み立ての途中に溜め場を捨てていれば、控えた位置は溜め場の外を指しうる (出口の安全網が
        // 空の形を返す)。そのときも溜め場の中に収める
        let placedRuns = min(shapeRecordingRunStart ?? batches.count, batches.count)
        var reads = false
        for batch in batches[..<placedRuns] {
            if batch.run.texture.texture === source { reads = true }
            for surface in batch.run.paint.surfaces where surface.texture === source {
                reads = true
            }
            if reads { break }
        }
        guard reads else { return true }
        guard let copy = try placedPictureCopy(fitting: source) else { return false }
        do {
            try gpu.withCommands { commands throws(RenderFailure) in
                guard let encoder = commands.makeComputeCommandEncoder() else {
                    throw .encoderUnavailable
                }
                // 面を書くのも写しを読むのも、断片・計算・blit の段だけである (頂点段は待たない)
                encoder.barrier(
                    afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .blit,
                    visibilityOptions: .device)
                encoder.copy(sourceTexture: source, destinationTexture: copy.texture)
                encoder.barrier(
                    afterStages: .blit, beforeQueueStages: [.dispatch, .fragment, .blit],
                    visibilityOptions: .device)
                encoder.endEncoding()
                gpu.commit(commands)
            }
        } catch {
            placedPictureCopiesFree.append(copy)
            throw error
        }
        placedPictureCopiesInUse.append(copy)
        placedPicturesCopied += 1
        let held = copy.held
        for index in 0..<placedRuns {
            if batches[index].run.texture.texture === source { batches[index].run.texture = held }
            for slot in batches[index].run.paint.surfaces.indices
            where batches[index].run.paint.surfaces[slot].texture === source {
                batches[index].run.paint.surfaces[slot] = held
            }
        }
        return true
    }

    /// 写しを 1 つ用意できるか (``placedPictureCopy(fitting:)`` が `nil` を返さないか)。上限に達していても、
    /// 空きがあれば使い回すか手放して作り直せる。
    private var canTakePlacedPictureCopy: Bool {
        placedPictureCopiesInUse.count + placedPictureCopiesFree.count < Self.placedPictureCopyLimit
            || !placedPictureCopiesFree.isEmpty
    }

    /// `source` と同じ形の写し。空きにあれば使い回し、無ければ作る。**上限に達していて使い回せる
    /// 空きも無ければ `nil`** (``placedPictureCopyLimit``)。形の合わない空きは、作る前に手放す。
    private func placedPictureCopy(fitting source: any MTLTexture) throws(RenderFailure)
        -> PlacedPictureCopy?
    {
        var found: Int?
        for (index, copy) in placedPictureCopiesFree.enumerated() where copy.fits(source) {
            found = index
            break
        }
        let copy: PlacedPictureCopy
        if let found {
            copy = placedPictureCopiesFree.remove(at: found)
        } else {
            if placedPictureCopiesInUse.count + placedPictureCopiesFree.count
                >= Self.placedPictureCopyLimit
            {
                guard !placedPictureCopiesFree.isEmpty else { return nil }
                placedPictureCopiesFree.removeFirst()
            }
            copy = try PlacedPictureCopy(gpu: gpu, like: source)
            placedPictureCopiesMade += 1
        }
        copy.lastUsedEpoch = placedPictureEpoch
        return copy
    }

    /// フレームの境目を数える番号。写しの空きのうち、1 フレーム使わなかったものを手放すのに読む。
    private var placedPictureEpoch = 0

    /// フレームの境目で、写しの空きを片付ける。直前のフレームで使わなかった写しを手放す。
    private func trimPlacedPictureCopies() {
        var kept: [PlacedPictureCopy] = []
        for copy in placedPictureCopiesFree where copy.lastUsedEpoch == placedPictureEpoch {
            kept.append(copy)
        }
        placedPictureCopiesFree = kept
        placedPictureEpoch &+= 1
    }

    /// 画素の口がいま描き切ると、形を組み立てている途中の面を描き切らせうるか ([#1588])。
    ///
    /// 途中の描き切りは冒頭で、自分を置いた面に置いた時点の絵を写させる (``settlePlacersBeforeChange()``)。
    /// 置いた面が組み立ての途中でも、組み立ての入口より前の列を写しへ差し替えるだけで描き切らせない
    /// が (#1855 の案 E)、**写しの上限に達していれば描き切らせ** (``keepPicture(placedFrom:)``)、組み立てが
    /// 控えた溜め場の区間がそこで空になる。画素の口は、自分の面だけでなく置かれた描き場所でも同じ守りに
    /// 入る — 同じフレームで `image(layer)` と置いてから、組み立ての中で `layer.get()` と読むと、本体の
    /// 組み立てが描き切られていた。**断る範囲は #1588 のまま**で、写しで済む場合も断る (緩めるかは
    /// 別に決める)。
    ///
    /// **見るのは自分を直に置いた面だけ** (#1656)。組み立ての途中でない面は写しを取って描き切られ
    /// ないので、その先へは連ならない。写しの上限・写しの失敗で描き切った面がさらに組み立ての途中の
    /// 面に置かれている形はここでは見ず、組み立ての出口の安全網が知らせる。細かさを下げた面の途中の
    /// 描き切りは出す先を変えないので、置いた面を描き切らせない。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    var isPlacedInAShapeInProgress: Bool {
        guard upscaleStage == nil else { return false }
        for entry in placers {
            guard let canvas = entry.canvas, canvas.placedGraphics.contains(ObjectIdentifier(self))
            else { continue }
            if canvas.recordingShape { return true }
        }
        return false
    }

    /// 直前のフレームで描画を呼んだ回数。
    ///
    /// **畳めているかを数えるための値。** 絵が同じでも畳まれていなければ保持は目的を
    /// 果たしていないので、絵ではなく回数で確かめる。
    private(set) var drawCallsInLastFrame = 0

    /// 直前のフレームで、描く先へのパスのエンコーダへ積んだ描く呼び出しの数。
    ///
    /// **列の数 (``drawCallsInLastFrame``) とは別に数える。** 裏面が絵に出うる置き場所を持つ
    /// 立体の列は、列の中で置き場所ごと・部品ごとに裏 → 表の 2 回で描く (``Batch/backFaceParts``) ので、
    /// 列の数は変わらずに呼び出しだけが増える。増えるのがその列だけであることを、絵ではなく
    /// 数で確かめる ([#1549](https://github.com/mokume-metal/mokume/issues/1549))。
    private(set) var drawsEncodedInLastFrame = 0

    /// 直前のフレームで積んだ平面の頂点の数。
    ///
    /// **平面が畳めているかは、描画の呼び出し回数では数えられない。** 平面は元から
    /// 1 つの列にまとまるので、畳んでも畳まなくても回数は変わらない — 変わるのは
    /// 組み立てて積む頂点の数のほうで、それが #424 で律速だったものである。
    private(set) var flatVerticesInLastFrame = 0

    /// 直前のフレームで、周 (`Outline`) から三角形を組み立てた回数。
    ///
    /// **基本図形が頂点を組み立てていないことを数える値** ([#752])。距離関数で描く
    /// 図形は周を作らないので、矩形と円だけの絵ならここは 0 になる。0 でなければ、
    /// どこかで三角形の経路 (任意多角形・貼る絵・利用者の断片、あるいは畳めなかった
    /// 雛形) を通っている。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    private(set) var flatOutlinesInLastFrame = 0
    var outlinesAssembledThisFrame = 0

    /// 直前のフレームで、並べた頂点を組み立てる間に点を舐めた延べ回数。
    ///
    /// **1 度に渡す量で二乗に効いていないことを、絵でも時間でもなく数で確かめる値**
    /// ([#915])。同じ総量を 1 塊で渡しても小分けで渡してもここが動かないなら、費用は
    /// 総量にしか比例していない。時間で見ると release でしか測れず、機械の都合で揺れる。
    ///
    /// 数えるのは 5 箇所 — 環を平らへ落とすとき・穴のために全点を落とすとき・
    /// 読み取り位置の倒れ先を作るとき・耳を切る判定で点を三角形と比べるとき
    /// ([#1595])・交わった周を探して組み直すとき ([#1538])。**どれか 1 つでも抜くと、
    /// そこへ二乗が戻っても数が動かない。**
    ///
    /// [#915]: https://github.com/mokume-metal/mokume/issues/915
    /// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
    /// [#1595]: https://github.com/mokume-metal/mokume/issues/1595
    private(set) var pointScansInLastFrame = 0
    var pointScansThisFrame = 0

    /// 検査から「描けなかったフレーム」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 描画の失敗は環境か資源が枯れたときにしか起きず、検査から自然には作れない。
    /// 一方で**描けなかったときに何が起きるか**は回帰検査を置くべき場所そのものなので
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))、ここに 1 つだけ
    /// 穴を空けてある。公開はしない。
    var failureForTesting: RenderFailure?

    /// 溜めた図形が 1 つでもあるか。
    ///
    /// **描き切りはこれを 2 度読む** — 列を積むかどうかと、描画の呼び出し回数の
    /// 計上である。かつては後者がド・モルガンで反転した三項演算子として書かれて
    /// おり、同じことを言っているのに字面が一致しなかった ([#893])。
    ///
    /// [#893]: https://github.com/mokume-metal/mokume/issues/893
    private var hasPendingGeometry: Bool {
        !vertices.isEmpty || !solidVertices.isEmpty || !formInstances.isEmpty
            || openSolid?.strokeGeometry != nil || openSolid?.fillGeometry != nil
            || batchesOwnVertices
    }

    /// 溜めた列のどれかが、自分の頂点の置き場 (立体の線の骨・モデルの塗り) を持つか。
    /// 持つ列だけのフレームでは溜め場が空のままなので、ここで拾う。閉包を標準ライブラリへ
    /// 渡さずに回す — 渡すと列ごとに隔離の実行時検査を払う (#1779)。
    private var batchesOwnVertices: Bool {
        for batch in batches where batch.ownVertices != nil { return true }
        return false
    }

    /// 描画先の絵を変えるものを、最後に描き切ってから溜めたか。
    ///
    /// **画素を読む口が描き切り直すかの判定** ([#1368])。図形 (``hasPendingGeometry``) に
    /// 塗り直しの予定を足す — 読んだあとの `background()` は図形が 1 つも無くても絵を変える。
    /// どちらも描き切りの末尾 (`discardFrame()`) で空に戻るので、別に印を持たなくても
    /// 「描き切ってから溜めたか」をそのまま表す。**図形を積む口ごとに印を立てる形は取らない** —
    /// 口が増えた日に、そこだけ黙って印が漏れる。
    ///
    /// [#1368]: https://github.com/mokume-metal/mokume/issues/1368
    var hasPendingDrawing: Bool { hasPendingGeometry || pendingBackground != nil }

    /// - Parameters:
    ///   - applyingEffects: 効果を通すか。**フレームの終わりだけ通す** —
    ///     フレームの途中の描き切り (`loadPixels()`) で通すと、効果のかかった絵の上に
    ///     続きが描かれ、しかもフレームの終わりにもう一度かかる。フレームの**境目**でも
    ///     同じことが起きないように、効果を通す前の絵を控えに残し、次のフレームの最初の
    ///     描き切りで戻す ([#1469])。
    ///   - mirroringPixels: 描き終えた絵を画素の写しへ読み戻す blit を末尾に積むか。
    ///     **画素を読む直前の描き切りだけ** `true` — 読まないフレームは 1 バイトも払わない
    ///     ([#753])。
    ///
    /// [#753]: https://github.com/mokume-metal/mokume/issues/753
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    func flush(applyingEffects: Bool = true, mirroringPixels: Bool = false)
        throws(RenderFailure)
    {
        // **自分の絵が変わる直前がここ。** 自分を溜めている面にいまの絵を写させると、
        // その面には「置いた時点の絵」が残る (#1656)。`beginDraw()` ではなくここに置くのは、
        // 描き切りが要る経路が対の外にもある (画素の読み出し) ため
        //
        // **この描き切りが描く先を変えるかは、ここで 1 度だけ数える** ([#2103])。変える操作は 3 つ:
        // 図形・背景を描く (`hasPendingDrawing`)・CPU が書いた画素を書き戻す (`hasPendingPixelWrites`)・
        // フレームの最初の描き切りで効果を通す前の絵を戻す (`restoresCarry`・[#1469])。置いた側へ写させるか
        // (すぐ下) と、拡大より後に描く先が変わった印 (``targetChangedSinceUpscale``) は、どちらもこれを
        // 読む。**描く先を変える操作を足すときは、ここへ数える** — 数え漏らすと、細かさを下げた面だけ
        // 追い付かずに前の絵が出る (戻しを数えていなかったのが #2103 の反証で見つかった)
        //
        // `drawsInFrame` ほかの意味は、下の組み立ての前の説明 (#1834・[#1913]) にある
        let drawsInFrame = isDrawing || applyingEffects
        let startsFrame = passesThisFrame == 0 && drawsInFrame
        let restoresCarry = carriesPictureBeforeEffects && startsFrame && pendingBackground == nil
        let changesTarget = hasPendingDrawing || target.hasPendingPixelWrites || restoresCarry
        //
        // **置かれるのは出す先 (``output``) なので、出す先が変わる描き切りで写させる** (#1656)。細かさを
        // 下げた面の出す先は、描き切りの中ではフレームの終わりの拡大でしか変わらない (途中の描き切りは描く
        // 先だけを変える) が、途中の描き切りでも描く先を変えるなら写させる ([#2042]・[#2103])。変えた描く
        // 先は、フレームの中でも外でも読まれる前に必ず出す先へ広げ直される (置く口の追い付き
        // ``catchUpOutputForPlacing(by:)``・コールバックを配った直後の追い付き・出す先を読む口・フレームの
        // 終わりの拡大)。写させるのを置く口の追い付きまで待つと、置く側自身の写しの代わりの描き切り
        // (``keepPicture(placedFrom:)``) が置く口の内側で走り、前置き (列・貼る絵・塗り) を済ませてから
        // 記録へ来る呼び手を壊す — 走らせなければ、写しの上限に達した後は追い付きを見送って前の絵を置く。
        // ここなら細かさ 1 の面と同じ時点・同じ作法になる
        //
        // **フレームの中で描く先を変えない途中の描き切り (何も溜めずに `get()` を呼ぶ) は写させない**
        // ([#2103])。出す先も変わらないので要らない写しで、写しの上限 (``placedPictureCopyLimit``) を
        // 食えば、置いた側に利用者が呼んでいない区切りが入る (#1656)。フレームの外ではこれまでどおり
        // 写させる。**描き切りの外で出す先を書く口は、それぞれ自分の頭で通る** (#1942。数え上げは
        // ``settlePlacersBeforeChange()``)
        //
        // [#1469]: https://github.com/mokume-metal/mokume/issues/1469
        // [#2042]: https://github.com/mokume-metal/mokume/issues/2042
        // [#2103]: https://github.com/mokume-metal/mokume/issues/2103
        if applyingEffects || upscaleStage == nil || !isDrawing || changesTarget {
            settlePlacersBeforeChange()
        }
        isFlushing = true
        defer { isFlushing = false }
        // CPU 上の列を確定し、実際に読む直前の画像更新を拾う (#1766)。配置後の
        // write と、別 Canvas の描き切りが登録簿を消費した後の write の両方を覆う。
        // 待ちが失敗しても再試行できるよう、GPU 可視メモリへ触る前に登録する。
        closeBatch()
        for batch in batches { batch.run.prepareSurfaces() }
        if let failureForTesting { throw failureForTesting }
        // **書く前に、環を 1 つ進めて待つ。** ここから先は GPU 可視メモリへ CPU が書く
        // (頂点・列ごとの値・効果の値・数の並びと画像の控え・置き場の取り直し)。書き先は
        // これから進むスロットの置き場なので、待つのは**そのスロットを最後に読んだ投入**
        // だけでよい — その先に積まれた新しいフレームの仕事まで待つ理由が無い ([#754])。
        //
        // 当初は `gpu.settle()` で投入済みの**全部**を待っていた ([#727])。置き場が
        // 1 本しか無かったので、それ以外に書ける場所が無かったためである。環にしたので、
        // 待ちは「1 周ぶん前の自分」に縮む — 置いた描き場所を N 枚使う絵で、フレーム
        // ごとに N+1 回の全ドレインが起きていたのがそれで消える。
        //
        // 詰まっていたら 1 バイトも書かずに投げ、このフレームは捨てる (`draw(_:)` の
        // `defer` が片付ける)。
        //
        // [#727]: https://github.com/mokume-metal/mokume/issues/727
        // [#754]: https://github.com/mokume-metal/mokume/issues/754
        try frameRing.advance()
        // 段の枠の採番は描き切りごとに 0 から。**1 本のコマンドの中でだけ衝突しない
        // ことが要る**ので、コマンドと同じ寿命で数える
        stagePassesUsed = 0
        // **奥行きは、引き継ぐ奥行きがあるときだけ引き継ぐ。** 途中の描き切りをまたいで引き継ぎ、
        // 塗り直しを頼まれたときだけ消す (そのフレームをそこから描き直すという意味なので)。
        // 「このフレームで描き切ったか」では決めない — フレームの最後の描き切りは奥行きを捨てる
        // ので、止まっている間の最初の描き切りに読める奥行きは無く、逆に止まっている間や
        // `setup()` で描き切った奥行きは、次のフレームの最初の描き切りが受け取る ([#1888])
        //
        // [#1888]: https://github.com/mokume-metal/mokume/issues/1888
        let continuesDepth = depthIsHeld && pendingBackground == nil
        let pass = target.makeRenderPass(
            clearColor: pendingBackground,
            continuingDepth: continuesDepth,
            keepingDepth: !applyingEffects)
        // **次のフレームの入りは、効果を通す前の絵** ([#1469])。前のフレームが描く先へ効果を
        // 通した絵を書いていたら、このフレームの最初の描き切りで控えから戻す。塗り直す
        // 描き切りでは戻さない — 戻しても消えるだけなので、毎フレーム塗り直すスケッチが
        // 払うのは控えへの写しだけになる。
        //
        // **戻すのはここで、`beginFrame()` ではない。** 自分を置いている面に絵を写させる
        // (上の `settlePlacersBeforeChange()`) より先に戻すと、置いた側が効果を通す前の絵を
        // 拾う — 置いた時点の絵は、前のフレームの出口 (効果を通した絵) である
        //
        // **フレームの外の描き切りは、フレームの最初の描き切りではない** ([#1834])。描き切った回数は
        // 頭でだけ 0 に戻るので、1 度も描き切らずに閉じたフレーム (描き切りに失敗した・閉じ忘れて
        // 捨てた) の後は 0 のまま残る。数だけで見ると、フレームの外の読む口・置いた面からの描き切りが
        // 控えを描く先へ戻し、前の絵 (効果を通した絵) をフレームの外で書き換えていた。フレームの
        // 終わりの描き切りは `isDrawing` を下ろした後に走るが、効果を通すのはそれだけである
        // (`applyingEffects`)
        //
        // [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        //
        // **時間方向の揺らしも、フレームの描き切りかで選ぶ** ([#1913]・``jitter(drawingInFrame:)``)
        //
        // [#1913]: https://github.com/mokume-metal/mokume/issues/1913
        //
        // (`drawsInFrame`・`startsFrame`・`restoresCarry` は、描く先が変わるかと一緒に頭で数えた)
        //
        // **止まっている間に変えた分は、効果を通す前の絵にも同じように加える** ([#1524])。効果を
        // 通したフレームの後、次のフレームが控えを戻すまでの間 (止まっている間のコールバック) は、
        // 描く先 (効果を通した絵・画面と読む画素はこれ) と控え (効果を通す前の絵・次のフレームの
        // 入りはこれ) の 2 枚を保つ。書いた画素は書き戻すたびに、描き切る図形・絵・背景は描き切る
        // たびに、両方へ載せる — 混ぜ方は、どちらも置いた面の上で決まる
        let changesCarry = changesGoIntoCarry && (restoresCarry || !startsFrame)
        let hasDrawing = hasPendingDrawing
        let drawsIntoCarry = changesCarry && !startsFrame && hasDrawing
        // **途中で投げたら、組み立ての口が畳む** (#1180)。ここに片付けは書かない。
        //
        // **「投入された」ことにする記帳は、口から返った後でだけ書く** ([#1183])。組み立ての
        // 途中で書くと、後続が投げたときに「積んだが投入されていない仕事」を済んだことに
        // してしまい、次の描き切りがそれを踏む — 焼けていない影の面を読む・CPU の画素への
        // 書き込みが失われる・消していない奥行きを読む。口の中では「何を積んだか」だけを
        // 集めて持ち出す
        //
        // [#1183]: https://github.com/mokume-metal/mokume/issues/1183
        let assembled = try gpu.withCommands { commands throws(RenderFailure) in
            // **効果を通す前の絵を、描くより先に戻す** ([#1469])。前のフレームの出口 (効果を
            // 通した絵) をこのフレームの入りにしない。
            //
            // フレームの外で描く先を変えられるのは、持ち越しを約束する区間だけである (ADR-0021
            // 決定 4 の追補 (2026-09-27)・[#1672])。描き場所の区間 (`beginDraw()`〜`endDraw()`) は
            // フレームそのもので、そこで書いた画素はこの戻しより後に載る — 書く口 (`set()`・
            // `pixels`) がまず画素を読むので、フレームの最初の描き切りは書く前に済んでいる。
            // 描き場所の区間の外 (`endDraw()` の後) の書き込みは断る。以前は通していたので、
            // 効果を通した絵ごと書き戻され、次のフレームで効果が 2 回掛かった ([#1655])。
            //
            // 残るのは本体の止まっている間のコールバックである。そこで変えた分は控えにも載せて
            // ある (上の `changesCarry`) ので、戻せば次のフレームの入りに残る。**書き戻していない
            // 画素は、戻す前に書き戻して控えへも写す** ([#1524]) — 戻してから書き戻すと、写しの
            // 全面 (効果を通した絵) が入りになり効果が焼き込まれ、書き戻さずに戻すと書いた画素が
            // 消える
            //
            // [#1469]: https://github.com/mokume-metal/mokume/issues/1469
            // [#1524]: https://github.com/mokume-metal/mokume/issues/1524
            // [#1655]: https://github.com/mokume-metal/mokume/issues/1655
            // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
            var wroteBack = false
            if changesCarry { wroteBack = try encodePixelWriteBackKeepingCarry(into: commands) }
            if restoresCarry {
                try encodeCarryRestore(into: commands, afterKeepingChanges: wroteBack)
            }

            // **CPU が画素へ書いたものがあれば、描く前に描画先へ戻す。** 描画先は GPU 専用の
            // 面なので、`pixels` への書き込みは写しに載っている。書いていないフレームは
            // 何も積まない (#753)。控えへも写したなら、書き戻しは済んでいる
            if !changesCarry { wroteBack = try target.encodePixelWriteBack(into: commands) }

            // **数の並びと画像へ CPU が書いた控えを、読む段より前に届ける** (#749)。書く口は
            // 待たずに控えへ積むだけなので、届けるのはここである。控えが無ければ何も積まない
            let uploaded = try encodeUploads(into: commands)

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

            // 控えへも描くなら、描く先の奥行きを描く前に写しておく ([#1524])。控えへのパスは描く先
            // へのパスと同じ奥行きから始める — 引き継ぐ奥行きが無ければ、写さず消して始める
            if drawsIntoCarry, continuesDepth { try encodeCarryDepthCopy(into: commands) }

            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                throw .encoderUnavailable
            }

            let prepared = try prepareBatches(shadow: bakedShadow, drawingInFrame: drawsInFrame)
            let drawsEncoded = encodeBatches(into: encoder, prepared: prepared)

            drawCallsInLastFrame = hasPendingGeometry ? batches.count : 0
            drawsEncodedInLastFrame = hasPendingGeometry ? drawsEncoded : 0
            flatVerticesInLastFrame = vertices.count
            flatOutlinesInLastFrame = outlinesAssembledThisFrame
            outlinesAssembledThisFrame = 0
            pointScansInLastFrame = pointScansThisFrame
            pointScansThisFrame = 0
            encoder.endEncoding()

            // **止まっている間に描き切るものは、効果を通す前の絵へも同じ列で描く** ([#1524])
            if drawsIntoCarry {
                try encodeCarryDraw(
                    into: commands, prepared: prepared, continuingDepth: continuesDepth)
            }

            // **描き終えた絵に効果を通す。** 段はすべて出力段の手前に立つので、画面も
            // 書き出しも観測も同じ 1 枚を受け取る (ADR-0023 決定 2)
            let carried = applyingEffects && applyEffects(into: commands)

            // **拡大は出口の直前・段の最後。** 効果は描く細かさの上で働き、その結果を
            // 出す細かさへ広げる。順を逆にすると、効果の半径が出す細かさで測られて
            // 細かさを変えるたびに効き方が変わる
            let upscaled = applyingEffects && applyUpscale(into: commands)

            // **画素を読む直前の描き切りなら、描き終えた絵を写しへ読み戻す blit を末尾に積む。**
            // 別のコマンドにすると投入が 1 本増えるので、同じコマンドの末尾に置く (#753)
            if mirroringPixels { try target.encodePixelReadback(into: commands) }

            // **投入して、待たない。** 直後の片付けで列が抱えていた参照 (面・数の並び・
            // 断片・外の置き場所) が落ちるので、GPU が終わるまで抱えておく側へ渡す —
            // この世代のコマンドはリソースを保持しないため、渡さないと利用者が `draw()` の
            // 中で作って手放した絵を、GPU が読んでいる途中で解放することになる (#727)
            //
            // **この投入が中身を書き換える面を名乗る** (#1932)。何も描かず書き戻さない描き切り
            // (`loadPixels()`・`get()` の読み戻しだけ) は面を書き換えないので名乗らない
            let submission = gpu.commit(
                commands,
                retaining: [
                    HeldFrame(
                        batches: batches, casters: frameCasters.casters, effects: pendingEffects,
                        imageInput: imageInputPass)
                ],
                writing: surfacesWritten(
                    drawing: changesTarget || wroteBack || carried, upscaling: upscaled))
            return (
                submission: submission, wroteBack: wroteBack, shadow: bakedShadow,
                uploaded: uploaded, carried: carried, upscaled: upscaled)
        }
        // 頼んだ計算はこの投入で流れた。粒の進めを、寿命を減らした量として数える (#1710)
        commitParticleAdvances()
        // **いまのスロットを読む投入は、これである。** 次にこのスロットが回ってきた
        // ときに待つ先になる。記録しないと、そのスロットは「いつ読み終わるか分からない
        // まま書いてよい」ことになる (#754)
        frameRing.noteSubmission()
        passesThisFrame += 1
        if pass.depthAttachment!.loadAction == .load { depthLoadsEncoded += 1 }
        if pass.depthAttachment!.storeAction == .store { depthStoresEncoded += 1 }
        // **奥行きを残した描き切りが、何かを描いたか引き継いだなら、次へ渡す奥行きがある。** 何も
        // 描かず消して始めただけなら、消した奥行きは消して始めるのと同じなので立てない (読むだけの
        // 区間が、次のフレームの最初のパスに奥行きの読み込みを課さない)。立てるのも投入の後だけ
        // ([#1183] と同じ作法) — 投げたコマンドは捨てられ、奥行きは書き換わらない
        depthIsHeld = !applyingEffects && (continuesDepth || hasDrawing)
        if assembled.wroteBack { target.markPixelsWrittenBack(by: assembled.submission) }
        // **拡大より後に描く先が変わったかを憶える** ([#1882])。フレームの終わりの描き切りは、
        // 拡大が積めたなら下ろす。**積めなかったなら (拡大は失敗を握り潰して警告だけ出す) 立てる**
        // — 下ろすと、出す先が古い絵のまま追い付き直されない。途中の描き切りは、描く先を変えたときに
        // 立てる (頭で数えた `changesTarget`・[#2103]。書き戻しは実際に積んだかでも見る)
        //
        // [#1882]: https://github.com/mokume-metal/mokume/issues/1882
        // [#2103]: https://github.com/mokume-metal/mokume/issues/2103
        if applyingEffects {
            targetChangedSinceUpscale = !assembled.upscaled
            placingCatchUpDeferred = false
        } else if upscaleStage != nil, changesTarget || assembled.wroteBack {
            targetChangedSinceUpscale = true
            placingCatchUpDeferred = false
        }
        gpu.pendingUploads.markUploaded(assembled.uploaded)
        // 「映した」は結末を見ずに付ける。この投入が打ち切られていたら、投げる読む口が範囲の中に
        // 見つけて投げ、印を下ろす (`RenderTarget.markPixelsMirrored(through:)`・#1932)
        if mirroringPixels { target.markPixelsMirrored(through: assembled.submission) }
        // 焼いたなら、その入力を覚える。使い回したフレームでは同じ値を書き直すだけになる
        if let shadow = assembled.shadow {
            lastShadowBakeKey = shadow.key
            shadowMapHolds = shadow.holds.map {
                (chain: $0, matrix: shadow.matrix, detail: shadow.map.detail)
            }
        }
        // フレームの最初の描き切りで、描く先は効果を通す前の絵に戻ったか塗り直された。
        // このコマンドが効果を通していれば、描く先はまた効果を通した絵になっている
        if startsFrame { carriesPictureBeforeEffects = false }
        if assembled.carried { carriesPictureBeforeEffects = true }

        // **描き切ったらその場で片付ける。** 片付けをフレームの頭に置くと、フレームの
        // 途中で描き切ったときに溜めたものが残り、同じ図形が 2 度描かれる。
        // ここは**描き切れたときだけ**の片付けで、投げたときは `draw(_:)` の
        // `defer` が同じことをする (#342) — 途中の描き切り (`loadPixels()`) が
        // 一時的に失敗しただけなら、溜めたものはフレーム末尾の描き切りに残す
        //
        // **途中の描き切りは、落とす側をフレームの終わりまで持ち越す** ([#1656])。捨てる前に
        // 写し、捨てた後に戻す (捨てる側の ``discardPending()`` は、塗り直しのために持ち越した
        // 分も捨てる)。フレームの終わりの描き切り (効果を通す) は持ち越さない
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        var kept = FrameCasters()
        if !applyingEffects {
            swap(&kept, &frameCasters)
            keepCasters(into: &kept)
        }
        discardFrame()
        if !applyingEffects { frameCasters = kept }
    }

    /// この描き場所の面のうち、投入が中身を書き換えるもの ([#1932])。
    /// ``RenderDevice/commit(_:retaining:writing:)`` に渡す。
    ///
    /// 投げる読む口は、自分の面へ書いた投入の打ち切りだけを持ち越し、自分の面へ書く新しい投入で
    /// 下ろす。**描く先を書き換えたら、出す先も一緒に名乗る** — 細かさを下げた面の出す先は描く先から
    /// 広げ直されるので、描く先の描画が打ち切られれば出す先の絵も仕上がらず、描く先を描き直せば
    /// 出す先も描き直される。
    ///
    /// - Parameters:
    ///   - drawing: 描く先を書き換えたか (図形・背景・書き戻し・効果を通す前の絵の戻し・効果)。
    ///   - upscaling: 出す先を広げ直したか。
    ///
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    func surfacesWritten(drawing: Bool, upscaling: Bool) -> [RenderTarget] {
        var surfaces: [RenderTarget] = []
        if drawing { surfaces.append(target) }
        if drawing || upscaling, output !== target { surfaces.append(output) }
        return surfaces
    }

    /// 溜めた列を 1 つずつ積む。**溜めたものが 1 つも無ければ何も積まない** —
    /// 置き場を取ることも、encoder の状態を変えることもしない。
    /// 溜めた列を描くのに要る置き場。**1 度の描き切りで 1 回だけ取る** — 同じ列を 2 つの面へ
    /// 描くとき ([#1524]) も、両方がこれを読む。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private struct PreparedBatches {
        let geometry: GeometryBuffers
        let perBatch: BatchBuffers
    }

    /// 溜めた列の置き場を取る。列が無ければ `nil`。
    private func prepareBatches(
        shadow bakedShadow: BakedShadow?, drawingInFrame: Bool
    ) throws(RenderFailure) -> PreparedBatches? {
        guard hasPendingGeometry else { return nil }
        // **置き場は積む前に全部取る。** 番地を束ねたあとに取り直すと、束ねた先が
        // 死んだ置き場を指す (``GrowableBuffer/buffer(holding:)``)
        return PreparedBatches(
            geometry: try uploadGeometry(reusing: bakedShadow?.solidUploads),
            perBatch: try uploadPerBatch(shadow: bakedShadow, drawingInFrame: drawingInFrame))
    }

    /// 溜めた列をエンコーダへ積む。返すのは積んだ描く呼び出しの数 (``drawsEncodedInLastFrame``)。
    @discardableResult
    private func encodeBatches(
        into encoder: any MTL4RenderCommandEncoder, prepared: PreparedBatches?
    ) -> Int {
        guard let prepared else { return 0 }
        var draws = 0
        let (geometry, perBatch) = (prepared.geometry, prepared.perBatch)

        // **見る窓は実際に刻む画素で測る。** 落とす行列は出す細かさで書かれた
        // 座標を -1…1 へ正規化するので、窓を狭めればそのまま細かく刻まれる。
        //
        // **面を置き換える列だけは、奥行きの幅を 1…1 に絞る** (``Batch/replacesSurface``)。板は
        // 手前と奥の面の真ん中に置いてある (切り取られない位置・``Camera/replacementCorners()``)
        // が、書く奥行きは塗り直しの load 動作が消す値 (1) とそろえる — 板の位置が絵に効かず、
        // 後から置く立体はどちらの道で置き換えても同じ前後で出る
        func viewport(pinnedFar: Bool) -> MTLViewport {
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(pixelWidth), height: Double(pixelHeight),
                znear: pinnedFar ? 1 : 0, zfar: 1)
        }
        encoder.setViewport(viewport(pinnedFar: false))
        var pinnedFar = false

        for (index, batch) in batches.enumerated() {
            let run = batch.run
            if batch.replacesSurface != pinnedFar {
                pinnedFar = batch.replacesSurface
                encoder.setViewport(viewport(pinnedFar: pinnedFar))
            }
            // 並びごとに、頂点の落とし方と奥行きの扱いを切り替える。**平面は奥行きを
            // 書かない**ので、あとから来た立体の前後関係を汚さない (ADR-0021 決定 2)
            switch batch.source {
            case .flat:
                encoder.setRenderPipelineState(
                    (run.paint.shader?.states ?? pipeline.states).drawing(batch))
                encoder.setDepthStencilState(pipeline.flatDepthState)
                pipeline.argumentTable.setAddress(
                    geometry.flatVertices.gpuAddress, index: ShapePipeline.vertexBufferIndex)
                pipeline.argumentTable.setAddress(
                    geometry.coverages.gpuAddress, index: ShapePipeline.coverageBufferIndex)
                // **口は立体と共用する。** 同じ列で平面と立体の両方を描くことは
                // 無いので、置き場所の口を 2 つ持つ理由が無い
                pipeline.argumentTable.setAddress(
                    geometry.flatInstances.gpuAddress
                        + UInt64(batch.instanceStart * MemoryLayout<FlatInstance>.stride),
                    index: ShapePipeline.instanceBufferIndex)
            case .form:
                // 基本図形。頂点の並びは読まず、置き場所の区間だけを渡す。奥行きの扱いは
                // 平面と同じ (常に通し・書かない)
                encoder.setRenderPipelineState(
                    pipeline.formStates(for: batch.formFlags).state(for: run.mode))
                encoder.setDepthStencilState(pipeline.flatDepthState)
                pipeline.argumentTable.setAddress(
                    geometry.formInstances.gpuAddress
                        + UInt64(batch.instanceStart * MemoryLayout<FormInstance>.stride),
                    index: ShapePipeline.instanceBufferIndex)
            case .solid:
                // **平面と同じ断片が効く。** 頂点の落とし方だけが違う
                encoder.setRenderPipelineState(
                    (batch.strokeGeometry != nil
                        ? pipeline.solidStrokeStates : (run.paint.shader?.solidStates ?? pipeline.solidStates))
                        .drawing(batch))
                encoder.setDepthStencilState(
                    batch.replacesSurface ? pipeline.replaceDepthState : pipeline.solidDepthState)
                // 引数を GPU が書く列 (粒) は、列の頭までを番地へ足す (``Batch/vertexBaseShift``)
                pipeline.argumentTable.setAddress(
                    (batch.ownVertices ?? geometry.solidVertices).gpuAddress
                        + batch.vertexBaseShift,
                    index: ShapePipeline.vertexBufferIndex)
                // **置き場所は列の先頭からを渡す。** そうすれば断片の側は 0 から
                // 数えるだけで済み、列ごとの下駄を持ち歩かなくてよい
                pipeline.argumentTable.setAddress(
                    (batch.instances?.storage ?? geometry.solidInstances).gpuAddress
                        + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
                    index: ShapePipeline.instanceBufferIndex)
            }
            // **どちら回りを表とするかを列ごとに明示する。** 断片は表裏を見て形から
            // 求めた向きを裏返すので、ここが黙っていると「表」の意味が土台の既定に
            // 委ねられる。表の巻き方は鏡映と裏返す投影で裏返るので、列が持っている
            // (`Batch.frontFacing`)。裏を向いた面を描くかも列が決めている (`Batch.cullMode`)
            encoder.setFrontFacing(batch.frontFacing)
            encoder.setCullMode(batch.cullMode)
            pipeline.argumentTable.setAddress(
                perBatch.matrices.gpuAddress + UInt64(index * Self.valuesStride),
                index: ShapePipeline.projectionBufferIndex)
            pipeline.argumentTable.setAddress(
                perBatch.values.gpuAddress + UInt64(index * Self.valuesStride),
                index: ShapePipeline.valuesBufferIndex)
            pipeline.argumentTable.setAddress(
                perBatch.lighting.gpuAddress + UInt64(index * Self.valuesStride),
                index: ShapePipeline.lightingBufferIndex)
            pipeline.argumentTable.setAddress(
                perBatch.materials.gpuAddress + UInt64(index * Self.valuesStride),
                index: ShapePipeline.materialBufferIndex)
            pipeline.argumentTable.setAddress(
                perBatch.surroundings.gpuAddress + UInt64(index * Self.valuesStride),
                index: ShapePipeline.surroundingsBufferIndex)
            encoder.setScissorRect(scissor(batch.clip))
            pipeline.argumentTable.setAddress(
                blendModeBuffer.gpuAddress
                    + UInt64(Int(run.mode.rawIndex) * Self.blendModeStride),
                index: ShapePipeline.blendModeBufferIndex)
            // **字の焼き場を読む列かを渡す。** 置き換える列はこれを見て、字形の外の余白を
            // 捨てる (#1557)。読まない断片にも束ねておく (口を空けたまま走らせない)
            pipeline.argumentTable.setAddress(
                glyphPageBuffer.gpuAddress
                    + UInt64((run.texture.isGlyphPage ? 1 : 0) * Self.blendModeStride),
                index: ShapePipeline.glyphPageBufferIndex)
            // **必ず何かを束ねる。** 渡されていない列には 1 個の 0 を束ねる —
            // 束ねずに走らせると、読んだ断片が絵の乱れではなく異常終了になる
            pipeline.argumentTable.setAddress(
                (run.paint.numbers ?? emptyNumbers).storage.gpuAddress,
                index: ShapePipeline.numbersBufferIndex)
            pipeline.argumentTable.setTexture(
                run.texture.gpuResourceID, index: ShapePipeline.textureIndex)
            // 利用者が宣言した面。**口は毎回すべて束ねる** — 渡していない口には
            // 読む面を束ねる。束ねずに走らせると、宣言より多く読んだ断片が
            // 絵の乱れではなく異常終了になる (数の並びと同じ扱い)
            for slot in 0..<ShapePipeline.surfaceCapacity {
                let surface = slot < run.paint.surfaces.count ? run.paint.surfaces[slot] : run.texture
                pipeline.argumentTable.setTexture(
                    surface.gpuResourceID, index: ShapePipeline.surfaceTextureIndex + slot)
            }
            encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
            if let arguments = batch.indirectArguments?.storage {
                // **個数は GPU が書いた引数から読む。** 計算の段の末尾の仕掛け
                // (`encodeComputeBarrier`) が頂点段の前で待つので、引数の読み出しは
                // 書き終わった後になる
                encoder.drawPrimitives(
                    primitiveType: .triangle, indirectBuffer: arguments.gpuAddress)
                draws += 1
            } else if batch.source == .form {
                // 基本図形はクアッド 1 枚 (頂点 6 つ) を置き場所の数だけ描く。頂点関数が
                // `vertex_id` から角を決めるので、頂点の並びは読まない
                encoder.drawPrimitives(
                    primitiveType: .triangle,
                    vertexStart: 0, vertexCount: Self.formQuadVertexCount,
                    instanceCount: batch.instanceCount)
                draws += 1
            } else if batch.drawsBackThenFront {
                draws += encodeBackThenFront(batch, indices: geometry.solidIndices, on: encoder)
            } else {
                encodeSolidDraw(
                    run, instances: 0..<batch.instanceCount, indices: geometry.solidIndices,
                    on: encoder)
                draws += 1
            }
        }
        return draws
    }

    /// 描く先の奥行きを、控えへ描くときの奥行き (``EffectPipeline/carryDepth()``) へ写す blit を
    /// 積む ([#1524])。描く先へのパスより先に積む — 描く先へのパスが奥行きを書き換えるため。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private func encodeCarryDepthCopy(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let depth = try effectPipeline().carryDepth()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .blit, visibilityOptions: .device)
        encoder.copy(sourceTexture: target.depthTexture, destinationTexture: depth.texture)
        // **写し終わるのを、続く描く先へのパス (奥行きを書く) と控えへのパスが待つ**
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.vertex, .fragment],
            visibilityOptions: .device)
        encoder.endEncoding()
    }

    /// 止まっている間に描き切るものを、効果を通す前の絵の控え (``EffectPipeline/carry()``) へも
    /// 描くパスを積む ([#1524])。
    ///
    /// **描く先へのパスと同じ列・同じ置き場で描く** (``prepareBatches(shadow:drawingInFrame:)`` は
    /// 1 回だけ取る)。塗り直し (`background()`) は控えも塗り直す。奥行きは、描く先へのパスの前に
    /// 写したもの (``encodeCarryDepthCopy(into:)``) から始め、塗り直すなら消してから始める。引き継ぐ奥行きが
    /// 無い描き切りでは写していないので、`continuingDepth` を偽にして消してから始める ([#1888])。
    /// 控えは次のフレームの頭で描く先へ戻され、その入りになる。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    /// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
    private func encodeCarryDraw(
        into commands: any MTL4CommandBuffer, prepared: PreparedBatches?, continuingDepth: Bool
    ) throws(RenderFailure) {
        let pipeline = try effectPipeline()
        guard let carry = pipeline.existingCarry else { return }
        let depth = try pipeline.carryDepth()
        // 描く先へのパスと同じ作り方 (塗り直しの色の移し方を含む) で組み、面だけを差し替える
        let pass = target.makeRenderPass(
            clearColor: pendingBackground, continuingDepth: continuingDepth, keepingDepth: false)
        pass.colorAttachments[0]!.texture = carry.texture
        pass.depthAttachment!.texture = depth.texture
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }
        // **控えへ書く前の段 (変わった画素の写し・奥行きの写し) が終わるのを待つ** (#341)
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: [.vertex, .fragment],
            visibilityOptions: .device)
        encodeBatches(into: encoder, prepared: prepared)
        encoder.endEncoding()
        effectCarryDrawsEncoded += 1
    }

    /// 裏面が絵に出うる部品を持つ立体の列を、置き場所ごとに描く (``Batch/backFaceParts``)。
    /// 返すのは積んだ描く呼び出しの数。
    ///
    /// 置き場所を置いた順に歩く。立つ部品が 1 つも無い置き場所は、続けて並んだものをまとめて
    /// 列の捨て方 (``Batch/cullMode``) で 1 回で描く。立つ部品のある置き場所は、列の区間を記録した
    /// 順に歩き、部品の外の区間と立っていない部品は 1 回、立っている部品は `.front` → `.back`
    /// (内向きなら `.back` → `.front`) の 2 回で描く。部品は、置き場所に印があれば全部が、無ければ
    /// 部品そのものに印のあるものだけが立つ。表の巻き方は列が決めてある (``Batch/frontFacing``) ので、
    /// `.front` を捨てれば裏の面、`.back` を捨てれば表の面になる。置き場所は `baseInstance` で選ぶ —
    /// 頂点関数の `instance_id` はこれを含むので、列の先頭から数えた番号のまま読める。
    private func encodeBackThenFront(
        _ batch: Batch, indices: any MTLBuffer, on encoder: any MTL4RenderCommandEncoder
    ) -> Int {
        let run = batch.run
        let whole =
            run.isIndexed
            ? run.indexStart..<(run.indexStart + run.indexCount) : run.start..<(run.start + run.count)
        var parts: [SolidPart] = []
        var alwaysShown: [SolidPart] = []
        for part in batch.backFaceParts
        where part.isIndexed == run.isIndexed && !part.range.isEmpty
            && whole.contains(part.range.lowerBound) && part.range.upperBound <= whole.upperBound
        {
            parts.append(part)
            if part.showsBackFaces { alwaysShown.append(part) }
        }
        var draws = 0
        func draw(_ range: Range<Int>?, _ culled: MTLCullMode, _ instances: Range<Int>) {
            encoder.setCullMode(culled)
            encodeSolidDraw(run, section: range, instances: instances, indices: indices, on: encoder)
            draws += 1
        }
        var marks = batch.backFaceInstances[...]
        var waiting: Int?
        for instance in 0..<batch.instanceCount {
            var marked = false
            while let next = marks.first, next <= instance {
                if next == instance { marked = true }
                marks = marks.dropFirst()
            }
            let shown = marked ? parts : alwaysShown
            guard !shown.isEmpty else {
                if waiting == nil { waiting = instance }
                continue
            }
            if let start = waiting {
                draw(nil, batch.cullMode, start..<instance)
                waiting = nil
            }
            let only = instance..<(instance + 1)
            var cursor = whole.lowerBound
            for part in shown {
                if part.range.lowerBound > cursor { draw(cursor..<part.range.lowerBound, batch.cullMode, only) }
                for culled in part.insideOut ? [MTLCullMode.back, .front] : [.front, .back] {
                    draw(part.range, culled, only)
                }
                cursor = part.range.upperBound
            }
            if cursor < whole.upperBound { draw(cursor..<whole.upperBound, batch.cullMode, only) }
        }
        if let start = waiting { draw(nil, batch.cullMode, start..<batch.instanceCount) }
        return draws
    }

    /// 列の三角形を出す。**添字を持つ列は添字で読む** (``Shape/Run/isIndexed``)。
    ///
    /// 画面と影の焼き付けで**同じ判定を通す**。片方だけ非添字のまま残すと、影だけが
    /// 別の形 (頂点を 3 つずつ束ねた並び) で焼かれる — 絵は出るので、影が崩れるまで
    /// 誰も気づけない。
    ///
    /// 添字は ``solidVertices`` の番号そのものなので `baseVertex` はずらさない。
    ///
    /// `section` は描く単位 (添字の列なら読む順の並び、そうでなければ頂点の並び) での区間で、
    /// `nil` なら列の全体。`instances` は描く置き場所 (列の先頭から数える)。
    ///
    /// `indexBase` は添字の置き場の中で区画が始まる位置で、途中の描き切りから持ち越した落とす列
    /// (``frameCasters``) だけが 0 でない値を渡す。
    private func encodeSolidDraw(
        _ run: Shape.Run, section: Range<Int>? = nil, instances: Range<Int>, indices: any MTLBuffer,
        indexBase: Int = 0,
        on encoder: any MTL4RenderCommandEncoder
    ) {
        guard run.isIndexed else {
            let range = section ?? run.start..<(run.start + run.count)
            encoder.drawPrimitives(
                primitiveType: .triangle,
                vertexStart: range.lowerBound, vertexCount: range.count, instanceCount: instances.count,
                baseInstance: instances.lowerBound)
            return
        }
        let range = section ?? run.indexStart..<(run.indexStart + run.indexCount)
        let stride = MemoryLayout<UInt32>.stride
        encoder.drawIndexedPrimitives(
            primitiveType: .triangle, indexCount: range.count, indexType: .uint32,
            indexBuffer: indices.gpuAddress + UInt64((indexBase + range.lowerBound) * stride),
            indexBufferLength: range.count * stride,
            instanceCount: instances.count, baseVertex: 0, baseInstance: instances.lowerBound)
    }

    /// Swift の並びに溜めた頂点・置き場所・光を、GPU の置き場へ写す。
    ///
    /// **このフレームで影を焼いていれば、立体の頂点・添字・置き場所は写し直さない** ([#1790])。
    /// 焼き付けがここより前に同じ中身を同じ置き場 (同じスロット・同じ `holding:`) へ写して
    /// あり、その間にこの 3 つの置き場へ書く者はいない。写し直すと、焼き直すフレームで
    /// 同じ中身を 2 度写すことになる (20 万三角形で約 1 ms)。焼き付けを使い回したフレーム
    /// では焼き付けが写していないので、ここで写す。
    ///
    /// [#1790]: https://github.com/mokume-metal/mokume/issues/1790
    private func uploadGeometry(
        reusing baked: SolidUploads?
    ) throws(RenderFailure) -> GeometryBuffers {
        let buffer = try vertexStorage.write(vertices, holding: vertices.count)
        // 頂点ごとの被覆。**区間が無ければ 1 つだけ書く** — 頂点関数は列の旗を見て読まない
        // (`FlatFrame.readsCoverage`) が、口には何かを束ねる
        let coverageBuffer: any MTLBuffer
        if coverageSpans.isEmpty {
            coverageBuffer = try coverageStorage.write([Float(1)], holding: 1)
        } else {
            var coverages = [Float](repeating: 1, count: vertices.count)
            for span in coverageSpans {
                for index in span.range where index < coverages.count { coverages[index] = span.value }
            }
            coverageBuffer = try coverageStorage.write(coverages, holding: coverages.count)
        }
        let formBuffer = try formInstanceStorage.write(
            formInstances, holding: max(formInstances.count, 1))
        let solid: SolidUploads
        if let baked { solid = baked } else { solid = try uploadSolids() }
        let flatInstanceBuffer = try flatInstanceStorage.write(
            flatInstances, holding: flatInstances.count)
        // 光の置き場。列は自分の区間を指す
        let lightsBuffer = try lightStorageBuffer.write(
            lightStorage, holding: max(lightStorage.count, 1))
        pipeline.argumentTable.setAddress(
            lightsBuffer.gpuAddress, index: ShapePipeline.lightsBufferIndex)
        return GeometryBuffers(
            flatVertices: buffer, coverages: coverageBuffer, formInstances: formBuffer,
            solidInstances: solid.instances, flatInstances: flatInstanceBuffer,
            solidVertices: solid.vertices, solidIndices: solid.indices)
    }

    /// 立体の頂点・添字・置き場所を写す。**影の焼き付けと画面が同じ `holding:` を渡す** —
    /// 要求する大きさが食い違うと、束ねた後に取り直した置き場を指すことになる
    /// (``GrowableBuffer/write(_:holding:)`` の順序の規律)。
    private func uploadSolids() throws(RenderFailure) -> SolidUploads {
        let instances = try solidInstanceStorage.write(
            solidInstances, holding: max(solidInstances.count, 1))
        let vertices = try solidVertexStorage.write(solidVertices, holding: solidVertices.count)
        let indices = try solidIndexStorage.write(solidIndices, holding: solidIndices.count)
        return SolidUploads(vertices: vertices, indices: indices, instances: instances)
    }

    /// 写した立体の置き場 (``uploadSolids()``)。
    private struct SolidUploads {
        let vertices: any MTLBuffer
        let indices: any MTLBuffer
        let instances: any MTLBuffer
    }

    /// 列ごとの値 (揺らぎを含む) と、フレームに 1 つの値 (時刻・面の大きさ・影) を置く。
    ///
    /// - Parameter drawingInFrame: フレームの描き切りか。時間方向の揺らしを選ぶ
    ///   (``jitter(drawingInFrame:)``・[#1913])。
    ///
    /// [#1913]: https://github.com/mokume-metal/mokume/issues/1913
    private func uploadPerBatch(
        shadow bakedShadow: BakedShadow?, drawingInFrame: Bool
    ) throws(RenderFailure) -> BatchBuffers {
        // 列ごとの行列を並べて置く。**列が閉じた時点の見る位置**がそのまま入り、揺らしだけは
        // 描き切りの時点で足す — 止まっている間に閉じた列も、描くのがどの描き切りかで揺らしが決まる
        let matrices = try matrixStorage.buffer(holding: batches.count)
        let unitsPerDrawnPixel = self.unitsPerDrawnPixel
        let readsCoverage: UInt32 = coverageSpans.isEmpty ? 0 : 1
        for (index, batch) in batches.enumerated() {
            // 行列のすぐ後ろに、輪郭の頂点が始まる番号を置く。**立体は行列しか
            // 読まない**ので、同じ区画に足しても効かない
            var frame = FlatFrame(
                projection: jittered(batch.matrix, drawingInFrame: drawingInFrame),
                strokeStart: UInt32(min(batch.strokeStart, Int(UInt32.max))),
                strokeShift: Self.solidStrokeShift(width: width, height: height),
                unitsPerDrawnPixel: unitsPerDrawnPixel, readsCoverage: readsCoverage)
            matrices.contents().advanced(by: index * Self.valuesStride)
                .copyMemory(from: &frame, byteCount: MemoryLayout<FlatFrame>.stride)
        }

        // 時刻と面の大きさは、フレームの中で変わらない。**大きさは出す画素**で、断片が
        // 受け取る位置 (`position`) も出す画素へ換算して渡す (#1639)。割って出す 0…1 の
        // 位置がここと食い違うと面からはみ出す
        let uniformsBuffer = try uniformsStorage.buffer(holding: 1)
        // 影の行列と設定も**フレームに 1 つ**で、列ごとには変わらない。揺らぎの種と細かさは
        // ここではなく列ごとの値に置く (下の `Lighting`・#1855)
        var uniforms = Uniforms(
            time: time,
            resolution: SIMD2(width, height),
            shadowBias: shadowBiasValue,
            shadowMatrix: bakedShadow?.matrix ?? matrix_identity_float4x4,
            shadowParams: SIMD4(
                bakedShadow == nil ? 0 : 1, 1 / Float(bakedShadow?.map.detail ?? 1), 0, 0),
            unitsPerDrawnPixel: unitsPerDrawnPixel)
        uniformsBuffer.contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)
        // **焼いていなくても、読む先は必ず束ねる。** 束ねない口を作ると、断片が
        // 触った瞬間に何が起きるかが土台任せになる。口は奥行きの面 (`depth2d`) なので、
        // 焼いていないフレームには同じ形の 1 画素の面を束ねる — 色の面を束ねると
        // 型が合わず、検証層が止める
        let shadowTexture: any MTLTexture
        if let bakedShadow {
            shadowTexture = bakedShadow.map.texture
        } else {
            shadowTexture = try unbakedShadowTextureHolding()
        }
        pipeline.argumentTable.setTexture(
            shadowTexture.gpuResourceID, index: ShapePipeline.shadowTextureIndex)
        pipeline.argumentTable.setAddress(
            uniformsBuffer.gpuAddress, index: ShapePipeline.uniformsBufferIndex)

        // 列ごとの値を並べて置く。**列が閉じた時点の値**がそのまま入っている。揺らぎの種と細かさも
        // ここで列ごとに届く — **断片が種を受け取る**ので、利用者が値として配線しなくても、置いた
        // 時点の CPU の `noise()` と同じ模様が出る (#366・#1503・#1855)
        let lighting = try lightingStorage.buffer(holding: batches.count)
        for (index, batch) in batches.enumerated() {
            var packed = Lighting(
                offset: UInt32(batch.lightRange.lowerBound),
                count: UInt32(batch.lightRange.count),
                viewer: batch.viewer,
                view: batch.view,
                noiseSeed: batch.noise.seed,
                noiseOctaves: UInt32(batch.noise.octaves),
                noiseFalloff: batch.noise.falloff)
            lighting.contents().advanced(by: index * Self.valuesStride)
                .copyMemory(from: &packed, byteCount: MemoryLayout<Lighting>.stride)
        }

        // 列ごとの材質。**列が閉じた時点のもの**がそのまま入る
        let materials = try materialStorage.buffer(holding: batches.count)
        for (index, batch) in batches.enumerated() {
            var packed = batch.material.packed
            materials.contents().advanced(by: index * Self.valuesStride)
                .copyMemory(from: &packed, byteCount: MemoryLayout<PackedMaterial>.stride)
        }

        // 列ごとの周囲。**列が閉じた時点のもの**がそのまま入る
        let surroundings = try surroundingsStorage.buffer(holding: batches.count)
        for (index, batch) in batches.enumerated() {
            var packed = batch.surroundings
            surroundings.contents().advanced(by: index * Self.valuesStride)
                .copyMemory(from: &packed, byteCount: MemoryLayout<PackedSurroundings>.stride)
        }

        let values = try uploadBatchValues()
        return BatchBuffers(
            matrices: matrices, lighting: lighting, materials: materials,
            surroundings: surroundings, values: values)
    }

    private func uploadBatchValues() throws(RenderFailure) -> any MTLBuffer {
        let values = try valuesStorage.buffer(holding: batches.count)
        for (index, batch) in batches.enumerated() {
            writeValues(of: batch, into: values.contents().advanced(by: index * Self.valuesStride))
        }
        return values
    }

    /// 列 1 つぶんの値を、区画 1 つへ書く。画面の列と、途中の描き切りから持ち越した落とす列
    /// (``frameCasters``) が同じ書き方を通る。
    private func writeValues(of batch: Batch, into region: UnsafeMutableRawPointer) {
        // **区画に収まることは入口で保証されている** (`Canvas.loadShader` /
        // `makeShader` が `valueSlotCapacity` を超える宣言を断る・#348)。ここで
        // 切り詰めないのは、黙って切り詰めると断片の `Values` に「宣言したのに
        // 一度も書かれない欄」が残り、絵が永久に間違ったまま出るためである
        let slot = region.assumingMemoryBound(to: Float.self)
        if var stroke = batch.strokePlacement {
            region.copyMemory(from: &stroke, byteCount: MemoryLayout<SolidStrokePlacement>.stride)
        } else if batch.run.paint.values.isEmpty {
            slot.update(repeating: 0, count: 4)
        } else {
            slot.update(from: batch.run.paint.values, count: batch.run.paint.values.count)
        }
    }

    /// 頂点と置き場所の置き場。``uploadGeometry()`` が満たし、列を積むときに読む。
    private struct GeometryBuffers {
        let flatVertices: any MTLBuffer
        let coverages: any MTLBuffer
        let formInstances: any MTLBuffer
        let solidInstances: any MTLBuffer
        let flatInstances: any MTLBuffer
        let solidVertices: any MTLBuffer
        let solidIndices: any MTLBuffer
    }

    /// 列ごとの値の置き場。**どれも列の番号 × `valuesStride` で区切って読む。**
    private struct BatchBuffers {
        let matrices: any MTLBuffer
        let lighting: any MTLBuffer
        let materials: any MTLBuffer
        let surroundings: any MTLBuffer
        let values: any MTLBuffer
    }

    /// 描き切りが GPU に読ませる参照のうち、この型が所有していないもの。
    ///
    /// 列 (`Batch`) は面・数の並び・断片・外の置き場所を抱え、効果は断片を抱える。
    /// どちらも描き切りの直後に空になるので、GPU が終わるまで生かしておく入れ物と
    /// して ``RenderDevice/commit(_:retaining:writing:)`` へ渡す。頂点や列ごとの値の置き場は
    /// この型が持ち続けるので、ここには要らない。
    private final class HeldFrame {
        let batches: [Batch]
        /// 途中の描き切りから持ち越して焼いた落とす列 (``Canvas/frameCasters``・#1656)。列と同じく
        /// 線の骨・モデルの塗り・外の置き場所を抱えるので、焼き付けが読み終わるまで生かす。
        let casters: [FrameCasters.Caster]
        let effects: [Effect]
        let imageInput: ImageInputPass?
        init(
            batches: [Batch], casters: [FrameCasters.Caster], effects: [Effect],
            imageInput: ImageInputPass?
        ) {
            self.imageInput = imageInput
            self.batches = batches
            self.casters = casters
            self.effects = effects
        }
    }

    /// 立体の置き場所の置き場。
    private let solidInstanceStorage: GrowableBuffer

    // MARK: - フレームで積み上げる落とす側 (#1656)

    /// このフレームで、途中の描き切りが既に描いた落とす側 ([#1656])。
    ///
    /// **影はそのフレームでそこまでに置いた立体から焼く約束である** (影の説明)。ところが途中の
    /// 描き切り (画素の口・写しの上限を越えた置いた描き場所の描き換え) は溜めた列を描いて捨てる
    /// ので、焼き付けがその回の列だけから落とす立体を選ぶと、区切りより前に置いた立体が、後に置いた
    /// 面へ影を落とさなかった。
    /// 区切りごとに、落とす列と、それが読む立体の頂点・添字・置き場所をここへ控えて、後の焼き付け
    /// にも入れる。後の面は、分けずに描いたときと同じ影を受ける。
    ///
    /// **区切りより前に描いた面へ、後から置いた立体の影は落とせない** (面は既に描画先に載って
    /// いて、描き直すしかない)。その向きは影と `loadPixels()` の説明に書いて引き受けた (案 A・
    /// ADR-0021 決定 3 の改訂 (2026-10-03))。
    ///
    /// 捨てるのは塗り直し (``discardPending()``) とフレームの終わり。塗り直しは分けずに描いたときも
    /// 前に置いた立体を捨てるので、そこで捨てて一致する。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    var frameCasters = FrameCasters()

    /// 途中の描き切りが描いた落とす側 (``Canvas/frameCasters``)。
    ///
    /// **控えるのは落とす列の分だけで、区切り 1 回につき 1 度だけ GPU へ上げる** (``CasterSegment``)。
    /// 列ごとに、読む頂点の区間・添字・置き場所を区画の頭へ寄せて詰め直す (添字は寄せた分を引く)。
    /// 後の焼き付けは上げた区画を読むだけなので、区切りが増えても払うのはその区切りの分だけである。
    /// 指紋も列ごとに控えたときに 1 度だけ取り、持ち越した順に ``chain`` へ混ぜておく。
    struct FrameCasters {
        struct Caster {
            /// 区画の中へ寄せた列。頂点・添字・置き場所の位置は、区画の中での位置である。
            var batch: Batch
            let segment: CasterSegment
            /// 区画の中の、頂点・添字・置き場所・値の置き場の頭 (バイト)。
            let vertexOffset: Int
            let indexOffset: Int
            let instanceOffset: Int
            let valuesOffset: Int
        }
        var casters: [Caster] = []
        /// 控えた区画。フレームの終わりに空きへ戻す。
        var segments: [CasterSegment] = []
        /// 持ち越した列の指紋を、持ち越した順に混ぜたもの (``casterDigest(_:)``)。
        var chain = ShadowBakeHasher()
        /// 指紋を取れない列 (GPU が埋める置き場所) を持ち越したら偽。
        var chainValid = true

        var isEmpty: Bool { casters.isEmpty }

        mutating func removeAll() {
            casters.removeAll()
            segments.removeAll()
            chain = ShadowBakeHasher()
            chainValid = true
        }
    }

    /// 控えた区画の空き。**読んだ投入が終わったものだけを使い回す** (``CasterSegment/reusableAfter``)。
    /// 8 本より多くは抱えない。
    private var casterSegmentsFree: [CasterSegment] = []

    /// 区画の頭をそろえる幅。値の区画 (``valuesStride``) と同じにして、どの置き場も定数の受け渡しの
    /// 境界に乗せる。
    private static let casterAlignment = valuesStride

    private static func alignedCaster(_ bytes: Int) -> Int {
        (bytes + casterAlignment - 1) / casterAlignment * casterAlignment
    }

    /// 落とす列 1 つを、区画へ寄せた形に詰め直したもの。控えるときと、その回の列の指紋を取る
    /// ときが同じ形を通る (同じ列なら、どちらで取っても同じ指紋になる)。
    private struct CompactCaster {
        var batch: Batch
        var vertices: ArraySlice<SolidVertex>
        var indices: [UInt32]
        var instances: ArraySlice<SolidInstance>
    }

    /// 溜め場の列 `batch` を、区画へ寄せた形に詰め直す。
    ///
    /// 頂点は列が読む区間だけ — 添字で読む列は添字の最小から最大まで、そうでない列は自分の区間。
    /// 自分の頂点の置き場を持つ列 (線の骨・モデルの塗り) は頂点を写さない。外の置き場所 (粒) を読む
    /// 列は置き場所を写さない。
    ///
    /// **溜め場の頂点を読む列は、頂点の頭 (`run.start`) を 0 へ置き直す** (``Batch/readsPooledVertices``)。
    /// 描く個数を GPU が書く列 (粒) も同じで、その列は頭を引数の `vertexStart` ではなく束ねる番地が
    /// 指すので (``Batch/vertexBaseShift``)、置き直した頭で読む場所が合う ([#2023])。置き直しは
    /// ``Batch/relocate(to:)`` を通し、位置から導く値 (裏 → 表で描く部品の区間) も同じだけずらす ([#2043])。
    ///
    /// [#2023]: https://github.com/mokume-metal/mokume/issues/2023
    /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
    private func compact(_ batch: Batch) -> CompactCaster {
        var moved = batch
        var run = batch.run
        var vertices: ArraySlice<SolidVertex> = []
        var indices: [UInt32] = []
        if batch.run.isIndexed {
            let range = batch.run.indexStart..<(batch.run.indexStart + batch.run.indexCount)
            var low = UInt32.max
            var high: UInt32 = 0
            for index in solidIndices[range] {
                low = min(low, index)
                high = max(high, index)
            }
            if batch.readsPooledVertices, low <= high {
                vertices = solidVertices[Int(low)...Int(high)]
                indices.reserveCapacity(range.count)
                for index in solidIndices[range] { indices.append(index - low) }
                run.start = 0
                run.count = Int(high - low) + 1
            } else {
                indices = Array(solidIndices[range])
            }
            run.indexStart = 0
        } else if batch.readsPooledVertices {
            vertices = solidVertices[batch.run.start..<(batch.run.start + batch.run.count)]
            run.start = 0
        }
        moved.relocate(to: run)
        var instances: ArraySlice<SolidInstance> = []
        if batch.instances == nil {
            instances = solidInstances[
                batch.instanceStart..<(batch.instanceStart + batch.instanceCount)]
            moved.instanceStart = 0
        }
        return CompactCaster(batch: moved, vertices: vertices, indices: indices, instances: instances)
    }

    /// いまの溜め場の落とす列を、``frameCasters`` へ足す。**途中の描き切りの末尾で、捨てる前に呼ぶ。**
    ///
    /// **控えるのは、フレームの中の区切りで、この面が影を 1 度でも有効にしたことがあるときだけ**
    /// (``shadowsEverEnabled``)。影を使わないスケッチの区切りは、ここで何も払わない。区切りの後で
    /// 初めて `shadows(true)` を呼んだフレームだけは、区切りより前の立体が影を落とさない (説明に
    /// 書いた)。フレームの外 (止まっている間のコールバック・`setup()`) の区切りでは控えない —
    /// 次のフレームの終わりまで捨てどきが来ず、止まっている間に読むたびに積み上がるため。
    ///
    /// 写すのは落とす列の分だけで、区画を 1 本取って 1 度書く。区画を取れなければ控えずに知らせる
    /// (区切りより前の立体の影が、後の面に落ちないだけで、絵は壊れない)。
    private func keepCasters(into kept: inout FrameCasters) {
        guard isDrawing, shadowsEverEnabled else { return }
        var compacted: [CompactCaster] = []
        for batch in batches where batch.castsShadow { compacted.append(compact(batch)) }
        guard !compacted.isEmpty else { return }
        let vertexStride = MemoryLayout<SolidVertex>.stride
        let indexStride = MemoryLayout<UInt32>.stride
        let instanceStride = MemoryLayout<SolidInstance>.stride
        var byteCount = 0
        for caster in compacted {
            byteCount += Self.alignedCaster(caster.vertices.count * vertexStride)
            byteCount += Self.alignedCaster(caster.indices.count * indexStride)
            byteCount += Self.alignedCaster(caster.instances.count * instanceStride)
            byteCount += Self.valuesStride
        }
        let segment: CasterSegment
        do {
            segment = try casterSegment(holding: byteCount)
        } catch {
            Diagnostics.warn(
                "Could not keep the shadow casters drawn before reading pixels, so what is drawn "
                    + "after it misses their shadows: \(error.headline)")
            return
        }
        let base = segment.buffer.contents()
        var offset = 0
        func put<Element>(_ elements: some Collection<Element>, stride: Int) -> Int {
            let start = offset
            var cursor = base.advanced(by: start)
            for element in elements {
                cursor.storeBytes(of: element, as: Element.self)
                cursor = cursor.advanced(by: stride)
            }
            offset += Self.alignedCaster(elements.count * stride)
            return start
        }
        kept.segments.append(segment)
        for caster in compacted {
            let vertexOffset = put(caster.vertices, stride: vertexStride)
            let indexOffset = put(caster.indices, stride: indexStride)
            let instanceOffset = put(caster.instances, stride: instanceStride)
            let valuesOffset = offset
            writeValues(of: caster.batch, into: base.advanced(by: valuesOffset))
            offset += Self.valuesStride
            if let digest = casterDigest(caster) {
                kept.chain.mix(digest)
            } else {
                kept.chainValid = false
            }
            kept.casters.append(
                FrameCasters.Caster(
                    batch: caster.batch, segment: segment, vertexOffset: vertexOffset,
                    indexOffset: indexOffset, instanceOffset: instanceOffset,
                    valuesOffset: valuesOffset))
        }
    }

    /// `byteCount` バイトが入る区画。空きのうち、読んだ投入が終わっていて入るものを使い回し、
    /// 無ければ作る。
    private func casterSegment(holding byteCount: Int) throws(RenderFailure) -> CasterSegment {
        for (index, segment) in casterSegmentsFree.enumerated()
        where segment.capacity >= byteCount && segment.isReusable {
            return casterSegmentsFree.remove(at: index)
        }
        return try CasterSegment(gpu: gpu, byteCount: max(byteCount, 1 << 16))
    }

    /// 控えた区画を空きへ戻す。**そこまでに積んだ投入がそれを読み終えてから**使い回す。
    private func releaseCasterSegments(_ segments: [CasterSegment]) {
        guard !segments.isEmpty else { return }
        // 組み立て中のコマンドがあれば、その 1 本も読みうる (``RenderDevice/retire(_:)`` と同じ数え方)
        let after = gpu.submissionCount + 1
        for segment in segments {
            segment.reusableAfter = after
            casterSegmentsFree.append(segment)
        }
        if casterSegmentsFree.count > 8 {
            casterSegmentsFree.removeFirst(casterSegmentsFree.count - 8)
        }
    }

    /// 持ち越した落とす列が、`numbers` を外の置き場所として読むか。**粒の置き場の組を使い回して
    /// よいかを、粒が尋ねる** (``Particles/claimDraw(by:)``・[#1656])。持ち越した列は、区切りの後も
    /// フレームの終わりの焼き付けで組の置き場所を読むので、描き切りの印が変わっても組は空かない。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    func keepsCaster(reading numbers: Numbers) -> Bool {
        for caster in frameCasters.casters where caster.batch.instances === numbers { return true }
        return false
    }

    /// 基本図形のクアッドを組む頂点の数 (三角形 2 枚)。
    static let formQuadVertexCount = 6

    /// 光から見た奥行きを焼く。焼かなかったら `nil`。
    ///
    /// 焼くのは**落とす側の列だけ**。分けられないと、自己遮蔽の強い形を置いた作品が
    /// 「影を切る」以外の逃げ道を失う。
    ///
    /// **前のフレームと同じ入力なら焼かず、前に焼いた面をそのまま返す** (ADR-0021 決定 4
    /// の「同じ宣言なら実体を作り直さない」の焼き付け側・[#757])。毎フレーム `shadows(true)`
    /// と書く作品で、動いていないフレームの焼き付けを丸ごと省く。省いたフレームは待つ
    /// 仕掛けも積まない — 面は前のコマンドで書き終わっていて、コマンドどうしの順は
    /// 土台が張っている。
    ///
    /// [#757]: https://github.com/mokume-metal/mokume/issues/757
    private func bakeShadow(
        into commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> BakedShadow? {
        guard let matrix = shadowMatrix, hasPendingGeometry else { return nil }
        var casting: [Batch] = []
        for batch in batches where batch.castsShadow { casting.append(batch) }
        // **途中の描き切りが既に描いた落とす側も焼く** ([#1656])。この回に落とす列が無くても、
        // 区切りより前に置いた立体の影を、この回に描く面が受ける
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        guard !casting.isEmpty || !frameCasters.isEmpty else { return nil }
        // **この回に影を受ける立体が無ければ焼かない** ([#1656])。平面は影を読まないので、区切りの
        // 後が手元の表示 (2D) だけのフレームで、終わりの焼き付けを払わない
        var receives = false
        for batch in batches where batch.source == .solid && batch.material.receivesShadow {
            receives = true
            break
        }
        guard receives else { return nil }

        // **前のフレームと同じ入力なら焼き直さない。** 光の行列・細かさ・落とす列の
        // 頂点と置き場所が 1 バイトも変わっていなければ、焼いても同じ奥行きが出るだけ
        // である。指紋は焼く直前に取り、**覚えるのは描き切りが投入した後** (`flush`) —
        // 焼き付けを積んだ後で投げたフレームの指紋を覚えると、次のフレームが焼けていない
        // 面を読む ([#1183])。投入されなかった焼き付けは面を書き換えていないので、前の
        // 指紋のまま使い回して正しい
        //
        // [#1183]: https://github.com/mokume-metal/mokume/issues/1183
        let detail = shadowDetailValue
        let (key, holds) = shadowBakeKey(matrix: matrix, detail: detail, casting: casting)
        if let key, key == lastShadowBakeKey, let shadowMap, shadowMap.detail == detail {
            shadowBakesReused += 1
            return BakedShadow(
                map: shadowMap, matrix: matrix, key: key, holds: holds, solidUploads: nil)
        }
        // **面が持ち越した列をちょうど焼いてあれば、この回の列だけを足して焼く** ([#1656])。前の
        // 区切りで焼いた面は、そのときの列 (いま持ち越している列の全部) を、同じ行列と細かさで
        // 持っている。足すだけなら、区切りのたびに持ち越した列を全部焼き直さずに済む
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        let adding: Bool
        if let held = shadowMapHolds, frameCasters.chainValid, !frameCasters.isEmpty,
            held.chain == frameCasters.chain.finish(), held.matrix == matrix,
            held.detail == detail, let shadowMap, shadowMap.detail == detail
        {
            adding = true
        } else {
            adding = false
        }
        let map = try shadowMapHolding(detail)
        // 写した置き場は画面の側でも使う (``uploadGeometry(reusing:)``)
        let solid = try uploadSolids()
        let solidBuffer = solid.vertices
        let solidIndexBuffer = solid.indices
        let instanceBuffer = solid.instances
        let batchValues = try uploadBatchValues()
        let matrixBuffer = try shadowMatrixStorage.buffer(holding: 1)
        // **輪郭は寄せない。** 寄せは画面の画素の約束で、光から見た奥行きの面には無い。
        // 描く画素の大きさは基本図形しか読まず、基本図形は影へ焼かないので 1 を置く
        var value = FlatFrame(
            projection: matrix, strokeStart: .max, strokeShift: .zero, unitsPerDrawnPixel: .one)
        matrixBuffer.contents().copyMemory(
            from: &value, byteCount: MemoryLayout<FlatFrame>.stride)

        guard
            let encoder = commands.makeRenderCommandEncoder(
                descriptor: map.makeRenderPass(keeping: adding))
        else {
            throw .encoderUnavailable
        }
        // **同じフレームで前に描き切っていれば、前に焼いた面を読む描画が読み終わるのを待ってから
        // 書く** ([#1656])。区切るフレームは 1 フレームに同じ面へ 2 度以上焼き、区切りの描画が面を
        // 読む。この世代は encoder をまたぐ依存を自動では張らない (#341)。区切らないフレームは
        // 最初の描き切りで焼くので待たない
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        if passesThisFrame > 0 {
            encoder.barrier(
                afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
            shadowRebakeBarriersEncoded += 1
        }
        encoder.setRenderPipelineState(pipeline.shadowState)
        encoder.setDepthStencilState(pipeline.solidDepthState)
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0, width: Double(map.detail), height: Double(map.detail),
                znear: 0, zfar: 1))
        pipeline.argumentTable.setAddress(
            solidBuffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
        pipeline.argumentTable.setAddress(
            matrixBuffer.gpuAddress, index: ShapePipeline.projectionBufferIndex)
        // **束ねるのは頂点段だけ。** 焼くパイプラインは断片を持たない (奥行きの面へは
        // 前後判定が書く) ので、断片段に渡すものが無い
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex])
        for (batchIndex, batch) in batches.enumerated() where batch.castsShadow {
            encodeCaster(
                batch,
                from: CasterSource(
                    vertices: solidBuffer.gpuAddress, indices: solidIndexBuffer, indexBase: 0,
                    instances: instanceBuffer.gpuAddress,
                    values: batchValues.gpuAddress + UInt64(batchIndex * Self.valuesStride)),
                on: encoder)
        }
        // 持ち越した列は、控えたときに上げた区画を読む (上げ直さない)。面が既に持っていれば焼かない
        if !adding {
            for caster in frameCasters.casters {
                let address = caster.segment.buffer.gpuAddress
                encodeCaster(
                    caster.batch,
                    from: CasterSource(
                        vertices: address + UInt64(caster.vertexOffset),
                        indices: caster.segment.buffer,
                        indexBase: caster.indexOffset / MemoryLayout<UInt32>.stride,
                        instances: address + UInt64(caster.instanceOffset),
                        values: address + UInt64(caster.valuesOffset)),
                    on: encoder)
            }
        }
        encodeShadowBarrier(on: encoder)
        encoder.endEncoding()
        shadowBakesEncoded += 1
        if adding { shadowBakesAdded += 1 }
        return BakedShadow(map: map, matrix: matrix, key: key, holds: holds, solidUploads: solid)
    }

    /// 落とす列 1 つが読む置き場。溜め場の列は溜め場を写した置き場を、途中の描き切りから持ち越した
    /// 列 (``frameCasters``) は自分の区画の頭へずらした番地を渡す。
    private struct CasterSource {
        /// 頂点の置き場の、区画の頭の番地。列が自分の頂点を持つなら読まない。
        let vertices: UInt64
        let indices: any MTLBuffer
        /// 添字の置き場の中で区画が始まる位置。
        let indexBase: Int
        /// 置き場所の置き場の、区画の頭の番地。列が外の置き場所を持つなら読まない。
        let instances: UInt64
        /// この列の値の区画の番地。
        let values: UInt64
    }

    /// 落とす列を 1 つ焼く。
    private func encodeCaster(
        _ batch: Batch, from source: CasterSource, on encoder: any MTL4RenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(
            batch.strokeGeometry == nil ? pipeline.shadowState : pipeline.solidStrokeShadowState)
        // 持ち越した列は詰め直した区画の頭を、溜め場の列は溜め場の頭を渡す。引数を GPU が書く列 (粒) は、
        // そこから列の頭までを足す (``Batch/vertexBaseShift``)。その列は溜め場の頂点を添字なしで読む
        // 列に限られ (``Batch/addressesVertexHead``)、持ち越した列は詰め直すときに頭が 0 へ置き直される
        // ので、足すのは 0 で、区画の頭がそのまま束ねる番地になる
        pipeline.argumentTable.setAddress(
            (batch.ownVertices?.gpuAddress ?? source.vertices) + batch.vertexBaseShift,
            index: ShapePipeline.vertexBufferIndex)
        pipeline.argumentTable.setAddress(source.values, index: ShapePipeline.valuesBufferIndex)
        pipeline.argumentTable.setAddress(
            (batch.instances?.storage.gpuAddress ?? source.instances)
                + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
            index: ShapePipeline.instanceBufferIndex)
        // 画面と同じ捨て方で焼く。閉じた形では光から見た最も近い面も必ず表なので、
        // 裏面を捨てても焼き付く奥行きは両面で焼いたときと変わらない
        //
        // **表の巻き方は光の行列に合わせる** (``ShadowMap/frontFacing(isMirrored:)``)。光から
        // 見る行列は画面の投影と別物 (縦を戻す補正 `Camera.clipAdjustment` も、利用者の
        // 投影も通らない) なので、鏡映していない列の表は画面と逆の反時計回りになり、画面の
        // 側の `Batch.frontFacing` は使えない。画面の巻き方を写していた間は光を向いた面が
        // 捨てられ、奥の面が焼き付いていた ([#1474])。鏡映は置き場所の符号だけで裏返す
        // ([#1446])
        //
        // [#1446]: https://github.com/mokume-metal/mokume/issues/1446
        // [#1474]: https://github.com/mokume-metal/mokume/issues/1474
        encoder.setFrontFacing(ShadowMap.frontFacing(isMirrored: batch.isMirrored))
        encoder.setCullMode(batch.cullMode)
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex])
        if let arguments = batch.indirectArguments?.storage {
            // 粒は影の側でも GPU が書いた個数で描く (本描画と同じ)
            encoder.drawPrimitives(
                primitiveType: .triangle, indirectBuffer: arguments.gpuAddress)
        } else {
            // 影は奥行きだけを焼くので、裏 → 表に分けない (`Batch.backFaceParts`)
            encodeSolidDraw(
                batch.run, instances: 0..<batch.instanceCount, indices: source.indices,
                indexBase: source.indexBase, on: encoder)
        }
    }

    /// 焼いた (または使い回した) 影と、その入力の指紋。
    private struct BakedShadow {
        let map: ShadowMap
        let matrix: simd_float4x4
        /// 焼き付けの入力の指紋。**投入した後で `lastShadowBakeKey` へ覚える。**
        /// 指紋を取れない入力 (粒) では `nil` で、覚えると次のフレームが使い回さない
        let key: UInt64?
        /// 面が持つ落とす列 (持ち越した列とこの回の列) の指紋の並び。**投入した後で
        /// `shadowMapHolds` へ覚える** — 次の区切りで、この回の列だけを足して焼けるかを見る。
        let holds: UInt64?
        /// 焼くために写した立体の置き場。**使い回したフレームでは `nil`** (写していない)。
        let solidUploads: SolidUploads?
    }

    /// 焼き付けの入力の指紋。**焼く側が読むものを全部**入れる — 光の行列・細かさ・
    /// 落とす列ごとの (頂点の区間・置き場所の区間・捨て方・表の巻き方) と、その区間の頂点と
    /// 置き場所の中身。焼く側が読まないもの (受ける側の材質・縁の余裕・視点) は入れない。
    ///
    /// GPU が埋める置き場所 (粒) を含む列があれば `nil` — CPU からは前のフレームと同じか
    /// どうかが分からないので、分からないものは焼く側に倒す。
    ///
    /// 指紋は 64 bit で、続けて描いたフレームどうしを比べるためだけに使う。**衝突すると
    /// 前のフレームの影が 1 フレーム残る**が、続く 2 フレームの入力が偶然同じ 64 bit に
    /// 落ちる確率は絵に出ない大きさである。
    ///
    /// 途中の描き切りから持ち越した落とす列 (``frameCasters``・[#1656]) も、同じ規則で混ぜる。
    /// **列ごとの指紋 (``casterDigest(_:)``) を、持ち越した順・この回の順に 1 本の並びとして混ぜる**
    /// — 区切りの回 (この回の列が球) と終わりの回 (持ち越した列が球) で、落とす側が同じなら同じ
    /// 指紋になる。持ち越した列の指紋は控えたときに 1 度だけ取ってあるので (``FrameCasters/chain``)、
    /// 区切りが増えても、ここで中身を読むのはこの回の列だけである。
    ///
    /// - Returns: 指紋と、面が持つことになる列の並びの指紋 (``BakedShadow/holds``)。どちらも、
    ///   指紋を取れない列があれば `nil`。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    private func shadowBakeKey(
        matrix: simd_float4x4, detail: Int, casting: [Batch]
    ) -> (key: UInt64?, holds: UInt64?) {
        guard frameCasters.chainValid else { return (nil, nil) }
        var chain = frameCasters.chain
        for batch in casting {
            guard let digest = casterDigest(compact(batch)) else { return (nil, nil) }
            chain.mix(digest)
        }
        let holds = chain.finish()
        var hasher = ShadowBakeHasher()
        hasher.mix(holds)
        hasher.mix(UInt64(frameCasters.casters.count + casting.count))
        withUnsafeBytes(of: matrix) { hasher.mix($0) }
        hasher.mix(UInt64(detail))
        return (hasher.finish(), holds)
    }

    /// 落とす列 1 つの指紋。**焼く側が読むものを全部**入れる。指紋を取れない列 (GPU が埋める
    /// 置き場所) なら `nil`。
    ///
    /// 区画へ寄せた形 (``CompactCaster``) から取るので、溜め場のどこに居たかは入らない — 同じ列を
    /// 控える前に取っても控えた後に取っても同じ値になる。
    private func casterDigest(_ caster: CompactCaster) -> UInt64? {
        let batch = caster.batch
        guard batch.instances == nil else { return nil }
        var hasher = ShadowBakeHasher()
        if batch.strokeGeometry != nil {
            // 形の鍵は下で混ぜる。視点・太さ・変換も焼かれる帯を変える。
            hasher.mix(4)
            withUnsafeBytes(of: batch.strokePlacement!) { hasher.mix($0) }
        }
        hasher.mix(UInt64(batch.run.start))
        hasher.mix(UInt64(batch.run.count))
        hasher.mix(UInt64(batch.instanceCount))
        hasher.mix(UInt64(batch.cullMode.rawValue))
        // 焼く側の表の巻き方も焼き付く奥行きを変える (鏡映の符号だけで決まる)
        hasher.mix(batch.isMirrored ? 1 : 0)
        // **読む順も焼く側が読むものである。** 頂点を 1 バイトも動かさずに添字だけを
        // 組み直すフレーム (面の張り替え・粗さの切り替え) は `index(_:)` がまさに
        // 誘う書き方で、これを混ぜないと前のフレームの影が居座る
        hasher.mix(UInt64(batch.run.indexCount))
        caster.indices.withUnsafeBytes { hasher.mix($0) }
        // **頂点は出どころで代表できるなら舐めない。** 組み込みの形の頂点は寸法から
        // 決まり、読み込んだモデルは読んだ後に変わらない。その場で並べた頂点と
        // 保持した形 (置くたびに番号が変わる) だけ中身を読む
        switch batch.solidSource {
        case .mesh(let shape):
            hasher.mix(1)
            hasher.mix(UInt64(bitPattern: Int64(shape.hashValue)))
        case .model(let identity):
            hasher.mix(2)
            hasher.mix(UInt64(identity))
        case .freeform, .retained, nil:
            hasher.mix(3)
            caster.vertices.withUnsafeBytes { hasher.mix($0) }
        }
        caster.instances.withUnsafeBytes { hasher.mix($0) }
        return hasher.finish()
    }

    /// 影の面がいま持つ落とす列の並びの指紋と、焼いたときの行列と細かさ ([#1656])。焼いたか使い
    /// 回した描き切りの投入の後で覚える。次の焼き付けは、持ち越した列の並びがこれと同じなら、
    /// この回の列だけを足して焼く。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    private var shadowMapHolds: (chain: UInt64, matrix: simd_float4x4, detail: Int)?

    /// 面を消さずに、この回の列だけを足して焼いた回数 (作ってから通算)。**検査が読む。**
    private(set) var shadowBakesAdded = 0
    /// 同じフレームで前に焼いた面を読む描画を待つ仕掛けを、焼き付けの頭に積んだ回数 (作ってから
    /// 通算)。**区切らないフレームでは増えないことを検査が見る。**
    private(set) var shadowRebakeBarriersEncoded = 0

    /// 前のフレームで焼いた入力の指紋。焼かなかったフレームでは触らない — 焼いた面は
    /// 誰にも書き換えられないので、影を切って戻したフレームも同じ指紋ならそのまま読める。
    private var lastShadowBakeKey: UInt64?

    /// 焼き上がりを待つ仕掛けを積む。**焼いた面を画面のパスが読む前に置く。**
    ///
    /// この世代のコマンド構造は encoder をまたぐ依存を自動では張らないので、同じ
    /// コマンドに順に積んだだけでは焼き付けと画面が重なりうる。重なると画面は
    /// 書き終わる前の焼き付け先を読み、**前のフレームの影が混ざる** ([#341])。
    ///
    /// - `afterStages`: 奥行きを書くのは断片段 (断片関数は無いが、前後判定の書き込みは
    ///   この段に属する)
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

    /// 焼いていないフレームに、影の口へ束ねる面。**最初に要ったときに 1 度だけ作る。**
    ///
    /// 焼いた面と同じ形 (奥行きの面) の 1 画素。断片は `shadowParams.x` が 0 なら
    /// 読まないので中身は問わないが、口の型に合う面を束ねておかないと、触らなくても
    /// 型の不一致として検証層が止める
    private func unbakedShadowTextureHolding() throws(RenderFailure) -> any MTLTexture {
        if let unbakedShadowTexture { return unbakedShadowTexture }
        let texture = try gpu.makeTexture(descriptor: ShadowMap.descriptor(side: 1))
        texture.label = "mokume.shadow.unbaked"
        unbakedShadowTexture = texture
        return texture
    }

}
