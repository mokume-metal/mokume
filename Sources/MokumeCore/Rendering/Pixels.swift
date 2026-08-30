// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 画素の面 — 描画先のメモリそのものへの窓。
///
/// 読むときに写しは作られず、書き換えは描画先へそのまま届く。使い方と、そう作った
/// 理由は ``Sketch/pixels`` にある。
///
/// ## 行の間隔
///
/// 行の先頭は整列している必要があるので、**1 行が幅ぶんより広いことがある**。
/// 位置から場所を求めるのに `bytesPerRow` を使うのはこのためで、`y * width + x`
/// では届かない幅がある (幅 3・13・63 など)。
///
public struct Pixels {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    let base: UnsafeMutableRawPointer
    /// 1 行あたりのバイト数。
    let bytesPerRow: Int

    init(base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

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
