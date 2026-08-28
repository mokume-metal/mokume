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
    /// 幅 (画素)。
    public let width: Float
    /// 高さ (画素)。
    public let height: Float

    let target: RenderTarget
    let gpu: RenderDevice
    let pipeline: ShapePipeline

    /// 描画先の座標へ落とす行列。半画素のずらしを含む。
    private let projection: simd_float4x4
    private let projectionBuffer: any MTLBuffer

    /// 溜めている頂点と、その置き場。
    var vertices: [ShapeVertex] = []
    private var vertexBuffer: (any MTLBuffer)?
    private var vertexCapacity = 0

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
    }

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
    /// 焼き付け先。**同じ細かさなら作り直さない** (同 決定 4)。
    private var shadowMap: ShadowMap?
    /// 焼き付け先を作った回数 (作ってから通算)。
    ///
    /// **作り直していないかを数える値。** 毎フレーム宣言してよい形にした以上、
    /// 宣言のたびに確保していないことは絵では分からない。
    private(set) var shadowMapsBuilt = 0
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
    /// いま読んでいる面の中身の種類。
    var currentTextureKind = TextureKind.coverage
    /// いま効いている塗り。`nil` なら組み込み。
    var currentShader: Shader?
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
        /// 平面は置き場所を持たない (1 個ぶんだけ描く)。
        var instanceStart: Int = 0
        var instanceCount: Int = 1

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

    /// いまのフレームの時刻 (秒)。利用者の断片から読める。
    var time: Float = 0
    /// 面の中身の種類の番号を置いた領域。同じく番地で指す。
    private let textureKindBuffer: any MTLBuffer
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

    /// 描画先を指定して作る。
    public init(target: RenderTarget, gpu: RenderDevice) throws(RenderFailure) {
        self.target = target
        self.gpu = gpu
        self.width = Float(target.width)
        self.height = Float(target.height)
        self.pipeline = try ShapePipeline(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
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

        let kinds = TextureKind.allCases
        let kindBuffer = try gpu.makeReadableBuffer(
            byteCount: kinds.count * Self.blendModeStride)
        for kind in kinds {
            let slot = kindBuffer.contents()
                .advanced(by: Int(kind.rawValue) * Self.blendModeStride)
                .assumingMemoryBound(to: UInt32.self)
            slot.pointee = kind.rawValue
        }
        self.textureKindBuffer = kindBuffer

        // 時刻と面の大きさ。フレームごとに書き換わるので 1 区画だけ持つ
        self.uniformsBuffer = try gpu.makeReadableBuffer(byteCount: Self.valuesStride)
    }

    /// これから置く頂点が読む面を決める。**変わるなら列を閉じる。**
    ///
    /// 閉じ忘れると、既に置いた図形や字が後から差し替わった面を読む。
    func useTexture(_ texture: any MTLTexture, kind: TextureKind) {
        if texture === currentTexture, kind == currentTextureKind { return }
        closeBatch()
        currentTexture = texture
        currentTextureKind = kind
    }

    /// 図形と字が読む面 (字形の置き場) へ戻す。
    func useGlyphTexture() {
        useTexture(atlas.texture, kind: .coverage)
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

    // これから描く図形の塗りの色。**塗りを止めていたら、呼んだ時点で再び塗るようになる。**
    public func fill(_ color: LinearRGBA) {
        currentFill = color
        hasFill = true
    }

    /// 図形の内側を塗らない。
    public func noFill() { hasFill = false }

    // これから引く線の色。**線を止めていたら、呼んだ時点で再び引くようになる。**
    public func stroke(_ color: LinearRGBA) {
        currentStroke = color
        hasStroke = true
    }

    /// 線を引かない。図形の輪郭も出なくなる。
    public func noStroke() { hasStroke = false }

    // これから引く線の太さ (画素)。
    public func strokeWeight(_ weight: Float) { currentStrokeWeight = max(0, weight) }

    // 描くものを、この矩形の中だけに収める。座標の読み方は ``rectMode(_:)`` が決める。
    //
    // **溜めている列をその場で閉じる** (混ぜ方と同じ理由)。積み降ろし
    // (``pushStyle()``) で戻るので、入れ子にして元へ帰れる。
    //
    // 面の外へ出た指定は面の内側へ収める — この世代の GPU は範囲外の切り抜きを
    // 受け取ると検証で落ちるので、指定をそのまま渡さない。
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

    // 切り抜きをやめる。
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
        let start = batches.last(where: { $0.source == .flat })
            .map { $0.run.start + $0.run.count } ?? 0
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    textureKind: currentTextureKind, shader: currentShader,
                    values: currentShader?.packedValues ?? [], source: openSource,
                    start: start, count: count),
                clip: currentClip,
                matrix: openSource == .flat ? projection : viewProjection,
                // 平面は光を受けない。立体は**閉じた時点に効いていた光**で描かれる
                lightRange: openSource == .flat ? 0..<0 : bakeActiveLights(),
                material: .default,
                viewer: SIMD4(0, 0, -1, 0),
                surroundings: bakeSurroundings(),
                castsShadow: false))
    }

    /// 開いている立体の列を閉じる。
    ///
    /// 頂点の区間と置き場所の区間を**両方**持って閉じる。頂点は形ごとに 1 組しか
    /// 無いので、「最後の列の終わりが次の始まり」という数え方はできない。
    private func closeSolidBatch() {
        guard let open = openSolid else { return }
        openSolid = nil
        let instanceCount = solidInstances.count - open.instanceStart
        guard open.vertexCount > 0, instanceCount > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    textureKind: currentTextureKind, shader: currentShader,
                    values: currentShader?.packedValues ?? [], source: .solid,
                    start: open.vertexStart, count: open.vertexCount),
                clip: currentClip,
                matrix: viewProjection,
                lightRange: bakeActiveLights(),
                material: currentMaterial.receiving(shadow: receivesShadow),
                viewer: viewer,
                surroundings: bakeSurroundings(),
                castsShadow: castsShadow,
                instanceStart: open.instanceStart, instanceCount: instanceCount))
        warnIfMaterialCannotShow()
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

    // 原点をずらす。
    public func translate(_ x: Float, _ y: Float) { transform.translate(x: x, y: y) }

    // 回す。縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    public func rotate(_ radians: Float) { transform.rotate(by: radians) }

    // 伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float) { transform.scale(x: x, y: y) }

    // 横方向へ斜めに歪める。
    public func shearX(_ radians: Float) { transform.shearX(by: radians) }

    // 縦方向へ斜めに歪める。
    public func shearY(_ radians: Float) { transform.shearY(by: radians) }

    // 与えた変換を、いまの変換の後に重ねる。
    public func applyMatrix(_ other: Transform) { transform.concatenate(other) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てない — 戻す先は残る。
    public func resetMatrix() { transform.reset() }

    // いまの変換を積んでおく。
    public func pushMatrix() { transformStack.append(transform) }

    // 積んでおいた変換へ戻す。積んでいなければ何もしない。
    public func popMatrix() {
        guard let restored = transformStack.popLast() else { return }
        transform = restored
    }

    /// いまのスタイルを積んでおく。
    public func pushStyle() { styleStack.append(currentStyle) }

    // 積んでおいたスタイルへ戻す。積んでいなければ何もしない。
    public func popStyle() {
        guard let restored = styleStack.popLast() else { return }
        currentStyle = restored
    }

    /// 変換とスタイルの両方を積んでおく。
    public func push() {
        pushMatrix()
        pushStyle()
    }

    // 積んでおいた変換とスタイルの両方へ戻す。積んでいなければ何もしない。
    public func pop() {
        popMatrix()
        popStyle()
    }

    // MARK: - 座標

    /// 点が、いまの変換でどこへ移るか (横)。
    public func screenX(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).x }

    // 点が、いまの変換でどこへ移るか (縦)。
    public func screenY(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).y }

    // MARK: - 図形

    // 面全体を塗り直す。
    //
    // それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    // 描く手間をかける意味がない。
    public func background(_ color: LinearRGBA) {
        vertices.removeAll(keepingCapacity: true)
        solidVertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        pendingBackground = color
    }

    /// 矩形。座標の読み方は ``rectMode(_:)`` が決める。
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
        guard box.width > 0, box.height > 0 else { return }
        let x = box.x
        let y = box.y
        let w = box.width
        let h = box.height
        draw(
            Outline(
                points: [
                    SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h),
                ], isClosed: true))
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
        let center = SIMD2(box.x + radiusX, box.y + radiusY)
        draw(
            Outline(
                points: Self.arcPoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    from: 0, sweep: 2 * .pi),
                isClosed: true, fanCenter: center))
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
        let center = SIMD2(box.x + radiusX, box.y + radiusY)
        let sweep = min(stop - start, 2 * .pi)
        let arcPoints = Self.arcPoints(
            center: center, radiusX: radiusX, radiusY: radiusY, from: start, sweep: sweep)
        // 一周ぶんなら中心は周に含めない (楕円と同じ形になる)
        let isFullTurn = sweep >= 2 * .pi
        draw(
            Outline(
                points: isFullTurn ? arcPoints : [center] + arcPoints,
                isClosed: true, fanCenter: center))
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
    }

    /// 周から、塗りと輪郭を出す。
    private func draw(_ outline: Outline) {
        if outline.fills, hasFill { fillInterior(outline) }
        if hasStroke, currentStrokeWeight > 0 { strokeOutline(outline) }
    }

    /// 周の内側を塗る。
    private func fillInterior(_ outline: Outline) {
        let points = outline.points
        guard points.count >= 3 else { return }
        let pivot = outline.fanCenter ?? points[0]
        let center = transform.apply(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return }
        var previous = transform.apply(x: ring[0].x, y: ring[0].y)
        for point in ring.dropFirst() {
            let current = transform.apply(x: point.x, y: point.y)
            appendTriangle(center, previous, current, color: currentFill)
            previous = current
        }
        if outline.fanCenter != nil, outline.isClosed {
            let first = transform.apply(x: ring[0].x, y: ring[0].y)
            appendTriangle(center, previous, first, color: currentFill)
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
    /// `r(1 − cos(π/n))`。これを 0.25 画素以下に収める `n` を選ぶ。半径が大きいほど
    /// 細かくなるが、上下で頭打ちにする — 小さすぎる円に 32 辺は無駄がなく、
    /// 大きすぎる円に 128 辺を超えて割いても見た目は変わらない。
    ///
    /// 拡大縮小の変換は考えない。拡大した円が粗くなるのは受け入れる。
    static func segmentCount(forRadius radius: Float) -> Int {
        let tolerance: Float = 0.25
        guard radius.isFinite, radius > tolerance else { return 32 }
        let n = Float.pi / acos(max(-1, 1 - tolerance / radius))
        guard n.isFinite else { return 32 }
        return min(128, max(32, Int(n.rounded(.up))))
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
        currentTextureKind = .coverage
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
        _ image: Image, x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
        image.uploadIfNeeded()
        useTexture(image.texture, kind: .color)

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
    func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
        colors: (LinearRGBA, LinearRGBA, LinearRGBA)
    ) {
        // **図形は白い区画を読む。** 直前に画像を描いていたら、その面を読んだままに
        // なるので戻す (変わらなければ何も起きない)
        beginFlat()
        useGlyphTexture()
        vertices.append(ShapeVertex(position: a, uv: whiteUV, color: colors.0))
        vertices.append(ShapeVertex(position: b, uv: whiteUV, color: colors.1))
        vertices.append(ShapeVertex(position: c, uv: whiteUV, color: colors.2))
    }

    // MARK: - 描き切る

    /// 1 フレーム分を描く。
    ///
    /// `body` の中で呼んだ図形が溜められ、抜けるときにまとめて描画先へ落ちる。
    /// GPU が終わるまで待ってから返る。
    public func draw(_ body: () -> Void) throws(RenderFailure) {
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
        }
        currentClip = nil
        transform = .identity
        transformStack.removeAll(keepingCapacity: true)
        hasLoadedPixels = false
        // 光もフレームを越えない (同 決定 4)。ここで空に戻る
        activeLights.removeAll(keepingCapacity: true)
        activeSurroundings = nil
        lightStorage.removeAll(keepingCapacity: true)

        isDrawing = true
        body()
        isDrawing = false

        try flush()
    }

    /// 直前のフレームで描画を呼んだ回数。
    ///
    /// **畳めているかを数えるための値。** 絵が同じでも畳まれていなければ保持は目的を
    /// 果たしていないので、絵ではなく回数で確かめる。
    private(set) var drawCallsInLastFrame = 0

    /// 検査から「描けなかったフレーム」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 描画の失敗は環境か資源が枯れたときにしか起きず、検査から自然には作れない。
    /// 一方で**描けなかったときに何が起きるか**は回帰検査を置くべき場所そのものなので
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))、ここに 1 つだけ
    /// 穴を空けてある。公開はしない。
    var failureForTesting: RenderFailure?

    func flush() throws(RenderFailure) {
        if let failureForTesting { throw failureForTesting }
        closeBatch()
        let pass = target.makeRenderPass(clearColor: pendingBackground)
        let commands = try gpu.beginCommands()

        // **画面へ描く前に、光から見た奥行きを焼く。** 同じコマンドの中で順に流すので、
        // 焼き上がりを待つ仕掛けは要らない (GPU がこの順で実行する)
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
                matrices.contents().advanced(by: index * Self.valuesStride)
                    .copyMemory(from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)
            }
            encoder.setViewport(
                MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(width), height: Double(height),
                    znear: 0, zfar: 1))

            // 時刻と面の大きさは、フレームの中で変わらない
            uniformsBuffer.contents().assumingMemoryBound(to: Float.self)
                .update(from: [time, 0, width, height, shadowBiasValue], count: 5)
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
                case .solid:
                    encoder.setRenderPipelineState(pipeline.solidState)
                    encoder.setDepthStencilState(pipeline.solidDepthState)
                    pipeline.argumentTable.setAddress(
                        solidBuffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
                    // **置き場所は列の先頭からを渡す。** そうすれば断片の側は 0 から
                    // 数えるだけで済み、列ごとの下駄を持ち歩かなくてよい
                    pipeline.argumentTable.setAddress(
                        instanceBuffer.gpuAddress
                            + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
                        index: ShapePipeline.instanceBufferIndex)
                }
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
                encoder.setScissorRect(
                    batch.clip
                        ?? MTLScissorRect(x: 0, y: 0, width: Int(width), height: Int(height)))
                pipeline.argumentTable.setAddress(
                    blendModeBuffer.gpuAddress
                        + UInt64(Int(run.mode.rawIndex) * Self.blendModeStride),
                    index: ShapePipeline.blendModeBufferIndex)
                pipeline.argumentTable.setTexture(
                    run.texture.gpuResourceID, index: ShapePipeline.textureIndex)
                pipeline.argumentTable.setAddress(
                    textureKindBuffer.gpuAddress
                        + UInt64(Int(run.textureKind.rawValue) * Self.blendModeStride),
                    index: ShapePipeline.textureKindBufferIndex)
                encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
                encoder.drawPrimitives(
                    primitiveType: .triangle,
                    vertexStart: run.start, vertexCount: run.count,
                    instanceCount: batch.instanceCount)
            }
        }

        drawCallsInLastFrame = vertices.isEmpty && solidVertices.isEmpty ? 0 : batches.count
        encoder.endEncoding()
        try gpu.commitAndWait(commands)

        // **描き切ったらその場で片付ける。** 片付けをフレームの頭に置くと、フレームの
        // 途中で描き切ったときに溜めたものが残り、同じ図形が 2 度描かれる
        vertices.removeAll(keepingCapacity: true)
        solidVertices.removeAll(keepingCapacity: true)
        solidInstances.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        openSolid = nil
        openSource = .flat
        pendingBackground = nil
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
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
        for batch in casting {
            pipeline.argumentTable.setAddress(
                instanceBuffer.gpuAddress
                    + UInt64(batch.instanceStart * MemoryLayout<SolidInstance>.stride),
                index: ShapePipeline.instanceBufferIndex)
            encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(
                primitiveType: .triangle,
                vertexStart: batch.run.start, vertexCount: batch.run.count,
                instanceCount: batch.instanceCount)
        }
        encoder.endEncoding()
        return (map, matrix)
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
