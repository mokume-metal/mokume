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
