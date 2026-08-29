// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 揺らぎが約束どおりの値を返すことを見る。
///
/// **断片との一致は見ない** — GPU が要るので `NoiseParityTests` が別に持つ。
@Suite("揺らぎ")
struct NoiseTests {
    @Test("同じ座標には何度でも同じ値")
    func theSamePlaceAlwaysGivesTheSameValue() {
        let noise = ValueNoise(seed: 42)
        #expect(noise.value(3.25, -7.5, 0.125) == noise.value(3.25, -7.5, 0.125))
    }

    @Test("種を変えると模様が変わる")
    func theSeedChangesThePattern() {
        let first = ValueNoise(seed: 1)
        let second = ValueNoise(seed: 2)
        let places: [(Float, Float)] = [(0.5, 0.5), (1.25, 3.75), (-2.5, 8.125)]
        #expect(places.contains { first.value($0.0, $0.1, 0) != second.value($0.0, $0.1, 0) })
    }

    @Test("0…1 に収まる")
    func valuesStayInRange() {
        let noise = ValueNoise(seed: 9)
        for step in 0..<2000 {
            let t = Float(step) * 0.017
            let value = noise.value(t, t * 0.31, t * 0.07)
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test("近い座標には近い値が返る (格子の目で飛ばない)")
    func neighbouringPlacesGiveNeighbouringValues() {
        let noise = ValueNoise(seed: 5)
        var previous = noise.value(0, 0, 0)
        // 格子の境 (整数) を必ずまたぐ刻みで歩く
        for step in 1...600 {
            let x = Float(step) * 0.05
            let value = noise.value(x, 0, 0)
            #expect(abs(value - previous) < 0.2, "x = \(x) で跳ねた")
            previous = value
        }
    }

    @Test("格子の境に折れ目が無い")
    func thereIsNoCreaseAtTheLattice() {
        // 端で傾きが 0 になる繋ぎ方なので、格子点をまたぐ傾きは 0 に寄る。
        // 線形に繋ぐと**格子点で傾きが飛ぶ** — 折れ目が縞として絵に出るので、
        // 「近い値が返る」だけでは足りずここを見る
        let noise = ValueNoise(seed: 5)
        let step: Float = 1e-3
        for lattice in 1...20 {
            let x = Float(lattice)
            let slope = abs(noise.value(x + step, 0, 0) - noise.value(x - step, 0, 0)) / (2 * step)
            #expect(slope < 0.05, "x = \(x) の格子点で傾きが飛んでいる (\(slope))")
        }
    }

    @Test("引数を省いた呼び方は 0 を渡したのと同じ")
    func omittedAxesAreZero() {
        let noise = ValueNoise(seed: 11)
        #expect(noise.value(1.5, 0, 0) == noise.value(1.5, 0, 0))
        #expect(noise.value(1.5, 2.5, 0) != noise.value(1.5, 0, 0))
    }

    @Test("重ねる枚数を増やすと細かさが乗る")
    func moreOctavesAddDetail() {
        func roughness(_ octaves: Int) -> Float {
            var noise = ValueNoise(seed: 4)
            noise.octaves = octaves
            var total: Float = 0
            var previous = noise.value(0, 0, 0)
            for step in 1...400 {
                let value = noise.value(Float(step) * 0.02, 0, 0)
                total += abs(value - previous)
                previous = value
            }
            return total
        }
        #expect(roughness(1) < roughness(6))
    }

    @Test("弱まりを 0 にすると 1 枚だけになる")
    func aZeroFalloffLeavesOneLayer() {
        var layered = ValueNoise(seed: 4)
        layered.octaves = 6
        layered.falloff = 0
        var single = ValueNoise(seed: 4)
        single.octaves = 1
        #expect(layered.value(1.5, 2.5, 3.5) == single.value(1.5, 2.5, 3.5))
    }

    @Test("数でない座標には 0 が返る (落ちない)")
    func nonFinitePlacesGiveZero() {
        let noise = ValueNoise(seed: 4)
        #expect(noise.value(.nan, 0, 0) == 0)
        #expect(noise.value(0, .infinity, 0) == 0)
    }

    @Test("扱える範囲の外を渡しても落ちない")
    func placesBeyondTheLimitDoNotCrash() {
        let noise = ValueNoise(seed: 4)
        let far = noise.value(1e30, -1e30, 1e12)
        #expect(far >= 0 && far <= 1)
        // 端に張り付くので、外はどこでも端と同じ値になる
        let limit = ValueNoise.coordinateLimit
        #expect(noise.value(1e30, 0, 0) == noise.value(limit, 0, 0))
    }
}

extension ValueNoise {
    /// 検査から種だけを決めるための近道。
    init(seed: Int) {
        self.init()
        self.seed = UInt32(bitPattern: Int32(truncatingIfNeeded: seed))
    }
}
