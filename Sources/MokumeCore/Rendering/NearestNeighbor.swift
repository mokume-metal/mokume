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
/// 通る道が 2 つある — 作業空間の画素 (``PixelBuffer``) と、出力段を通った後の絵
/// (``DisplayImage``)。**どちらも同じ絵についての同じ要求に答える道**なので、片方だけ
/// 拾い方や丸め方が動くと「通った道で違う絵が返る」ことになり、しかもどちらも
/// もっともらしく見えるので気付けない
/// ([#960](https://github.com/mokume-metal/mokume/issues/960) の 3)。
///
/// 畳む前は 20 行が逐語同文で、差は要素の型と変数名だけだった。``DisplayImage`` の側の
/// doc は既に「拾い方は ``PixelBuffer/scaled(by:)`` と同じ」と、**揃っていることを契約
/// として名乗っていた** — 注意書きで守る形をやめ、揃わせようがない形にした。
///
/// ## どちらの道を通っても同じバイト列になる
///
/// 出力段は画素ごとの純関数で、ここは元の成分を混ぜずにそのまま拾う。だから「間引いて
/// から変換」と「変換してから間引き」は同じバイト列になる
/// ([#382](https://github.com/mokume-metal/mokume/issues/382))。順序が絵を変えない以上、
/// 呼び出し側は費用の安いほうを取れる。
enum NearestNeighbor {
    /// 間引いた画素を返す。**縮めないときは `nil`** — 呼び出し側は元をそのまま返す。
    ///
    /// - Parameters:
    ///   - source: 1 画素 4 成分で並んだ元。長さは `width * height * 4`。
    ///   - factor: 縮小率 (1 = 実寸)。**1 以上と 0 以下は縮めない。**
    static func scaled<Element: Numeric>(
        _ source: [Element], width: Int, height: Int, by factor: Double
    ) -> (components: [Element], width: Int, height: Int)? {
        guard factor > 0, factor < 1 else { return nil }
        let newWidth = Swift.max(1, Int((Double(width) * factor).rounded()))
        let newHeight = Swift.max(1, Int((Double(height) * factor).rounded()))
        var scaled = [Element](repeating: .zero, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let sourceY = Swift.min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sourceX = Swift.min(width - 1, x * width / newWidth)
                let from = (sourceY * width + sourceX) * 4
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
