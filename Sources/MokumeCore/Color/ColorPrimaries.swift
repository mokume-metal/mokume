// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 線形 sRGB と作業空間 (線形 Display P3) の間で、原色を移す変換。
///
/// [ADR-0011] 決定 3 の改訂 (2026-09-15) は、入口の変換を「作業空間へ移す」こと —
/// 転送関数を外すことと原色を移すことの両方 — と決め、**利用者が数で書いた色は sRGB の
/// 原色の値**だとした。読み込んだ画像は CoreGraphics が原色ごと移すので、数値の入口も
/// ここを通して揃える ([#911])。読み出しは逆行列でたどり、往復を保つ。
///
/// 係数は 2 つの色空間の原色と、共通の白色点 D65 から導いた値である (どちらも
/// sRGB 曲線の転送関数を持ち、違うのは原色だけ)。**範囲の外の値も切らない** — sRGB の
/// 外にある作業空間の色は、負や 1 を超える成分として読める (決定 1 の extended)。
///
/// 計算は `Double` で行う。`Float` の積では、原色の上に乗った色を往復したときに 0 の
/// 成分が最下位で揺れ、「書いた目盛りで読める」契約を無用に崩すため。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [#911]: https://github.com/mokume-metal/mokume/issues/911
enum ColorPrimaries {
    /// 線形 sRGB → 線形 Display P3 (行ごと)。
    private static let workingFromSRGBRows: [SIMD3<Double>] = [
        SIMD3(0.822_461_968_714_362_4, 0.177_538_031_285_637_9, 0),
        SIMD3(0.033_194_198_850_961_7, 0.966_805_801_149_038_6, 0),
        SIMD3(0.017_082_630_721_120_0, 0.072_397_440_663_963_4, 0.910_519_928_614_916_4),
    ]

    /// 線形 Display P3 → 線形 sRGB (上の逆行列)。
    private static let sRGBFromWorkingRows: [SIMD3<Double>] = [
        SIMD3(1.224_940_176_280_559_8, -0.224_940_176_280_560_1, 0),
        SIMD3(-0.042_056_954_709_688_2, 1.042_056_954_709_687_8, 0),
        SIMD3(-0.019_637_554_590_334_4, -0.078_636_045_550_631_8, 1.098_273_600_140_966_5),
    ]

    /// 線形 sRGB の 3 成分を、作業空間の 3 成分へ移す (入口)。
    static func working(fromSRGB linear: SIMD3<Float>) -> SIMD3<Float> {
        apply(workingFromSRGBRows, to: linear)
    }

    /// 作業空間の 3 成分を、線形 sRGB の 3 成分へ移す (読み出し)。
    static func sRGB(fromWorking linear: SIMD3<Float>) -> SIMD3<Float> {
        apply(sRGBFromWorkingRows, to: linear)
    }

    private static func apply(_ rows: [SIMD3<Double>], to value: SIMD3<Float>) -> SIMD3<Float> {
        let column = SIMD3<Double>(value)
        return SIMD3(
            Float((rows[0] * column).sum()),
            Float((rows[1] * column).sum()),
            Float((rows[2] * column).sum()))
    }
}
