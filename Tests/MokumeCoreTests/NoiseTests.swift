// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 揺らぎが約束どおりの値を返すことを見る。
///
/// **断片との一致は見ない** — GPU が要るので `NoiseParityTests` が別に持つ。
/// 作者が呼ぶ口を通す検査も面 (GPU) を要するので、入れ子の ``ThroughTheCanvas`` に分けてある。
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

    /// 作者が呼ぶ口 (``Canvas/noise(_:_:_:_:)``) を通す検査。
    ///
    /// **省いた軸を 0 で埋めるのは口の既定値**で、``ValueNoise`` は 3 軸を必ず受け取る。
    /// だから省いた形は ``ValueNoise`` を直に呼んでも通らない — 以前ここにあった検査は
    /// 同じ式どうしを比べており、既定値を壊しても緑のままだった
    /// ([#1388](https://github.com/mokume-metal/mokume/issues/1388))。面を作るので GPU が要る。
    @Suite(
        "作者が呼ぶ口",
        .enabled(if: RenderDevice.isAvailable, "面を作るので GPU が要る")
    )
    struct ThroughTheCanvas {
        @Test("引数を省いた呼び方は、省いた軸に 0 を渡したのと同じ")
        func omittedAxesAreZero() throws {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            canvas.noiseSeed(11)
            let places: [(x: Float, y: Float)] = [(1.5, 2.5), (-3.25, 0.75), (17.125, -8.5)]
            for place in places {
                #expect(canvas.noise(place.x) == canvas.noise(place.x, 0, 0), "x = \(place.x)")
                #expect(
                    canvas.noise(place.x, place.y) == canvas.noise(place.x, place.y, 0),
                    "(\(place.x), \(place.y))")
            }
            // **比べた座標が、省いた軸を 0 以外で埋めたら見分けのつく場所であること。**
            // 軸を動かしても値が変わらない座標では、既定値が壊れても上の一致は崩れない
            for place in places {
                #expect(
                    canvas.noise(place.x, 0, 0) != canvas.noise(place.x, 1, 0), "x = \(place.x)")
                #expect(
                    canvas.noise(place.x, place.y, 0) != canvas.noise(place.x, place.y, 1),
                    "(\(place.x), \(place.y))")
            }
        }

        /// 4 つ目の座標 (#2425)。省いた形は 0 を渡したのと同じで、渡した形は値を動かす。
        @Test("4 つ目の座標を省いた呼び方は、0 を渡したのと同じで、渡せば値が動く")
        func theFourthAxisDefaultsToZero() throws {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            canvas.noiseSeed(11)
            let places: [(x: Float, y: Float, z: Float)] = [
                (1.5, 2.5, 0.25), (-3.25, 0.75, 1.5), (17.125, -8.5, -2.75),
            ]
            for place in places {
                #expect(
                    canvas.noise(place.x, place.y, place.z) == canvas.noise(place.x, place.y, place.z, 0),
                    "(\(place))")
                // 比べた座標で、4 つ目の軸を動かすと値が変わること (既定値を壊すと見分けがつく)
                #expect(
                    canvas.noise(place.x, place.y, place.z, 0) != canvas.noise(place.x, place.y, place.z, 1.5),
                    "(\(place))")
            }
        }
    }

    // MARK: - 4 次元 (#2425)

    /// 4 つ目の座標を持つ揺らぎは、0…1 に収まる。
    @Test("4 つの座標で引いても 0…1 に収まる")
    func fourDimensionalValuesStayInRange() {
        let noise = ValueNoise(seed: 9)
        for step in 0..<3000 {
            let t = Float(step) * 0.017
            let value = noise.value(t, t * 0.31, t * 0.07, t * 0.53 - 20)
            #expect(value >= 0 && value <= 1, "step \(step) で \(value)")
        }
    }

    @Test("4 つ目の座標が、模様を変える")
    func theFourthAxisChangesThePattern() {
        let noise = ValueNoise(seed: 3)
        let places: [(Float, Float, Float)] = [(0.5, 0.5, 0.5), (1.25, 3.75, 2.5), (-2.5, 8.125, -1.25)]
        for place in places {
            #expect(
                noise.value(place.0, place.1, place.2, 0.5) != noise.value(place.0, place.1, place.2, 1.5),
                "\(place)")
        }
        // 種も 4 次元の側へ効く
        let other = ValueNoise(seed: 4)
        #expect(places.contains { noise.value($0.0, $0.1, $0.2, 0.5) != other.value($0.0, $0.1, $0.2, 0.5) })
        // 重ねる枚数も効く
        var single = ValueNoise(seed: 3)
        single.octaves = 1
        #expect(places.contains { noise.value($0.0, $0.1, $0.2, 0.5) != single.value($0.0, $0.1, $0.2, 0.5) })
    }

    @Test("4 つ目の座標に沿って、格子の境でも値が滑らかにつながる")
    func theFourthAxisIsSmoothAcrossTheLattice() {
        let noise = ValueNoise(seed: 5)
        // 整数 (格子の境) を必ずまたぐ刻みで歩く。0 のまわり (3 次元の経路へ切り替わる所) も含む
        var previous = noise.value(0.3, 0.7, 0.2, -3)
        for step in 1...1200 {
            let w = -3 + Float(step) * 0.005
            let value = noise.value(0.3, 0.7, 0.2, w)
            #expect(abs(value - previous) < 0.05, "w = \(w) で跳ねた (\(abs(value - previous)))")
            previous = value
        }
        // 端で傾きが 0 になる繋ぎ方なので、格子点をまたぐ傾きは 0 に寄る
        let step: Float = 1e-3
        for lattice in -5...5 {
            let w = Float(lattice)
            let slope = abs(noise.value(0.3, 0.7, 0.2, w + step) - noise.value(0.3, 0.7, 0.2, w - step)) / (2 * step)
            #expect(slope < 0.05, "w = \(w) の格子点で傾きが飛んでいる (\(slope))")
        }
    }

    /// **例 (2 次元の場を 2 秒で巡らせる)**: 時刻を円周に載せて 3 つ目と 4 つ目に渡す。
    /// θ = 0 と θ = 2π で場が一致し (継ぎ目が無い)、θ = π では別の場になる (巡りながら変わる)。
    ///
    /// 一致は**ビット単位ではなく許容の内**である。`Float` の `sin(2π)` は 0 でなく 1.7e-7 ほど外れるので、
    /// θ = 2π の座標は 4 つ目の軸がわずかに 0 から外れる。値は 4 つ目の軸について連続なので、
    /// 差は 1e-6 の桁に収まる。
    @Test("円周に載せた座標で引くと、1 周で元の場に戻り、半周では別の場になる")
    func aFieldLoopsAroundTheCircle() {
        let noise = ValueNoise(seed: 7)
        let tolerance: Float = 5e-6
        var halfTurnGap: Float = 0
        var count: Float = 0
        for (radius, label) in [(Float(1), "半径 1"), (0.8, "半径 0.8 (例の値)")] {
            var worst: Float = 0
            for y in stride(from: Float(10), to: 300, by: 20) {
                for x in stride(from: Float(10), to: 400, by: 20) {
                    func field(_ angle: Float) -> Float {
                        noise.value(x * 0.01, y * 0.01, cos(angle) * radius, sin(angle) * radius)
                    }
                    worst = max(worst, abs(field(0) - field(2 * Float.pi)))
                    halfTurnGap += abs(field(0) - field(Float.pi))
                    count += 1
                }
            }
            #expect(worst < tolerance, "\(label): θ = 0 と 2π で \(worst) ずれている")
        }
        #expect(halfTurnGap / count > 0.03, "θ = π の場が θ = 0 とほとんど違わない (巡っていない)")
    }

    @Test("円周に沿って動かすと、場は少しずつ変わる (跳ばない)")
    func theLoopMovesGradually() {
        let noise = ValueNoise(seed: 7)
        var previous = noise.value(0.5, 0.5, 1, 0)
        for step in 1...720 {
            let angle = Float(step) * 2 * Float.pi / 720
            let value = noise.value(0.5, 0.5, cos(angle), sin(angle))
            #expect(abs(value - previous) < 0.05, "θ = \(angle) で跳ねた")
            previous = value
        }
    }

    @Test("4 つ目の座標が数でなければ 0 が返り、範囲の外でも落ちない")
    func theFourthAxisIsGuarded() {
        let noise = ValueNoise(seed: 4)
        #expect(noise.value(0, 0, 0, .nan) == 0)
        #expect(noise.value(0, 0, 0, .infinity) == 0)
        let far = noise.value(1, 2, 3, 1e30)
        #expect(far >= 0 && far <= 1)
        // 端に張り付くので、外はどこでも端と同じ値になる
        let limit = ValueNoise.coordinateLimit
        #expect(noise.value(1, 2, 3, 1e30) == noise.value(1, 2, 3, limit))
        #expect(noise.value(1, 2, 3, -1e30) == noise.value(1, 2, 3, -limit))
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
