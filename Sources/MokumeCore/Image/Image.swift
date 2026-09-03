// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
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
    /// 面へ送る前に待つ相手 (前のフレームがまだこの面を読んでいるかもしれない・#727)。
    private let gpu: RenderDevice
    /// CPU 側が GPU 側より新しいか。
    private var needsUpload = false
    /// 大きさの違う絵を渡されたことを、もう知らせたか。
    private var warnedMismatch = false

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
        self.gpu = gpu
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

    /// 表示できる形の絵を、まとめて書き込む。**外から届いた映像を絵にする道である。**
    ///
    /// 受け取るのは出口が出すのと同じ形 (``DisplayImage``) で、作業空間への変換は
    /// ここが引き受ける ([ADR-0011] 決定 3 の「入力側は作業空間へ入る時点で線形へ
    /// 変換する」)。**呼ぶ側は色を変換しない。**
    ///
    /// 1 画素ずつ ``set(_:_:_:)`` を呼ぶのと結果は同じだが、費用が違う — 1920×1080
    /// では呼び出しだけで 1 フレームの予算を超える
    /// ([#487](https://github.com/mokume-metal/mokume/issues/487))。
    ///
    /// ## 大きさは絵が持つ
    ///
    /// **書き込みで絵の大きさは変わらない。** 大きさの違う絵を渡しても何も起きず、
    /// 理由が 1 度だけ診断に出る。送り元の解像度が変わったら ``Canvas/createImage(_:_:)``
    /// で作り直す — 毎フレーム触る口の中に面の作り直しを置かないためである。
    ///
    /// <!-- example: 文脈 var settings = SketchSettings(width: 400, height: 300) -->
    /// ```swift
    /// private var video: Image?
    ///
    /// func setup() {
    ///     // 面は 1 度だけ作る。書き込みでは大きさが変わらない
    ///     video = try? createImage(320, 180)
    /// }
    ///
    /// func draw() {
    ///     guard let video else { return }
    ///     // ふつうはここへ外から届いた 1 枚をそのまま渡す。この例では自分で組み立てる
    ///     var bytes = [UInt8](repeating: 255, count: 320 * 180 * 4)
    ///     for index in 0..<(320 * 180) {
    ///         bytes[index * 4] = UInt8(index % 320 * 255 / 319)
    ///         bytes[index * 4 + 1] = UInt8(index / 320 * 255 / 179)
    ///         bytes[index * 4 + 2] = 90
    ///     }
    ///     video.write(DisplayImage(width: 320, height: 180, bytes: bytes))
    ///     image(video, 0, 0, width, height)
    /// }
    /// ```
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func write(_ picture: DisplayImage) {
        guard picture.width == width, picture.height == height else {
            warnMismatchOnce(picture)
            return
        }
        OutputStage.decode(picture, into: &pixels)
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

    /// 大きさの違う絵を渡されたことを、**最初の 1 度だけ**知らせる。
    ///
    /// 毎フレーム呼ばれる口なので、毎回出すと同じ行が診断を埋めて他が読めなくなる
    /// ([ADR-0020] 決定 5 の「警告を出して安全な既定へ倒す」は、出し続けよとは
    /// 言っていない)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnMismatchOnce(_ picture: DisplayImage) {
        guard !warnedMismatch else { return }
        warnedMismatch = true
        Diagnostics.warn(
            "write(): 渡された絵の大きさ \(picture.width)x\(picture.height) が、"
                + "この絵の大きさ \(width)x\(height) と違うので書き込みませんでした。"
                + "送り元の大きさが変わったなら createImage() で作り直してください")
    }

    /// 書き換えた画素を GPU 側へ送る。描く直前に呼ばれる。
    func uploadIfNeeded() {
        guard needsUpload else { return }
        upload()
    }

    private func upload() {
        // 描き切りは GPU の完了を待たずに返る (#727)。前のフレームがまだこの面を読んで
        // いるかもしれないので、書き換える直前に投入済みのものが終わるのを待つ。
        // 書き換えないフレームはここへ来ないので、待ちも払わない
        gpu.settleQuietly(before: "画像を面へ送る")
        pixels.withUnsafeBytes { source in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: source.baseAddress!,
                bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride)
        }
        needsUpload = false
    }
}
