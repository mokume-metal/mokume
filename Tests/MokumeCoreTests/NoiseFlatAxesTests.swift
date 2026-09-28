// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 0 の軸の隅を引かない揺らぎが、3 次元のまま引いた値と 1 ビットも違わないことの検査
/// ([#1788])。GPU を要さない。
///
/// 比べる相手は**変える前の ``ValueNoise/value(_:_:_:)``** — どの呼び方でも 3 次元の層を
/// 重ねる形 — を、検査の中で組み直したものである。`noise(x)` / `noise(x, y)` の形 (残りの軸が
/// 0) で、`-0`・整数の座標・締め付けの境・極端に大きい / 小さい座標を混ぜ、重ねる枚数と
/// 種を変えて見る。
///
/// [#1788]: https://github.com/mokume-metal/mokume/issues/1788
@Suite("0 の軸を引かない揺らぎ")
struct NoiseFlatAxesTests {
    /// 変える前の重ね方。**どの軸も 3 次元の層で引く。**
    private func threeDimensional(_ noise: ValueNoise, _ x: Float, _ y: Float, _ z: Float) -> Float {
        guard x.isFinite, y.isFinite, z.isFinite else { return 0 }
        var sum: Float = 0
        var total: Float = 0
        var amplitude: Float = 1
        var frequency: Float = 1
        for octave in 0..<max(1, noise.octaves) {
            let layerSeed = noise.seed &+ UInt32(octave) &* 0x9E37_79B1
            sum +=
                ValueNoise.layer(x * frequency, y * frequency, z * frequency, layerSeed) * amplitude
            total += amplitude
            amplitude *= noise.falloff
            frequency *= 2
        }
        return total > 0 ? sum / total : 0
    }

    /// 比べる座標。締め付けの境 (±1e6) の前後と、整数・`-0`・極端な値を混ぜる。
    private static let coordinates: [Float] = {
        var values: [Float] = [
            0, -0.0, 1, -1, 0.5, -0.5, 2.25, -7.75, 12345.678, -98765.43,
            999_999.5, -999_999.5, 1_000_000, -1_000_000, 1_000_001, 1e30, -1e30, 1e-30, -1e-30,
            .leastNonzeroMagnitude, 0.999_999_94,
        ]
        // 滑らかにつながる所も粗く舐める
        var t: Float = -40
        while t < 40 {
            values.append(t)
            t += 0.73
        }
        return values
    }()

    @Test(
        "1 次元と 2 次元の揺らぎが、3 次元の層で引いた値とビット単位で一致する",
        arguments: [(octaves: 1, falloff: Float(0.5)), (4, 0.5), (8, 0.35), (16, 0.9)])
    func flatAxesMatchTheThreeDimensionalLayer(octaves: Int, falloff: Float) {
        var mismatches = 0
        for seed: UInt32 in [0, 7, 0xDEAD_BEEF] {
            let noise = ValueNoise(seed: seed, octaves: octaves, falloff: falloff)
            for x in Self.coordinates {
                // noise(x) の形 (縦も奥行きも 0、-0 も含む)
                for (y, z) in [(Float(0), Float(0)), (-0.0, 0), (0, -0.0)] {
                    if noise.value(x, y, z).bitPattern != threeDimensional(noise, x, y, z).bitPattern {
                        mismatches += 1
                    }
                }
                // noise(x, y) の形 (奥行きだけ 0)
                for y in Self.coordinates {
                    for z in [Float(0), -0.0] {
                        if noise.value(x, y, z).bitPattern
                            != threeDimensional(noise, x, y, z).bitPattern
                        {
                            mismatches += 1
                        }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    /// 奥行きが 0 でない呼び方は、今までどおり 3 次元の層を通る。
    @Test("奥行きのある揺らぎは、今までどおりの値を返す")
    func threeDimensionalCallsAreUnchanged() {
        let noise = ValueNoise(seed: 3, octaves: 4, falloff: 0.5)
        for x in Self.coordinates {
            for z: Float in [0.25, -3.5, 1e-30] {
                #expect(noise.value(x, 1.5, z).bitPattern == threeDimensional(noise, x, 1.5, z).bitPattern)
            }
        }
    }
}
