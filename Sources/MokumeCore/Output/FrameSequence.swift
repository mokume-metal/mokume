// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 連番の名前を組み立てるもの。
///
/// `"out/frame-####.png"` の `#` の並びが番号の桁になる。**桁を揃える**ので、名前順に
/// 並べたときが撮った順になる (`FrameObserver` の撮り方と同じ作法)。
///
/// ## 番号はファイル名に入る
///
/// `#` の並びを探すのは、最後の `/` より後ろ (ファイル名) だけである。置き場の
/// ディレクトリの名前の `#` (`"take#1/f-##.png"` の `take#1`) は場所の一部で、番号の
/// 場所ではない。パス全体から探すと番号がディレクトリへ入り、1 枚ごとに別の置き場が
/// できて、名前順が撮った順にならない ([#2313])。ファイル名に並びが 2 つ以上あるときは
/// 最初の並びを番号にする。
///
/// ## `#` が無い指定は組み立てない
///
/// 番号の入る場所が無い名前をそのまま受けると、**全部のフレームが同じ名前になり、
/// 最後の 1 枚だけが残る**。撮れているつもりで撮れていない、という最も分かりにくい
/// 壊れ方なので、組み立ての時点で断る (``init(pattern:)`` が `nil` を返す)。置き場の
/// 名前にしか `#` の無い指定 (`"take#1/still.png"`) も、ファイル名に番号の入る場所が
/// 無いので断る。
///
/// 番号が桁に収まらなくなったら、切り詰めずに桁が伸びる。名前順と撮った順が食い違う
/// ことになるが、**枚数を黙って失うよりはよい**。
///
/// **隔離を持たない。** 名前を組み立てるだけの値で、走らせる前に綴りを確かめる口
/// (``FrameRecorder/accepts(_:)``) が main actor の外から使う。
///
/// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
nonisolated struct FrameSequence {
    /// 番号の前に付く部分。
    let prefix: String
    /// 番号の桁数。
    let digits: Int
    /// 番号の後ろに付く部分。
    let suffix: String

    /// 頼まれたときの綴り (`#` の並びを含む)。名乗るときに使う。
    var pattern: String { prefix + String(repeating: "#", count: digits) + suffix }

    /// 次に撮る番号。この録りの中での通し番号で、0 から始まる。
    private(set) var index = 0

    /// ファイル名の `#` の並びを番号の場所として読む。**1 つも無ければ組み立てない。**
    ///
    /// **`/` と `#` は Unicode scalar で探す** ([#2313] の反証)。ファイルシステムは 1 文字
    /// ずつの `/` で区切る。`Character` (書記素) で比べると、直後の結合文字 (U+0301 など) と
    /// 1 つの文字になった `/` や `#` を見落とし、区切りを越えて置き場の名前の `#` を番号に
    /// したり、並んだ `#` の桁を 1 つ少なく数えたりする。
    ///
    /// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
    init?(pattern: String) {
        let scalars = pattern.unicodeScalars
        // 最後の `/` より後ろ (ファイル名) だけを探す。置き場の名前の `#` は場所の一部である
        let name = scalars.lastIndex(of: "/").map(scalars.index(after:)) ?? scalars.startIndex
        guard let start = scalars[name...].firstIndex(of: "#") else { return nil }
        var end = start
        while end < scalars.endIndex, scalars[end] == "#" { end = scalars.index(after: end) }
        prefix = String(scalars[scalars.startIndex..<start])
        digits = scalars.distance(from: start, to: end)
        suffix = String(scalars[end...])
    }

    /// `index` 枚目 (0 始まり) の行き先。**番号が桁に収まらなければ桁が伸びる**ので、後ろの枚ほど長い。
    func name(at index: Int) -> String {
        prefix + String(format: "%0\(digits)d", index) + suffix
    }

    /// 次の 1 枚の行き先を返し、番号を 1 つ進める。
    mutating func next() -> String {
        defer { index += 1 }
        return name(at: index)
    }
}
