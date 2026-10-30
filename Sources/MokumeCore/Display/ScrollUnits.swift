// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 窓が受けたスクロールの量を、スケッチへ届ける**点**の単位へ揃える
/// ([#2442](https://github.com/mokume-metal/mokume/issues/2442)・[ADR-0034] 決定 8)。
///
/// AppKit の `scrollingDeltaX` / `scrollingDeltaY` は機器で単位が違う。`hasPreciseScrollingDeltas` が真の機器
/// (トラックパッド・Magic Mouse) は指の動いた**点**で、偽の機器 (ふつうのホイール) は**行**である。
/// そのまま流すと、同じ `deltaY` に掛ける係数が機器で桁違いになるので、行の機器の量だけ決まった点数を掛けて、
/// どの機器の量も点で並ぶようにする。
///
/// **窓の側だけが通る。** 外から送る `scrolled` は最初から点として扱い、ここを通さない
/// (外から送る経路に掛け算を足さない・[#2731])。AppKit に依らない純粋な関数なので、GPU も窓も要らずに検査できる。
///
/// **慣性の続き (`momentumPhase`) は区別しない。** 指を離した後の続きも同じ量として届く。慣性かを読む口は、作例が来てから足す。
///
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
/// [#2731]: https://github.com/mokume-metal/mokume/issues/2731
enum ScrollUnits {
    /// ホイール 1 行が何点か。
    ///
    /// AppKit の `NSScrollView` が行送りの既定に使う値 (10 点) に合わせる。ホイールの 1 刻みが 10 点で届き、
    /// トラックパッドの小さなひと撫で (10 点前後) と同じ桁で並ぶ。
    static let pointsPerLine: Double = 10

    /// 窓が受けた量を、スケッチへ届ける点へ換算する。
    ///
    /// - Parameters:
    ///   - dx: `scrollingDeltaX`。
    ///   - dy: `scrollingDeltaY`。
    ///   - isPrecise: `hasPreciseScrollingDeltas`。真なら量は既に点で、そのまま返す。偽なら行なので ``pointsPerLine`` を掛ける。
    static func points(dx: Double, dy: Double, isPrecise: Bool) -> (dx: Float, dy: Float) {
        let scale = isPrecise ? 1 : pointsPerLine
        return (Float(dx * scale), Float(dy * scale))
    }
}
