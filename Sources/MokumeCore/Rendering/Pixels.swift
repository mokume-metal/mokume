// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 画素の面 — 描画先の写しへの窓。
///
/// 読むときに写しは作られず、書き換えは次に GPU が描画先へ触る前に自動で戻される
/// (送り直しの手順は無い)。使い方と、そう作った理由は ``Sketch/pixels`` にある。
///
/// ## 行の間隔
///
/// 位置から場所を求めるのに `bytesPerRow` を使う。いまは幅ぶんそのままだが、
/// 置き場の都合で広くなりうる値なので `y * width + x` では届かない形にしてある。
///
public struct Pixels {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    let base: UnsafeMutableRawPointer
    /// 1 行あたりのバイト数。
    let bytesPerRow: Int
    /// 書いたことを知らせる先。**書く口はすべてここへ旗を立てる** — 立て忘れると、
    /// 書いた画素が描画先へ戻らない。
    let mirror: PixelMirror?

    init(
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
        mirror: PixelMirror?
    ) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.mirror = mirror
    }

    /// 大きさ 0 の窓。写しを用意できなかったときに返す — 読むと透明、書いても何も起きない。
    static let unavailable = Pixels(
        base: unavailableBase, width: 0, height: 0, bytesPerRow: 0, mirror: nil)
    /// 大きさ 0 の窓が指す先。大きさが 0 なので触られることはない。
    private static let unavailableBase = UnsafeMutableRawPointer.allocate(
        byteCount: 8, alignment: 8)

    /// 画素の総数。
    public var count: Int { width * height }

    /// 指定した位置の色。原点は左上。
    ///
    /// 範囲の外を読むと透明が返り、範囲の外へ書くと何も起きない
    /// (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public subscript(x: Int, y: Int) -> LinearRGBA {
        get {
            guard contains(x, y) else { return .transparent }
            let texel = address(x, y).pointee
            return LinearRGBA(
                premultipliedRed: Float(texel.x), green: Float(texel.y),
                blue: Float(texel.z), alpha: Float(texel.w))
        }
        nonmutating set {
            guard contains(x, y) else { return }
            address(x, y).pointee = SIMD4<Float16>(
                Float16(newValue.red), Float16(newValue.green),
                Float16(newValue.blue), Float16(newValue.alpha))
            mirror?.hasPendingWrites = true
        }
    }

    /// 全体を 1 色で埋める。
    public func fill(_ color: LinearRGBA) {
        let texel = SIMD4<Float16>(
            Float16(color.red), Float16(color.green), Float16(color.blue), Float16(color.alpha))
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: SIMD4<Float16>.self)
            for x in 0..<width { row[x] = texel }
        }
        if count > 0 { mirror?.hasPendingWrites = true }
    }

    private func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    private func address(_ x: Int, _ y: Int) -> UnsafeMutablePointer<SIMD4<Float16>> {
        base.advanced(by: y * bytesPerRow)
            .assumingMemoryBound(to: SIMD4<Float16>.self)
            .advanced(by: x)
    }
}
