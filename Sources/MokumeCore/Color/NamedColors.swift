// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 名前の付いた色。CSS 2.1 の 17 色を、CSS と同じ値 (sRGB) で持つ ([#2595])。
//
// **値は `color(r, g, b)` で作った色と 1 ビットも変わらない。** 作る口は原色の移し替えを通るので
// main actor に残る ([#2389]) が、名前の付いた色は隔離の外から読めなければならない (値型 `Rect`・`Circle` の
// `fill` に渡す・#2580)。そのため、移し替えた後の作業空間の値 (線形・Display P3・乗算済み) を書き込んである。
// 検査 (`NamedColorTests`) が、17 色それぞれを `color(r, g, b)` で作った色と比べる。
//
// [#2389]: https://github.com/mokume-metal/mokume/issues/2389
// [#2595]: https://github.com/mokume-metal/mokume/issues/2595

extension Color {
    /// CSS の `black` (`#000000`)。
    nonisolated public static let black = Color(
        premultipliedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    /// CSS の `silver` (`#c0c0c0`)。
    nonisolated public static let silver = Color(
        premultipliedRed: 0.5271152, green: 0.5271152, blue: 0.5271152, alpha: 1.0)
    /// CSS の `gray` (`#808080`)。
    nonisolated public static let gray = Color(
        premultipliedRed: 0.21586053, green: 0.21586053, blue: 0.21586053, alpha: 1.0)
    /// CSS の `white` (`#ffffff`)。
    nonisolated public static let white = Color(
        premultipliedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    /// CSS の `maroon` (`#800000`)。
    nonisolated public static let maroon = Color(
        premultipliedRed: 0.17753708, green: 0.0071653174, blue: 0.0036874658, alpha: 1.0)
    /// CSS の `red` (`#ff0000`)。
    nonisolated public static let red = Color(
        premultipliedRed: 0.82246196, green: 0.0331942, blue: 0.017082632, alpha: 1.0)
    /// CSS の `purple` (`#800080`)。
    nonisolated public static let purple = Color(
        premultipliedRed: 0.17753708, green: 0.0071653174, blue: 0.20023277, alpha: 1.0)
    /// CSS の `fuchsia` (`#ff00ff`)。
    nonisolated public static let fuchsia = Color(
        premultipliedRed: 0.82246196, green: 0.0331942, blue: 0.9276026, alpha: 1.0)
    /// CSS の `green` (`#008000`)。
    nonisolated public static let green = Color(
        premultipliedRed: 0.038323455, green: 0.20869522, blue: 0.01562775, alpha: 1.0)
    /// CSS の `lime` (`#00ff00`)。
    nonisolated public static let lime = Color(
        premultipliedRed: 0.17753804, green: 0.9668058, blue: 0.07239744, alpha: 1.0)
    /// CSS の `olive` (`#808000`)。
    nonisolated public static let olive = Color(
        premultipliedRed: 0.21586053, green: 0.21586053, blue: 0.019315215, alpha: 1.0)
    /// CSS の `yellow` (`#ffff00`)。
    nonisolated public static let yellow = Color(
        premultipliedRed: 1.0, green: 1.0, blue: 0.08948007, alpha: 1.0)
    /// CSS の `navy` (`#000080`)。
    nonisolated public static let navy = Color(
        premultipliedRed: 0.0, green: 0.0, blue: 0.19654532, alpha: 1.0)
    /// CSS の `blue` (`#0000ff`)。
    nonisolated public static let blue = Color(
        premultipliedRed: 0.0, green: 0.0, blue: 0.91051996, alpha: 1.0)
    /// CSS の `teal` (`#008080`)。
    nonisolated public static let teal = Color(
        premultipliedRed: 0.038323455, green: 0.20869522, blue: 0.21217306, alpha: 1.0)
    /// CSS の `aqua` (`#00ffff`)。
    nonisolated public static let aqua = Color(
        premultipliedRed: 0.17753804, green: 0.9668058, blue: 0.98291737, alpha: 1.0)
    /// CSS の `orange` (`#ffa500`)。
    nonisolated public static let orange = Color(
        premultipliedRed: 0.8892628, green: 0.3969667, blue: 0.044323053, alpha: 1.0)
}
