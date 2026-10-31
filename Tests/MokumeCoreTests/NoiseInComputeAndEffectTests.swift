// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// **計算と効果の断片から引いた揺らぎが、CPU の `noise()` と同じ値になる**ことと、計算に時刻が届くことを
/// 見る ([#3569])。
///
/// 塗りの断片との突き合わせは ``NoiseParityTests`` が持つ。式は `Noise.metal` の 1 本で、3 本の前置きは
/// 種・枚数・弱まりを取り出して渡すだけなので、ここで見るのは**取り出しと届け方**である — 計算は
/// `MOKUME_FRAME` の口 (`Frame`)、効果は `Pixel` の欄が、頼んだ時点の設定を運ぶ。
///
/// 読み戻す精度は ``NoiseParityTests`` と同じ。計算は `float` の並びをそのまま読むのでビット単位で、効果は
/// 描き先が半精度なので**差そのもの**を返させて読む。
///
/// [#3569]: https://github.com/mokume-metal/mokume/issues/3569
@Suite(
    "計算と効果の断片から揺らぎと時刻が引ける",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NoiseInComputeAndEffectTests {
    /// 許される食い違い。``NoiseParityTests/tolerance`` と同じ。
    private static let tolerance: Float = 1e-6

    /// 引く座標。**格子の上・格子の間・負の側・遠く**を混ぜる。
    private static let places: [SIMD3<Float>] = [
        SIMD3(0, 0, 0),
        SIMD3(0.5, 0.5, 0.5),
        SIMD3(3.25, 7.75, 1.125),
        SIMD3(-1, -2, -3),
        SIMD3(-12.3, 45.6, -78.9),
        SIMD3(1234.5, -6789.25, 42.0625),
    ]

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
    }

    // MARK: - 計算

    /// 並びの `id` 番目に、座標 `places[id]` の揺らぎを書く。座標は値で渡す代わりに、式で作る。
    private static let grain = """
        kernel void grain(device float *out [[buffer(0)]],
                          constant Frame &frame [[buffer(MOKUME_FRAME)]],
                          uint id [[thread_position_in_grid]])
        {
            float3 p = float3(float(id) * 0.37 - 3.1, float(id % 3) * 1.25, -0.5 * float(id));
            out[id] = mokume_noise(frame, p);
        }
        """

    private static func grainPlace(_ id: Int) -> SIMD3<Float> {
        SIMD3(Float(id) * 0.37 - 3.1, Float(id % 3) * 1.25, -0.5 * Float(id))
    }

    /// 4 つ目の軸を持つ座標。`w` が 0 でない点が主。
    private static let grain4 = """
        kernel void grain4(device float *out [[buffer(0)]],
                           constant Frame &frame [[buffer(MOKUME_FRAME)]],
                           uint id [[thread_position_in_grid]])
        {
            float4 p = float4(float(id) * 0.31, 0.77, 1.0, float(id) * 0.6 - 2.0);
            out[id] = mokume_noise(frame, p);
        }
        """

    /// 時刻を書くだけの計算。
    private static let clock = """
        kernel void clock(device float *out [[buffer(0)]],
                          constant Frame &frame [[buffer(MOKUME_FRAME)]],
                          uint id [[thread_position_in_grid]])
        {
            out[id] = frame.time;
        }
        """

    @Test(
        "計算の断片の mokume_noise は、CPU の noise() と同じ値になる",
        arguments: [
            (seed: 0, octaves: 4, falloff: Float(0.5)),
            (seed: 7, octaves: 1, falloff: 0.5),
            (seed: 12345, octaves: 2, falloff: 0.3),
            (seed: -9, octaves: 6, falloff: 0.8),
        ])
    func computeNoiseMatchesTheCPU(seed: Int, octaves: Int, falloff: Float) throws {
        let canvas = try makeCanvas()
        let count = 24
        let out = try canvas.makeNumbers(count: count)
        let grain = try canvas.makeComputation(Self.grain, name: "grain")
        canvas.noiseSeed(seed)
        canvas.noiseDetail(octaves, falloff)

        try canvas.draw { canvas.compute(grain, over: count, writes: [out]) }

        let drawn = canvas.read(out)
        for id in 0..<count {
            let place = Self.grainPlace(id)
            let expected = canvas.noise(place.x, place.y, place.z)
            #expect(
                abs(drawn[id] - expected) < Self.tolerance,
                "id \(id): GPU \(drawn[id]) / CPU \(expected) (seed \(seed), octaves \(octaves), falloff \(falloff))")
        }
    }

    @Test("計算の断片の 4 つ目の軸も CPU と同じ値になる")
    func computeNoiseMatchesTheCPUOnTheFourthAxis() throws {
        let canvas = try makeCanvas()
        let count = 16
        let out = try canvas.makeNumbers(count: count)
        let grain = try canvas.makeComputation(Self.grain4, name: "grain4")
        canvas.noiseSeed(3)

        try canvas.draw { canvas.compute(grain, over: count, writes: [out]) }

        let drawn = canvas.read(out)
        for id in 0..<count {
            let expected = canvas.noise(Float(id) * 0.31, 0.77, 1.0, Float(id) * 0.6 - 2.0)
            #expect(abs(drawn[id] - expected) < Self.tolerance, "id \(id): \(drawn[id]) / \(expected)")
        }
    }

    @Test("計算の揺らぎは、頼んだ時点の種と細かさで引く")
    func computeNoiseUsesTheSettingsAtTheTimeOfAsking() throws {
        let canvas = try makeCanvas()
        let first = try canvas.makeNumbers(count: 8)
        let second = try canvas.makeNumbers(count: 8)
        let grain = try canvas.makeComputation(Self.grain, name: "grain")

        try canvas.draw {
            canvas.noiseSeed(1)
            canvas.noiseDetail(2, 0.5)
            canvas.compute(grain, over: 8, writes: [first])
            // 溜めた頼みは流す段まで走らない。ここで決め直した設定が、先の頼みに引きずられてはならない
            canvas.noiseSeed(2)
            canvas.noiseDetail(5, 0.25)
            canvas.compute(grain, over: 8, writes: [second])
        }

        let (drawnFirst, drawnSecond) = (canvas.read(first), canvas.read(second))
        func expected(seed: Int, octaves: Int, falloff: Float, id: Int) -> Float {
            let reference = ValueNoise(seed: UInt32(seed), octaves: octaves, falloff: falloff)
            let place = Self.grainPlace(id)
            return reference.value(place.x, place.y, place.z, 0)
        }
        for id in 0..<8 {
            #expect(
                abs(drawnFirst[id] - expected(seed: 1, octaves: 2, falloff: 0.5, id: id)) < Self.tolerance,
                "最初の頼み id \(id)")
            #expect(
                abs(drawnSecond[id] - expected(seed: 2, octaves: 5, falloff: 0.25, id: id)) < Self.tolerance,
                "次の頼み id \(id)")
        }
        #expect(drawnFirst != drawnSecond)
    }

    @Test("計算に時刻が届き、頼んだ時点のものが効く")
    func computeReceivesTheTimeAtTheTimeOfAsking() throws {
        let canvas = try makeCanvas()
        let first = try canvas.makeNumbers(count: 4)
        let second = try canvas.makeNumbers(count: 4)
        let clock = try canvas.makeComputation(Self.clock, name: "clock")

        try canvas.draw {
            canvas.time = 1.5
            canvas.compute(clock, over: 4, writes: [first])
            canvas.time = 4.25
            canvas.compute(clock, over: 4, writes: [second])
        }

        #expect(canvas.read(first) == [1.5, 1.5, 1.5, 1.5])
        #expect(canvas.read(second) == [4.25, 4.25, 4.25, 4.25])
    }

    @Test("口を書かない計算は、これまでどおり動く")
    func computeWithoutTheFrameBindingStillRuns() throws {
        let canvas = try makeCanvas()
        let out = try canvas.makeNumbers(count: 4)
        let plain = try canvas.makeComputation(
            """
            kernel void plain(device float *out [[buffer(0)]],
                              constant Values &values [[buffer(MOKUME_VALUES)]],
                              uint id [[thread_position_in_grid]])
            {
                out[id] = values.amount * float(id);
            }
            """,
            name: "plain", values: ["amount": 2])

        try canvas.draw { canvas.compute(plain, over: 4, writes: [out]) }

        #expect(canvas.read(out) == [0, 2, 4, 6])
    }

    // MARK: - 効果

    /// 効果の断片が返すのは**差そのもの**。座標と期待値は値で渡す。
    private static let comparison = """
        float4 effect(Pixel in, Values values) {
            float mine = mokume_noise(in, float3(values.place, values.depth));
            return float4(abs(mine - values.expected), 0.0, 0.0, 1.0);
        }
        """

    private static let comparison4 = """
        float4 effect(Pixel in, Values values) {
            float mine = mokume_noise(in, float4(values.place, values.depth, values.fourth));
            return float4(abs(mine - values.expected), 0.0, 0.0, 1.0);
        }
        """

    /// 断片が出した値と `expected` の差を、効果を通した絵から読む。
    private func gap(
        of body: String, _ canvas: Canvas, at place: SIMD4<Float>, expected: Float,
        through apply: (Canvas, EffectShader) -> Void
    ) throws -> Float {
        let shader = try canvas.makeEffect(
            body,
            values: [
                "place": .pair(place.x, place.y), "depth": .number(place.z),
                "fourth": .number(place.w), "expected": .number(expected),
            ])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            apply(canvas, shader)
        }
        return canvas.get(4, 4).red
    }

    @Test(
        "効果の断片の mokume_noise は、CPU の noise() と同じ値になる",
        arguments: [
            (seed: 0, octaves: 4, falloff: Float(0.5)),
            (seed: 7, octaves: 1, falloff: 0.5),
            (seed: 12345, octaves: 2, falloff: 0.3),
            (seed: -9, octaves: 6, falloff: 0.8),
        ])
    func effectNoiseMatchesTheCPU(seed: Int, octaves: Int, falloff: Float) throws {
        for place in Self.places {
            let canvas = try makeCanvas()
            canvas.noiseSeed(seed)
            canvas.noiseDetail(octaves, falloff)
            let expected = canvas.noise(place.x, place.y, place.z)
            let difference = try gap(
                of: Self.comparison, canvas, at: SIMD4(place, 0), expected: expected
            ) { canvas, shader in canvas.effects([.custom(shader)]) }
            #expect(
                difference < Self.tolerance,
                "\(place): 差 \(difference) (seed \(seed), octaves \(octaves), falloff \(falloff))")
        }
    }

    @Test("効果の断片の 4 つ目の軸も CPU と同じ値になる")
    func effectNoiseMatchesTheCPUOnTheFourthAxis() throws {
        for place in [SIMD4<Float>(3.25, 7.75, 1.125, 0.375), SIMD4(-12.3, 45.6, -78.9, 10.1)] {
            let canvas = try makeCanvas()
            canvas.noiseSeed(5)
            let expected = canvas.noise(place.x, place.y, place.z, place.w)
            let difference = try gap(
                of: Self.comparison4, canvas, at: place, expected: expected
            ) { canvas, shader in canvas.effects([.custom(shader)]) }
            #expect(difference < Self.tolerance, "\(place): 差 \(difference)")
        }
    }

    @Test("効果の揺らぎは、効果を積んだ時点の種と細かさで引く")
    func effectNoiseUsesTheSettingsAtTheTimeOfStacking() throws {
        let place = SIMD3<Float>(3.25, 7.75, 1.125)
        let canvas = try makeCanvas()
        canvas.noiseSeed(11)
        canvas.noiseDetail(3, 0.4)
        let expected = canvas.noise(place.x, place.y, place.z)

        let difference = try gap(
            of: Self.comparison, canvas, at: SIMD4(place, 0), expected: expected
        ) { canvas, shader in
            canvas.effects([.custom(shader)])
            // 積んだ後に決め直した設定で引いてはならない (フレームの終わりに通すときではなく、積んだ時点)
            canvas.noiseSeed(99)
            canvas.noiseDetail(1, 0.9)
        }
        #expect(difference < Self.tolerance, "差 \(difference)")
    }

    @Test("filter() で掛ける効果の揺らぎも CPU と同じ値になる")
    func filterNoiseMatchesTheCPU() throws {
        let place = SIMD3<Float>(-12.3, 45.6, -78.9)
        let canvas = try makeCanvas()
        canvas.noiseSeed(21)
        canvas.noiseDetail(2, 0.6)
        let expected = canvas.noise(place.x, place.y, place.z)

        let difference = try gap(
            of: Self.comparison, canvas, at: SIMD4(place, 0), expected: expected
        ) { canvas, shader in canvas.filter([.custom(shader)]) }
        #expect(difference < Self.tolerance, "差 \(difference)")
    }

    @Test("効果の揺らぎは、設定を変えると別の値になる (検査が何も見ていないのではない)")
    func effectNoiseFollowsTheSettings() throws {
        let place = SIMD3<Float>(3.25, 7.75, 1.125)
        let canvas = try makeCanvas()
        canvas.noiseSeed(1)
        let wrong = canvas.noise(place.x, place.y, place.z)
        canvas.noiseSeed(2)
        // 期待値を別の種で作ると、差は読み取れる大きさで出る
        let difference = try gap(
            of: Self.comparison, canvas, at: SIMD4(place, 0), expected: wrong
        ) { canvas, shader in canvas.effects([.custom(shader)]) }
        #expect(difference > 1e-3, "別の種の期待値と突き合わせたのに、差が \(difference) しか出ない")
    }
}
