// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 連番の名前を組み立てるもの。
///
/// `"out/frame-####.png"` の `#` の並びが番号の桁になる。**桁を揃える**ので、名前順に
/// 並べたときが撮った順になる (`FrameObserver` の撮り方と同じ作法)。
///
/// ## `#` が無い指定は組み立てない
///
/// 番号の入る場所が無い名前をそのまま受けると、**全部のフレームが同じ名前になり、
/// 最後の 1 枚だけが残る**。撮れているつもりで撮れていない、という最も分かりにくい
/// 壊れ方なので、組み立ての時点で断る (``init(pattern:)`` が `nil` を返す)。
///
/// 番号が桁に収まらなくなったら、切り詰めずに桁が伸びる。名前順と撮った順が食い違う
/// ことになるが、**枚数を黙って失うよりはよい**。
struct FrameSequence {
    /// 番号の前に付く部分。
    let prefix: String
    /// 番号の桁数。
    let digits: Int
    /// 番号の後ろに付く部分。
    let suffix: String

    /// 次に撮る番号。この録りの中での通し番号で、0 から始まる。
    private(set) var index = 0

    /// `#` の並びを番号の場所として読む。**1 つも無ければ組み立てない。**
    init?(pattern: String) {
        guard let start = pattern.firstIndex(of: "#") else { return nil }
        var end = start
        while end < pattern.endIndex, pattern[end] == "#" { end = pattern.index(after: end) }
        prefix = String(pattern[pattern.startIndex..<start])
        digits = pattern.distance(from: start, to: end)
        suffix = String(pattern[end...])
    }

    /// 次の 1 枚の行き先を返し、番号を 1 つ進める。
    mutating func next() -> String {
        defer { index += 1 }
        return prefix + String(format: "%0\(digits)d", index) + suffix
    }
}
