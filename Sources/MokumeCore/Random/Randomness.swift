// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 種から同じ列を出す生成器。
///
/// **既定の種も固定である。** 時刻から作らない — 種を決めずに書いたスケッチも、
/// 走らせるたびに同じ絵になる ([ADR-0001] 原則 2)。「毎回ちがう」が欲しいときは、
/// 利用者が自分で変わる値を種に渡す。
///
/// 中身は SplitMix64。状態が 64 ビット 1 本しかないので**同じ種から必ず同じ列**が
/// 出て、載せ替えても再現が壊れない。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
struct Randomness: Sendable {
    private var state: UInt64

    /// **種を決めなければ 0** — 時刻から作らない (原則 2)。
    init(seed: Int = 0) {
        // 種 0 でも列が縮退しないよう、1 歩進めた位置から始める
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
    }

    /// 次の 64 ビット。
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 以上 1 未満。
    ///
    /// 上位 24 ビットだけを使う。`Float` の仮数は 24 ビットなので、**ここで丸めが
    /// 起きない** — 丸めが入ると 1.0 ちょうどが出うる。
    mutating func unitValue() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// 下から上まで (上は含まない)。
    ///
    /// **順序が逆でも受け取る。** 描いている途中で落ちないようにするためで、
    /// 上下が同じなら常にその値が出る。
    mutating func value(from low: Float, to high: Float) -> Float {
        guard low.isFinite, high.isFinite else { return low.isFinite ? low : 0 }
        let lower = min(low, high)
        let upper = max(low, high)
        return lower + (upper - lower) * unitValue()
    }
}
