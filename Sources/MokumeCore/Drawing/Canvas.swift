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
    private var warnedReversedArc = false

    /// 閉じた列。**同じ列は単一の混ぜ方でしか描かれない。**
    ///
    /// 混ぜ方を変える操作がその時点で列を閉じるので、既に置いた図形が後の設定で
    /// 描かれることがない。閉じ忘れると絵は「たまに」おかしくなる — 設定を変えない
    /// 単純なスケッチでは一生出ないので、規律として持つ。
    private var batches: [(mode: BlendMode, start: Int, count: Int)] = []

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
    }

    private var currentStyle: Style {
        get {
            Style(
                fill: currentFill, stroke: currentStroke, strokeWeight: currentStrokeWeight,
                strokeCap: currentStrokeCap, strokeJoin: currentStrokeJoin,
                hasFill: hasFill, hasStroke: hasStroke,
                rectMode: currentRectMode, ellipseMode: currentEllipseMode,
                blendMode: currentBlendMode)
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
            // 混ぜ方が変わるなら列を閉じてから戻す
            blendMode(newValue.blendMode)
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

    /// 描くものを、下にある絵とどう混ぜるか。
    ///
    /// **溜めている列をその場で閉じる。** 既に置いた図形が後の混ぜ方で描かれないように
    /// するためで、閉じ忘れは「設定を変えたときだけ絵が崩れる」形で現れる。
    public func blendMode(_ mode: BlendMode) {
        guard mode != currentBlendMode else { return }
        closeBatch()
        currentBlendMode = mode
    }

    /// 溜めている頂点を、いまの混ぜ方の列として閉じる。
    private func closeBatch() {
        let start = batches.last.map { $0.start + $0.count } ?? 0
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append((currentBlendMode, start, count))
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

    private func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: LinearRGBA
    ) {
        vertices.append(ShapeVertex(position: a, color: color))
        vertices.append(ShapeVertex(position: b, color: color))
        vertices.append(ShapeVertex(position: c, color: color))
    }

    // MARK: - 描き切る

    /// 1 フレーム分を描く。
    ///
    /// `body` の中で呼んだ図形が溜められ、抜けるときにまとめて描画先へ落ちる。
    /// GPU が終わるまで待ってから返る。
    public func draw(_ body: () -> Void) throws(RenderFailure) {
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
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
                pipeline.argumentTable.setAddress(
                    blendModeBuffer.gpuAddress
                        + UInt64(Int(batch.mode.rawIndex) * Self.blendModeStride),
                    index: ShapePipeline.blendModeBufferIndex)
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
