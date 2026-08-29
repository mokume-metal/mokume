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
    public subscript(x: Int, y: Int) -> LinearRGBA {
        precondition(
            x >= 0 && x < width && y >= 0 && y < height,
            "読み出す位置が描画先の外にある: (\(x), \(y)) / \(width)x\(height)")
        let base = (y * width + x) * 4
        return LinearRGBA(
            premultipliedRed: Float(components[base]),
            green: Float(components[base + 1]),
            blue: Float(components[base + 2]),
            alpha: Float(components[base + 3]))
    }
}

extension PixelBuffer {
    /// 間引いて小さくした画素を返す。
    ///
    /// 観測を軽く運ぶための縮小で、写真の縮小ではない — 近い点をそのまま拾う。
    /// なめらかさより、**元の絵のどこがどう見えていたかが保たれる**ことを取る。
    ///
    /// **間引くのは出力段より前である。** 出力段は画素ごとの純関数で、ここは元の成分を
    /// 混ぜずにそのまま拾うので、「間引いてから変換」と「変換してから間引き」は同じバイト列に
    /// なる。順序が絵を変えない以上、費用の安いほうを取る (#382)。
    ///
    /// 倍率が 1 以上、または範囲外のときはそのまま返す。
    func scaled(by factor: Double) -> PixelBuffer {
        guard factor > 0, factor < 1 else { return self }
        let newWidth = Swift.max(1, Int((Double(width) * factor).rounded()))
        let newHeight = Swift.max(1, Int((Double(height) * factor).rounded()))
        var components = [Float16](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let sourceY = Swift.min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sourceX = Swift.min(width - 1, x * width / newWidth)
                let source = (sourceY * width + sourceX) * 4
                let destination = (y * newWidth + x) * 4
                components[destination] = self.components[source]
                components[destination + 1] = self.components[source + 1]
                components[destination + 2] = self.components[source + 2]
                components[destination + 3] = self.components[source + 3]
            }
        }
        return PixelBuffer(width: newWidth, height: newHeight, components: components)
    }
}
