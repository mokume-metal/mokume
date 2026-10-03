// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 4 成分ずつ並んだ画素を、いちばん近い元の画素で間引く。
///
/// ## なぜなめらかにしないのか
///
/// 観測を軽く運ぶための縮小で、写真の縮小ではない。なめらかさより、**元の絵のどこが
/// どう見えていたかが保たれる**ことを取る。
///
/// ## なぜ 1 つなのか
///
/// 本体が縮める道は、出力段を通した絵の置き場から拾う 1 つ (``EncodedImage/read(scaledBy:)``)
/// だけである。検査は「変換してから間引く」「間引いてから変換する」を独立した参照として
/// 組むが、**拾い方はここを呼んで借り、写しを持たない** — 片方だけ拾い方や丸め方が動くと
/// 「通った道で違う絵が返る」ことになり、しかもどちらももっともらしく見えるので気付けない
/// ([#960](https://github.com/mokume-metal/mokume/issues/960) の 3)。
///
/// かつては作業空間の画素と出力段を通った後の絵の両方に縮める口が本体にあり、20 行が
/// 逐語同文だったのをここへ畳んだ。本体の呼び手が無くなった口は検査の側へ移した
/// ([#1984](https://github.com/mokume-metal/mokume/issues/1984))。
///
/// ## 間引く順序は絵を変えない
///
/// 出力段は画素ごとの純関数で、ここは元の成分を混ぜずにそのまま拾う。だから「間引いて
/// から変換」と「変換してから間引き」は同じバイト列になる
/// ([#382](https://github.com/mokume-metal/mokume/issues/382))。順序が絵を変えない以上、
/// 呼び出し側は費用の安いほうを取れる。
enum NearestNeighbor {
    /// 行の間に詰め物がある元から、拾う画素だけを詰めて返す。**縮めないときは `nil`。**
    ///
    /// 出力段を通した絵の置き場 (``EncodedImage``) は行の間隔が幅ぶんより広いことがあり、
    /// そこから原寸の配列を作らずに直接拾うための口である ([#1745])。詰め物の無い元は
    /// `rowStride` を `width * 4` にして渡す。
    ///
    /// - Parameters:
    ///   - rows: 1 画素 4 成分で並んだ行の列。`rowStride * (height - 1) + width * 4` 要素以上。
    ///   - rowStride: 1 行ぶんの要素数 (詰め物を含む)。`width * 4` 以上。
    ///   - factor: 縮小率 (1 = 実寸)。**1 以上と 0 以下は縮めない。**
    ///
    /// [#1745]: https://github.com/mokume-metal/mokume/issues/1745
    static func scaled<Element: Numeric>(
        rows source: UnsafeBufferPointer<Element>, rowStride: Int,
        width: Int, height: Int, by factor: Double
    ) -> (components: [Element], width: Int, height: Int)? {
        guard factor > 0, factor < 1 else { return nil }
        let newWidth = Swift.max(1, Int((Double(width) * factor).rounded()))
        let newHeight = Swift.max(1, Int((Double(height) * factor).rounded()))
        var scaled = [Element](repeating: .zero, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let sourceY = Swift.min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sourceX = Swift.min(width - 1, x * width / newWidth)
                let from = sourceY * rowStride + sourceX * 4
                let to = (y * newWidth + x) * 4
                scaled[to] = source[from]
                scaled[to + 1] = source[from + 1]
                scaled[to + 2] = source[from + 2]
                scaled[to + 3] = source[from + 3]
            }
        }
        return (scaled, newWidth, newHeight)
    }
}
