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

    /// 明るさを画面へ写す段の設定。**画面の性質なのでフレームを越える**。
    ///
    /// ここに置くのは、効く先が「この描画先から出て行く絵すべて」だからである。
    /// 画面へ差し出す経路も書き出す経路も、行き先は違っても出どころはここ 1 つ
    /// なので、設定も 1 つで足りる。
    var brightness = Brightness.default

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

    let gpu: RenderDevice

    /// 出力段を通した絵の置き場。**頼まれてはじめて作り、以後は使い回す。**
    ///
    /// 出口が 1 つも無いスケッチはここで 1 バイトも払わない (観測が無ければ
    /// 払わないのと同じ作法)。使い回すのは [ADR-0023] 決定 5 による。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var encodedStorage: EncodedImage?
    /// 出力段を通すパイプライン。同じく頼まれてはじめて作る。
    var outputPassStorage: OutputPass?

    /// 出力段を通した絵の置き場を作った回数。**作り直していないこと**を
    /// 検査から数えるための目印。
    var encodedImagesMade = 0

    /// 出力段を通した道を通った回数。
    ///
    /// **置き場を作った回数とは別に要る。** 置き場は 1 枚を使い回すので、作った回数は
    /// 何回通っても 1 のままである。「出口が 1 つも無ければ道を 1 回も通らない」
    /// ([ADR-0023] 決定 5) を検査から見るのはこちら。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var encodePassCount = 0

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
    /// 中身が確定しているのは GPU の仕事が終わったあとだけで、描画の経路は投入しても
    /// 待たない (#727)。だから**ここで待つ** — 投入済みのものが全部終わっていれば
    /// 何もせず返る。窓は生のポインタなので、**取ったフレームの中で使い切る**。次の
    /// フレームへ持ち越すと、GPU が書いている途中の面へ触ることになる。
    var pixels: Pixels {
        gpu.settleQuietly(before: "画素を読む")
        return Pixels(
            base: storage.contents(), width: width, height: height, bytesPerRow: bytesPerRow)
    }

    // MARK: - 描く

    /// この描画先へ描くパスの記述を作る。
    ///
    /// - Parameters:
    ///   - clearColor: 塗り直す色。`nil` なら前の内容の上に描き足す。
    ///   - continuingFrame: 同じフレームで既に描き切っているか。**奥行きを引き継ぐ。**
    ///   - keepingDepth: このあと同じフレームでもう一度描き切りうるか。奥行きを残す。
    func makeRenderPass(
        clearColor: LinearRGBA?, continuingFrame: Bool = false, keepingDepth: Bool = false
    ) -> MTL4RenderPassDescriptor {
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

        // 奥行きは**フレームごと**に作り直す。**いちばん奥から始める**ので、最初に
        // 置いた立体は必ず通り、あとから来た手前のものがそれを隠す。
        //
        // 「フレームごと」であって「パスごと」ではない。1 フレームを何回かに分けて
        // 描き切ることがある (画素を読む・置いた描き場所が描き換わる) ので、途中の
        // 区切りで消すと**描いた順で決まる絵**に戻ってしまう。
        //
        // 残すのは途中の描き切りのときだけ。フレームの最後の描き切りで残すと、
        // 分けて描き切らないスケッチまで毎フレーム書き出しを払うことになる
        let depth = pass.depthAttachment!
        depth.texture = depthTexture
        if continuingFrame {
            depth.loadAction = .load
        } else {
            depth.loadAction = .clear
            depth.clearDepth = 1
        }
        depth.storeAction = keepingDepth ? .store : .dontCare
        return pass
    }

    /// 効果の段が書き込むパスの記述を作る。
    ///
    /// **奥行きを持たない。** 段は絵から絵への変換で、前後関係を持たないためである。
    /// 奥行きを付けたパスへ、奥行きを見ないパイプラインを通すことはできない。
    func makeEffectPass() -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        // 画面いっぱいの三角形が全部の画素を書くので、前の内容は読まない
        attachment.loadAction = .dontCare
        attachment.storeAction = .store
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
    /// いるので、**ここでするのは待つことと行の詰め直しだけ**である。待つのは投入済みの
    /// 描画が終わるまで (全部終わっていれば何もしない・#727)。行の間隔が幅ぶんより広い
    /// ことがあるので、値としての ``PixelBuffer`` へ移すときに詰める。
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        try gpu.settle()
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
