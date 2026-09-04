// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Metal
import MokumeDiagnostics
import simd

/// 字形を焼いて溜めておく 1 枚の面。
///
/// ## なぜ 1 枚にまとめるのか
///
/// 字は 1 文字ずつ別々の絵だが、面を分けると**字ごとに描画を切らなければならない**。
/// 1 枚に詰めておけば、文字列も図形も同じ列にそのまま並べられる。
///
/// ## この面は色を持つ
///
/// 焼くのは覆っている割合ではなく**色そのもの** (線形 P3・アルファ乗算済み) である。
/// 単色の字は白で焼かれるので `RGB == A` になり、塗りの色を掛けると「塗りの色 ×
/// 覆い」に戻る — **覆いの面だったときと 1 画素も変わらない**。絵文字のように
/// それ自身が色を持つ字形は、その色がそのまま入る。
///
/// 焼く道具立ては ``ImageFile`` と同じで、色空間の変換は CoreGraphics が行う
/// ([ADR-0011] 決定 3 の「入口で変換」)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
///
/// ## 図形もこの面を読む
///
/// 左上の隅に**白く塗った区画**を置いてある。図形はそこを指すので、字と図形で
/// シェーダを分けずに済む (白を掛けても色は変わらない)。区画の中央を指すので、
/// 隣の字形が滲み込むことはない。
///
/// ## 書き込んでよい時機
///
/// 焼き付けは CPU からこの面へ直接書き込む。**GPU がこの面を読んでいる間に書き換えて
/// はならない。** 面への描画は投入しても GPU の完了を待たずに返る (#727) ので、焼く
/// 直前に投入済みのものが全部終わるのを待つ。新しい字形が出ないフレームは焼かない
/// ので、待ちも払わない。広げるとき (`grow`) は新しい面を作るだけなので待たない —
/// 前の面は、そこを指している列が GPU の完了まで抱える。
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor final class GlyphAtlas {
    /// 最初の一辺 (画素)。
    static let initialSize = 256
    /// 広げられる上限 (画素)。
    static let maximumSize = 4096
    /// 字形の絵の周りに置く余白 (画素)。
    ///
    /// **この余白は送り位置に混ざってはならない。** 焼くときに余白ぶんずらし、
    /// 描くときに同じだけ戻すので、位置には現れない。
    static let padding = 2
    /// 白く塗った区画の一辺 (画素)。
    static let whiteBlock = 4
    /// 焼き場の画素の形式。**作業空間と同じ** — 線形・アルファ乗算済みの 16F
    /// ([ADR-0011] 決定 2)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static let pixelFormat: MTLPixelFormat = .rgba16Float
    /// 1 画素ぶんのバイト数。
    static let bytesPerPixel = MemoryLayout<SIMD4<Float16>>.stride

    /// 焼いた字形 1 つぶん。
    struct Entry {
        /// 面の中での左上と右下 (0…1)。
        var uvMin: SIMD2<Float>
        var uvMax: SIMD2<Float>
        /// 送り位置と基準線から見た、絵の左上のずれ (画素)。
        var offset: SIMD2<Float>
        /// 絵の大きさ (画素)。
        var size: SIMD2<Float>
        /// 絵を持たない字 (空白など)。
        var isBlank: Bool
        /// **字形が自分の色を持っているか** (絵文字がこれに当たる)。
        ///
        /// 色を持つ字形には塗りの色を掛けない — 積む側が頂点の色を「白 × 塗りの
        /// 透明度」に差し替えるので、合成の式は 1 本のままでよい (``Canvas``)。
        var isColored: Bool
    }

    /// 字形を引いた結果。**引けなかったときは理由を名乗る** ([#738])。
    ///
    /// 理由が要るのは、受け取る側が「面を広げれば入るのか」を判断できないためである。
    /// 分けないと、広げても入らない 1 字のために面を広げ続けることになる — 広げるたびに
    /// 焼いた字形は全部捨てられるので、**入らない字が他の全部を焼き直させる**形になり、
    /// 上限まで行き着いた後は回復もしない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    enum Lookup {
        /// 焼いてある (あるいはいま焼いた) 字形。
        case found(Entry)
        /// いまの面に場所が無い。**広げれば入る。**
        case full
        /// 上限の面 (``maximumSize``) より大きい。**広げても入らない。**
        case tooLarge(width: Int, height: Int)
        /// 焼き場を用意できなかった。広げても変わらない。
        case unbakeable
    }

    /// 焼き分けの鍵。
    struct Key: Hashable {
        var fontKey: String
        var size: Float
        var style: TextStyle
        var glyph: UInt16
    }

    private(set) var texture: any MTLTexture
    private(set) var size: Int
    private var entries: [Key: Entry] = [:]
    private var cursorX: Int
    private var cursorY: Int
    private var rowHeight: Int
    /// 焼く前に待つ相手 (「書き込んでよい時機」を参照)。
    private let gpu: RenderDevice
    /// 大きすぎる字形のことを、もう知らせたか。
    ///
    /// **毎フレーム起きうる** — 入らない字は焼かれないので、次のフレームでも同じ道を
    /// 通る。1 度だけ言うのは ``Diagnostics/warn(_:)`` の但し書きに従う。
    private var warnedTooLarge = false

    init(gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        self.size = Self.initialSize
        self.texture = try Self.makeTexture(side: size, gpu: gpu)
        self.cursorX = Self.whiteBlock + Self.padding
        self.cursorY = 0
        self.rowHeight = Self.whiteBlock + Self.padding
        paintWhiteBlock()
    }

    /// **いまの面も常駐から退かせる** ([#738])。焼き場は描き場所ごとに 1 つ立つので、
    /// 描き場所を作っては捨てる書き方は、外さないとここで積む。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    isolated deinit { gpu.retire(texture) }

    private static func makeTexture(side: Int, gpu: RenderDevice) throws(RenderFailure)
        -> any MTLTexture
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.glyphs"
        // 面全体を 0 で埋める。字形を焼く前に読まれても、透明として振る舞う
        let zeros = [SIMD4<Float16>](repeating: .zero, count: side * side)
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: zeros,
            bytesPerRow: side * Self.bytesPerPixel)
        return texture
    }

    /// 左上の隅を白く塗る。図形はここを指す。
    private func paintWhiteBlock() {
        let side = Self.whiteBlock
        let white = [SIMD4<Float16>](repeating: SIMD4(1, 1, 1, 1), count: side * side)
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: white,
            bytesPerRow: side * Self.bytesPerPixel)
    }

    /// 図形が指す、白い区画の中の点。
    ///
    /// 区画の中央 — 白い画素だけに囲まれた点を指すので、線形に読んでもちょうど 1 になる。
    var whiteUV: SIMD2<Float> {
        let center = Float(Self.whiteBlock) / 2 / Float(size)
        return SIMD2(center, center)
    }

    /// もう一段広げられるか。
    var canGrow: Bool { size < Self.maximumSize }

    /// 面を倍の大きさで取り直す。
    ///
    /// **焼いた字形は引き継がない。** 新しい面の中では場所が変わるので、位置を
    /// 計算し直すより、要るものをもう一度焼くほうが単純である。前の面は、そこを
    /// 指している列が抱えたまま残る。
    ///
    /// **前の面は常駐から退かせる** ([#738])。列が抱えているのは GPU が読み終わるまでで、
    /// 常駐の集合はそれと関係なく抱え続ける — 外さないと 256 から 4096 までの面が全部
    /// 残り、最後の 1 枚だけで 128 MiB になる。ここで待たないのは、広げるのが列を閉じた
    /// 直後 = フレームの途中だからで、外れるのは投入済みのものが終わってからである。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    func grow(gpu: RenderDevice) throws(RenderFailure) {
        let next = min(Self.maximumSize, size * 2)
        let previous = texture
        // **新しい面を先に作る。** 作れずに投げたときも、前の面はそのまま使える
        texture = try Self.makeTexture(side: next, gpu: gpu)
        gpu.retire(previous)
        size = next
        entries.removeAll(keepingCapacity: true)
        cursorX = Self.whiteBlock + Self.padding
        cursorY = 0
        rowHeight = Self.whiteBlock + Self.padding
        paintWhiteBlock()
    }

    /// 焼いてある字形。まだ無ければ焼く。**引けなければ理由を返す。**
    func entry(for key: Key, font: CTFont) -> Lookup {
        if let found = entries[key] { return .found(found) }
        let baked = bake(key: key, font: font)
        if case .found(let entry) = baked { entries[key] = entry }
        return baked
    }

    /// 字形を焼いて面へ置く。
    private func bake(key: Key, font: CTFont) -> Lookup {
        var glyph = CGGlyph(key.glyph)
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)

        // 絵を持たない字 (空白)。場所は取らないが、送り幅は持つ
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else {
            return .found(
                Entry(
                    uvMin: .zero, uvMax: .zero, offset: .zero, size: .zero, isBlank: true,
                    isColored: false))
        }

        let pad = Self.padding
        let left = Int(bounds.minX.rounded(.down)) - pad
        let bottom = Int(bounds.minY.rounded(.down)) - pad
        let right = Int(bounds.maxX.rounded(.up)) + pad
        let top = Int(bounds.maxY.rounded(.up)) + pad
        let width = right - left
        let height = top - bottom
        guard width > 0, height > 0 else { return .unbakeable }
        // **上限の面にも入らないなら、広げても入らない。** ここで名乗って諦める
        guard width <= Self.maximumSize, height <= Self.maximumSize else {
            warnTooLargeOnce(width: width, height: height)
            return .tooLarge(width: width, height: height)
        }
        // いまの面より大きいだけなら、広げれば入る
        guard width <= size, height <= size else { return .full }

        guard let origin = reserve(width: width, height: height) else { return .full }
        guard
            let pixels = render(
                glyph: glyph, font: font, width: width, height: height, penX: -left,
                penY: -bottom)
        else { return .unbakeable }

        // 前のフレームがまだこの面を読んでいるかもしれない。書く直前に待つ
        gpu.settleQuietly(before: "字形を焼く")
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: width * Self.bytesPerPixel)

        let side = Float(size)
        return .found(
            Entry(
                uvMin: SIMD2(Float(origin.x) / side, Float(origin.y) / side),
                uvMax: SIMD2(Float(origin.x + width) / side, Float(origin.y + height) / side),
                // 縦は下向きに測るので、基準線から上端までの距離が負のずれになる
                offset: SIMD2(Float(left), Float(-top)),
                size: SIMD2(Float(width), Float(height)),
                isBlank: false,
                isColored: Self.hasOwnColor(pixels)))
    }

    /// 広げても入らない字形を頼まれたことを、**最初の 1 度だけ**知らせる。
    ///
    /// 黙って何も描かないと、利用者は書体か色か位置を疑う ([ADR-0020] 決定 5)。
    /// 大きさが理由だと分かれば、`textSize()` を下げるという次の一手が打てる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnTooLargeOnce(width: Int, height: Int) {
        guard !warnedTooLarge else { return }
        warnedTooLarge = true
        Diagnostics.warn(
            "text(): 字形 1 つが \(width)x\(height) 画素あり、焼き場の上限 "
                + "\(Self.maximumSize)x\(Self.maximumSize) に入りません。"
                + "この字は描かれません — textSize() を下げてください")
    }

    /// 焼いた画素が、字形自身の色を持っているか。
    ///
    /// 白で焼いた単色の字は**乗算済みで `RGB == A` が厳密に成立する**ので、崩れて
    /// いれば字形の側が色を持っている。書体の種別ではなく焼いた結果を見るので、
    /// 絵文字でも色つきの飾り字でも同じ 1 つの判定で足りる。
    private static func hasOwnColor(_ pixels: [SIMD4<Float16>]) -> Bool {
        // 8bit で 1 段ぶんより粗いずれだけを色と見る (焼きの誤差を色と取り違えない)
        let tolerance = Float16(1.0 / 512)
        return pixels.contains { texel in
            abs(texel.x - texel.w) > tolerance || abs(texel.y - texel.w) > tolerance
                || abs(texel.z - texel.w) > tolerance
        }
    }

    /// 面の中に場所を取る。棚を左から埋め、いっぱいになったら次の段へ。
    private func reserve(width: Int, height: Int) -> (x: Int, y: Int)? {
        if cursorX + width > size {
            cursorX = 0
            cursorY += rowHeight
            rowHeight = 0
        }
        guard cursorY + height <= size else { return nil }
        let origin = (x: cursorX, y: cursorY)
        cursorX += width
        rowHeight = max(rowHeight, height)
        return origin
    }

    /// 字形 1 つを、作業空間の色の並びとして描く。
    ///
    /// **白で塗る。** 単色の字はこれで `RGB == A` になり、後から塗りの色を掛けると
    /// 覆いの面だったときと同じ値に戻る。色を持つ字形 (絵文字) は塗りの指定を無視して
    /// 自分の色を書き込むので、同じ 1 本の焼き方で両方が通る。
    ///
    /// 画素ごとの位置合わせと、画面の並びに合わせた平滑化は**切ってある**。入れると
    /// 同じ字が置き場所によって違う絵になり、焼いたものを使い回せなくなる。
    ///
    /// 描く道具の座標は下から上へ数えるが、**並びの先頭は絵の上端**なので、
    /// 面へはそのままの順で写る (``ImageFile/decode(at:name:)`` と同じ)。
    private func render(
        glyph: CGGlyph, font: CTFont, width: Int, height: Int, penX: Int, penY: Int
    ) -> [SIMD4<Float16>]? {
        var pixels = [SIMD4<Float16>](repeating: .zero, count: width * height)
        let stride = width * Self.bytesPerPixel
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            // 画像と同じ道具立て。色空間の変換は CoreGraphics が行う (ADR-0011 決定 3)
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 16, bytesPerRow: stride, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }

            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)

            var index = glyph
            var position = CGPoint(x: CGFloat(penX), y: CGFloat(penY))
            CTFontDrawGlyphs(font, &index, &position, 1, context)
            return true
        }
        return drawn ? pixels : nil
    }
}
