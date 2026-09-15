// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 画面の色と作業空間の色を往復させる。
enum KnobColor {
    /// 作業空間の値を、画面で選ぶ色にする。
    ///
    /// 乗算を戻してから符号化する — 作業空間の成分はアルファ乗算済みなので、そのまま
    /// 符号化すると透明な色ほど暗く見える。
    static func display(of value: LinearRGBA) -> Color {
        let alpha = value.alpha
        guard alpha > 0 else { return Color(.displayP3, red: 0, green: 0, blue: 0, opacity: 0) }
        return Color(
            .displayP3,
            red: Double(TransferFunction.encode(value.red / alpha)),
            green: Double(TransferFunction.encode(value.green / alpha)),
            blue: Double(TransferFunction.encode(value.blue / alpha)),
            opacity: Double(alpha))
    }

    /// 画面で選んだ色を、作業空間の値にする。
    ///
    /// **``LinearRGBA/display(red:green:blue:alpha:)`` を通さない。** あちらは sRGB の原色の
    /// 値を受ける口で、ここで取り出すのは作業空間と同じ Display P3 の成分である。転送関数だけを
    /// 外せば作業空間の値になり、選ぶ欄の広い色域もそのまま運べる ([#911])。
    ///
    /// [#911]: https://github.com/mokume-metal/mokume/issues/911
    static func working(of color: Color) -> LinearRGBA {
        guard let components = NSColor(color).usingColorSpace(.displayP3) else {
            return .transparent
        }
        return LinearRGBA(
            straightRed: TransferFunction.decode(Float(components.redComponent)),
            green: TransferFunction.decode(Float(components.greenComponent)),
            blue: TransferFunction.decode(Float(components.blueComponent)),
            alpha: Float(components.alphaComponent))
    }
}
