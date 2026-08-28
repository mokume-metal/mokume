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
    private var warnedReversedArc = false

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

    /// これから描く図形の塗りの色。
    public func fill(_ color: LinearRGBA) { currentFill = color }

    /// これから引く線の色。
    public func stroke(_ color: LinearRGBA) { currentStroke = color }

    /// これから引く線の太さ (画素)。
    public func strokeWeight(_ weight: Float) { currentStrokeWeight = max(0, weight) }

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

    /// いまの変換を積んでおく。
    public func push() { transformStack.append(transform) }

    /// 積んでおいた変換へ戻す。積んでいなければ何もしない。
    public func pop() {
        guard let restored = transformStack.popLast() else { return }
        transform = restored
    }

    // MARK: - 図形

    /// 面全体を塗り直す。
    ///
    /// それまでに溜めた図形は消える — 全面を塗るのだから、下に隠れるものを
    /// 描く手間をかける意味がない。
    public func background(_ color: LinearRGBA) {
        vertices.removeAll(keepingCapacity: true)
        pendingBackground = color
    }

    /// 矩形を塗る。座標の読み方は ``rectMode(_:)`` が決める。
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
        guard box.width > 0, box.height > 0 else { return }
        let x = box.x
        let y = box.y
        let w = box.width
        let h = box.height
        appendTriangle(
            transform.apply(x: x, y: y),
            transform.apply(x: x + w, y: y),
            transform.apply(x: x + w, y: y + h),
            color: currentFill)
        appendTriangle(
            transform.apply(x: x, y: y),
            transform.apply(x: x + w, y: y + h),
            transform.apply(x: x, y: y + h),
            color: currentFill)
    }

    /// 正方形を塗る。座標の読み方は ``rectMode(_:)`` が決める。
    public func square(_ a: Float, _ b: Float, _ extent: Float) {
        rect(a, b, extent, extent)
    }

    /// 円を塗る。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) {
        ellipse(a, b, diameter, diameter)
    }

    /// 楕円を塗る。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentEllipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return }
        fillFan(
            centerX: box.x + radiusX, centerY: box.y + radiusY,
            radiusX: radiusX, radiusY: radiusY,
            from: 0, sweep: 2 * .pi, color: currentFill)
    }

    /// 円弧を塗る。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// 塗りは**中心を含む扇形**。角度は右向きが 0 で、増える向きは画面の上で時計回りに見える。
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
        fillFan(
            centerX: box.x + radiusX, centerY: box.y + radiusY,
            radiusX: radiusX, radiusY: radiusY,
            from: start, sweep: min(stop - start, 2 * .pi), color: currentFill)
    }

    /// 三角形を塗る。
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        appendTriangle(
            transform.apply(x: x1, y: y1),
            transform.apply(x: x2, y: y2),
            transform.apply(x: x3, y: y3),
            color: currentFill)
    }

    /// 四角形を塗る。頂点は与えた順に結ばれる。
    public func quad(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
        _ x3: Float, _ y3: Float, _ x4: Float, _ y4: Float
    ) {
        let p1 = transform.apply(x: x1, y: y1)
        let p2 = transform.apply(x: x2, y: y2)
        let p3 = transform.apply(x: x3, y: y3)
        let p4 = transform.apply(x: x4, y: y4)
        appendTriangle(p1, p2, p3, color: currentFill)
        appendTriangle(p1, p3, p4, color: currentFill)
    }

    /// 点を打つ。大きさは ``strokeWeight(_:)`` で決めた太さ、色は線の色。
    public func point(_ x: Float, _ y: Float) {
        let radius = currentStrokeWeight / 2
        guard radius > 0 else { return }
        fillFan(
            centerX: x, centerY: y, radiusX: radius, radiusY: radius,
            from: 0, sweep: 2 * .pi, color: currentStroke)
    }

    /// 線を引く。太さは ``strokeWeight(_:)`` で決めた値。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        let dx = x2 - x1
        let dy = y2 - y1
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, currentStrokeWeight > 0 else { return }

        // 線の向きに直交する方向へ、太さの半分ずつ広げた帯として描く
        let half = currentStrokeWeight / 2
        let nx = -dy / length * half
        let ny = dx / length * half

        let a = transform.apply(x: x1 + nx, y: y1 + ny)
        let b = transform.apply(x: x2 + nx, y: y2 + ny)
        let c = transform.apply(x: x2 - nx, y: y2 - ny)
        let d = transform.apply(x: x1 - nx, y: y1 - ny)
        appendTriangle(a, b, c, color: currentStroke)
        appendTriangle(a, c, d, color: currentStroke)
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

    /// 中心から扇状に三角形を並べて、円・楕円・円弧を塗る。
    ///
    /// 円と楕円は「一周ぶんの扇」であり、円弧と別の道具にはしない。同じ順序で頂点を
    /// 積むので、`sweep` が一周のときの結果は分割の仕方まで一致する。
    private func fillFan(
        centerX: Float, centerY: Float, radiusX: Float, radiusY: Float,
        from start: Float, sweep: Float, color: LinearRGBA
    ) {
        let full = Self.segmentCount(forRadius: max(radiusX, radiusY))
        // 一周に満たない扇は、そのぶんだけ辺を割く (荒くならないよう切り上げる)
        let segments = max(1, Int((Float(full) * sweep / (2 * .pi)).rounded(.up)))
        let step = sweep / Float(segments)
        let center = transform.apply(x: centerX, y: centerY)
        var previous = transform.apply(
            x: centerX + radiusX * cos(start), y: centerY + radiusY * sin(start))
        for index in 1...segments {
            let angle = start + step * Float(index)
            let point = transform.apply(
                x: centerX + radiusX * cos(angle), y: centerY + radiusY * sin(angle))
            appendTriangle(center, previous, point, color: color)
            previous = point
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
            encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(
                primitiveType: .triangle, vertexStart: 0, vertexCount: vertices.count)
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
