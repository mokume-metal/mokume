// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 粒の力と噴き口が、**doc に書いた式どおり**に粒を動かし・置くことの検査 ([#1384])。
/// GPU を要する。
///
/// `ParticleTests` が見ているのは、描き方の 2 経路が同じ絵を出すことと、寿命・詰め方・
/// 置き場の確保である。それだけだと、力が別の力へ崩れても・噴き口が形の外へ出しても、
/// 2 経路が同じように崩れていれば緑のままになる。ここでは GPU が進めた粒の状態を読み、
/// 式から導いた値と比べる ([ADR-0019] 決定 4)。
///
/// ## 積分は CPU で独立に書く
///
/// 進め方は ``Force`` の doc が決めている — 力を加速度として足し合わせ、**先に速度を、
/// 進めた速度で位置を**進める (半陰的オイラー)。減速だけは足さず、進めた速度に
/// e^{−amount·Δt} を掛ける。刻みは `deltaTime`。ここではその方式を CPU で書き直して
/// 照合する。実装 (`Shaders/Computations/Particles.metal`) の綴りは写さない。
///
/// ## 完全一致が取れるところと、取れないところ
///
/// 刻みを 1/64 秒に、力と速さを 2 進の短い小数にすると、重力の積分は**丸めなしで
/// 閉じる**。そこは完全一致で比べる — 閉じていることは、CPU の単精度の積分が倍精度の
/// 閉じた式と一致することで検査自身が確かめる。単精度の積和が 1 回の丸めにまとめられて
/// いても (fma)、丸めが無ければ値は変わらない。
///
/// 引く・押す・回す力は、向きを長さで割るので 2 進で閉じない (平方根と割り算は近似の
/// 算術 — fast math — を通る)。減速も、速度に e^{−amount·Δt} を掛けるので閉じない
/// (`exp` も近似の算術を通る — [#1471])。そこは相対 1e-5 を許す。単精度の数目盛りぶんで、
/// 向きや大きさを取り違えたときのずれより 4 桁以上小さい。
///
/// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
/// [#1471]: https://github.com/mokume-metal/mokume/issues/1471
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "粒の力と噴き口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ParticleForceTests {
    /// 1 フレームの長さ。**2 のべき**なので、掛けても丸めが入らない。
    private static let step: Float = 1.0 / 64

    /// 最初のフレームに出す粒の群れ。
    private struct Release {
        var source: Emitter
        var count = 1
        /// 出たときの速さと向き (幅は取らない)。
        var speed: Float = 0
        var angle: Float = 0
    }

    /// 最初のフレームで粒を出し、毎フレーム同じ力を掛けて `frames` フレーム進め、
    /// 粒の状態を枠の順に返す。**寿命は尽きないだけ長く取る。**
    ///
    /// - Parameters:
    ///   - step: 1 フレームの長さ。省くと ``step`` (1/64 秒)。
    ///   - everyFrame: 各フレームを進めた直後の粒の状態を受け取る。1 つ目の引数は
    ///     進めたフレームの数 (1 始まり)。
    private func advance(
        _ releases: [Release], forces: [Force], frames: Int, step: Float = Self.step,
        everyFrame: ((Int, [Particle]) -> Void)? = nil
    ) throws -> [Particle] {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        canvas.deltaTime = step
        let total = releases.reduce(0) { $0 + $1.count }
        let dust = try canvas.makeParticles(count: total)
        var randomness = Randomness(seed: 1384)
        func state() -> [Particle] {
            canvas.read(dust.state).withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Particle.self).prefix(total))
            }
        }
        for frame in 0..<frames {
            try canvas.draw {
                if frame == 0 {
                    for release in releases {
                        // 1 フレームで `count` 個 (レートは毎秒の数)。**1 つ上の値に丸める** —
                        // 刻みが 2 のべきでないと count ÷ step × step が count にわずかに
                        // 届かず、端数として繰り越されて出ない (刻み 1/30 秒で 1 個 → 0 個)
                        canvas.emit(
                            dust, from: release.source,
                            rate: (Float(release.count) / step).nextUp,
                            speed: release.speed...release.speed,
                            angle: release.angle...release.angle, life: 100...100,
                            size: 1...1, color: .linear(red: 1, green: 1, blue: 1),
                            using: &randomness)
                    }
                }
                if !forces.isEmpty { canvas.force(dust, forces) }
                canvas.particles(dust)
            }
            everyFrame?(frame + 1, state())
        }
        let particles = state()
        // 出したはずの数が出ている (以降の照合の前提)
        try #require(particles.filter { $0.life > 0 }.count == total, "出した粒の数が合わない")
        return particles
    }

    private static func position(_ particle: Particle) -> SIMD3<Float> {
        SIMD3(particle.x, particle.y, particle.z)
    }

    private static func velocity(_ particle: Particle) -> SIMD3<Float> {
        SIMD3(particle.vx, particle.vy, particle.vz)
    }

    /// `drawn` が `expected` から相対 `tolerance` 以内にあるか。
    private static func close(
        _ drawn: SIMD3<Float>, _ expected: SIMD3<Double>, tolerance: Double = 1e-5
    ) -> Bool {
        simd_length(SIMD3<Double>(drawn) - expected) <= tolerance * simd_length(expected)
    }

    // MARK: - 重力と積分

    /// 完了条件 6 の前半 ([#1384])。速度 0 の粒 1 つに重力を掛け、N フレーム後の位置と速度を
    /// **CPU で書いた半陰的オイラー**と完全一致で比べる。
    ///
    /// 前進オイラー (位置を先に進める) なら位置は x₀ + g·Δt²·N(N − 1)/2 になり、半陰的
    /// オイラーの N(N + 1)/2 とは 1 フレームぶん (g·Δt²·N) ずれる。奥行き (z) にも効かせる。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("重力は、半陰的オイラーの積分どおりに粒を運ぶ")
    func gravityFollowsTheSemiImplicitEuler() throws {
        let start = SIMD3<Float>(20, 8, 0)
        let gravity = SIMD3<Float>(16, 64, -32)
        let frames = 12

        // CPU の積分 (単精度)。先に速度、進めた速度で位置
        var position = start
        var velocity = SIMD3<Float>(0, 0, 0)
        for _ in 0..<frames {
            velocity += gravity * Self.step
            position += velocity * Self.step
        }
        // **前提: 丸めなしで閉じている。** 倍精度の閉じた式と一致する
        let n = Double(frames)
        let dt = Double(Self.step)
        let closed = SIMD3<Double>(start) + SIMD3<Double>(gravity) * dt * dt * n * (n + 1) / 2
        try #require(SIMD3<Double>(position) == closed, "CPU の積分が丸めている — 値の選び方が悪い")
        try #require(SIMD3<Double>(velocity) == SIMD3<Double>(gravity) * dt * n)

        let particle = try advance(
            [Release(source: .point(start.x, start.y, start.z))],
            forces: [.gravity(gravity.x, gravity.y, gravity.z)], frames: frames)[0]
        #expect(Self.position(particle) == position, "\(Self.position(particle)) — 積分からは \(position)")
        #expect(Self.velocity(particle) == velocity, "\(Self.velocity(particle)) — 積分からは \(velocity)")
    }

    // MARK: - 減速

    /// 完了条件 6 ([#1384]) を [#1471] で書き換えたもの。**減速は、1 フレームごとに速度を
    /// e^{−amount·Δt} 倍にする** — n フレームなら e^{−n·amount·Δt} 倍。減速だけの粒で、
    /// 各フレームを倍精度の式と相対 1e-5 で比べる。
    ///
    /// **当初は (1 − amount·Δt) 倍**を、2 進で閉じる値 (127/128 倍ずつ) の完全一致で見ていた。
    /// それはいまの実装を写した約束で、刻みが粗いと 1 − amount·Δt が負になって速さが
    /// 増えた ([#1471])。3 フレームで (127/128)³ と e^{−3/128} は相対 1.9e-4 ずれるので、
    /// 1e-5 で見分けが付く。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    /// [#1471]: https://github.com/mokume-metal/mokume/issues/1471
    @Test("減速は、1 フレームごとに速度を e^{−amount·Δt} 倍にする")
    func dragScalesTheVelocityEachFrame() throws {
        let speed: Float = 32
        let amount: Float = 0.5
        let frames = 3
        var seen: [Int: SIMD3<Float>] = [:]
        _ = try advance(
            [Release(source: .point(8, 8), speed: speed, angle: 0)],
            forces: [.drag(amount)], frames: frames
        ) { frame, particles in seen[frame] = Self.velocity(particles[0]) }
        for frame in 1...frames {
            let expected = SIMD3<Double>(
                Double(speed) * exp(-Double(frame) * Double(amount) * Double(Self.step)), 0, 0)
            let drawn = try #require(seen[frame])
            #expect(
                Self.close(drawn, expected),
                "\(frame) フレーム目の速度 \(drawn) — 式からは \(expected)")
            #expect(drawn.y == 0 && drawn.z == 0, "減速が速度の向きを変えた: \(drawn)")
        }
    }

    /// [#1471] の完了条件 1。**どれだけ強い減速でも、速度の向きは変わらず、速さは増えない。**
    ///
    /// 減速だけの粒を amount·Δt が 1 を超える刻みで進め、毎フレーム見る:
    ///
    /// - 速度は出たときの向き (x の正) のまま — y・z は 0 で、x は負にならない
    /// - 速さは前のフレームより小さい (0 に届いたら 0 のまま)
    /// - 出た位置からの隔たりは v₀ ÷ amount を越えない。連続の解
    ///   x₀ + v₀/amount·(1 − e^{−amount·t}) が止まるまでに進む距離で、1 フレームごとに
    ///   e^{−amount·Δt} を掛ける進め方の総距離 v₀·Δt ÷ (e^{amount·Δt} − 1) はその内側にある
    ///
    /// 組は 2 つ。刻み 1/30・amount 70 は本文の再現 (1 − amount·Δt = −1.33)。刻み 1/6・
    /// amount 20 は、実時計の `deltaTime` が上限 (10 / fps — 60 fps で 1/6 秒) に当たった
    /// 1 枚に当たる (1 − amount·Δt = −2.33)。フレーム数を 12 に留めるのは、速さが
    /// 非正規数へ潰れて「毎フレーム小さくなる」が丸めで崩れる手前で止めるため
    /// (12 フレームで速さ 60 は 1e-10 を下回る程度)。
    ///
    /// [#1471]: https://github.com/mokume-metal/mokume/issues/1471
    @Test(
        "強い減速を粗い刻みで進めても、粒は向きを変えず、速さを増やさない",
        arguments: [(Float(1) / 30, Float(70)), (Float(1) / 6, Float(20))])
    func strongDragOnACoarseStepNeverOvershoots(step: Float, amount: Float) throws {
        let speed: Float = 60
        let start = SIMD3<Float>(8, 32, 0)
        let reach = speed / amount
        var previous = speed
        var frames: [Int] = []
        _ = try advance(
            [Release(source: .point(start.x, start.y), speed: speed, angle: 0)],
            forces: [.drag(amount)], frames: 12, step: step
        ) { frame, particles in
            frames.append(frame)
            let velocity = Self.velocity(particles[0])
            let away = simd_length(Self.position(particles[0]) - start)
            #expect(
                velocity.y == 0 && velocity.z == 0 && velocity.x >= 0,
                "\(frame) フレーム目の速度 \(velocity) — 出たときの向き (x の正) を外れた")
            #expect(
                velocity.x < previous || (previous == 0 && velocity.x == 0),
                "\(frame) フレーム目の速さ \(velocity.x) — 前のフレームは \(previous)")
            #expect(
                away <= reach,
                "\(frame) フレーム目: 出た位置から \(away) — 止まるまでに進む距離は \(reach)")
            previous = velocity.x
        }
        #expect(frames == Array(1...12))
    }

    /// [#1471] の完了条件 2。**減速だけの粒の 1 秒後の速さは、フレームレートに依らず
    /// v₀·e^{−amount}** — 説明が単位を「1 秒あたりに削る割合」で言っている以上、刻みで
    /// 変わってはいけない。刻み 1/32 で 32 フレームと、1/64 で 64 フレームを見る。
    ///
    /// 許す幅は相対 1e-4。Metal Shading Language Specification の精度の表 (「Numerical
    /// Compliance」の章・単精度) は `exp` を、fast math を切ると 4 ulp 以内、fast math
    /// (ライブラリの既定) では 3 + floor(|2x|) ulp 以内 — この引数 (|x| ≦ 1/8) では 3 ulp —
    /// とする。大きいほうの 4 ulp で見積もる。毎フレーム同じ引数 (−amount·Δt・2 進で閉じる)
    /// で同じ誤差を掛けるので、n フレームで相対 n × 4 ulp ≈ 64 × 4.8e-7 = 3.1e-5 まで積もり、
    /// 掛け算の丸め (1 回 0.5 ulp) を 64 回足しても 3.4e-5 である。1e-4 はその外側に取った。
    /// いまの式との違いはずっと大きい — amount 4 で (1 − 4/32)³² は e^{−4} の 0.76 倍、
    /// (1 − 4/64)⁶⁴ は 0.88 倍。
    ///
    /// [#1471]: https://github.com/mokume-metal/mokume/issues/1471
    @Test("減速だけの粒の 1 秒後の速さは、刻みに依らず v₀·e^{−amount} になる", arguments: [32, 64])
    func dragOverOneSecondDoesNotDependOnTheStep(framesPerSecond: Int) throws {
        let speed: Float = 32
        let amount: Float = 4
        let particle = try advance(
            [Release(source: .point(8, 32), speed: speed, angle: 0)],
            forces: [.drag(amount)], frames: framesPerSecond,
            step: 1 / Float(framesPerSecond))[0]
        let expected = SIMD3<Double>(Double(speed) * exp(-Double(amount)), 0, 0)
        let drawn = Self.velocity(particle)
        #expect(
            Self.close(drawn, expected, tolerance: 1e-4),
            "刻み 1/\(framesPerSecond) の 1 秒後の速度 \(drawn) — 式からは \(expected)")
    }

    /// [#1471] の完了条件 3。**減速は、足し合わせた加速度で進めた速度に掛かる**
    /// (v ← (v + a·Δt)·e^{−k·Δt})。静止した粒に重力 g と減速 amount を組んで 1 フレーム
    /// 進めると、速度は g·Δt·e^{−amount·Δt}、位置はその速度で進んだところになる。
    ///
    /// 掛けてから足す順 (v·e^{−k·Δt} + a·Δt) を取ると、静止した粒の速度は g·Δt のまま
    /// 減速が効かない — g 64・amount 8・刻み 1/64 なら e^{−1/8} ≈ 0.8825 に対して 1 で、
    /// 相対 1e-5 で見分けが付く。位置も見るのは、減速を掛ける前の速度で位置を進める
    /// 取り違えを外すため (y が 0.1175 / 64 ずれる)。
    ///
    /// [#1471]: https://github.com/mokume-metal/mokume/issues/1471
    @Test("減速は、ほかの力で進めた速度に掛かる")
    func dragScalesTheVelocityAdvancedByTheOtherForces() throws {
        let start = SIMD3<Float>(8, 8, 0)
        let gravity: Float = 64
        let amount: Float = 8
        let particle = try advance(
            [Release(source: .point(start.x, start.y))],
            forces: [.gravity(0, gravity), .drag(amount)], frames: 1)[0]
        let dt = Double(Self.step)
        let velocity = SIMD3<Double>(0, Double(gravity) * dt * exp(-Double(amount) * dt), 0)
        let position = SIMD3<Double>(start) + velocity * dt
        #expect(
            Self.close(Self.velocity(particle), velocity),
            "速度 \(Self.velocity(particle)) — 式からは \(velocity)")
        #expect(
            Self.close(Self.position(particle), position),
            "位置 \(Self.position(particle)) — 式からは \(position)")
    }

    // MARK: - 引く・押す

    /// 完了条件 6 ([#1384])。**引く力は、粒から 1 点への向きへ大きさ strength の加速度**で、
    /// 距離に依らない。1 フレーム後の速度は strength·Δt·(P − x)/|P − x|。遠ざける力は
    /// その符号を返したもの。
    ///
    /// 近い粒 (距離 14) と遠い粒 (距離 56) を奥行きを含む別々の向きに置き、どちらも同じ式で
    /// 照合する — 距離で弱まる実装や、向きを取り違えた実装はここで外れる。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test(
        "引く力・押す力は、1 点への向きへ距離に依らない大きさで効く",
        arguments: [("attract", Float(1)), ("repel", Float(-1))])
    func attractionPointsAtTheTargetWithAFixedStrength(name: String, sign: Float) throws {
        let target = SIMD3<Float>(32, 32, 0)
        let strength: Float = 48
        // 長さ 7 の組 (2, 3, 6) と (6, −2, 3) を 2 倍・8 倍して、距離 14 と 56
        let places = [target - SIMD3(2, 3, 6) * 2, target + SIMD3(6, -2, 3) * 8]
        let force: Force =
            sign > 0
            ? .attract(target.x, target.y, target.z, strength: strength)
            : .repel(target.x, target.y, target.z, strength: strength)

        let particles = try advance(
            places.map { Release(source: .point($0.x, $0.y, $0.z)) }, forces: [force], frames: 1)
        for (place, particle) in zip(places, particles) {
            let toward = SIMD3<Double>(target - place)
            let expected =
                toward / simd_length(toward) * Double(sign * strength) * Double(Self.step)
            let drawn = Self.velocity(particle)
            #expect(
                Self.close(drawn, expected),
                "\(name): \(place) からの速度 \(drawn) — 式からは \(expected)")
        }
    }

    // MARK: - 回す

    /// 完了条件 6 ([#1384])。**回す力は、中心から粒への向き (画面の面内) を x から y へ
    /// 90° 回した向きへ、大きさ strength の加速度**で、距離に依らず奥行きには効かない。
    /// 1 フレーム後の速度は strength·Δt·(−dy, dx, 0)/|(dx, dy)|。
    ///
    /// 粒を奥行きの違う 2 か所に置く — 回す向きが面内の位置だけで決まり、z が混ざらないこと
    /// まで見る。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("回す力は、中心からの向きを x から y へ 90° 回した向きに、距離に依らない大きさで効く")
    func swirlTurnsAQuarterFromTheCentre() throws {
        let centre = SIMD2<Float>(32, 32)
        let strength: Float = 40
        // (3, 4) を 2 倍 (距離 10・手前) と、(−12, 5) を 2 倍 (距離 26・奥)
        let places = [
            SIMD3<Float>(centre.x + 6, centre.y + 8, 10),
            SIMD3<Float>(centre.x - 24, centre.y + 10, -30),
        ]
        let particles = try advance(
            places.map { Release(source: .point($0.x, $0.y, $0.z)) },
            forces: [.swirl(centre.x, centre.y, strength: strength)], frames: 1)
        for (place, particle) in zip(places, particles) {
            let away = SIMD2<Double>(Double(place.x - centre.x), Double(place.y - centre.y))
            let turned = SIMD3<Double>(-away.y, away.x, 0) / simd_length(away)
            let expected = turned * Double(strength) * Double(Self.step)
            let drawn = Self.velocity(particle)
            #expect(Self.close(drawn, expected), "\(place) の速度 \(drawn) — 式からは \(expected)")
            #expect(particle.vz == 0, "回す力が奥行きに効いた")
        }
    }

    // MARK: - 揺らす

    /// 完了条件 6 ([#1384])。**揺らす力は、各成分 (x・y・z) が −strength…strength の一様な
    /// 値の加速度**で、粒ごとに違う。乱数を使うので値そのものは照合できず、分布の不変条件で
    /// 見る。
    ///
    /// strength を 1/Δt に取ると、1 フレーム後の速度の各成分がそのまま −1…1 の揺れになる
    /// (2 のべきを掛けるだけなので丸めは入らない)。4096 粒で:
    ///
    /// - **どの成分も ±1 を越えない** (上限は丸めなしで成り立つ)
    /// - 各成分の平均は 0 に近い (標準誤差 0.009 の 5 倍の 0.05 以内)
    /// - 各成分の分散は一様分布の 1/3 に近い (±10% — 標準誤差の 7 倍)
    /// - 奥行きにも効く・粒ごとに違う
    ///
    /// 列は種から決まるので、何度走らせても同じ値になる (揺れで落ちたり通ったりはしない)。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("揺らす力は、各成分が −strength…strength の一様な揺れになる")
    func wanderStaysWithinItsStrength() throws {
        let count = 4096
        let particles = try advance(
            [Release(source: .point(32, 32), count: count)],
            forces: [.wander(strength: 1 / Self.step)], frames: 1)
        let velocities = particles.map(Self.velocity)

        let beyond = velocities.filter { simd_abs($0).max() > 1 }
        #expect(beyond.isEmpty, "±strength を越えた粒が \(beyond.count) 個: \(beyond.prefix(3))")

        for axis in 0..<3 {
            let values = velocities.map { Double($0[axis]) }
            let mean = values.reduce(0, +) / Double(count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(count)
            #expect(abs(mean) < 0.05, "成分 \(axis) の平均 \(mean)")
            #expect(abs(variance - 1.0 / 3) < 1.0 / 30, "成分 \(axis) の分散 \(variance)")
        }
        #expect(Set(velocities.map { $0.x }).count > count * 9 / 10, "粒ごとに揺れが違っていない")
    }

    // MARK: - 噴き口

    /// 速度 0 で出した粒の位置。**1 フレーム進めても動かない** (速度 0・力なし)。
    private func emittedPlaces(from source: Emitter, count: Int = 4096) throws -> [SIMD3<Float>] {
        try advance([Release(source: source, count: count)], forces: [], frames: 1)
            .map(Self.position)
    }

    /// 比率 `fraction` が期待 `expected` の `margin` 以内か。4096 個の割合の標準誤差は
    /// 1/2 で 0.008・1/4 で 0.007・1/8 で 0.005 なので、margin はその 4〜5 倍に取る。
    private static func fraction(
        _ places: [SIMD3<Float>], where predicate: (SIMD3<Float>) -> Bool
    ) -> Double {
        Double(places.filter(predicate).count) / Double(places.count)
    }

    /// 完了条件 7 ([#1384])。**円は面内の内側から、どこも同じ確からしさで出る** (`Emitter`
    /// の doc)。中心から r 以内・z は 0。面積が同じ確からしさなら、半径 r/2 の内側に入るのは
    /// 面積比の 1/4 — 半径をそのまま引く (平方根を取らない) と中心へ寄って 1/2 になる。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("円からは、面内の円の内側だけに、どこも同じ確からしさで出る")
    func circleEmitsInsideTheDiscUniformly() throws {
        let (centre, radius) = (SIMD2<Float>(40, 24), Float(16))
        let places = try emittedPlaces(from: .circle(centre.x, centre.y, radius: radius))
        func distance(_ p: SIMD3<Float>) -> Float { simd_length(SIMD2(p.x, p.y) - centre) }

        let outside = places.filter { distance($0) > radius * (1 + 1e-5) }
        #expect(outside.isEmpty, "円の外に \(outside.count) 個: \(outside.prefix(3))")
        #expect(places.allSatisfy { $0.z == 0 }, "円から出た粒が面を外れた")

        let inner = Self.fraction(places) { distance($0) <= radius / 2 }
        #expect(abs(inner - 0.25) < 0.03, "半径の半分の内側に \(inner) — 面積比は 1/4")
        let right = Self.fraction(places) { $0.x > centre.x }
        #expect(abs(right - 0.5) < 0.04, "中心より右に \(right)")
    }

    /// 完了条件 7 ([#1384])。**線分からは、線分の上に、どこも同じ確からしさで出る。**
    /// 線からの隔たりは 0 (単精度の丸め 1e-4 画素まで)、線分に沿った位置 t は 0…1、前半に
    /// 入るのは半分。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("線分からは、線分の上だけに、どこも同じ確からしさで出る")
    func lineEmitsAlongTheSegmentUniformly() throws {
        let (from, to) = (SIMD2<Float>(4, 10), SIMD2<Float>(60, 50))
        let places = try emittedPlaces(from: .line(from.x, from.y, to.x, to.y))
        let along = to - from
        func offLine(_ p: SIMD3<Float>) -> Float {
            let d = SIMD2(p.x, p.y) - from
            return abs(d.x * along.y - d.y * along.x) / simd_length(along)
        }
        func t(_ p: SIMD3<Float>) -> Float {
            simd_dot(SIMD2(p.x, p.y) - from, along) / simd_length_squared(along)
        }

        let off = places.filter { offLine($0) > 1e-4 }
        #expect(off.isEmpty, "線分を外れた粒が \(off.count) 個: \(off.prefix(3))")
        let beyond = places.filter { t($0) < -1e-5 || t($0) > 1 + 1e-5 }
        #expect(beyond.isEmpty, "線分の端を越えた粒が \(beyond.count) 個: \(beyond.prefix(3))")
        #expect(places.allSatisfy { $0.z == 0 }, "線分から出た粒が面を外れた")

        let front = Self.fraction(places) { t($0) < 0.5 }
        #expect(abs(front - 0.5) < 0.04, "線分の前半に \(front)")
    }

    /// 完了条件 7 ([#1384])。**球からは、球の内側から、どこも同じ確からしさで出る。**
    /// 中心から r 以内で、体積が同じ確からしさなら半径 r/2 の内側に入るのは体積比の 1/8
    /// (半径を 3 乗根で引かないと中心へ寄る)。奥行き (z) にも散る。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("球からは、球の内側だけに、どこも同じ確からしさで出る")
    func sphereEmitsInsideTheBallUniformly() throws {
        let (centre, radius) = (SIMD3<Float>(32, 32, -10), Float(12))
        let places = try emittedPlaces(
            from: .sphere(centre.x, centre.y, centre.z, radius: radius))
        func distance(_ p: SIMD3<Float>) -> Float { simd_length(p - centre) }

        let outside = places.filter { distance($0) > radius * (1 + 1e-5) }
        #expect(outside.isEmpty, "球の外に \(outside.count) 個: \(outside.prefix(3))")

        let inner = Self.fraction(places) { distance($0) <= radius / 2 }
        #expect(abs(inner - 0.125) < 0.025, "半径の半分の内側に \(inner) — 体積比は 1/8")
        for axis in 0..<3 {
            let above = Self.fraction(places) { $0[axis] > centre[axis] }
            #expect(abs(above - 0.5) < 0.04, "成分 \(axis) で中心より大きい側に \(above)")
        }
    }
}
