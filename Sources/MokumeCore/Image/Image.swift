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
/// 送るのは**描き切りの時点**の画素で、描き切りが GPU 側のコピーで面へ届ける
/// ([#749](https://github.com/mokume-metal/mokume/issues/749))。だから描いた後で置き直さずに
/// 書き換えても、そのフレームには書き換えた後の絵が出る (同じフレームで 2 回置いた
/// ときに、両方へ最後の絵が出るのと同じ理屈である)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class Image {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    /// 作業空間の画素 (線形・アルファ乗算済み)。行は上から下へ。
    var pixels: [SIMD4<Float16>]
    /// GPU 側の面。
    let texture: any MTLTexture
    /// 送りを頼む先 (控えの登録簿) と、逃げ道で待つ相手。
    private let gpu: RenderDevice
    /// CPU 側が GPU 側より新しいか。
    ///
    /// **検査が読む。** 描き切りが待てずに送れなかったときは立ったままになり、次の
    /// 描き切りへ持ち越す ([#934](https://github.com/mokume-metal/mokume/issues/934))。
    private(set) var needsUpload = false {
        didSet { if needsUpload { writeGeneration &+= 1 } }
    }
    /// 画素を書き換えた世代。**送った後に書き換えられていたら、旗を下ろさない。**
    private var writeGeneration: UInt64 = 0
    var isQueuedForUpload = false
    /// 逃げ道で直接送った回数。**検査が読む。**
    private(set) var directUploads = 0
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
        // **待たずに送る。** いま作った面を GPU はまだ知らないので、読み終わるのを待つ
        // 相手が居ない
        replaceTexture()
    }

    /// **面を常駐から退かせる** ([#738])。
    ///
    /// 常駐の集合は入れたものを抱えるので、絵を手放しても面は解放されない。`draw()` の
    /// 中で `loadImage` を呼ぶ書き方は、これでフレームごとに 1 枚ずつ積んでいた
    /// (実測: 256x256 を 200 フレームで +108 MiB)。退かせるだけで待たないので、
    /// 手放す側は寿命を気にしなくてよい。置いた列や、置いて作った形がまだ読むなら、
    /// それらが絵を抱えているのでここは走らない ([#1079]・[#1178])。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    /// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
    isolated deinit { gpu.retire(texture) }

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
            "write(): the picture passed is \(picture.width)x\(picture.height), which differs "
                + "from this image's \(width)x\(height), so nothing was written. If the source "
                + "changed size, make it again with createImage()")
    }

    /// 書き換えた画素を送るよう頼む。描く直前に呼ばれる。
    ///
    /// **その場では送らない。** 描き切りは GPU の完了を待たずに返る (#727) ので、前の
    /// フレームがまだこの面を読んでいるかもしれない。その場で面へ書くには投入済みの全部を
    /// 待つしかなく、毎フレーム映像を差し替えるスケッチでは CPU と GPU の重なりがそこで
    /// 消えていた (#749)。登録簿に載せて、描き切りが GPU 側のコピーで届ける。
    /// 書き換えないフレームは何も積まない。
    func requestUpload() {
        guard needsUpload else { return }
        gpu.pendingUploads.enqueue(self)
    }

    private var pixelBytes: Int { pixels.count * MemoryLayout<SIMD4<Float16>>.stride }
    private var bytesPerRow: Int { width * MemoryLayout<SIMD4<Float16>>.stride }

    private func replaceTexture() {
        pixels.withUnsafeBytes { source in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: source.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }
}

extension Image: PendingUpload {
    var pendingUploadByteCount: Int { needsUpload ? pixelBytes : 0 }

    func stageUpload(
        into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer, at offset: Int,
        on encoder: any MTL4ComputeCommandEncoder
    ) -> UInt64 {
        pixels.withUnsafeBytes { source in
            bytes.copyMemory(from: source.baseAddress!, byteCount: pixelBytes)
        }
        encoder.copy(
            sourceBuffer: staging, sourceOffset: offset, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: 0, sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        return writeGeneration
    }

    func uploadDirectly() -> UInt64? {
        // **待てなければ送らない** (#934)。旗は立ったままなので、次の描き切りへ持ち越す
        guard
            gpu.settleBeforeWriting(
                orWarn: "Could not wait for the GPU before sending an image to a surface, so "
                    + "the write was held back")
        else { return nil }
        replaceTexture()
        directUploads += 1
        return writeGeneration
    }

    func markUploaded(through generation: UInt64) {
        guard generation == writeGeneration else { return }
        needsUpload = false
    }
}
