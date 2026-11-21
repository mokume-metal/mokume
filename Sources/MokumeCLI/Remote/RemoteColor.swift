// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 色のつまみを、ブラウザの色の欄 (`#rrggbb`) と作業空間の色の間で往復させる。
///
/// 窓のつまみ (`KnobColor`) と同じく、**乗算を戻してから転送関数で符号化した成分**を見せる。
/// ブラウザの欄は不透明度を持たないので、書き戻すときは今の不透明度を保つ。欄は sRGB で選ぶが、
/// 成分はそのまま作業空間 (Display P3 の原色) の符号化した値として読む — 窓と同じ数字を見せ、
/// 同じ数字を書き戻すためで、広い色域の色は欄の中では端に寄って見える。
nonisolated enum RemoteColor {
    /// 作業空間の色を、欄に出す `#rrggbb` にする。透明な色は黒。
    static func hex(of color: LinearRGBA) -> String {
        guard color.alpha > 0 else { return "#000000" }
        let components = [color.red, color.green, color.blue].map { component -> Int in
            let encoded = TransferFunction.encode(component / color.alpha)
            return Int((min(max(encoded, 0), 1) * 255).rounded())
        }
        return "#" + components.map { String(format: "%02x", $0) }.joined()
    }

    /// 欄で選んだ `#rrggbb` を、`alpha` の不透明度の作業空間の色にする。読めなければ `nil`。
    static func color(hex: String, alpha: Float) -> LinearRGBA? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let packed = UInt32(digits, radix: 16) else { return nil }
        let channel = { (shift: UInt32) -> Float in
            TransferFunction.decode(Float((packed >> shift) & 0xff) / 255)
        }
        return LinearRGBA(straightRed: channel(16), green: channel(8), blue: channel(0), alpha: alpha)
    }
}
