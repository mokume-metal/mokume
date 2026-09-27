// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 粒の受け口 (`force`・`emit`) が、**数でない値・無限を受け取っても、生きている粒を
/// 壊さない**ことの検査 ([#1623])。GPU を要する。
///
/// 約束は [ADR-0020] 決定 5 — フレームごとに呼ばれる口は投げずに、受け口で値を検め、
/// 注意を言って安全な既定へ倒す。粒の口の安全な既定は「その値を効かせない」で、
/// 力なら積まない、`emit` なら粒を出さない。
///
/// 範囲は受け口に渡る数のすべてで、1 例ではなく並べて回す。力は 5 種の数の成分 12 個
/// (弱まり始める距離は別の扱いで、`ParticleForceTests` が見る)、`emit` は `rate`・
/// `from` の成分・`color` の成分・幅 (`speed`・`angle`・`life`・`size`) の端である。
/// 幅の端の数でない値は、Swift の `...` が幅を作る時点で止めるので届かない。無限だけを回す。
///
/// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@Suite(
    "粒の受け口の数でない値",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ParticleInputTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
    }

    private func fingerprint(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 再現

    /// [#1623] の完了条件 1。**本文の再現そのもの** — 2 枚目にだけ `once` の力を掛け、
    /// 各フレームの絵の指紋と、明るい画素の数を返す。
    ///
    /// 直す前は、`.gravity(.nan, 0)` を掛けた 2 枚目で生きていた粒の速度がすべて数でなく
    /// なり、その粒は寿命まで描かれない。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    private func pictures(once: Force) throws -> [(fingerprint: String, lit: Int)] {
        let canvas = try makeCanvas()
        canvas.deltaTime = 1.0 / 30
        var randomness = Randomness(seed: 1623)
        let dust = try canvas.makeParticles(count: 512)
        var frames: [(String, Int)] = []
        for frame in 1...12 {
            try canvas.draw {
                canvas.background(.display(red: 0.05, green: 0.05, blue: 0.05))
                let up = -Float.pi / 2
                canvas.emit(
                    dust, from: .point(32, 58), rate: 120, speed: 40...60,
                    angle: (up - 0.4)...(up + 0.4), life: 2...2, size: 3...3,
                    color: .display(red: 0.94, green: 0.55, blue: 0.16), using: &randomness)
                canvas.force(dust, [.gravity(0, 20)])
                if frame == 2 { canvas.force(dust, [once]) }
                canvas.particles(dust)
            }
            let bytes = try canvas.target.encodeForDisplay().bytes
            var lit = 0
            for pixel in stride(from: 0, to: bytes.count, by: 4)
            where max(bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]) > 51 {
                lit += 1
            }
            frames.append((fingerprint(bytes), lit))
        }
        return frames
    }

    @Test("数でない力を 1 度掛けても、生きている粒は消えず、0 の力と同じ絵になる")
    func aNonNumberForceLeavesTheLivingParticlesAlone() throws {
        let broken = try pictures(once: .gravity(.nan, 0))
        let reference = try pictures(once: .gravity(0, 0))
        // 何も描けていないと「同じ」も成り立ってしまうので、粒が出ていることを先に見る
        #expect(reference[1].lit > 0, "参照の 2 枚目に粒が写っていない")
        for index in reference.indices {
            #expect(
                broken[index].fingerprint == reference[index].fingerprint,
                "\(index + 1) 枚目: 明るい画素 \(broken[index].lit) / 参照 \(reference[index].lit)")
        }
    }

    // MARK: - 力

    /// 力の数の成分 12 個のそれぞれに、`value` を入れた力。名前は注意の文面に出る値の綴り。
    private nonisolated static func forces(with value: Float) -> [Force] {
        [
            .gravity(value, 0, 0), .gravity(0, value, 0), .gravity(0, 0, value),
            .attract(value, 0, 0, strength: 1), .attract(0, value, 0, strength: 1),
            .attract(0, 0, value, strength: 1), .attract(0, 0, 0, strength: value),
            .wander(strength: value),
            .swirl(value, 0, strength: 1), .swirl(0, value, strength: 1),
            .swirl(0, 0, strength: value),
            .drag(value),
        ]
    }

    nonisolated static let unacceptableForces: [Force] = [Float.nan, .infinity, -.infinity].flatMap(forces(with:))

    /// [#1623] の完了条件 2・4。**その力だけを積まず、注意を 1 度言い、並べた有限な力は
    /// 今までどおり積む。** 断った力は上限の枠も取らない — 上限ちょうどの有限な力と
    /// 並べても、上限の注意は鳴らない。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("数でない値・無限を成分に持つ力は積まず、1 度注意し、並べた有限な力は効く", arguments: unacceptableForces)
    func refusesAForceWithAnUnacceptableComponent(bad: Force) throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        let finite = Array(repeating: Force.drag(0.5), count: Particles.maximumForces - 1)
        var kept: [Force] = []
        try canvas.draw {
            canvas.force(dust, [.gravity(0, 1), bad] + finite)
            kept = dust.takeForces()
        }
        #expect(kept == [.gravity(0, 1)] + finite, "\(bad) を並べた呼び出しで積まれた力: \(kept)")
        #expect(dust.warnings.hasWarned(.unacceptableForce), "\(bad) を黙って受け取った")
        #expect(!dust.warnings.hasWarned(.tooManyForces), "断った \(bad) が上限の枠を取った")
        let message = try #require(dust.warnings.message(for: .unacceptableForce))
        #expect(message.contains("\(bad)"), "注意が、受け取れなかった力を言っていない: \(message)")

        // **1 度だけ言う。** 2 度目の数でない力で文面は替わらない
        try canvas.draw { canvas.force(dust, [.gravity(.nan, 1)]) }
        #expect(dust.warnings.message(for: .unacceptableForce) == message)
        #expect(dust.takeForces().isEmpty)
    }

    /// [#1623] の反証 1。**減速は速さを増やさない** (``Force/drag(_:)``) ので、負の `amount` は
    /// 注意を言って積まない。30 fps の `drag(-10000)` は 1 フレームで e^{333} 倍 (溢れる) で、
    /// 効かせた群の粒がすべて数でなくなっていた。0 は今までどおり黙って積む。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("負の減速は積まず、1 度注意する", arguments: [Float(-10_000), -1, -Float.leastNonzeroMagnitude])
    func refusesANegativeDrag(amount: Float) throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        var kept: [Force] = []
        try canvas.draw {
            canvas.force(dust, [.gravity(0, 1), .drag(amount), .drag(0)])
            kept = dust.takeForces()
        }
        #expect(kept == [.gravity(0, 1), .drag(0)], "drag(\(amount)) を並べた呼び出しで積まれた力: \(kept)")
        let message = try #require(dust.warnings.message(for: .negativeDrag))
        #expect(message.contains("\(amount)"), "注意が、渡した値を言っていない: \(message)")
        #expect(!dust.warnings.hasWarned(.unacceptableForce))
    }

    // MARK: - 状態

    /// 静止した粒を `count` 個出し、毎フレーム `forces` を掛けて `frames` フレーム進めた
    /// 後の、生きている粒の状態。
    private func advanced(
        from source: Emitter = .point(32, 32), count: Int = 16, forces: [Force], frames: Int
    ) throws -> (living: [Particle], dust: Particles) {
        let canvas = try makeCanvas()
        canvas.deltaTime = 1.0 / 30
        var randomness = Randomness(seed: 1623)
        let dust = try canvas.makeParticles(count: count)
        for frame in 0..<frames {
            try canvas.draw {
                if frame == 0 {
                    canvas.emit(
                        dust, from: source, rate: (Float(count) * 30).nextUp, speed: 0...0,
                        angle: 0...0, life: 100...100, size: 1...1,
                        color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                }
                if !forces.isEmpty { canvas.force(dust, forces) }
                canvas.particles(dust)
            }
        }
        let living = canvas.read(dust.state).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Particle.self).prefix(count)).filter { $0.life > 0 }
        }
        return (living, dust)
    }

    private static func isFinite(_ particle: Particle) -> Bool {
        [particle.x, particle.y, particle.z, particle.vx, particle.vy, particle.vz]
            .allSatisfy(\.isFinite)
    }

    nonisolated static let overflowingForces: [[Force]] = [
        [.gravity(0, 3e38), .gravity(0, 3e38)],
        [.gravity(0, 3e38)],
        [.attract(0, 0, strength: 3e38), .attract(0, 0, strength: 3e38)],
        [.swirl(0, 0, strength: 3e38), .gravity(3e38, 0)],
    ]

    /// [#1623] の反証 2・7。**有限の力でも、和や積分が溢れれば粒の状態は数でなくなる** —
    /// 受け口は数でない値・無限そのものしか断れない。状態の側 (断片の書き戻し) で、進めた
    /// 状態が数でなくなるフレームは動かさない。粒は消えず、状態は有限のまま残る。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("有限の力が溢れても、生きている粒の状態は数でなくならない", arguments: overflowingForces)
    func overflowingFiniteForcesKeepTheStateFinite(forces: [Force]) throws {
        let (living, _) = try advanced(forces: forces, frames: 40)
        #expect(living.count == 16, "\(forces) で生きている粒が \(living.count) 個に減った")
        let broken = living.filter { !Self.isFinite($0) }
        #expect(broken.isEmpty, "\(forces) で状態が数でなくなった粒: \(broken.count) 個")
    }

    /// [#1623] の反証 3。**端が有限でも、出る所が `Float` で溢れることがある。** 線分は
    /// 差だけが溢れるので、両端から直に混ぜて出す (`Randomness.scaled` と同じ手・#1312)。
    /// 円と球は中心 + 半径そのものが溢れるので、溢れた粒は置かずに注意する。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("端が有限の線分は、差が溢れても有限の所から出る")
    func aLineWhoseSpanOverflowsStillEmitsFinitePlaces() throws {
        let (living, dust) = try advanced(from: .line(-3e38, 0, 3e38, 0), forces: [], frames: 1)
        #expect(living.count == 16)
        #expect(living.allSatisfy(Self.isFinite), "線分から出た粒の位置が数でない")
        #expect(!dust.warnings.hasWarned(.unacceptableEmission))
    }

    @Test(
        "中心 + 半径が溢れる円・球からは、溢れた粒を置かずに注意する",
        arguments: [Emitter.circle(3e38, 0, radius: 3e38), .sphere(0, 0, 3e38, radius: 3e38)])
    func placesOutsideTheFloatRangeAreNotEmitted(source: Emitter) throws {
        let (living, dust) = try advanced(from: source, forces: [], frames: 1)
        #expect(living.allSatisfy(Self.isFinite), "\(source) から数でない位置の粒が出た")
        #expect(living.count < 16, "\(source) から溢れる粒が 1 つも出ていない (検査の前提)")
        let message = try #require(dust.warnings.message(for: .unacceptableEmission))
        #expect(message.contains("from"))
    }

    /// [#1623] の反証 6。**`color` を省いた `emit` は塗りで出すので、注意は塗りを名指す。**
    /// `color` と言うと、渡していない引数を名乗る。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("color を省いた emit で塗りが数でなければ、注意は塗りを名指す")
    func anOmittedColorNamesTheFill() throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        var randomness = Randomness(seed: 1623)
        try canvas.draw {
            canvas.fill(LinearRGBA(premultipliedRed: .nan, green: 0, blue: 0, alpha: 1))
            canvas.emit(
                dust, from: .point(32, 32), rate: 60, speed: 0...0, angle: 0...0, life: 1...1,
                size: 1...1, color: nil, using: &randomness)
        }
        #expect(dust.cursor == 0)
        let message = try #require(dust.warnings.message(for: .unacceptableEmission))
        #expect(message.contains("fill"), "塗りを名指していない: \(message)")
    }

    // MARK: - 出す

    /// `emit` の 1 回ぶんの引数。既定はどれも有限で、1 フレームで粒が出る。
    nonisolated struct Emission: CustomTestStringConvertible, Sendable {
        var name: String
        var rate: Float = 600
        var from: Emitter = .point(32, 32)
        var speed: ClosedRange<Float> = 0...10
        var angle: ClosedRange<Float> = 0...1
        var life: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = 1...2
        /// 乗算済みの赤・緑・青・不透明度。色の組み立ては主の actor に載るので、数で持つ
        var color: SIMD4<Float> = [1, 1, 1, 1]

        var testDescription: String { name }
    }

    nonisolated static let unacceptableEmissions: [Emission] = {
        var cases: [Emission] = []
        for value in [Float.nan, .infinity, -.infinity] {
            cases.append(Emission(name: "rate \(value)", rate: value))
            let places: [Emitter] = [
                .point(value, 0), .point(0, value), .point(0, 0, value),
                .line(value, 0, 1, 1), .line(0, 0, 1, value),
                .circle(value, 0, radius: 1), .circle(0, 0, radius: value),
                .sphere(0, 0, value, radius: 1), .sphere(0, 0, 0, radius: value),
            ]
            for place in places { cases.append(Emission(name: "from \(place)", from: place)) }
            cases.append(Emission(name: "color red \(value)", color: [value, 1, 1, 1]))
            cases.append(Emission(name: "color alpha \(value)", color: [1, 1, 1, value]))
        }
        // 幅の端は無限だけ (数でない値は `...` が作る時点で止める)
        let infinity = Float.infinity
        cases += [
            Emission(name: "speed 0...inf", speed: 0...infinity),
            Emission(name: "speed -inf...0", speed: -infinity...0),
            Emission(name: "angle 0...inf", angle: 0...infinity),
            Emission(name: "life 1...inf", life: 1...infinity),
            Emission(name: "size 1...inf", size: 1...infinity),
            Emission(name: "size -inf...1", size: -infinity...1),
        ]
        return cases
    }()

    private func emit(_ emission: Emission, into dust: Particles, on canvas: Canvas) throws -> Int {
        var randomness = Randomness(seed: 1623)
        let before = dust.cursor
        try canvas.draw {
            canvas.emit(
                dust, from: emission.from, rate: emission.rate, speed: emission.speed,
                angle: emission.angle, life: emission.life, size: emission.size,
                color: LinearRGBA(
                    premultipliedRed: emission.color.x, green: emission.color.y,
                    blue: emission.color.z, alpha: emission.color.w),
                using: &randomness)
            canvas.particles(dust)
        }
        return dust.cursor - before
    }

    /// [#1623] の完了条件 3・4。**粒を出さず、注意を 1 度言う。** 同じ粒へ有限の値で出せば、
    /// 今までどおり出る。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("emit に数でない値・無限を渡すと粒を出さず、1 度注意する", arguments: unacceptableEmissions)
    func refusesAnUnacceptableEmission(bad: Emission) throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 64)
        #expect(try emit(bad, into: dust, on: canvas) == 0, "\(bad.name) で粒が出た")
        #expect(dust.warnings.hasWarned(.unacceptableEmission), "\(bad.name) を黙って受け取った")
        let message = try #require(dust.warnings.message(for: .unacceptableEmission))
        let argument = String(bad.name.prefix { $0 != " " })
        #expect(message.contains(argument), "注意が、受け取れなかった引数を言っていない: \(message)")

        // 断った後も、有限の値なら今までどおり出る。注意は重ねない
        #expect(try emit(Emission(name: "finite"), into: dust, on: canvas) == 10)
        #expect(try emit(bad, into: dust, on: canvas) == 0)
        #expect(dust.warnings.message(for: .unacceptableEmission) == message)
    }

    /// 断った `emit` も、そのフレームの 1 回と数える (`Particles.count` の約束 — [#1468])。
    /// 数えないと、断った噴き口の後ろの繰り越しが前へずれる。条件付きで断られる噴き口の
    /// 後ろに置いた噴き口が、1 か所から出したときと同じ数を出すことで見る。
    ///
    /// [#1468]: https://github.com/mokume-metal/mokume/issues/1468
    @Test("断った emit も 1 回と数え、後ろの噴き口の繰り越しをずらさない")
    func aRefusedEmissionStillTakesItsTurn() throws {
        let canvas = try makeCanvas()
        canvas.deltaTime = 1.0 / 30
        let dust = try canvas.makeParticles(count: 256)
        var randomness = Randomness(seed: 1468)
        var counts = [0, 0]
        for frame in 0..<60 {
            try canvas.draw {
                // 1 か所目: 奇数のフレームだけ断られる。偶数のフレームは毎秒 7 個
                let first = dust.cursor
                canvas.emit(
                    dust, from: .point(16, 32), rate: frame.isMultiple(of: 2) ? 7 : .nan,
                    speed: 0...0, angle: 0...0, life: 0.2...0.2, size: 1...1,
                    color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                let second = dust.cursor
                canvas.emit(
                    dust, from: .point(48, 32), rate: 15, speed: 0...0, angle: 0...0,
                    life: 0.2...0.2, size: 1...1, color: .linear(red: 1, green: 1, blue: 1),
                    using: &randomness)
                counts[0] += second - first
                counts[1] += dust.cursor - second
                canvas.particles(dust)
            }
        }
        // 2 か所目は毎フレーム 0.5 個を自分の繰り越しに足すので、60 フレームでちょうど 30 個。
        // 1 か所目が断られたフレームに順番を詰めると、2 か所目は 1 か所目の繰り越し
        // (0 個か 7/30 個の端数) と自分の繰り越しを行き来し、端数を取り合う
        #expect(counts[1] == 30, "後ろの噴き口が出した数 \(counts[1]) — 頼んだ数は 30")
        #expect(counts[0] == 7, "条件付きの噴き口が出した数 \(counts[0]) — 30 フレームぶんで 7 個")
    }

    // MARK: - 既存の注意

    /// [#1623] の完了条件 4。**新しい注意が、既存の鍵を黙らせない。**
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    @Test("数でない値の注意の後でも、既存の注意は鳴る")
    func theNewWarningsDoNotSilenceTheOldOnes() throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        var randomness = Randomness(seed: 11)
        try canvas.draw {
            canvas.force(dust, [.gravity(.nan, 0), .attract(0, 0, strength: 1, weakeningBeyond: 0)])
            for _ in 0..<(Particles.maximumForces + 1) { canvas.force(dust, [.drag(0.1)]) }
            canvas.emit(
                dust, from: .point(.nan, 0), rate: 240, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
            canvas.emit(
                dust, from: .point(32, 32), rate: 240, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
            _ = dust.takeForces()
        }
        // 枠 4 個を長生きする粒で埋めた後に、もう 1 個出して上書きさせる
        try canvas.draw {
            canvas.emit(
                dust, from: .point(32, 32), rate: 60, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
        }
        #expect(dust.warnings.hasWarned(.unacceptableForce))
        #expect(dust.warnings.hasWarned(.unacceptableEmission))
        #expect(dust.warnings.hasWarned(.badWeakeningDistance))
        #expect(dust.warnings.hasWarned(.tooManyForces))
        #expect(dust.warnings.hasWarned(.overwrite))
    }
}
