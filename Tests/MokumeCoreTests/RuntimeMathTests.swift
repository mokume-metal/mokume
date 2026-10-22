// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 本体が計算する値が、最適化の有無で変わらないことの検査 ([#1736])。
///
/// **意味を持つのは release (`make test-release`) である。** debug は sin と cos の対を
/// 畳まず、定数の呼び出しも組むときに計算しないので、ここはいつも緑になる。release で
/// 本体が `sin` / `pow` などを ``RuntimeMath`` を通さずに呼ぶと、対が `__sincosf_stret` に
/// 畳まれるか、定数が組むときに計算され、1 ULP ずれて赤になる。
///
/// 期待値は**この検査の中で、実行時に別々に**計算する。比べる側まで最適化に畳まれないよう、
/// 1 関数に 1 つの呼び出しだけを置いて `@inline(never)` で包む (``RuntimeMath`` と同じ形)。
///
/// [#1736]: https://github.com/mokume-metal/mokume/issues/1736
@Suite("最適化で値が変わらない超越関数")
struct RuntimeMathTests {
    @inline(never) private static func separateSin(_ x: Float) -> Float { sin(x) }
    @inline(never) private static func separateCos(_ x: Float) -> Float { cos(x) }
    /// 組むときに値が分からないようにする。定数をそのまま渡すと、期待値の側が畳まれる
    @inline(never) private static func opaque(_ x: Float) -> Float { x }

    /// 回転の行列は、sin と cos を別々に呼んだ値で組まれる。
    ///
    /// 畳んだ値が別々に呼んだ値と違う角度は 0.2% ほどなので、刻みを細かくして 2 万点を見る。
    @Test("回転の行列は sin と cos を別々に呼んだ値で組まれる")
    func rotationUsesSeparateSineAndCosine() {
        var mismatches: [Float] = []
        for step in 0..<20_000 {
            let angle = Float(step) * 0.000_37
            let c = Self.separateCos(angle)
            let s = Self.separateSin(angle)
            let x = Transform.rotationX(angle)
            let y = Transform.rotationY(angle)
            let z = Transform.rotationZ(angle)
            if x.columns.1.y != c || x.columns.1.z != s
                || y.columns.0.x != c || y.columns.0.z != -s
                || z.columns.0.x != c || z.columns.0.y != s
            {
                mismatches.append(angle)
            }
        }
        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) 個の角度で、回転の行列が sin と cos を別々に呼んだ値と違う (最初は \(mismatches.first.map { "\($0)" } ?? "-"))。本体が sin / cos を RuntimeMath を通さずに呼び、最適化が対を畳んでいる")
    }

    /// 定数で書いた周囲の色は、同じ数を実行時に変換した色と同じになる。
    ///
    /// 周囲の色は `.display(red: 0.42, …)` と定数で書いてあり、release ではその変換
    /// (`pow(…, 2.4)`) が組むときに計算されうる。
    @Test("定数で書いた周囲の色は、実行時に変換した色と同じ", arguments: [
        ("sky", [0.42, 0.58, 0.9, 0.78, 0.85, 0.95, 0.28, 0.26, 0.24]),
        ("studio", [0.95, 0.95, 0.95, 0.6, 0.6, 0.62, 0.25, 0.25, 0.27]),
        ("sunset", [0.25, 0.3, 0.55, 0.95, 0.6, 0.35, 0.2, 0.14, 0.12]),
    ] as [(String, [Float])])
    func presetColorsMatchRuntimeConversion(name: String, written: [Float]) throws {
        // 周囲そのものは引数に載せない (main actor の値を引数の並びで読めない)
        let presets = ["sky": Surroundings.sky, "studio": .studio, "sunset": .sunset]
        let preset = try #require(presets[name])
        func display(_ offset: Int) -> Color {
            .display(
                red: Self.opaque(written[offset]), green: Self.opaque(written[offset + 1]),
                blue: Self.opaque(written[offset + 2]))
        }
        #expect(preset.top == display(0), "\(name) の上の色")
        #expect(preset.horizon == display(3), "\(name) の地平の色")
        #expect(preset.bottom == display(6), "\(name) の下の色")
    }
}
