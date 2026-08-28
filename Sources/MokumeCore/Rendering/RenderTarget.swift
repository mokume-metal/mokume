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

    /// 奥行きを覚えておく面の形式。
    static let depthFormat: MTLPixelFormat = .depth32Float

    /// 1 画素あたりのバイト数 (4 成分 × 半精度浮動小数 2 バイト)。
    static let bytesPerPixel = 8

    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int

    let texture: any MTLTexture

    /// 奥行きを覚えておく面。
    ///
    /// **立体を置かないスケッチでも持つ。** 使うときだけ確保する形にすると、確保の
    /// 有無で描き方が 2 通りに分かれる — 分かれた経路は片方でしか成り立たない性質を
    /// 生む ([ADR-0021] 決定 2・3)。中身はフレームごとに捨てるので、保存はしない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    let depthTexture: any MTLTexture

    /// テクスチャが載っている領域。**描いた結果はここに現れる**ので、読むために
    /// 写しを取る必要がない。
    let storage: any MTLBuffer

    /// 1 行あたりのバイト数。整列の要求を満たすため、幅ぶんより広いことがある。
    let bytesPerRow: Int

    private let gpu: RenderDevice

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
        descriptor.storageMode = .shared

        let bytesPerRow = gpu.alignedBytesPerRow(width * Self.bytesPerPixel)
        self.bytesPerRow = bytesPerRow
        let backing = try gpu.makeBufferBackedTexture(
            descriptor: descriptor, bytesPerRow: bytesPerRow)
        backing.texture.label = "mokume.target"
        self.texture = backing.texture
        self.storage = backing.storage

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        let depthTexture = try gpu.makeTexture(descriptor: depth)
        depthTexture.label = "mokume.target.depth"
        self.depthTexture = depthTexture
    }

    // MARK: - 画素として見る

    /// 描いた結果を画素として読み書きする面。返るのは描画先そのものへの窓である。
    ///
    /// 中身が確定しているのは GPU の仕事が終わったあとだけだが、描画の経路は投入の
    /// たびに完了まで待つので、呼び出し側へ制御が戻った時点では常に確定している。
    var pixels: Pixels {
        Pixels(
            base: storage.contents(), width: width, height: height, bytesPerRow: bytesPerRow)
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

        // 奥行きはフレームごとに作り直す。**いちばん奥から始める**ので、最初に
        // 置いた立体は必ず通り、あとから来た手前のものがそれを隠す
        let depth = pass.depthAttachment!
        depth.texture = depthTexture
        depth.loadAction = .clear
        depth.clearDepth = 1
        depth.storeAction = .dontCare
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
    /// 読み出しには GPU の仕事が要らない。描画先は CPU から読める領域の上に載って
    /// いるので、**ここでするのは行の詰め直しだけ**である。行の間隔が幅ぶんより広い
    /// ことがあるので、値としての ``PixelBuffer`` へ移すときに詰める。
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        let componentsPerRow = width * 4
        var components = [Float16](repeating: 0, count: componentsPerRow * height)
        let source = storage.contents()
        components.withUnsafeMutableBytes { destination in
            let base = destination.baseAddress!
            for row in 0..<height {
                base.advanced(by: row * componentsPerRow * 2)
                    .copyMemory(
                        from: source.advanced(by: row * bytesPerRow),
                        byteCount: width * Self.bytesPerPixel)
            }
        }
        return PixelBuffer(width: width, height: height, components: components)
    }
}
