// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
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

    /// 矩形を塗る。`x`・`y` は左上の角。
    public func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) {
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

    /// 円を塗る。`x`・`y` は中心、`diameter` は直径。
    public func circle(_ x: Float, _ y: Float, _ diameter: Float) {
        let radius = diameter / 2
        guard radius > 0 else { return }
        let segments = Self.segmentCount(forRadius: radius)
        let center = transform.apply(x: x, y: y)
        let step = 2 * Float.pi / Float(segments)
        var previous = transform.apply(x: x + radius, y: y)
        for index in 1...segments {
            let angle = step * Float(index)
            let point = transform.apply(
                x: x + radius * cos(angle), y: y + radius * sin(angle))
            appendTriangle(center, previous, point, color: currentFill)
            previous = point
        }
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

    private func flush() throws(RenderFailure) {
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
