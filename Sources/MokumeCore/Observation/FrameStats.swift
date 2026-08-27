// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 絵の要約。
///
/// 読み手 (多くは画像を直接は見られない道具やエージェント) が、**画像を開かずに**
/// 「真っ黒ではないか」「絵が隅に寄っていないか」を判定できるようにする。
///
/// 値は出力段を通した後の表示できる形で数える ([ADR-0011] 決定 6 の量子化点)。
/// 作業空間の値で数えると、表示できる範囲を超えた明るさが平均を引っ張り、
/// 「見た目」とずれた数字になる。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public struct FrameStats: Encodable, Equatable, Sendable {
    /// 内容のある領域の範囲。左上を原点に、幅・高さで正規化してある。
    public struct Bounds: Encodable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// 数えた点の並び。
    public struct Grid: Encodable, Equatable, Sendable {
        public let width: Int
        public let height: Int
    }

    /// 赤・緑・青の平均 (0…1)。
    public let meanColor: [Double]
    /// 明るさの平均 (0…1)。
    public let meanLuminance: Double
    /// 地 (いちばん多い色) と違う色を持つ点の割合 (0…1)。
    public let contentFraction: Double
    /// 内容のある点の外接範囲。1 点も無ければ `nil`。
    public let contentBounds: Bounds?
    /// 数えた点の並び。全画素ではなく、この格子で間引いて数えている。
    public let sampleGrid: Grid

    /// 色の近さを測るときの許容。8 bit で 8 段階ぶん。量子化と、なだらかな階調の
    /// わずかな揺れを内容と数えないための幅。
    private static let threshold = 8

    /// 絵を格子で間引いて数える。
    ///
    /// **地はいちばん多い色とする。** 左上の点を地に決める定義は、そこに何か描かれて
    /// いると内容と地が入れ替わる (左上に図形を置いた絵で「内容が 9 割」になる)。
    /// 知りたいのは「何か描かれているか」なので、多数派を地に取る。
    ///
    /// - Parameter maximumSamples: 1 辺あたりの最大の点数。大きな絵でも数える手間が
    ///   一定に収まる。
    static func summarize(_ image: DisplayImage, maximumSamples: Int = 64) -> FrameStats {
        let columns = min(image.width, maximumSamples)
        let rows = min(image.height, maximumSamples)
        guard columns > 0, rows > 0 else {
            return FrameStats(
                meanColor: [0, 0, 0],
                meanLuminance: 0,
                contentFraction: 0,
                contentBounds: nil,
                sampleGrid: Grid(width: 0, height: 0))
        }

        typealias Sample = (
            x: Int, y: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
        )
        var samples: [Sample] = []
        samples.reserveCapacity(rows * columns)
        var histogram: [UInt32: Int] = [:]
        var sumRed = 0, sumGreen = 0, sumBlue = 0

        for row in 0..<rows {
            let y = rows == 1 ? 0 : row * (image.height - 1) / (rows - 1)
            for column in 0..<columns {
                let x = columns == 1 ? 0 : column * (image.width - 1) / (columns - 1)
                let pixel = image[x, y]
                sumRed += Int(pixel.red)
                sumGreen += Int(pixel.green)
                sumBlue += Int(pixel.blue)
                samples.append((x, y, pixel.red, pixel.green, pixel.blue, pixel.alpha))
                // 量子化してから数える。なだらかな階調で多数派が散らばらないように
                let key =
                    UInt32(pixel.red / 8) << 24 | UInt32(pixel.green / 8) << 16
                    | UInt32(pixel.blue / 8) << 8 | UInt32(pixel.alpha / 8)
                histogram[key, default: 0] += 1
            }
        }

        // 同数のときに結果が揺れないよう、多い順・キーの小さい順で決める
        let groundKey =
            histogram.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? 0
        let ground = (
            red: Int((groundKey >> 24) & 0xFF) * 8,
            green: Int((groundKey >> 16) & 0xFF) * 8,
            blue: Int((groundKey >> 8) & 0xFF) * 8,
            alpha: Int(groundKey & 0xFF) * 8
        )

        var contentCount = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

        for sample in samples {
            let distance = max(
                abs(Int(sample.red) - ground.red),
                max(
                    abs(Int(sample.green) - ground.green),
                    max(
                        abs(Int(sample.blue) - ground.blue),
                        abs(Int(sample.alpha) - ground.alpha))))
            guard distance >= threshold else { continue }
            contentCount += 1
            minX = min(minX, sample.x)
            minY = min(minY, sample.y)
            maxX = max(maxX, sample.x)
            maxY = max(maxY, sample.y)
        }

        let sampleCount = Double(rows * columns)
        let mean = [
            Double(sumRed) / sampleCount / 255,
            Double(sumGreen) / sampleCount / 255,
            Double(sumBlue) / sampleCount / 255,
        ]
        // 明るさは知覚に寄せた重み付け (赤 0.2126 / 緑 0.7152 / 青 0.0722)
        let luminance = mean[0] * 0.2126 + mean[1] * 0.7152 + mean[2] * 0.0722

        var bounds: Bounds?
        if contentCount > 0 {
            let width = Double(image.width)
            let height = Double(image.height)
            bounds = Bounds(
                x: Double(minX) / width,
                y: Double(minY) / height,
                width: Double(maxX - minX + 1) / width,
                height: Double(maxY - minY + 1) / height)
        }

        return FrameStats(
            meanColor: mean,
            meanLuminance: luminance,
            contentFraction: Double(contentCount) / sampleCount,
            contentBounds: bounds,
            sampleGrid: Grid(width: columns, height: rows))
    }
}
