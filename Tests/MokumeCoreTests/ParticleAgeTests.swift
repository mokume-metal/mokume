// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing
import simd

@testable import MokumeCore

/// 粒の塗りの断片から、年齢 `in.particle.age` を読む ([#2459])。GPU を要する。
///
/// 時計はフレーム番号から導く (60 fps)。寿命 1 の粒は 60 枚描かれ (``Particles/frames(life:perSecond:)``)、
/// 出して最初に描かれる枚が年齢 0、n 枚目が (n − 1) ÷ 61 になる。
///
/// 年齢は画素の色として読む。値は書き出しの変換 (`encodeForDisplay`) を通るので、期待する値は
/// 同じ変換を通した値と突き合わせる。
///
/// [#2459]: https://github.com/mokume-metal/mokume/issues/2459
@Suite(
    "粒の年齢 (断片から読む)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ParticleAgeTests {
    /// 寿命 1 秒の粒が 60 fps で描かれる枚数。
    private static let frames = 60
    /// 升の幅 (画素)。粒は真ん中に、動かずに置く。
    private static let side = ParticleLifetimeTests.spacing

    /// 作る前に当てる断片。**粒の板は作った時点の断片で塗られる** ([#1649])。
    ///
    /// [#1649]: https://github.com/mokume-metal/mokume/issues/1649
    private static let softBody = """
        float4 paint(Fragment in, Values values) {
            // 板の中の位置は shapePosition (形自身の座標で、plane(1, 1) の板なら ±0.5)。粒の `uv` は
            // 白い区画を指す一点で、板の中では変わらない
            float r = length(in.shapePosition.xy) * 2.0;
            return in.color * (1.0 - smoothstep(0.0, 1.0, r)) * (1.0 - in.particle.age);
        }
        """

    /// 年齢を赤で出す断片。緑は 1 に固定する (何も塗られていない黒と区別するため)。
    private static let ageBody = """
        float4 paint(Fragment in, Values values) {
            return float4(in.particle.age, 1.0, 0.0, 1.0);
        }
        """

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: try RenderDevice(), width: Self.side, height: Self.side)
    }

    /// 真ん中の画素 (表示の値)。
    private func center(_ canvas: Canvas) throws -> [UInt8] {
        let bytes = try canvas.target.encodeForDisplay().bytes
        let start = ((Self.side / 2) * Self.side + Self.side / 2) * 4
        return Array(bytes[start..<(start + 4)])
    }

    /// 線形の値 `value` が、書き出しの変換を通ったあとの 0…255。
    private func encoded(_ value: Float) -> Int {
        Int((OutputStage.encodeForDisplay(value) * 255).rounded())
    }

    /// 表示の値 `byte` に戻る線形の値 (`encoded(_:)` の逆。二分法で求める)。
    private func decoded(_ byte: Int) -> Float {
        var low: Float = 0
        var high: Float = 1
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if encoded(mid) < byte { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// 寿命 `1...1` の粒を 1 つ出して `count` 枚進め、`read` を毎枚呼ぶ。
    /// 断片は粒を作る前に当てる。
    private func play(
        _ body: String, route: Canvas.ParticleRoute = .instanced, count: Int,
        read: (Int, Row) throws -> Void
    ) throws {
        let canvas = try makeCanvas()
        canvas.shader(try canvas.makeShader(body))
        let row = try Row(on: canvas, route: route)
        for frame in 0..<count {
            try row.advance(emitting: frame == 0)
            try read(frame, row)
        }
    }

    /// 1 つの升の真ん中に粒を出す手順 (``ParticleLifetimeTests/Row`` と同じ形で、寿命と大きさを決める)。
    final class Row {
        let canvas: Canvas
        let dust: Particles
        private let timing = FrameTiming(clock: .frameIndex(frameRate: 60), now: { 0 })
        private var randomness = Randomness(seed: 2459)

        init(on canvas: Canvas, route: Canvas.ParticleRoute) throws {
            self.canvas = canvas
            canvas.particleRoute = route
            dust = try canvas.makeParticles(count: 4)
        }

        func advance(emitting: Bool) throws {
            timing.advance(at: nil)
            canvas.time = timing.time
            canvas.frameStep = timing.step
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                if emitting {
                    // 1 枚目に毎秒 60 個を頼むと、ちょうど 1 個出る (#1640)
                    canvas.emit(
                        dust, from: .point(Float(ParticleAgeTests.side) / 2, Float(ParticleAgeTests.side) / 2),
                        toward: .plane(0...0), rate: 60, speed: 0...0, life: 1...1, size: 8...8,
                        color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                }
                canvas.particles(dust)
            }
        }
    }

    // MARK: - 1: 寿命の半分で不透明度がおよそ半分

    @Test("寿命 1 の粒に soft の断片を当てて 30 枚進めると、中心の不透明度は出した直後のおよそ半分になる")
    func fadesToAboutHalfByTheMiddleOfTheLife() throws {
        var first = 0
        var middle = 0
        try play(Self.softBody, count: 31) { frame, row in
            let red = Int(try center(row.canvas)[0])
            if frame == 0 { first = red }
            if frame == 30 { middle = red }
        }
        // 出した直後は年齢 0 で、中心はほぼ白 (板の端まで 1 から縁へ落ちる柔らかさの分だけ 255 に届かない)
        #expect(first >= 230, "出した直後の中心 \(first)")
        // 30 枚目 (年齢 30/61 ≈ 0.49) の中心は (1 − 年齢) ≈ 0.51 倍。線形の比で 0.4〜0.6 に収まる
        let ratio = decoded(middle) / decoded(first)
        #expect((0.4...0.6).contains(ratio), "30 枚目の中心は出した直後の \(ratio) 倍")
    }

    // MARK: - 2: 年齢の範囲

    @Test("年齢は出した枚で 0、30 枚目で約半分、最後の枚で 1 に近く、毎枚 0…1 の内に増えていく")
    func ageGrowsFromZeroToJustUnderOne() throws {
        var ages: [Int] = []
        try play(Self.ageBody, count: Self.frames) { _, row in
            ages.append(Int(try center(row.canvas)[0]))
        }
        #expect(ages.count == Self.frames)
        #expect(ages[0] == 0, "出した枚の年齢 \(ages[0])")
        // 30 枚目は 30/61 ≈ 0.4918
        #expect(abs(ages[30] - encoded(30.0 / 61.0)) <= 2, "30 枚目の年齢 \(ages[30])")
        // 59 枚目は 59/61 ≈ 0.967。1 には届かない (1 は 255)
        #expect(ages[59] >= encoded(0.9) && ages[59] < 255, "最後の枚の年齢 \(ages[59])")
        #expect(zip(ages, ages.dropFirst()).allSatisfy { $0 <= $1 }, "年齢が戻っている")
        #expect(ages.allSatisfy { (0...255).contains($0) })
    }

    // MARK: - 3: 粒でない形では 0

    @Test("粒でない形 (平面・立体) に同じ断片を当てても組み上がり、年齢は 0 として読める")
    func aNonParticleShapeReadsZero() throws {
        let canvas = try makeCanvas()
        canvas.shader(try canvas.makeShader(Self.ageBody))
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.rect(0, 0, Float(Self.side), Float(Self.side))
        }
        // 緑 255 (塗られている)・赤 0 (年齢 0)
        #expect(try center(canvas) == [0, 255, 0, 255])

        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.translate(Float(Self.side) / 2, Float(Self.side) / 2, 0)
            canvas.box(6, 6, 6)
        }
        #expect(try center(canvas) == [0, 255, 0, 255])
    }

    // MARK: - 4: 決定論・2 つの経路

    @Test("同じ種・同じフレームを 2 度描くと、絵の指紋が一致する")
    func drawingTwiceGivesTheSamePicture() throws {
        func picture() throws -> [UInt8] {
            var bytes: [UInt8] = []
            try play(Self.softBody, count: 31) { frame, row in
                if frame == 30 { bytes = try row.canvas.target.encodeForDisplay().bytes }
            }
            return bytes
        }
        let first = try picture()
        let second = try picture()
        #expect(first.contains { $0 != 0 })
        #expect(first == second)
    }

    @Test("速い経路と参照の経路は、年齢を読む断片でも同じ絵を出す")
    func bothRoutesAgreeOnTheAge() throws {
        func ages(_ route: Canvas.ParticleRoute) throws -> [Int] {
            var values: [Int] = []
            try play(Self.ageBody, route: route, count: Self.frames) { _, row in
                values.append(Int(try center(row.canvas)[0]))
            }
            return values
        }
        let fast = try ages(.instanced)
        let reference = try ages(.reference)
        #expect(fast == reference)
        #expect(fast.last ?? 0 > 200, "年齢が育っている")
    }
}
