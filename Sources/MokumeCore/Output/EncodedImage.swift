// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 出力段を通した絵の置き場。**面に描かずに取り出したもの** ([ADR-0024] 決定 6)。
///
/// 中身は ``DisplayImage`` と同じ形 — 標準レンジへ収め、ディスプレイのエンコードを
/// 掛け、チャンネルあたり 8 bit へ量子化し、アルファは乗算を戻した状態である。
/// 違うのは**まだ GPU の上にいる**ことで、毎フレーム絵を受け取る出口はここから
/// 直接受け取れる (読み戻しを払わない)。
///
/// **1 枚を作り、フレームをまたいで使い回す** ([ADR-0023] 決定 5)。毎フレーム
/// 確保すると、長く回したときにだけ重くなる — 動かし始めは正常に見える。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
final class EncodedImage {
    /// 幅 (画素)。
    let width: Int
    /// 高さ (画素)。
    let height: Int
    /// 1 行あたりのバイト数。整列の要求を満たすため、幅ぶんより広いことがある。
    let bytesPerRow: Int

    /// 出口が受け取るテクスチャ。
    let texture: any MTLTexture
    /// テクスチャが載っている領域。**同じメモリ**なので、読み戻しは写しを取らない。
    private let storage: any MTLBuffer

    init(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) {
        self.width = width
        self.height = height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: OutputPass.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared

        let bytesPerRow = gpu.alignedBytesPerRow(
            width * OutputPass.bytesPerPixel, for: OutputPass.pixelFormat)
        self.bytesPerRow = bytesPerRow
        let backing = try gpu.makeBufferBackedTexture(
            descriptor: descriptor, bytesPerRow: bytesPerRow)
        backing.texture.label = "mokume.output.encoded"
        self.texture = backing.texture
        self.storage = backing.storage
    }

    /// この絵へ書き込むパスの記述を作る。
    ///
    /// 全画素を書き直すので、前の内容は読まない。
    func makeRenderPass() -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .dontCare
        attachment.storeAction = .store
        return pass
    }

    /// バイト列として読み戻す。
    ///
    /// **画素ごとの計算は 1 つも無い。** 出力段は既に GPU が通しているので、ここで
    /// するのは行の詰め直しだけである (行の間隔が幅ぶんより広いことがある)。
    func read() -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: width * height * OutputPass.bytesPerPixel)
        let source = storage.contents()
        let widthInBytes = width * OutputPass.bytesPerPixel
        bytes.withUnsafeMutableBytes { destination in
            let base = destination.baseAddress!
            for row in 0..<height {
                base.advanced(by: row * widthInBytes)
                    .copyMemory(
                        from: source.advanced(by: row * bytesPerRow), byteCount: widthInBytes)
            }
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }
}
