// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 表示できる形になった絵。
///
/// 作業空間の値ではなく、**出力段を通した後**の画素が入っている — 標準レンジへ収め、
/// ディスプレイのエンコードを掛け、チャンネルあたり 8 bit へ量子化した状態
/// ([ADR-0011] 決定 3・6)。
///
/// アルファは乗算していない (straight)。作業空間の内側では乗算済みで運ぶが、外へ出す
/// 境界で戻す ([ADR-0011] 決定 4)。
///
/// 画素は左上を原点に行優先で、1 画素あたり 4 バイト (赤・緑・青・不透明度) が並ぶ。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public struct DisplayImage: Equatable, Sendable {
    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int
    /// 画素のバイト列。
    public let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// 指定した位置の 4 成分。原点は左上。
    public subscript(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        precondition(
            x >= 0 && x < width && y >= 0 && y < height,
            "読み出す位置が絵の外にある: (\(x), \(y)) / \(width)x\(height)")
        let base = (y * width + x) * 4
        return (bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3])
    }
}

extension DisplayImage {
    /// 間引いて小さくした絵を返す。
    ///
    /// 観測を軽く運ぶための縮小で、写真の縮小ではない — 近い点をそのまま拾う。
    /// なめらかさより、**元の絵のどこがどう見えていたかが保たれる**ことを取る。
    ///
    /// 倍率が 1 以上、または範囲外のときはそのまま返す。
    func scaled(by factor: Double) -> DisplayImage {
        guard factor > 0, factor < 1 else { return self }
        let newWidth = Swift.max(1, Int((Double(width) * factor).rounded()))
        let newHeight = Swift.max(1, Int((Double(height) * factor).rounded()))
        var bytes = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let sourceY = Swift.min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sourceX = Swift.min(width - 1, x * width / newWidth)
                let source = (sourceY * width + sourceX) * 4
                let destination = (y * newWidth + x) * 4
                bytes[destination] = self.bytes[source]
                bytes[destination + 1] = self.bytes[source + 1]
                bytes[destination + 2] = self.bytes[source + 2]
                bytes[destination + 3] = self.bytes[source + 3]
            }
        }
        return DisplayImage(width: newWidth, height: newHeight, bytes: bytes)
    }
}
