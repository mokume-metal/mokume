// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

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
public final class RenderTarget: EffectSurface {
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

    /// 描く先の面。**GPU 専用 (`.private`) で、CPU からは読めない。**
    ///
    /// CPU から読める置き場の上に載せた面 (buffer-backed のリニアテクスチャ) なら写しを
    /// 取らずに読めるが、その形には GPU のロスレス圧縮も並べ替えも効かず、**画素を読まない
    /// スケッチまで、描く・効果を通す・画面へ写すたびに素の帯域を払っていた** ([#753])。
    /// 読むときは写し (``pixelMirror``) を取る。
    ///
    /// [#753]: https://github.com/mokume-metal/mokume/issues/753
    let texture: any MTLTexture

    /// 奥行きを覚えておく面。
    ///
    /// **立体を置かないスケッチでも持つ。** 使うときだけ確保する形にすると、確保の
    /// 有無で描き方が 2 通りに分かれる — 分かれた経路は片方でしか成り立たない性質を
    /// 生む ([ADR-0021] 決定 2・3)。中身はフレームごとに捨てるので、保存はしない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    let depthTexture: any MTLTexture

    let gpu: RenderDevice

    /// 画素の写し。**頼まれてはじめて作り、以後は使い回す。**
    ///
    /// 出口が 1 つも無いスケッチが出力段の置き場を払わないのと同じ作法で、画素を
    /// 読まない描画先はここで 1 バイトも払わない。
    private(set) var pixelMirror: PixelMirror?

    /// 写しを作った回数。**作り直していないこと**と、**頼まれていなければ 0 のまま**
    /// であることを検査から数えるための目印。
    private(set) var pixelMirrorsMade = 0

    /// 写しからテクスチャへ書き戻す blit を積んだ回数。``Pixels`` へ書いたフレームだけ増える。
    private(set) var pixelWriteBacksEncoded = 0

    /// テクスチャから写しへ読み戻す blit を積んだ回数。画素を読むフレームだけ増える。
    private(set) var pixelReadbacksEncoded = 0

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

    /// 出力段を通った道を通った回数。
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
        descriptor.storageMode = .private
        // 透明な黒から始める。塗り直さずに描き足す最初のフレームが読むのは、この値
        let texture = try gpu.makeClearedTexture(descriptor: descriptor)
        texture.label = "mokume.target"
        self.texture = texture

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        let depthTexture = try gpu.makeTexture(descriptor: depth)
        depthTexture.label = "mokume.target.depth"
        self.depthTexture = depthTexture
    }

    // MARK: - 画素として見る

    /// 描いた結果を画素として読み書きする面。返るのは描画先の写しへの窓である。
    ///
    /// 中身が確定しているのは GPU の仕事が終わったあとだけで、描画の経路は投入しても
    /// 待たない (#727)。だから**ここで待つ** — 投入済みのものが全部終わっていれば
    /// 何もせず返る。写しが最後に映してから GPU に新しい投入があれば、ここで読み戻しを
    /// 1 本積んで待つ (描き切りが読み戻しを積んでいれば、それは起きない)。窓は生の
    /// ポインタなので、**取ったフレームの中で使い切る**。
    ///
    /// **落ちない** ([ADR-0020] 決定 5)。写しを用意できなければ大きさ 0 の窓を返す —
    /// 読むと透明、書いても何も起きない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    var pixels: Pixels {
        gpu.settleQuietly(before: "画素を読む")
        do {
            let mirror = try mirrorForReading()
            return Pixels(
                base: mirror.storage.contents(), width: width, height: height,
                bytesPerRow: mirror.bytesPerRow, mirror: mirror)
        } catch {
            Diagnostics.warn("画素の写しを用意できませんでした: \(error.headline)")
            return .unavailable
        }
    }

    // MARK: - 写し

    /// 写し。無ければ作る。
    private func mirrorHolding() throws(RenderFailure) -> PixelMirror {
        if let pixelMirror { return pixelMirror }
        let mirror = try PixelMirror(gpu: gpu, width: width, height: height)
        pixelMirror = mirror
        pixelMirrorsMade += 1
        return mirror
    }

    /// いまの絵を映した写し。**呼ぶ前に ``RenderDevice/settle()`` が済んでいること。**
    ///
    /// CPU が書いたまま戻していない写しは CPU の側が最新なので、映し直さない。それ以外で、
    /// 最後に映した投入より新しい投入があれば、読み戻しを 1 本積んで終わるまで待つ。
    private func mirrorForReading() throws(RenderFailure) -> PixelMirror {
        let mirror = try mirrorHolding()
        if mirror.hasPendingWrites || mirror.syncedThrough == gpu.submissionCount {
            return mirror
        }
        let commands = try gpu.beginCommands()
        try encodePixelReadback(into: commands)
        markPixelsMirrored(through: gpu.commit(commands))
        try gpu.settle()
        return mirror
    }

    /// テクスチャから写しへ読み戻す blit を積む。**描き切りの末尾に積む形。**
    ///
    /// 積んだコマンドを投入したら、その番号を ``markPixelsMirrored(through:)`` で
    /// 知らせる — 知らせないと、次に ``pixels`` を頼まれたときにもう 1 本積む。
    func encodePixelReadback(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let mirror = try mirrorHolding()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        // **描き終わるのを待つ。** この世代は encoder をまたぐ依存を自動では張らない
        // (#341)。前の書き戻し (blit) も待つ — 間に描画が無い形でも順が崩れないように
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .blit,
            visibilityOptions: .device)
        encoder.copy(
            sourceTexture: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationBuffer: mirror.storage, destinationOffset: 0,
            destinationBytesPerRow: mirror.bytesPerRow, destinationBytesPerImage: 0)
        encoder.endEncoding()
        pixelReadbacksEncoded += 1
    }

    /// 読み戻しを積んだコマンドが、番号 `submission` で投入されたことを記録する。
    func markPixelsMirrored(through submission: UInt64) {
        pixelMirror?.syncedThrough = submission
    }

    /// CPU が写しへ書いたものをテクスチャへ戻す blit を積む。**書いていなければ何も積まない。**
    ///
    /// GPU がこの描画先へ触るコマンドの**先頭**に積む (描き切り・出力段)。積んだ blit を
    /// 後続の段が待つ仕掛けもここで積む。
    func encodePixelWriteBack(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        guard let mirror = pixelMirror, mirror.hasPendingWrites else { return }
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.copy(
            sourceBuffer: mirror.storage, sourceOffset: 0, sourceBytesPerRow: mirror.bytesPerRow,
            sourceBytesPerImage: 0,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        // **戻し終わるのを、続く描画・効果・読み戻しが待つ。** `.device` を渡さないと
        // 実行順だけ揃って中身が見えない (#341 で実測)
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.vertex, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
        mirror.hasPendingWrites = false
        pixelWriteBacksEncoded += 1
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

    /// 描画先を 1 色で塗り、GPU が終わるまで待つ。
    public func fill(with color: LinearRGBA) throws(RenderFailure) {
        // 全画素を塗り直すので、写しに残っていた CPU の書き込みは戻さず捨てる
        pixelMirror?.hasPendingWrites = false
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
    /// 読むのは写し (`pixels` と同じ置き場) である。待つのは投入済みの描画が終わる
    /// まで (全部終わっていれば何もしない・#727) で、写しが古ければ読み戻しを 1 本積んで
    /// 待つ。行の間隔が幅ぶんより広いことがあるので、値としての ``PixelBuffer`` へ移す
    /// ときに詰める。
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        try gpu.settle()
        let mirror = try mirrorForReading()
        let componentsPerRow = width * 4
        var components = [Float16](repeating: 0, count: componentsPerRow * height)
        let source = mirror.storage.contents()
        components.withUnsafeMutableBytes { destination in
            let base = destination.baseAddress!
            for row in 0..<height {
                base.advanced(by: row * componentsPerRow * 2)
                    .copyMemory(
                        from: source.advanced(by: row * mirror.bytesPerRow),
                        byteCount: width * Self.bytesPerPixel)
            }
        }
        return PixelBuffer(width: width, height: height, components: components)
    }
}

/// 描画先の画素の写し。CPU から読み書きできる置き場。
///
/// **どちらが最新かを 2 つの値で持つ。** `hasPendingWrites` が立っていれば CPU の側が
/// 最新で、次に GPU がこの描画先へ触る前に書き戻される。立っていなければ GPU の側が
/// 最新で、`syncedThrough` (最後に映した投入の番号) より新しい投入があれば映し直す。
final class PixelMirror {
    /// 置き場。`.shared` なので CPU からそのまま読み書きできる。
    let storage: any MTLBuffer
    /// 1 行あたりのバイト数。
    let bytesPerRow: Int
    /// CPU が書いたまま、まだテクスチャへ戻していないか。
    var hasPendingWrites = false
    /// この番号までの投入の結果を映している。0 はまだ 1 度も映していない。
    var syncedThrough: UInt64 = 0

    init(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) {
        // blit の行間隔に整列の要求は無い (リニアテクスチャを置き場に載せるときの要求は
        // ここには効かない) ので、幅ぶんそのままでよい
        bytesPerRow = width * RenderTarget.bytesPerPixel
        storage = try gpu.makeReadableBuffer(byteCount: bytesPerRow * height)
        storage.label = "mokume.target.mirror"
    }
}
