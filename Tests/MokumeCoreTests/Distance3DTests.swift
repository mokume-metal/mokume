// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 3 次元の `dist(x1, y1, z1, x2, y2, z2)` と `mag(x, y, z)` ([#3358])。GPU は要らない。
///
/// 見るのは 4 つ。**正確なユークリッド距離を返すこと**、**`Float`・`Double`・`Int` をそのまま受けること**、
/// **2 次元の口と食い違わないこと** (z が 0 なら 2 次元の答えと同じ)、**数でない値を返さず溢れも潰れもしないこと**
/// (2 次元の口と同じ約束・[#2935])。
///
/// [#3358]: https://github.com/mokume-metal/mokume/issues/3358
/// [#2935]: https://github.com/mokume-metal/mokume/issues/2935
@Suite("3 次元の dist と mag")
struct Distance3DTests {
    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 1e-6) -> Bool {
        abs(one / other - 1) < tolerance
    }

    @Test("3 次元の距離と大きさは、ピタゴラスの定理どおりの値を返す")
    func exactEuclideanValues() {
        #expect(dist(0, 0, 0, 3, 4, 12) == 13)
        #expect(isNear(dist(1, 1, 1, 3, 3, 4), Float(17).squareRoot()))
        #expect(dist(1, 2, 3, 1, 2, 3) == 0)
        #expect(mag(2, 3, 6) == 7)
        #expect(mag(1, 2, 2) == 3)
        #expect(mag(-2, -3, -6) == 7)
        #expect(mag(0, 0, 0) == 0)
        // 点を入れ替えても、符号を反転しても同じ (向きは見ない)
        #expect(dist(3, 4, 12, 0, 0, 0) == 13)
        #expect(dist(0, 0, 0, -3, -4, -12) == 13)
        // 軸 1 本だけ違うなら、その軸の差の絶対値
        #expect(dist(0, 0, 5, 0, 0, -2) == 7)
        #expect(mag(0, 0, -9) == 9)
    }

    @Test("Float・Double・Int の変数をそのまま渡せて、戻り値は Float")
    func everyStoredWidthPasses() {
        let whole: Int = 6
        let half: Double = 1.5
        let single: Float = 4
        let viaInt: Float = dist(0, 0, 0, 2, 3, whole)
        #expect(viaInt == 7)
        #expect(mag(2, 3, whole) == 7)
        #expect(mag(half, 2, 6.0) == 6.5)
        #expect(dist(single, 0, 0, 0, 3, 0) == 5)
        #expect(dist(0, 0, 0, half, 2, 6) == 6.5)
    }

    @Test("z が 0 なら、2 次元の dist・mag と同じ値")
    func zeroDepthMatchesThePlanarMouths() {
        let samples: [(Float, Float, Float, Float)] = [
            (0, 0, 3, 4), (1, 1, 4, 5), (-7.5, 2.25, 3.125, -9), (3e19, 4e19, 0, 0), (3e-30, 4e-30, 0, 0),
        ]
        for (x1, y1, x2, y2) in samples {
            #expect(dist(x1, y1, 0, x2, y2, 0) == dist(x1, y1, x2, y2), "dist \(x1) \(y1) \(x2) \(y2)")
            #expect(mag(x2, y2, 0) == mag(x2, y2), "mag \(x2) \(y2)")
        }
        // 原点を 1 つ目の点にした dist は mag と同じ
        #expect(dist(0, 0, 0, 2, 3, 6) == mag(2, 3, 6))
    }

    @Test("2 乗が溢れる大きさでも、潰れる小ささでも、距離は有限で返る")
    func theDistanceSurvivesTheExtremes() {
        // 1e30 の 2 乗は Float の上限を越える。そのまま 2 乗して開くと ∞
        let far = mag(1e30, 1e30, 1e30)
        #expect(far.isFinite)
        #expect(isNear(far, 1e30 * Float(3).squareRoot()))
        #expect(isNear(dist(0, 0, 0, 3e19, 4e19, 12e19), 13e19))
        // 大きいのが z だけでも (x・y の指数だけで寄せると z の 2 乗が溢れる)
        #expect(isNear(mag(1, 1, 3e30), 3e30))
        #expect(isNear(dist(0, 0, 0, 1, 1, 3e30), 3e30))
        // 1e-30 の 2 乗は 0 に潰れる。そのまま開くと 0
        let near = mag(2e-30, 3e-30, 6e-30)
        #expect(near > 0)
        #expect(isNear(near, 7e-30))
        #expect(isNear(dist(0, 0, 0, 3e-30, 4e-30, 12e-30), 13e-30))
        // 非正規数だけの値も 0 にならない (0 になるのは 0 ベクトルだけ)
        #expect(mag(1.4e-45, 0, 0) > 0)
        // 結果が Float の範囲を越えるときは ∞
        #expect(mag(3e38, 3e38, 3e38) == .infinity)
        #expect(dist(-3e38, 0, 0, 3e38, 0, 0) == .infinity)
        // 境目の内側と外側が連続する
        #expect(isNear(mag(1e18, 0, 0), 1e18))
        #expect(isNear(mag(1.1e18, 0, 0), 1.1e18))
    }

    @Test("数でない値・無限の値は 0 を返し、2 次元の口とは別に 1 度だけ言う")
    func notANumberReturnsZeroAndWarnsPerMouth() {
        let bad: [Float] = [.nan, .infinity, -.infinity]
        for value in bad {
            #expect(dist(value, 0, 0, 3, 4, 12) == 0)
            #expect(dist(0, 0, value, 3, 4, 12) == 0)
            #expect(dist(0, 0, 0, 3, 4, value) == 0)
            #expect(mag(value, 4, 12) == 0)
            #expect(mag(3, 4, value) == 0)
        }
        for (entry, name) in [(NumberValues.Warning.Entry.dist3D, "dist()"), (.mag3D, "mag()")] {
            #expect(NumberValues.warnings.hasWarned(.notANumber(entry)), "\(name)")
            #expect(NumberValues.warnings.message(for: .notANumber(entry))?.hasPrefix(name) == true, "\(name)")
        }
    }
}
