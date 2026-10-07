// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 2 つの値が、最後の数桁 (4 ulp) を除いて同じか。
///
/// **`cos` と `sin` は、最適化の仕方で最後の桁が揺れる。** release では同じ引数の組が `sincos` 1 回に
/// まとめられうるが、検査の側の式は別の文脈で組まれるので、同じ値が 1 ulp 違うことがある (専用機の
/// release の検査で、1000 本のうち 26 本が違った。debug は全部一致する)。向きの式や乱数を引く
/// 回数・順が違えば値は桁違いに外れるので、4 ulp はそれを見逃さない。
private func sameValue(_ a: Float, _ b: Float) -> Bool {
    abs(a - b) <= 4 * Float.ulpOfOne * max(abs(a), abs(b))
}

/// 粒の飛ぶ向き (``Heading``) の引き方 ([#1042])。**GPU を要らない** — 引いた向きそのものを見る。
///
/// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
@Suite("粒の飛ぶ向き")
struct HeadingTests {
    /// 全方位の向きを `count` 本引く。
    private static func sphereDirections(count: Int) -> [SIMD3<Float>] {
        var randomness = Randomness(seed: 1042)
        return (0..<count).map { _ in Heading.sphere.sample(using: &randomness) }
    }

    /// 割合の検査に使う本数。帽子 (割合 0.05) の標準偏差は約 0.0007 で、許す幅 0.005 は 7 倍。
    private static let drawn = sphereDirections(count: 100_000)

    @Test("全方位の向きは長さ 1 で、奥行きの成分を持つ")
    func sphereDirectionsAreUnitAndLeaveThePlane() {
        let off = Self.drawn.filter { abs(simd_length($0) - 1) > 1e-5 }
        #expect(off.isEmpty, "長さが 1 でない向き: \(off.count) 本 (例 \(off.prefix(3)))")
        #expect(Self.drawn.contains { $0.z > 0.5 } && Self.drawn.contains { $0.z < -0.5 })
    }

    /// 球面上で一様なら、**どの軸から見ても**、高さ h の帽子には面積どおり h / 2 の割合が
    /// 落ちる (アルキメデスの帽子の定理)。仰角を角度のまま一様に引くと、z 軸の極の帽子
    /// (成分 > 0.9) に 0.05 ではなく約 0.14 が落ちる。軸を z だけにしないのは、方位角の
    /// 偏りや成分の取り違えも拾うため。
    @Test(
        "全方位の向きは、どの軸の極の帽子にも赤道の帯にも面積どおりの割合で落ちる",
        arguments: [
            SIMD3<Float>(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 1),
            SIMD3(1, -2, 0.5),
        ])
    func sphereDirectionsCoverCapsByArea(axis: SIMD3<Float>) {
        let unit = simd_normalize(axis)
        let along = Self.drawn.map { simd_dot($0, unit) }
        let total = Float(along.count)
        let north = Float(along.filter { $0 > 0.9 }.count) / total
        let south = Float(along.filter { $0 < -0.9 }.count) / total
        let equator = Float(along.filter { abs($0) < 0.1 }.count) / total
        #expect(abs(north - 0.05) < 0.005, "軸 \(axis) の北の帽子の割合 \(north) — 面積どおりなら 0.05")
        #expect(abs(south - 0.05) < 0.005, "軸 \(axis) の南の帽子の割合 \(south) — 面積どおりなら 0.05")
        #expect(abs(equator - 0.1) < 0.005, "軸 \(axis) の赤道の帯の割合 \(equator) — 面積どおりなら 0.1")
    }

    @Test("全方位の向きの x・y・z の各成分は、[-1, 1] の 10 区間に同じ数ずつ落ちる")
    func sphereComponentsAreUniform() {
        let expected = Float(Self.drawn.count) / 10
        for component in 0..<3 {
            var bins = [Int](repeating: 0, count: 10)
            for direction in Self.drawn {
                bins[min(9, Int((direction[component] + 1) / 2 * 10))] += 1
            }
            let worst = bins.map { abs(Float($0) - expected) / expected }.max() ?? 0
            #expect(worst < 0.05, "成分 \(component) の区間ごとの数 \(bins) — 期待は各 \(Int(expected))")
        }
    }

    /// **引く回数が揺れると、向きを差し替えた瞬間にその後の乱数の列全体がずれる**
    /// (`Emitter.sample` と同じ約束)。面内は幅が 0 でも 1 回引く — `toward` を省いた
    /// 呼び出しが、向きを幅で渡していた頃と同じ列を引くための条件である。
    @Test(
        "引く回数は種類ごとに決まっていて、面内は幅が 0 でも 1 回・全方位は 2 回",
        arguments: [
            (Heading.plane(0...0), 1), (.plane(1...1), 1), (.plane(-0.5...2), 1),
            (.plane(0...(2 * Float.pi)), 1), (.sphere, 2),
        ])
    func drawsAFixedNumberOfValues(heading: Heading, draws: Int) {
        var sampled = Randomness(seed: 77)
        var skipped = Randomness(seed: 77)
        for _ in 0..<100 { _ = heading.sample(using: &sampled) }
        for _ in 0..<(100 * draws) { _ = skipped.next() }
        #expect(sampled.next() == skipped.next(), "\(heading) が 1 本あたり \(draws) 回引いていない")
    }

    /// [#1042] の完了条件 3 の、GPU の要らない半分。面内の向きは、幅から 1 回引いた角度の
    /// `(cos, sin, 0)` — 向きを `angle` の幅で渡していた頃の速度の式の、速さを掛ける前である。
    ///
    /// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
    @Test("面内の向きは、幅から 1 回引いた角度の (cos, sin, 0)")
    func planeDirectionIsTheAngleDrawnOnce() {
        var sampled = Randomness(seed: 11)
        var replica = Randomness(seed: 11)
        var mismatches = 0
        for _ in 0..<1000 {
            let direction = Heading.plane(-1...2.5).sample(using: &sampled)
            let angle = replica.value(from: -1, to: 2.5)
            let same =
                sameValue(direction.x, cos(angle)) && sameValue(direction.y, sin(angle))
                && direction.z == 0
            if !same { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

/// 撒いた粒の初速 ([#1042])。**置いた直後の状態を読む** — 進めると力と積分が混ざるので、
/// 粒は出すだけで進めない。
///
/// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
@Suite(
    "撒いた粒の初速",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HeadingEmissionTests {
    /// 点から `count` 個を 1 フレームで出し、置いた直後の粒を返す。
    private func placed(
        toward heading: Heading, speed: ClosedRange<Float>, count: Int = 256, seed: Int
    ) throws -> [Particle] {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        canvas.deltaTime = 1.0 / 30
        var randomness = Randomness(seed: seed)
        let dust = try canvas.makeParticles(count: count)
        try canvas.draw {
            canvas.emit(
                dust, from: .point(32, 32, 0), toward: heading, rate: (Float(count) * 30).nextUp,
                speed: speed, life: 0.5...3, size: 1...4,
                color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
        }
        #expect(dust.cursor == count, "出た数 \(dust.cursor) — 検査の前提は \(count) 個")
        return canvas.read(dust.state).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Particle.self).prefix(count))
        }
    }

    /// [#1042] の完了条件 1。
    ///
    /// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
    @Test("toward: .sphere で撒いた粒の初速は奥行きへも向き、速さは渡した速さのまま")
    func sphereGivesParticlesDepthVelocity() throws {
        let particles = try placed(toward: .sphere, speed: 50...50, seed: 1042)
        let flat = particles.filter { $0.vz == 0 }
        #expect(flat.isEmpty, "vz が 0 の粒: \(flat.count) 個")
        #expect(particles.contains { $0.vz > 25 } && particles.contains { $0.vz < -25 })
        let speeds = particles.map { simd_length(SIMD3($0.vx, $0.vy, $0.vz)) }
        let off = speeds.filter { abs($0 - 50) > 1e-3 }
        #expect(off.isEmpty, "速さが 50 でない粒: \(off.prefix(3))")
    }

    /// 比べる側。面内 (今までの向き) は、どの粒も `vz` が 0 のまま。
    @Test("toward: .plane で撒いた粒の初速は、どれも画面の面内")
    func planeKeepsParticlesInThePlane() throws {
        let particles = try placed(toward: .plane(0...(2 * Float.pi)), speed: 50...50, seed: 1042)
        #expect(particles.allSatisfy { $0.vz == 0 })
        #expect(particles.contains { abs($0.vx) > 25 } && particles.contains { abs($0.vy) > 25 })
    }

    nonisolated static let planes: [ClosedRange<Float>] = [0...(2 * Float.pi), 0.3...2.9, 1...1]

    /// [#1042] の完了条件 3。**種を決めて面内へ撒いた粒の値が、向きを `angle` の幅で渡していた
    /// 頃の式と同じ — 速度の x・y は `cos` と `sin` の最後の桁の揺れ (`sameValue`) を
    /// 除いて、ほかの値は 1 ビットも違わない。** 物差しは同じ種から、出していた頃の順 (場所 → 向き 1 回 →
    /// 速さ → 寿命 → 大きさ → 種) に引き直した値で、点の噴き口は場所に 1 回も引かない。
    /// 幅が 0 (`1...1`) でも向きに 1 回引く。最後の種まで一致すれば、列がずれていない。
    ///
    /// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
    @Test("面内へ撒いた粒の値は、向きに 1 回引く今までの式のまま", arguments: planes)
    func planeKeepsTheValuesOfTheAngleFormula(angle: ClosedRange<Float>) throws {
        let particles = try placed(toward: .plane(angle), speed: 10...80, seed: 2042)
        var replica = Randomness(seed: 2042)
        var mismatches: [Int] = []
        for (index, particle) in particles.enumerated() {
            let heading = replica.value(from: angle.lowerBound, to: angle.upperBound)
            let rate = replica.value(from: 10, to: 80)
            let span = max(0, replica.value(from: 0.5, to: 3))
            let extent = max(0, replica.value(from: 1, to: 4))
            let seed = replica.unitValue()
            let same =
                sameValue(particle.vx, cos(heading) * rate)
                && sameValue(particle.vy, sin(heading) * rate) && particle.vz == 0
                && particle.span == span && particle.size == extent && particle.seed == seed
            if !same { mismatches.append(index) }
        }
        #expect(mismatches.isEmpty, "今までの式と違う粒: \(mismatches.prefix(5)) ほか")
    }

    /// `toward` を省いた `emit` と、今までの `angle` の既定と同じ幅を渡した `emit`。
    final class OmittedHeading: Sketch {
        var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
        var dots: Particles?
        init() {}
        func setup() {
            randomSeed(1042)
            dots = try? makeParticles(count: 64)
        }
        func draw() {
            guard let dots else { return }
            emit(dots, from: .point(16, 16), rate: 600)
        }
    }

    final class WrittenHeading: Sketch {
        var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
        var dots: Particles?
        init() {}
        func setup() {
            randomSeed(1042)
            dots = try? makeParticles(count: 64)
        }
        func draw() {
            guard let dots else { return }
            emit(dots, from: .point(16, 16), toward: .plane(0...(2 * Float.pi)), rate: 600)
        }
    }

    private func state(of sketch: some Sketch, dots: () -> Particles?) throws -> [Float] {
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        defer { runtime.closePlugins() }
        for _ in 0..<3 { try runtime.advance() }
        let group = try #require(dots(), "粒を作れていない")
        return runtime.canvas.read(group.state)
    }

    /// [#1042] の完了条件 3 の、公開の口の半分。**省いた `toward` は、`angle` の既定だった幅の
    /// 面内である** — 上の検査と合わせて、`toward` を省いた呼び出しは種を決めた粒の値を変えない。
    ///
    /// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
    @Test("toward を省いた emit は、面内の全方向 0...2π を渡したのと同じ粒を出す")
    func omittedHeadingIsTheFullPlane() throws {
        let omitted = OmittedHeading()
        let written = WrittenHeading()
        let fromOmitted = try state(of: omitted) { omitted.dots }
        let fromWritten = try state(of: written) { written.dots }
        #expect(fromOmitted.contains { $0 != 0 }, "粒が 1 つも置かれていない — 比べる前提が崩れている")
        #expect(fromOmitted == fromWritten)
    }
}
