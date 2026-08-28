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
    private let gpu: RenderDevice
    private let pipeline: ShapePipeline

    /// 描画先の座標へ落とす行列。半画素のずらしを含む。
    private let projection: simd_float4x4
    private let projectionBuffer: any MTLBuffer

    /// 溜めている頂点と、その置き場。
    private var vertices: [ShapeVertex] = []
    private var vertexBuffer: (any MTLBuffer)?
    private var vertexCapacity = 0

    /// このフレームで塗り直す色。`nil` なら前の内容の上に描き足す。
    private var pendingBackground: LinearRGBA?

    // MARK: - 描く状態

    private var currentFill = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    private var currentStroke = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    private var currentStrokeWeight: Float = 1
    private var transform = Transform2D.identity
    private var transformStack: [Transform2D] = []
    private var currentRectMode = ShapeMode.corner
    private var currentEllipseMode = ShapeMode.center
    private var currentStrokeCap = StrokeCap.round
    private var currentStrokeJoin = StrokeJoin.miter
    private var hasFill = true
    private var hasStroke = true
    private var styleStack: [Style] = []
    private var currentBlendMode = BlendMode.blend
    private var currentClip: MTLScissorRect?
    private var warnedReversedArc = false
    private var warnedVertexOutsideShape = false

    // MARK: 文字

    /// 字形を焼いて溜める面。**図形もここの白い区画を読む** (``GlyphAtlas``)。
    let atlas: GlyphAtlas
    /// いま列が読んでいる面。面を広げると差し替わる。
    private var currentTexture: any MTLTexture
    /// 図形が指す、白い区画の中の点。面を広げるたびに取り直す。
    private var whiteUV: SIMD2<Float>
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
    var warnedMissingFont = false
    var warnedAtlasFull = false

    // MARK: - 組み立て中の形

    /// 並べている途中の頂点。``beginShape(_:)`` から ``endShape(_:)`` までの間だけ中身を持つ。
    private var shapePoints: [SIMD2<Float>] = []
    /// 並べ終えた穴。
    private var shapeHoles: [[SIMD2<Float>]] = []
    /// 穴を並べている最中なら、その点。
    private var holePoints: [SIMD2<Float>]?
    private var shapeKind = VertexKind.polygon
    private var isBuildingShape = false
    private var currentCurveDetail = 20
    private var currentCurveTightness: Float = 0
    /// 通過点を結ぶ曲線の制御点。4 つ揃うごとに 1 区間を引く。
    private var curveGuides: [SIMD2<Float>] = []

    /// 閉じた列。**同じ列は単一の混ぜ方でしか描かれない。**
    ///
    /// 混ぜ方を変える操作がその時点で列を閉じるので、既に置いた図形が後の設定で
    /// 描かれることがない。閉じ忘れると絵は「たまに」おかしくなる — 設定を変えない
    /// 単純なスケッチでは一生出ないので、規律として持つ。
    private var batches:
        [(
            mode: BlendMode, clip: MTLScissorRect?, texture: any MTLTexture, start: Int,
            count: Int
        )] = []

    /// 混ぜ方の番号を置いた領域。列ごとに番地をずらして指す。
    private let blendModeBuffer: any MTLBuffer
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
                textLeading: currentTextLeading, textWrap: currentTextWrap)
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

    /// これから描く図形の塗りの色。**塗りを止めていたら、呼んだ時点で再び塗るようになる。**
    public func fill(_ color: LinearRGBA) {
        currentFill = color
        hasFill = true
    }

    /// 図形の内側を塗らない。
    public func noFill() { hasFill = false }

    /// これから引く線の色。**線を止めていたら、呼んだ時点で再び引くようになる。**
    public func stroke(_ color: LinearRGBA) {
        currentStroke = color
        hasStroke = true
    }

    /// 線を引かない。図形の輪郭も出なくなる。
    public func noStroke() { hasStroke = false }

    /// これから引く線の太さ (画素)。
    public func strokeWeight(_ weight: Float) { currentStrokeWeight = max(0, weight) }

    /// 描くものを、この矩形の中だけに収める。座標の読み方は ``rectMode(_:)`` が決める。
    ///
    /// **溜めている列をその場で閉じる** (混ぜ方と同じ理由)。積み降ろし
    /// (``pushStyle()``) で戻るので、入れ子にして元へ帰れる。
    ///
    /// 面の外へ出た指定は面の内側へ収める — この世代の GPU は範囲外の切り抜きを
    /// 受け取ると検証で落ちるので、指定をそのまま渡さない。
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

    /// 切り抜きをやめる。
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
    private func closeBatch() {
        let start = batches.last.map { $0.start + $0.count } ?? 0
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append((currentBlendMode, currentClip, currentTexture, start, count))
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

    /// 原点をずらす。
    public func translate(_ x: Float, _ y: Float) { transform.translate(x: x, y: y) }

    /// 回す。縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    public func rotate(_ radians: Float) { transform.rotate(by: radians) }

    /// 伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float) { transform.scale(x: x, y: y) }

    /// 横方向へ斜めに歪める。
    public func shearX(_ radians: Float) { transform.shearX(by: radians) }

    /// 縦方向へ斜めに歪める。
    public func shearY(_ radians: Float) { transform.shearY(by: radians) }

    /// 与えた変換を、いまの変換の後に重ねる。
    public func applyMatrix(_ other: Transform2D) { transform.concatenate(other) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てない — 戻す先は残る。
    public func resetMatrix() { transform.reset() }

    /// いまの変換を積んでおく。
    public func pushMatrix() { transformStack.append(transform) }

    /// 積んでおいた変換へ戻す。積んでいなければ何もしない。
    public func popMatrix() {
        guard let restored = transformStack.popLast() else { return }
        transform = restored
    }

    /// いまのスタイルを積んでおく。
    public func pushStyle() { styleStack.append(currentStyle) }

    /// 積んでおいたスタイルへ戻す。積んでいなければ何もしない。
    public func popStyle() {
        guard let restored = styleStack.popLast() else { return }
        currentStyle = restored
    }

    /// 変換とスタイルの両方を積んでおく。
    public func push() {
        pushMatrix()
        pushStyle()
    }

    /// 積んでおいた変換とスタイルの両方へ戻す。積んでいなければ何もしない。
    public func pop() {
        popMatrix()
        popStyle()
    }

    // MARK: - 座標

    /// 点が、いまの変換でどこへ移るか (横)。
    public func screenX(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).x }

    /// 点が、いまの変換でどこへ移るか (縦)。
    public func screenY(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).y }

    // MARK: - 図形

    /// 面全体を塗り直す。
    ///
    /// それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    /// 描く手間をかける意味がない。
    public func background(_ color: LinearRGBA) {
        vertices.removeAll(keepingCapacity: true)
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

    /// 線。塗りは持たない。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2)], isClosed: false, fills: false))
    }

    /// 点。大きさは線の太さ、形は端点の形 (``strokeCap(_:)``) が決める。
    public func point(_ x: Float, _ y: Float) {
        draw(Outline(points: [SIMD2(x, y)], isClosed: false, fills: false))
    }

    // MARK: - 頂点を並べて描く

    /// 頂点を並べ始める。
    public func beginShape(_ kind: VertexKind = .polygon) {
        isBuildingShape = true
        shapeKind = kind
        shapePoints.removeAll(keepingCapacity: true)
        shapeHoles.removeAll(keepingCapacity: true)
        holePoints = nil
    }

    /// 頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float) {
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce()
            return
        }
        appendShapePoint(SIMD2(x, y))
    }

    /// 3 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    ///
    /// 手前に点が無いときは何もしない — 曲線は「いまの点から」繋ぐものなので、
    /// 始点が無ければ引きようがない。
    public func bezierVertex(
        _ cx1: Float, _ cy1: Float, _ cx2: Float, _ cy2: Float, _ x: Float, _ y: Float
    ) {
        guard isBuildingShape, let start = lastShapePoint else {
            warnVertexOutsideShapeOnce()
            return
        }
        let c1 = SIMD2(cx1, cy1)
        let c2 = SIMD2(cx2, cy2)
        let end = SIMD2(x, y)
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            appendShapePoint(Self.cubicPoint(start, c1, c2, end, t))
        }
    }

    /// 2 次の曲線で、いまの点から `x`・`y` まで繋ぐ。
    public func quadraticVertex(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        guard isBuildingShape, let start = lastShapePoint else {
            warnVertexOutsideShapeOnce()
            return
        }
        // 2 次は 3 次の特別な形として通す — 曲線の道具を 1 本に保つ
        let control = SIMD2(cx, cy)
        let end = SIMD2(x, y)
        let c1 = start + (control - start) * (2.0 / 3.0)
        let c2 = end + (control - end) * (2.0 / 3.0)
        bezierVertex(c1.x, c1.y, c2.x, c2.y, end.x, end.y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける** — 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが実際に描かれる。
    public func curveVertex(_ x: Float, _ y: Float) {
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce()
            return
        }
        curveGuides.append(SIMD2(x, y))
        guard curveGuides.count >= 4 else { return }
        let count = curveGuides.count
        let p0 = curveGuides[count - 4]
        let p1 = curveGuides[count - 3]
        let p2 = curveGuides[count - 2]
        let p3 = curveGuides[count - 1]
        if shapePoints.isEmpty { appendShapePoint(p1) }
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            appendShapePoint(Self.catmullRomPoint(p0, p1, p2, p3, t, tightness: currentCurveTightness))
        }
    }

    /// 曲線をいくつの直線で近似するか。
    public func curveDetail(_ steps: Int) { currentCurveDetail = max(1, steps) }

    /// 通過点を結ぶ曲線の張り具合。0 が既定で、大きくすると曲がりが緩くなる。
    public func curveTightness(_ amount: Float) { currentCurveTightness = amount }

    /// 穴を並べ始める。
    public func beginContour() {
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce()
            return
        }
        holePoints = []
    }

    /// 穴を並べ終える。
    public func endContour() {
        guard let hole = holePoints else { return }
        if hole.count >= 3 { shapeHoles.append(hole) }
        holePoints = nil
    }

    /// 並べ終えて描く。
    public func endShape(_ end: ShapeEnd = .open) {
        defer {
            isBuildingShape = false
            shapePoints.removeAll(keepingCapacity: true)
            shapeHoles.removeAll(keepingCapacity: true)
            curveGuides.removeAll(keepingCapacity: true)
            holePoints = nil
        }
        guard isBuildingShape else { return }
        endContour()  // 閉じ忘れた穴も畳む

        switch shapeKind {
        case .points:
            for p in shapePoints { point(p.x, p.y) }

        case .lines:
            var index = 0
            while index + 1 < shapePoints.count {
                line(
                    shapePoints[index].x, shapePoints[index].y,
                    shapePoints[index + 1].x, shapePoints[index + 1].y)
                index += 2
            }

        case .triangles:
            var index = 0
            while index + 2 < shapePoints.count {
                triangle(
                    shapePoints[index].x, shapePoints[index].y,
                    shapePoints[index + 1].x, shapePoints[index + 1].y,
                    shapePoints[index + 2].x, shapePoints[index + 2].y)
                index += 3
            }

        case .polygon:
            drawFreeform(closed: end == .close)
        }
    }

    /// 並べた点を、凹みと穴を許す形として描く。
    private func drawFreeform(closed: Bool) {
        guard shapePoints.count >= 2 else {
            if let only = shapePoints.first { point(only.x, only.y) }
            return
        }

        // 塗りは凹みうるので三角形化を通す。穴は先に 1 周へ畳む
        if hasFill, shapePoints.count >= 3 {
            let ring = shapeHoles.isEmpty
                ? shapePoints
                : Triangulation.mergeHoles(outer: shapePoints, holes: shapeHoles)
            for triangle in Triangulation.triangulate(ring) {
                appendTriangle(
                    transform.apply(x: ring[triangle.0].x, y: ring[triangle.0].y),
                    transform.apply(x: ring[triangle.1].x, y: ring[triangle.1].y),
                    transform.apply(x: ring[triangle.2].x, y: ring[triangle.2].y),
                    color: currentFill)
            }
        }

        // 輪郭は周をそのままなぞる。穴の縁も輪郭を持つ
        if hasStroke, currentStrokeWeight > 0 {
            strokeOutline(Outline(points: shapePoints, isClosed: closed, fills: false))
            for hole in shapeHoles {
                strokeOutline(Outline(points: hole, isClosed: true, fills: false))
            }
        }
    }

    private var lastShapePoint: SIMD2<Float>? {
        holePoints?.last ?? shapePoints.last
    }

    private func appendShapePoint(_ point: SIMD2<Float>) {
        if holePoints != nil {
            holePoints?.append(point)
        } else {
            shapePoints.append(point)
        }
    }

    /// 3 次の曲線の上の点。
    static func cubicPoint(
        _ p0: SIMD2<Float>, _ c1: SIMD2<Float>, _ c2: SIMD2<Float>, _ p1: SIMD2<Float>, _ t: Float
    ) -> SIMD2<Float> {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// 通過点を結ぶ曲線の上の点。`tightness` が 0 のとき、4 点のうち中の 2 点を滑らかに繋ぐ。
    static func catmullRomPoint(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
        _ t: Float, tightness: Float
    ) -> SIMD2<Float> {
        let s = (1 - tightness) / 2
        let t2 = t * t
        let t3 = t2 * t
        let m1 = (p2 - p0) * s
        let m2 = (p3 - p1) * s
        return p1 * (2 * t3 - 3 * t2 + 1)
            + m1 * (t3 - 2 * t2 + t)
            + p2 * (-2 * t3 + 3 * t2)
            + m2 * (t3 - t2)
    }

    private func warnVertexOutsideShapeOnce() {
        guard !warnedVertexOutsideShape else { return }
        warnedVertexOutsideShape = true
        Diagnostics.warn(
            "vertex(): beginShape() と endShape() の間で呼んでください。この呼び出しは何もしません")
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
    private func strokeOutline(_ outline: Outline) {
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
        vertices.append(ShapeVertex(position: position, uv: uv, color: color))
    }

    /// 焼き場が埋まったことを、初回だけ知らせる。
    private func warnAtlasFullOnce() {
        guard !warnedAtlasFull else { return }
        warnedAtlasFull = true
        Diagnostics.warn(
            "text(): 字形を焼く場所が上限まで埋まりました。これ以上の新しい字は描かれません")
    }

    private func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: LinearRGBA
    ) {
        vertices.append(ShapeVertex(position: a, uv: whiteUV, color: color))
        vertices.append(ShapeVertex(position: b, uv: whiteUV, color: color))
        vertices.append(ShapeVertex(position: c, uv: whiteUV, color: color))
    }

    // MARK: - 描き切る

    /// 1 フレーム分を描く。
    ///
    /// `body` の中で呼んだ図形が溜められ、抜けるときにまとめて描画先へ落ちる。
    /// GPU が終わるまで待ってから返る。
    public func draw(_ body: () -> Void) throws(RenderFailure) {
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        currentClip = nil
        pendingBackground = nil
        transform = .identity
        transformStack.removeAll(keepingCapacity: true)

        body()

        try flush()
    }

    /// 検査から「描けなかったフレーム」を作るための差し込み。製品の経路では常に `nil`。
    ///
    /// 描画の失敗は環境か資源が枯れたときにしか起きず、検査から自然には作れない。
    /// 一方で**描けなかったときに何が起きるか**は回帰検査を置くべき場所そのものなので
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))、ここに 1 つだけ
    /// 穴を空けてある。公開はしない。
    var failureForTesting: RenderFailure?

    private func flush() throws(RenderFailure) {
        if let failureForTesting { throw failureForTesting }
        closeBatch()
        let pass = target.makeRenderPass(clearColor: pendingBackground)
        let commands = try gpu.beginCommands()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }

        if !vertices.isEmpty {
            let buffer = try vertexBufferHolding(vertices.count)
            vertices.withUnsafeBytes { source in
                buffer.contents().copyMemory(
                    from: source.baseAddress!, byteCount: source.count)
            }
            encoder.setRenderPipelineState(pipeline.state)
            encoder.setViewport(
                MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(width), height: Double(height),
                    znear: 0, zfar: 1))
            pipeline.argumentTable.setAddress(
                buffer.gpuAddress, index: ShapePipeline.vertexBufferIndex)
            pipeline.argumentTable.setAddress(
                projectionBuffer.gpuAddress, index: ShapePipeline.projectionBufferIndex)
            for batch in batches {
                encoder.setScissorRect(
                    batch.clip
                        ?? MTLScissorRect(x: 0, y: 0, width: Int(width), height: Int(height)))
                pipeline.argumentTable.setAddress(
                    blendModeBuffer.gpuAddress
                        + UInt64(Int(batch.mode.rawIndex) * Self.blendModeStride),
                    index: ShapePipeline.blendModeBufferIndex)
                pipeline.argumentTable.setTexture(
                    batch.texture.gpuResourceID, index: ShapePipeline.glyphTextureIndex)
                encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
                encoder.drawPrimitives(
                    primitiveType: .triangle,
                    vertexStart: batch.start, vertexCount: batch.count)
            }
        }

        encoder.endEncoding()
        try gpu.commitAndWait(commands)
    }

    /// 頂点を置く領域。足りなければ取り直す。
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
