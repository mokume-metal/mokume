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
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    var recordedStrokeRanges: [Range<Int>] = []

    /// 保持する形を記録している間に、立体の線が積んだ部品の元 (``SolidStrokePiece``)。
    ///
    /// 立体の線の帯は視点に合わせて組むので、記録したときの視点で組んだ帯は置いた先で
    /// 合わない。**部品の元を覚えておき、置くときに組み直す** (`Shape.solidStrokes`)。
    /// 記録を終えると `createShape` が抜く。
    var recordedSolidStrokes: [SolidStrokePiece] = []

    /// 保持する形を記録している間に、**GPU で組める**組み込み立体の線を覚えたもの
    /// (``RetainedGPUStroke``・#1756)。記録を終えると `createShape` が抜く。
    var recordedGPUStrokes: [RetainedGPUStroke] = []

    /// 保持した形の線を、組めるものは GPU で組むか。**検査が偽にして、CPU で組む物差しを作る。**
    var placesRetainedStrokesOnGPU = true

    /// 立体の線の部品を組み直している間、頂点を積む代わりに位置を受け取る先。
    ///
    /// 組み直しは即時に描くときと**同じ関数** (帯・円板・正方形) を通す。向き・幅・寄せの
    /// 式を 2 か所に書くと、片方だけ直した誤りが保持した形でだけ現れる (#1547)。
    var solidStrokeCapture: [SIMD3<Float>]?

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
    /// 変換も色も入っていない — どちらも置き場所が持つためである。円の分割数は半径から
    /// 決まる (``segmentCount(forRadius:)``) ので、寸法が入った時点で分割数も一致する。
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
        /// (``Canvas/placementMayShowBackFaces``)。1 つでも居れば列ごと両面で描く
        /// (``Batch/cullMode``)。
        ///
        /// **形を置いたときに記録する。** 塗りの不透明度も貼る絵も、変えただけでは列を閉じない
        /// (`fill`・`noTexture()`・`pop()`) ので、1 つの列に置いたときのスタイルが違う形が
        /// 同居し、閉じる時点のスタイルはもう置いたときのものではない。閉じる時点を読むと、
        /// 置いた後で外した絵の列が裏面を捨て、透けた画素から見えるはずの奥の面が消える
        /// ([#1564](https://github.com/mokume-metal/mokume/issues/1564))。
        var mayShowBackFaces = false
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
    /// いま組み立てている列が**周囲そのものを出す**なら、その周囲。
    ///
    /// 背景の面だけが立てる旗で、置いてある周囲とは別に持つ — 背景に出す周囲と
    /// 映り込む周囲は、別々に選べる (片方だけ呼んでもよい)。
    var backdrop: Surroundings?
    /// 列ごとの周囲の置き場。列 1 つにつき 1 区画。
    private let surroundingsStorage: GrowableBuffer

    /// 影を落とすか。**フレームを越えない** ([ADR-0021] 決定 4)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shadowsEnabled = false
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
    /// **描画の状態として持つ。** 断片からも同じ値が引けるよう uniforms を通って
    /// 送られるためで、置き場が 2 つに割れると CPU と断片で別の模様が出る ([#366])。
    ///
    /// **描き場所は作った面と同じ値を読み書きする** (``noiseStore``・[#1503])。`Canvas` に
    /// 置いたのは断片へ届けるためで、面ごとに分けるためではない — 種と細かさはスケッチに 1 つ。
    ///
    /// [#366]: https://github.com/mokume-metal/mokume/issues/366
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
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
        /// この置き場を読む面 (弱く持つ)。書き換える前に描き切らせる相手で、作った面と
        /// 描き場所が載る (``createGraphics(_:_:)``)。直に作った面だけなら空のまま
        private(set) var readers: [WeakCanvas] = []

        func add(reader canvas: Canvas) {
            readers.removeAll { $0.canvas == nil }
            guard !readers.contains(where: { $0.canvas === canvas }) else { return }
            readers.append(WeakCanvas(canvas: canvas))
        }
    }

    /// 揺らぎの種と細かさを書き換える。**置いた図形は、置いた時点の種で引く** ([#1503])。
    ///
    /// 断片の種は描き切りの時点で uniforms へ詰まり、CPU の `noise()` は呼んだ時点の種を
    /// 読む。置いた後に種を決め直すと、置いた図形の断片だけが後の種で引かれ、同じ時点で
    /// 引いた CPU の値と食い違う (#366 の約束が破れる)。置き場を共有する面はどれも同じ
    /// 種を読むので、**書き換える前に、置き場を読む面のうち図形を溜めているものを描き切らせる。**
    /// 効果はフレームの終わりに立つ段なので、途中の描き切りでは通さない (``loadPixels()`` と同じ)。
    ///
    /// 同じ値の書き直しでは描き切らない (毎フレーム同じ種を決め直す書き方で、途中の描き切りを
    /// 増やさない)。描き切るのはフレームの中の面だけで、持ち越しの区間 (`setup()` など) に
    /// 溜めた図形は次のフレームへ持ち越すものなので触らない。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    func changeNoise(_ change: (inout ValueNoise) -> Void) {
        var next = noiseSettings
        change(&next)
        guard next != noiseSettings else { return }
        var readers = [self]
        for entry in noiseStore.readers {
            if let reader = entry.canvas, reader !== self { readers.append(reader) }
        }
        for reader in readers
        where reader.isDrawing && !reader.isFrameLeftOpenPastTheMainFrame
            && !reader.isFlushing && reader.hasPendingGeometry
        {
            do {
                try reader.flush(applyingEffects: false)
            } catch {
                Diagnostics.warn(
                    "Could not finish drawing before the noise settings changed: \(error.headline)")
            }
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
    /// 計算のあとに次の段が待つ仕掛けを積んだ回数 (作ってから通算)。
    ///
    /// 影の側 (``shadowBarriersEncoded``) と同じ理由で持つ — 抜けていても絵は普段どおり
    /// 出て、GPU が混んだときだけ稀に書き終わる前の並びが読まれる。積む 1 行と同じ場所で
    /// 数え、**その行を消したら数も減る**。
    var computeBarriersEncoded = 0
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

    /// いまのフレームを ``beginDraw()`` が開いたなら、そのときの本体のフレームの番号
    /// (``Timebase/frame``)。``draw(_:)`` が開いたフレームとフレームの外では `nil`。
    ///
    /// **閉じ忘れうるのは `beginDraw()` が開いたフレームだけ** — ``draw(_:)`` が開いたフレームは、
    /// 閉包を抜けるときに同じ呼び出しが閉じる。番号を持つのは、描き場所が閉じ忘れたまま
    /// **本体のフレームの境目を越えたか**を見分けるためである ([#1622])。同じ本体のフレームの
    /// 中で `beginDraw()` を重ねただけなら、境目は越えていない (``leftOpenAcrossBoundary``)。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    private(set) var beginDrawFrame: Int?

    /// 変換とスタイルが意味を持つ文脈にいるか。**フレームの中と、形を組み立てている間。**
    ///
    /// 組み立て (``createShape(_:)``) の中は、形自身の座標で記録する文脈である — そこで
    /// 書いた変換とスタイルの積み降ろしは**形に焼き付く**ので、どのフレームにも属さない
    /// まま意味を持つ ([ADR-0021] 決定 4 の 2026-09-15 の改訂・[#1172])。`setup()` で
    /// 組み立てると中の `push()` / `translate()` が落ち、9 枚の葉が 1 か所へ重なっていた。
    ///
    /// **シーンの記述 (視点・光・囲み・影・材質・粒・計算) はここを見ない。** あちらは
    /// 形に焼き付かずフレームに属するので、記録の間もフレームの外のままである。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
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
    var carriesOver = false {
        didSet {
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
    /// **描き場所で、閉じ忘れたまま本体のフレームの境目を越えたフレームは入らない**
    /// (``isFrameLeftOpenPastTheMainFrame``)。そのフレームは次の ``beginDraw()`` が描かずに捨てる
    /// もので ([#1622])、もう区間ではない — 置けるままにすると、`beginDraw()` を 1 度だけ書いて
    /// `endDraw()` を忘れた描き場所に、描き切りが来ないまま置いたものが溜まり続ける (#1592 と同じ形)。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    var writesToSurface: Bool { (isDrawing && !isFrameLeftOpenPastTheMainFrame) || carriesOver }

    /// 描き場所の ``beginDraw()`` が開いたフレームが、閉じないまま本体のフレームの境目を越えたか。
    ///
    /// 越えたかは本体のフレームの番号 (``Timebase/frame``) で見分ける (``leftOpenAcrossBoundary``
    /// と同じ見方)。**時刻の置き場の持ち主 (本体・直に使う面) では立たない** — 持ち主の境目は
    /// 自分の次のフレームの頭そのもので、そこで閉じ忘れを捨てる。
    private var isFrameLeftOpenPastTheMainFrame: Bool {
        guard isDrawing, let opened = beginDrawFrame, timebase.owner !== self else { return false }
        return opened != timebase.frame
    }

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

    /// このフレームで描き切った回数。**奥行きを引き継ぐかの判定に使う。**
    private var passesThisFrame = 0

    /// 置いた描き場所のうち、まだ描き切っていないもの。
    ///
    /// **置いた時点の絵を守るために覚えている。** 溜めてから描くので、置いたあとに
    /// その描き場所が描き換わると、先に置いた場所まで最新の絵に化ける。
    ///
    /// 記録するのは**置くたび** — 画像として置いたときと、貼った塗りや保持した形がその
    /// 面を読むように切り替えたとき (``useTexture(_:)``)、断片の面として読む図形を積んだ
    /// とき (``notePaintPlacement()``・[#1653]) である。落とすのは描き切り
    /// (フレームの終わりと、描き場所が描き換わる直前) と塗り直し (``discardPending()``) で、
    /// 落とした後に同じ面のまま置いた形も、置いた時点で記録し直される ([#1543])。
    ///
    /// [#1543]: https://github.com/mokume-metal/mokume/issues/1543
    /// [#1653]: https://github.com/mokume-metal/mokume/issues/1653
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
    /// 丸い継ぎ目と端の円板の、周のずれの控え。**直前の太さの 1 件だけ** (#1785・
    /// `appendDisc(at:half:)`)。
    var discOffsets: (half: Float, offsets: [SIMD2<Float>])?
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
        var clip: MTLScissorRect?
        /// この列を描画先の座標へ落とす行列。
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
        /// 書いた引数をそのまま indirect draw に渡す。
        var indirectArguments: Numbers?
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
        var cullMode: MTLCullMode = .none
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

        /// 頂点を溜め場ではなく自分の置き場から読むなら、その置き場。
        var ownVertices: (any MTLBuffer)? { strokeGeometry?.buffer ?? fillGeometry?.buffer }

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
    /// (`emit` の繰り越し) が読む** — フレーム番号から導く時計では秒に直さずに渡るので、
    /// fps によって毎秒 1 個ずれることが無い (``FrameStep``・[#1640])。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
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
        /// 作った面 (``owner``) が始めたフレームの数。**描き場所の境目の印** — 描き場所は
        /// 本体のフレームの中で描かれるので、閉じ忘れたフレームが本体の境目を越えたかを
        /// これで見る ([#1622])。数えるのは作った面の ``beginFrame()`` だけである。
        ///
        /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
        var frame = 0
        /// この置き場を作った面。**弱く持つ** — 置き場は面が持ち、面を生かす筋合いが無い。
        weak var owner: Canvas?
    }

    /// これまでに閉じたフレームの数。**時計ではなく番号**なので、同じ入力からは
    /// 何度走らせても同じ列になる。
    ///
    /// 描き切れなかったフレームも、閉じ忘れて ``beginDraw()`` が捨てたフレーム ([#1622]) も
    /// 1 枚に数える — 番号はフレームの境目の印として読まれる (粒の繰り越し・焼き場の頁)。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
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
        var clip: MTLScissorRect?
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
                || !Self.sameClip(style.clip, newValue.clip)
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
        // 塗り直しも置くことである。区間の外では、溜めたものを捨てる前に断る ([#1672])。
        //
        // **見るのは形の組み立てを含まない述語** (``writesToSurface``)。塗り直しは形に焼き付かず、
        // 面を塗る予定として組み立ての外へ残るので、フレームの外の組み立ての中で通すと、
        // 描き場所の次のフレームを知らない色で塗る
        //
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard writesToSurface else { return warnOutsideFrame(.placing) }
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
        _ = sweepPending(emptying: true)
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
        list(&recordedStrokeRanges)
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
        // もう一度走ると、進み方が観測の有無で変わる
        pendingComputations.removeAll(keepingCapacity: true)
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
    /// (``beginDraw()`` の説明)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    public func draw(_ body: () -> Void) throws(RenderFailure) {
        if isDrawing, !leftOpenAcrossBoundary {
            warnFrameCallInsideFrame("draw")
            body()
            return
        }
        beginFrame()
        body()
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
    /// **``endDraw()`` を呼ばずに次のフレームが始まったら (`beginDraw()` か ``draw(_:)``)、
    /// 閉じていないフレームは描かずに捨て、注意してから描き始め直す** ([ADR-0021] 決定 4 の
    /// 追補 (2026-09-27)・[#1622])。捨てたフレームで書いた変換・溜めた図形・開いた形・書いた画素
    /// (``set(_:_:_:)``・``pixels``) は、次のフレームへ持ち込まない (積んだ力 (``force(_:_:)``) も
    /// 落とす・[#1678])。ただし、次の 2 つは取り消せない:
    ///
    /// - 捨てたフレームの途中で既に描き切った絵 (``loadPixels()`` など)。面に載っている
    /// - 捨てたフレームで出した粒 (`emit`)。粒の状態の並びへ直に積まれている
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
        beginDrawFrame = timebase.frame
    }

    /// 開いているフレームが、``beginDraw()`` で開いたまま閉じ忘れて、境目を越えたか ([#1622])。
    ///
    /// - ``draw(_:)`` が開いたフレームは越えない (閉包を抜けるときに閉じる)
    /// - 時刻の置き場の持ち主 (本体・直に使う面) では、次のフレームを始めること自体が境目で
    ///   ある。`beginDraw()` を重ねれば越えている
    /// - 描き場所では、本体のフレームの番号 (``Timebase/frame``) が開いたときから進んでいれば
    ///   越えている。進んでいなければ、同じ本体のフレームの中での重ね呼びである
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    private var leftOpenAcrossBoundary: Bool {
        guard isDrawing, let opened = beginDrawFrame else { return false }
        return timebase.owner === self || opened != timebase.frame
    }

    /// 描き場所へ描き切る。**投げない。**
    ///
    /// 毎フレーム呼ばれるので、1 段の失敗でフレームごと落とさない ([ADR-0020]
    /// 決定 5)。描き切れなかったときは前の絵がそのまま残り、理由が知らされる。そのフレームは
    /// 描かずに捨てるので、置いた図形も書いた画素も次のフレームへ持ち込まない ([#1678])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    public func endDraw() {
        guard isDrawing else { return warnNotDrawing() }
        // `draw { }` が開いたフレームは、閉包を抜けるときに `draw` が閉じる。ここで閉じると
        // 閉包が戻った後に `draw` がもう一度描き切り、番号も 2 つ進む
        guard beginDrawFrame != nil else { return warnFrameCallInsideFrame("endDraw") }
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
            // **閉じ忘れた描き場所のフレームは、描かずに捨てる** ([#1622])。`beginDraw()` /
            // `endDraw()` は対で開いて閉じる操作で、積む・降ろすと同じく 1 つのフレームの中で
            // 釣り合う。直す前の `beginDraw()` は注意だけで帰っていたので、前のフレームで書いた
            // 変換が次の描き直しに積み上がり、閉じ忘れた 1 枚の続きとして描かれた。捨てる場所を
            // 入口ではなくここに置くのは、次のフレームが `draw { }` から来ても同じにするため
            //
            // 番号は進める。番号はフレームの境目の印で、粒の繰り越し (#1468) と焼き場の頁
            // (#1342) が読む — 進めないと、捨てたフレームと次のフレームが同じ 1 枚に数えられる
            //
            // [#1622]: https://github.com/mokume-metal/mokume/issues/1622
            warnUnfinishedFrameDropped()
            framesDrawn += 1
            // 捨てたフレームで積んだ力も落とす。出した粒 (`emit`) は状態の並びへ直に積まれて
            // いて (#934 で持ち越す)、取り消せない
            for (particles, before) in forcesThisFrame {
                particles.value?.dropForces(after: before)
            }
            abandonFrame()
            discardFrame()
        }
        // 閉じ忘れたフレームを捨てた後で見る — 捨てたフレームの中で置いたものは区間の中である
        checkNothingPlacedOutsideTheRegions()
        // 時刻の置き場の持ち主だけが、本体のフレームを数える (``Timebase/frame``)
        if timebase.owner === self { timebase.frame += 1 }
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
        // **自分を置いた面には、断片の面の記録を取り直させる** (``paintSurfacesNoted``)。控えを
        // 持つ面は、自分を読む図形を積んでも記録を飛ばすので、描き始めた後に置いた図形の
        // 「描き切る前に置いた」の注意が出なくなる。自分を置いた面はどれも ``placers`` に居る
        for entry in placers { entry.canvas?.paintSurfacesNoted = nil }
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
        defer {
            abandonFrame()
            // **溜めたものもフレームを越えない。** 描き切りは 6 箇所から投げるので、
            // 片付けを成功経路の末尾だけに置くと、描けなかったフレームの図形が次の
            // フレームでもう一度描かれる (#342)。書いた画素も同じで、写しの書き込み待ちを
            // 残すと次の描き切りが面へ戻す (#1678)。`defer` は投げても走るので、どの
            // 経路を通ってもここでフレームの境目に落ちる
            discardFrame()
        }
        isDrawing = false
        framesDrawn += 1

        // 焼き付けが読むのと同じ光を、描き切りの前に読む (投げても設定の誤りは知らせる)
        warnIfShadowHasNoCaster()
        try flush()
    }

    /// フレームの終わりに、**シーンの記述と開いたままの操作を既定へ戻す。** 溜めたものには
    /// 触らない (それは ``discardFrame()``)。
    ///
    /// 通る道は 2 つある。描き切った後 (``endFrame()`` の `defer`) と、閉じ忘れたフレームを
    /// 描かずに捨てるとき (``beginFrame()`` の頭・[#1622]) である。並びを 1 か所に置くのは、
    /// 戻す状態を境目の関数ごとに手で並べると、並べ落とした状態だけが越えるからである
    /// ([#1671])。
    ///
    /// **描き切る道では、flush の後に呼ぶ** (光と周囲と視点を列が閉じるときに読む・[#1504])。
    /// 捨てる道は描き切らないので、順序の制約は無い。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    /// [#1671]: https://github.com/mokume-metal/mokume/issues/1671
    private func abandonFrame() {
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

    /// 閉じ忘れたまま境目を越えたフレームを捨てたことを、初回だけ知らせる ([#1622])。
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

    // MARK: - 置いた時点の絵を守る

    /// 描き場所を置いたことを、両側に覚えさせる。
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
        // **描き切る前に置いたら知らせる。** 出るのは前のフレームの絵で、しかも
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
        // **記録済みなら相手へは載せ直さない** (#1683 の反証 2 回目)。貼る絵の記録は置くたびに
        // 来るので、相手の `placers` を毎回探さない。こちらの記録と相手の `placers` は組で、
        // 相手が `placers` を空にするときはこちらの記録も落とす (``settle(before:)``)
        guard placedGraphics.insert(ObjectIdentifier(graphics)).inserted else { return }
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
        let placed = ObjectIdentifier(graphics)
        guard placedGraphics.contains(placed) else { return }
        // **相手の `placers` から外れたので、こちらの記録も落とす。** 記録が残ったままだと、
        // 次に置いたとき記録済みとして相手へ載せ直さず (``note(placing:)``)、相手が次に変わる
        // 前に描き切らせてもらえない。描き切れば記録ごと落ちるが、描き切っている最中と、
        // 描き切りに失敗したときは残る
        defer {
            placedGraphics.remove(placed)
            placedGraphicsDrops &+= 1
        }
        guard !isFlushing else { return }
        do {
            // 効果はフレームの終わりに立つ段なので、途中の描き切りでは通さない
            try flush(applyingEffects: false)
        } catch {
            Diagnostics.warn(
                "Could not finish drawing before the drawing target changed: \(error.headline)")
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
    /// 数えるのは 4 箇所 — 環を平らへ落とすとき・穴のために全点を落とすとき・
    /// 読み取り位置の倒れ先を作るとき・耳を切る判定で点を三角形と比べるとき
    /// ([#1595])。**どれか 1 つでも抜くと、そこへ二乗が戻っても数が動かない。**
    ///
    /// [#915]: https://github.com/mokume-metal/mokume/issues/915
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
        // **自分の絵が変わる直前がここ。** 自分を溜めている面を先に描き切らせると、
        // その面には「置いた時点の絵」が残る。`beginDraw()` ではなくここに置くのは、
        // 描き切りが要る経路が対の外にもある (画素の読み出し) ため
        settlePlacersBeforeChange()
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
        // **奥行きはフレームで 1 つ。** 途中の描き切りをまたいで引き継ぎ、塗り直しを
        // 頼まれたときだけ消す (そのフレームをそこから描き直すという意味なので)
        let pass = target.makeRenderPass(
            clearColor: pendingBackground,
            continuingFrame: passesThisFrame > 0 && pendingBackground == nil,
            keepingDepth: !applyingEffects)
        // **次のフレームの入りは、効果を通す前の絵** ([#1469])。前のフレームが描く先へ効果を
        // 通した絵を書いていたら、このフレームの最初の描き切りで控えから戻す。塗り直す
        // 描き切りでは戻さない — 戻しても消えるだけなので、毎フレーム塗り直すスケッチが
        // 払うのは控えへの写しだけになる。
        //
        // **戻すのはここで、`beginFrame()` ではない。** 自分を置いている面を描き切らせる
        // (上の `settlePlacersBeforeChange()`) より先に戻すと、置いた側が効果を通す前の絵を
        // 拾う — 置いた時点の絵は、前のフレームの出口 (効果を通した絵) である
        let startsFrame = passesThisFrame == 0
        let restoresCarry = carriesPictureBeforeEffects && startsFrame && pendingBackground == nil
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
            // **効果を通す前の絵を、何より先に戻す。** CPU の画素の書き戻しより後に戻すと、
            // フレームの外で `pixels` へ書いたものを控えの絵で消してしまう。
            //
            // フレームの外で画素を書けるのは、持ち越しを約束する区間だけである (ADR-0021
            // 決定 4 の追補 (2026-09-27)・[#1672])。描き場所の区間 (`beginDraw()`〜`endDraw()`) は
            // フレームそのもので、そこで書いた画素はこの戻しより後に載る — 書く口 (`set()`・
            // `pixels`) がまず画素を読むので、フレームの最初の描き切りは書く前に済んでいる。
            // 描き場所の区間の外 (`endDraw()` の後) の書き込みは断る。以前は通していたので、
            // 効果を通した絵ごと書き戻され、次のフレームで効果が 2 回掛かった ([#1655])。
            //
            // 残るのは本体の止まっている間のコールバックで書いた画素だけで、先に戻すので、それは
            // 効果を通した絵ごと描く先へ載る。どう扱うかは [#1524] の判断に残す
            //
            // [#1524]: https://github.com/mokume-metal/mokume/issues/1524
            // [#1655]: https://github.com/mokume-metal/mokume/issues/1655
            // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
            if restoresCarry { try encodeCarryRestore(into: commands) }

            // **CPU が画素へ書いたものがあれば、描く前に描画先へ戻す。** 描画先は GPU 専用の
            // 面なので、`pixels` への書き込みは写しに載っている。書いていないフレームは
            // 何も積まない (#753)
            let wroteBack = try target.encodePixelWriteBack(into: commands)

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

            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                throw .encoderUnavailable
            }

            try encodeBatches(into: encoder, shadow: bakedShadow)

            drawCallsInLastFrame = hasPendingGeometry ? batches.count : 0
            flatVerticesInLastFrame = vertices.count
            flatOutlinesInLastFrame = outlinesAssembledThisFrame
            outlinesAssembledThisFrame = 0
            pointScansInLastFrame = pointScansThisFrame
            pointScansThisFrame = 0
            encoder.endEncoding()

            // **描き終えた絵に効果を通す。** 段はすべて出力段の手前に立つので、画面も
            // 書き出しも観測も同じ 1 枚を受け取る (ADR-0023 決定 2)
            let carried = applyingEffects && applyEffects(into: commands)

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
                commands,
                retaining: [
                    HeldFrame(batches: batches, effects: pendingEffects, imageInput: imageInputPass)
                ])
            return (
                submission: submission, wroteBack: wroteBack, shadow: bakedShadow,
                uploaded: uploaded, carried: carried)
        }
        // **いまのスロットを読む投入は、これである。** 次にこのスロットが回ってきた
        // ときに待つ先になる。記録しないと、そのスロットは「いつ読み終わるか分からない
        // まま書いてよい」ことになる (#754)
        frameRing.noteSubmission()
        passesThisFrame += 1
        if assembled.wroteBack { target.markPixelsWrittenBack() }
        gpu.pendingUploads.markUploaded(assembled.uploaded)
        if mirroringPixels { target.markPixelsMirrored(through: assembled.submission) }
        // 焼いたなら、その入力を覚える。使い回したフレームでは同じ値を書き直すだけになる
        if let shadow = assembled.shadow { lastShadowBakeKey = shadow.key }
        // フレームの最初の描き切りで、描く先は効果を通す前の絵に戻ったか塗り直された。
        // このコマンドが効果を通していれば、描く先はまた効果を通した絵になっている
        if startsFrame { carriesPictureBeforeEffects = false }
        if assembled.carried { carriesPictureBeforeEffects = true }

        // **描き切ったらその場で片付ける。** 片付けをフレームの頭に置くと、フレームの
        // 途中で描き切ったときに溜めたものが残り、同じ図形が 2 度描かれる。
        // ここは**描き切れたときだけ**の片付けで、投げたときは `draw(_:)` の
        // `defer` が同じことをする (#342) — 途中の描き切り (`loadPixels()`) が
        // 一時的に失敗しただけなら、溜めたものはフレーム末尾の描き切りに残す
        discardFrame()
    }

    /// 溜めた列を 1 つずつ積む。**溜めたものが 1 つも無ければ何も積まない** —
    /// 置き場を取ることも、encoder の状態を変えることもしない。
    private func encodeBatches(
        into encoder: any MTL4RenderCommandEncoder,
        shadow bakedShadow: BakedShadow?
    ) throws(RenderFailure) {
        guard hasPendingGeometry else { return }

        // **置き場は積む前に全部取る。** 番地を束ねたあとに取り直すと、束ねた先が
        // 死んだ置き場を指す (``GrowableBuffer/buffer(holding:)``)
        let geometry = try uploadGeometry(reusing: bakedShadow?.solidUploads)
        let perBatch = try uploadPerBatch(shadow: bakedShadow)

        // **見る窓は実際に刻む画素で測る。** 落とす行列は出す細かさで書かれた
        // 座標を -1…1 へ正規化するので、窓を狭めればそのまま細かく刻まれる。
        //
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(pixelWidth), height: Double(pixelHeight),
                znear: 0, zfar: 1))

        for (index, batch) in batches.enumerated() {
            let run = batch.run
            // 並びごとに、頂点の落とし方と奥行きの扱いを切り替える。**平面は奥行きを
            // 書かない**ので、あとから来た立体の前後関係を汚さない (ADR-0021 決定 2)
            switch batch.source {
            case .flat:
                encoder.setRenderPipelineState(
                    (run.paint.shader?.states ?? pipeline.states).state(for: run.mode))
                encoder.setDepthStencilState(pipeline.flatDepthState)
                pipeline.argumentTable.setAddress(
                    geometry.flatVertices.gpuAddress, index: ShapePipeline.vertexBufferIndex)
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
                        .state(for: run.mode))
                encoder.setDepthStencilState(pipeline.solidDepthState)
                pipeline.argumentTable.setAddress(
                    (batch.ownVertices ?? geometry.solidVertices).gpuAddress,
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
            } else if batch.source == .form {
                // 基本図形はクアッド 1 枚 (頂点 6 つ) を置き場所の数だけ描く。頂点関数が
                // `vertex_id` から角を決めるので、頂点の並びは読まない
                encoder.drawPrimitives(
                    primitiveType: .triangle,
                    vertexStart: 0, vertexCount: Self.formQuadVertexCount,
                    instanceCount: batch.instanceCount)
            } else {
                encodeSolidDraw(
                    run, instanceCount: batch.instanceCount, indices: geometry.solidIndices,
                    on: encoder)
            }
        }
    }

    /// 列の三角形を出す。**添字を持つ列は添字で読む** (``Shape/Run/isIndexed``)。
    ///
    /// 画面と影の焼き付けで**同じ判定を通す**。片方だけ非添字のまま残すと、影だけが
    /// 別の形 (頂点を 3 つずつ束ねた並び) で焼かれる — 絵は出るので、影が崩れるまで
    /// 誰も気づけない。
    ///
    /// 添字は ``solidVertices`` の番号そのものなので `baseVertex` はずらさない。
    private func encodeSolidDraw(
        _ run: Shape.Run, instanceCount: Int, indices: any MTLBuffer,
        on encoder: any MTL4RenderCommandEncoder
    ) {
        guard run.isIndexed else {
            encoder.drawPrimitives(
                primitiveType: .triangle,
                vertexStart: run.start, vertexCount: run.count, instanceCount: instanceCount)
            return
        }
        let stride = MemoryLayout<UInt32>.stride
        encoder.drawIndexedPrimitives(
            primitiveType: .triangle, indexCount: run.indexCount, indexType: .uint32,
            indexBuffer: indices.gpuAddress + UInt64(run.indexStart * stride),
            indexBufferLength: run.indexCount * stride,
            instanceCount: instanceCount)
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
            flatVertices: buffer, formInstances: formBuffer,
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

    /// 列ごとの値と、フレームに 1 つの値 (時刻・面の大きさ・影・揺らぎ) を置く。
    private func uploadPerBatch(
        shadow bakedShadow: BakedShadow?
    ) throws(RenderFailure) -> BatchBuffers {
        // 列ごとの行列を並べて置く。**列が閉じた時点の見る位置**がそのまま入る
        let matrices = try matrixStorage.buffer(holding: batches.count)
        let unitsPerDrawnPixel = self.unitsPerDrawnPixel
        for (index, batch) in batches.enumerated() {
            // 行列のすぐ後ろに、輪郭の頂点が始まる番号を置く。**立体は行列しか
            // 読まない**ので、同じ区画に足しても効かない
            var frame = FlatFrame(
                projection: batch.matrix,
                strokeStart: UInt32(min(batch.strokeStart, Int(UInt32.max))),
                strokeShift: Self.solidStrokeShift(width: width, height: height),
                unitsPerDrawnPixel: unitsPerDrawnPixel)
            matrices.contents().advanced(by: index * Self.valuesStride)
                .copyMemory(from: &frame, byteCount: MemoryLayout<FlatFrame>.stride)
        }

        // 時刻と面の大きさは、フレームの中で変わらない。**大きさは実際に刻む
        // 画素**である — 断片が受け取る位置 (`position`) がその数で来るので、
        // 割って出す 0…1 の位置がここと食い違うと面からはみ出す
        let uniformsBuffer = try uniformsStorage.buffer(holding: 1)
        // 影の行列と設定も**フレームに 1 つ**で、列ごとには変わらない。揺らぎの種と
        // 細かさは、**断片が種を受け取る**ので、利用者が値として配線しなくても CPU の
        // `noise()` と同じ模様が出る
        var uniforms = Uniforms(
            time: time,
            resolution: SIMD2(Float(pixelWidth), Float(pixelHeight)),
            shadowBias: shadowBiasValue,
            shadowMatrix: bakedShadow?.matrix ?? matrix_identity_float4x4,
            shadowParams: SIMD4(
                bakedShadow == nil ? 0 : 1, 1 / Float(bakedShadow?.map.detail ?? 1), 0, 0),
            noiseSeed: noiseSettings.seed,
            noiseOctaves: UInt32(noiseSettings.octaves),
            noiseFalloff: noiseSettings.falloff)
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

        // 列ごとの値を並べて置く。**列が閉じた時点の値**がそのまま入っている
        let lighting = try lightingStorage.buffer(holding: batches.count)
        for (index, batch) in batches.enumerated() {
            var packed = Lighting(
                offset: UInt32(batch.lightRange.lowerBound),
                count: UInt32(batch.lightRange.count),
                viewer: batch.viewer,
                view: batch.view)
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
            // **区画に収まることは入口で保証されている** (`Canvas.loadShader` /
            // `makeShader` が `valueSlotCapacity` を超える宣言を断る・#348)。ここで
            // 切り詰めないのは、黙って切り詰めると断片の `Values` に「宣言したのに
            // 一度も書かれない欄」が残り、絵が永久に間違ったまま出るためである
            let slot = values.contents().advanced(by: index * Self.valuesStride)
                .assumingMemoryBound(to: Float.self)
            if var stroke = batch.strokePlacement {
                UnsafeMutableRawPointer(slot).copyMemory(
                    from: &stroke, byteCount: MemoryLayout<SolidStrokePlacement>.stride)
            } else if batch.run.paint.values.isEmpty {
                slot.update(repeating: 0, count: 4)
            } else {
                slot.update(from: batch.run.paint.values, count: batch.run.paint.values.count)
            }
        }
        return values
    }

    /// 頂点と置き場所の置き場。``uploadGeometry()`` が満たし、列を積むときに読む。
    private struct GeometryBuffers {
        let flatVertices: any MTLBuffer
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
    /// して ``RenderDevice/commit(_:retaining:)`` へ渡す。頂点や列ごとの値の置き場は
    /// この型が持ち続けるので、ここには要らない。
    private final class HeldFrame {
        let batches: [Batch]
        let effects: [Effect]
        let imageInput: ImageInputPass?
        init(batches: [Batch], effects: [Effect], imageInput: ImageInputPass?) {
            self.imageInput = imageInput
            self.batches = batches
            self.effects = effects
        }
    }

    /// 立体の置き場所の置き場。
    private let solidInstanceStorage: GrowableBuffer

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
        guard !casting.isEmpty else { return nil }

        // **前のフレームと同じ入力なら焼き直さない。** 光の行列・細かさ・落とす列の
        // 頂点と置き場所が 1 バイトも変わっていなければ、焼いても同じ奥行きが出るだけ
        // である。指紋は焼く直前に取り、**覚えるのは描き切りが投入した後** (`flush`) —
        // 焼き付けを積んだ後で投げたフレームの指紋を覚えると、次のフレームが焼けていない
        // 面を読む ([#1183])。投入されなかった焼き付けは面を書き換えていないので、前の
        // 指紋のまま使い回して正しい
        //
        // [#1183]: https://github.com/mokume-metal/mokume/issues/1183
        let detail = shadowDetailValue
        let key = shadowBakeKey(matrix: matrix, detail: detail, casting: casting)
        if let key, key == lastShadowBakeKey, let shadowMap, shadowMap.detail == detail {
            shadowBakesReused += 1
            return BakedShadow(map: shadowMap, matrix: matrix, key: key, solidUploads: nil)
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
        pipeline.argumentTable.setAddress(
            solidBuffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
        pipeline.argumentTable.setAddress(
            matrixBuffer.gpuAddress, index: ShapePipeline.projectionBufferIndex)
        // **束ねるのは頂点段だけ。** 焼くパイプラインは断片を持たない (奥行きの面へは
        // 前後判定が書く) ので、断片段に渡すものが無い
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex])
        for (batchIndex, batch) in batches.enumerated() where batch.castsShadow {
            encoder.setRenderPipelineState(
                batch.strokeGeometry == nil ? pipeline.shadowState : pipeline.solidStrokeShadowState)
            pipeline.argumentTable.setAddress(
                (batch.ownVertices ?? solidBuffer).gpuAddress,
                index: ShapePipeline.vertexBufferIndex)
            pipeline.argumentTable.setAddress(
                batchValues.gpuAddress + UInt64(batchIndex * Self.valuesStride),
                index: ShapePipeline.valuesBufferIndex)
            pipeline.argumentTable.setAddress(
                (batch.instances?.storage ?? instanceBuffer).gpuAddress
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
                encodeSolidDraw(
                    batch.run, instanceCount: batch.instanceCount, indices: solidIndexBuffer,
                    on: encoder)
            }
        }
        encodeShadowBarrier(on: encoder)
        encoder.endEncoding()
        shadowBakesEncoded += 1
        return BakedShadow(map: map, matrix: matrix, key: key, solidUploads: solid)
    }

    /// 焼いた (または使い回した) 影と、その入力の指紋。
    private struct BakedShadow {
        let map: ShadowMap
        let matrix: simd_float4x4
        /// 焼き付けの入力の指紋。**投入した後で `lastShadowBakeKey` へ覚える。**
        /// 指紋を取れない入力 (粒) では `nil` で、覚えると次のフレームが使い回さない
        let key: UInt64?
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
    private func shadowBakeKey(
        matrix: simd_float4x4, detail: Int, casting: [Batch]
    ) -> UInt64? {
        var hasher = ShadowBakeHasher()
        withUnsafeBytes(of: matrix) { hasher.mix($0) }
        hasher.mix(UInt64(detail))
        hasher.mix(UInt64(casting.count))
        for batch in casting {
            guard batch.instances == nil else { return nil }
            if batch.strokeGeometry != nil {
                // 形の鍵は下で混ぜる。視点・太さ・変換も焼かれる帯を変える。
                hasher.mix(4)
                withUnsafeBytes(of: batch.strokePlacement!) { hasher.mix($0) }
            }
            hasher.mix(UInt64(batch.run.start))
            hasher.mix(UInt64(batch.run.count))
            hasher.mix(UInt64(batch.instanceStart))
            hasher.mix(UInt64(batch.instanceCount))
            hasher.mix(UInt64(batch.cullMode.rawValue))
            // 焼く側の表の巻き方も焼き付く奥行きを変える (鏡映の符号だけで決まる)
            hasher.mix(batch.isMirrored ? 1 : 0)
            // **読む順も焼く側が読むものである。** 頂点を 1 バイトも動かさずに添字だけを
            // 組み直すフレーム (面の張り替え・粗さの切り替え) は `index(_:)` がまさに
            // 誘う書き方で、これを混ぜないと前のフレームの影が居座る
            hasher.mix(UInt64(batch.run.indexStart))
            hasher.mix(UInt64(batch.run.indexCount))
            solidIndices.withUnsafeBytes { bytes in
                let stride = MemoryLayout<UInt32>.stride
                let end = min(
                    bytes.count, (batch.run.indexStart + batch.run.indexCount) * stride)
                let start = min(end, batch.run.indexStart * stride)
                hasher.mix(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            }
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
                solidVertices.withUnsafeBytes { bytes in
                    let stride = MemoryLayout<SolidVertex>.stride
                    let end = min(bytes.count, (batch.run.start + batch.run.count) * stride)
                    let start = min(end, batch.run.start * stride)
                    hasher.mix(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                }
            }
            solidInstances.withUnsafeBytes { bytes in
                let stride = MemoryLayout<SolidInstance>.stride
                let end = min(bytes.count, (batch.instanceStart + batch.instanceCount) * stride)
                let start = min(end, batch.instanceStart * stride)
                hasher.mix(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            }
        }
        return hasher.finish()
    }

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
