// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics

@testable import MokumeCore

/// sRGB で書いた色が作業空間と書き出しでどうなるかを、**CoreGraphics に**変換させて導く。
///
/// 数値の入口は sRGB の原色の値を作業空間 (Display P3) へ移す ([ADR-0011] 決定 3 の改訂)。
/// だから彩度のある色の期待値は、打った数そのものではなく変換を経た値になる
/// ([ADR-0019] 決定 4 の改訂)。**実装の行列を使わずに導く** — 同じ行列で期待値を作ると、
/// 係数が誤っていても検査が一致してしまう。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
enum SRGBReference {
    /// sRGB のエンコード値 (0…1) を、作業空間の線形の値へ移す。
    static func working(red: Double, green: Double, blue: Double) -> LinearRGBA {
        let moved = convert(red, green, blue, to: CGColorSpace.extendedLinearDisplayP3)
        return .linear(red: Float(moved[0]), green: Float(moved[1]), blue: Float(moved[2]))
    }

    /// sRGB のエンコード値 (0…1) が、書き出し (8 bit・Display P3) で取るバイト列。
    static func writtenBytes(red: Double, green: Double, blue: Double) -> (UInt8, UInt8, UInt8) {
        let moved = convert(red, green, blue, to: CGColorSpace.displayP3)
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        return (byte(moved[0]), byte(moved[1]), byte(moved[2]))
    }

    private static func convert(
        _ red: Double, _ green: Double, _ blue: Double, to name: CFString
    ) -> [CGFloat] {
        let source = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red, green, blue, 1])!
        return source.converted(
            to: CGColorSpace(name: name)!, intent: .relativeColorimetric, options: nil)!
            .components!
    }
}
