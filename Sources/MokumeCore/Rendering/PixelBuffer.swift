// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画先から CPU 側へ読み出した画素。
///
/// 値は**作業空間そのまま** — 線形・アルファ乗算済み・半精度浮動小数の範囲で、
/// 表示できる範囲を超えた明るさもそのまま入っている。表示や書き出しのための変換は
/// 出力段が行うので、ここには現れない ([ADR-0011] 決定 3)。
///
/// 原点は左上、行優先。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public struct PixelBuffer: Equatable, Sendable {
    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int

    /// 画素の成分列。1 画素あたり 4 成分 (赤・緑・青・不透明度) が並ぶ。
    public let components: [Float16]

    init(width: Int, height: Int, components: [Float16]) {
        self.width = width
        self.height = height
        self.components = components
    }

    /// 指定した位置の色。原点は左上。
    ///
    /// 範囲の外を読むと透明が返る (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。
    /// 画素の面 (``Pixels``) と絵 (``Image/get(_:_:)``) も範囲の外で同じ値を返すので、
    /// どの口で読んでも答えは変わらない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public subscript(x: Int, y: Int) -> LinearRGBA {
        // 置き場の位置を求める掛け算より先に見る。大きな位置では掛け算のほうが溢れて落ちる
        guard x >= 0, y >= 0, x < width, y < height else { return .transparent }
        let base = (y * width + x) * 4
        return LinearRGBA(
            premultipliedRed: Float(components[base]),
            green: Float(components[base + 1]),
            blue: Float(components[base + 2]),
            alpha: Float(components[base + 3]))
    }
}

extension PixelBuffer {
    /// 間引いて小さくした画素を返す。**拾い方は ``NearestNeighbor`` が持つ。**
    ///
    /// **間引くのは出力段より前である。** 順序が絵を変えないので (あちらの doc)、
    /// 費用の安いほうを取れる。
    ///
    /// 倍率が 1 以上、または範囲外のときはそのまま返す。
    func scaled(by factor: Double) -> PixelBuffer {
        guard let small = NearestNeighbor.scaled(
            components, width: width, height: height, by: factor)
        else { return self }
        return PixelBuffer(
            width: small.width, height: small.height, components: small.components)
    }
}
