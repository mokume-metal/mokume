// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

@testable import MokumeCore

// 検査が「変換してから間引く」「間引いてから変換する」の参照を組むための縮小 (#1984)。
// 本体の縮小は置き場から拾う 1 つ (`EncodedImage.read(scaledBy:)`) だけになったので、
// 配列から縮める口はこちらに置く。拾い方は本体の `NearestNeighbor.scaled(rows:...)` を
// 呼んで借り、写しを作らない — 写せば本体と検査の拾い方が別々に動きうる。

extension NearestNeighbor {
    /// 詰め物の無い配列から間引く。**縮めないときは `nil`**。
    ///
    /// - Parameters:
    ///   - source: 1 画素 4 成分で並んだ元。長さは `width * height * 4`。
    ///   - factor: 縮小率 (1 = 実寸)。**1 以上と 0 以下は縮めない。**
    static func scaled<Element: Numeric>(
        _ source: [Element], width: Int, height: Int, by factor: Double
    ) -> (components: [Element], width: Int, height: Int)? {
        source.withUnsafeBufferPointer { rows in
            scaled(rows: rows, rowStride: width * 4, width: width, height: height, by: factor)
        }
    }
}

extension PixelBuffer {
    /// 間引いて小さくした画素を返す。倍率が 1 以上、または 0 以下のときはそのまま返す。
    func scaled(by factor: Double) -> PixelBuffer {
        guard let small = NearestNeighbor.scaled(
            components, width: width, height: height, by: factor)
        else { return self }
        return PixelBuffer(
            width: small.width, height: small.height, components: small.components)
    }
}

extension DisplayImage {
    /// 間引いて小さくした絵を返す。倍率が 1 以上、または 0 以下のときはそのまま返す。
    func scaled(by factor: Double) -> DisplayImage {
        guard let small = NearestNeighbor.scaled(
            bytes, width: width, height: height, by: factor)
        else { return self }
        return DisplayImage(
            width: small.width, height: small.height, bytes: small.components)
    }
}
