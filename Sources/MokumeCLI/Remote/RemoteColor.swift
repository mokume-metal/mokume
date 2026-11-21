// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 色のつまみを、ブラウザの色の欄 (`#rrggbb`) と作業空間の色の間で往復させる。
///
/// **数字は窓のつまみの綴り (`KnobText`) と同じ sRGB の目盛りにする** — コードに書く `color(242, 115, 51)` と
/// 同じ数字で、ブラウザの色の欄も sRGB で選ぶ。読むときは ``red(_:)`` などで作業空間から sRGB へ移し、
/// 書き戻すときは ``LinearRGBA/display(red:green:blue:alpha:)`` で作業空間へ移す (ADR-0011 決定 3)。
/// sRGB の外にある作業空間の色は、欄の中では端に寄る。欄は不透明度を持たないので、書き戻すときは
/// 今の不透明度を保つ。
nonisolated enum RemoteColor {
    /// 作業空間の色を、欄に出す `#rrggbb` にする。
    static func hex(of color: LinearRGBA) -> String {
        "#" + [red(color), green(color), blue(color)]
            .map { String(format: "%02x", Int(min(max($0, 0), 255).rounded())) }
            .joined()
    }

    /// 欄で選んだ `#rrggbb` を、`alpha` の不透明度の作業空間の色にする。読めなければ `nil`。
    static func color(hex: String, alpha: Float) -> LinearRGBA? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let packed = UInt32(digits, radix: 16) else { return nil }
        let channel = { (shift: UInt32) -> Float in Float((packed >> shift) & 0xff) / 255 }
        return LinearRGBA.display(red: channel(16), green: channel(8), blue: channel(0), alpha: alpha)
    }
}
