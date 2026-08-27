// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 描いた結果が置かれる場所。
///
/// [ADR-0012] 決定 1 のとおり、**レンダリングの成果物はテクスチャ**で、画面表示は
/// それを受け取る経路の 1 つにすぎない。だから描画先は画面より先に立ち、画面を
/// 持たない実行でも同じものが同じように描かれる。
///
/// 画素は半精度浮動小数で持つ ([ADR-0011] 決定 2)。表示できる範囲を超えた明るさと、
/// 色域の外側の値を、出力段まで捨てずに運ぶためである。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
public final class RenderTarget {
    /// 作業空間の画素の形式。
    static let pixelFormat: MTLPixelFormat = .rgba16Float

    /// 1 画素あたりのバイト数 (4 成分 × 半精度浮動小数 2 バイト)。
    static let bytesPerPixel = 8

    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int

    let texture: any MTLTexture
    private let gpu: RenderDevice

    /// 読み出し用の領域。読み出しのたびに確保し直さず、描画先と同じ寿命で持つ。
    private lazy var readbackBuffer: (any MTLBuffer)? = try? gpu.makeReadableBuffer(
        byteCount: width * height * Self.bytesPerPixel)

    /// 指定した大きさの描画先を確保する。
    public init(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) {
        guard width > 0, height > 0 else {
            throw .invalidSize(width: width, height: height)
        }
        self.gpu = gpu
        self.width = width
        self.height = height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        self.texture = try gpu.makeTexture(descriptor: descriptor)
    }

    // MARK: - 描く

    /// この描画先へ描くパスの記述を作る。
    ///
    /// - Parameter clearColor: 塗り直す色。`nil` なら前の内容の上に描き足す。
    func makeRenderPass(clearColor: LinearRGBA?) -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.storeAction = .store
        if let clearColor {
            attachment.loadAction = .clear
            attachment.clearColor = MTLClearColor(
                red: Double(clearColor.red),
                green: Double(clearColor.green),
                blue: Double(clearColor.blue),
                alpha: Double(clearColor.alpha))
        } else {
            attachment.loadAction = .load
        }
        return pass
    }

    /// 描画先を 1 色で塗り、GPU が終わるまで待つ。
    public func fill(with color: LinearRGBA) throws(RenderFailure) {
        let commands = try gpu.beginCommands()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: makeRenderPass(clearColor: color))
        else {
            throw .encoderUnavailable
        }
        encoder.endEncoding()
        try gpu.commitAndWait(commands)
    }

    // MARK: - 読み出す

    /// 描画先の内容を CPU 側へ読み出す。
    ///
    /// 読み出せるのは**作業空間そのままの値**で、表示のための変換は経ていない。
    /// 表示・書き出しのための変換は出力段が 1 度だけ行う ([ADR-0011] 決定 3)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        let byteCount = width * height * Self.bytesPerPixel
        guard let buffer = readbackBuffer else {
            throw .bufferUnavailable(byteCount: byteCount)
        }

        let commands = try gpu.beginCommands()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.copy(
            sourceTexture: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationBuffer: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: width * Self.bytesPerPixel,
            destinationBytesPerImage: byteCount)
        encoder.endEncoding()
        try gpu.commitAndWait(commands)

        let components = buffer.contents().bindMemory(
            to: Float16.self, capacity: width * height * 4)
        return PixelBuffer(
            width: width,
            height: height,
            components: Array(UnsafeBufferPointer(start: components, count: width * height * 4)))
    }
}
