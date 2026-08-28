// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// 読み込んだ、あるいは自分で作った絵。
///
/// ## 画素は作業空間の値で持つ
///
/// 中身は**線形・アルファ乗算済み**の半精度 4 成分で、色域は作業空間と同じ
/// ([ADR-0011])。読み込みの時点で 1 度だけ変換するので、描くたびに変換は起きない。
/// ``get(_:_:)`` と ``set(_:_:_:)`` が扱う色も同じ表現なので、
/// **`set(x, y, get(x, y))` は絵を変えない。**
///
/// ## 書き換えたら、描くときに自動で送られる
///
/// ``set(_:_:_:)`` は CPU 側を書き換え、「送り直しが要る」と印を付けるだけである。
/// 実際の送りは描くときに 1 度だけ起きるので、**送り直しを呼び忘れて絵が変わらない**
/// という形の不具合が起きない。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public final class Image {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    /// 作業空間の画素 (線形・アルファ乗算済み)。行は上から下へ。
    var pixels: [SIMD4<Float16>]
    /// GPU 側の面。
    let texture: any MTLTexture
    /// CPU 側が GPU 側より新しいか。
    private var needsUpload = false

    /// 画素を渡して作る。
    init(width: Int, height: Int, pixels: [SIMD4<Float16>], gpu: RenderDevice) throws(
        RenderFailure
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.image"
        self.texture = texture
        upload()
    }

    /// 1 画素の色。範囲の外は透明を返す (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func get(_ x: Int, _ y: Int) -> LinearRGBA {
        guard x >= 0, y >= 0, x < width, y < height else {
            return LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0)
        }
        let texel = pixels[y * width + x]
        return LinearRGBA(
            premultipliedRed: Float(texel.x), green: Float(texel.y), blue: Float(texel.z),
            alpha: Float(texel.w))
    }

    /// 1 画素の色を書き換える。範囲の外は何もしない。
    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = SIMD4(
            Float16(color.red), Float16(color.green), Float16(color.blue),
            Float16(color.alpha))
        needsUpload = true
    }

    /// 全体を 1 色で埋める。
    public func fill(_ color: LinearRGBA) {
        let texel = SIMD4<Float16>(
            Float16(color.red), Float16(color.green), Float16(color.blue),
            Float16(color.alpha))
        for index in pixels.indices { pixels[index] = texel }
        needsUpload = true
    }

    /// 書き換えた画素を GPU 側へ送る。描く直前に呼ばれる。
    func uploadIfNeeded() {
        guard needsUpload else { return }
        upload()
    }

    private func upload() {
        pixels.withUnsafeBytes { source in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: source.baseAddress!,
                bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride)
        }
        needsUpload = false
    }
}
