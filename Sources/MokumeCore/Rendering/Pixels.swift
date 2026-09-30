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
    /// 書いてよいかを尋ねる先。**書く口はすべて、書く前にここを通る** ([#1672])。
    ///
    /// 答えるのは窓を渡した面 (``Canvas/pixels``) で、だめなら面がそのわけを 1 度言う。窓は
    /// プロパティに取っておけるので、取った時点ではなく書く時点で尋ねる。`nil` なら尋ねない
    /// (面を通さずに取った窓)。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    let admitsWrite: (() -> Bool)?

    init(
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
        mirror: PixelMirror?, admitsWrite: (() -> Bool)? = nil
    ) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.mirror = mirror
        self.admitsWrite = admitsWrite
    }

    /// 書く前に `admits` へ尋ねる窓。中身は同じ写しを指す。
    func asking(_ admits: @escaping () -> Bool) -> Pixels {
        Pixels(
            base: base, width: width, height: height, bytesPerRow: bytesPerRow, mirror: mirror,
            admitsWrite: admits)
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
    /// **読む値も書く値も、線形・アルファ乗算済みの ``LinearRGBA`` である** ([ADR-0011] 決定 4)。
    /// 変換が挟まらないので、読んだ値をそのまま書き戻しても、塗りの色 (`fill(_:)`) へ
    /// 渡しても色は沈まない。0–255 の乗算していない数で読むときは ``red(_:)`` ほかを通す。
    ///
    /// 範囲の外を読むと透明が返り、範囲の外へ書くと何も起きない
    /// (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。書けるのは、置いてよい区間
    /// (フレームの中と、本体の `setup()`・止まっている間のコールバック) だけで、外で書くと
    /// 1 度注意して何もしない (``fill(_:)`` も同じ)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
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
            guard admitsWrite?() ?? true, contains(x, y) else { return }
            address(x, y).pointee = HalfSurface.texel(newValue)
            mirror?.hasPendingWrites = true
        }
    }

    /// 全体を 1 色で埋める。
    public func fill(_ color: LinearRGBA) {
        guard admitsWrite?() ?? true else { return }
        let texel = HalfSurface.texel(color)
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
