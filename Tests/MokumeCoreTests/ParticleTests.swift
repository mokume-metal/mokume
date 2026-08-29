// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 粒のうち、時間の方向にしか現れないもの。**GPU は要らない。**
///
/// ここに集めてあるのは「1 枚の絵では絶対に出ない」種類の正しさである。端数の繰り越しが
/// その代表で、低いレートで数百フレーム回して初めて「放出が消える」が見える。
@Suite("粒の出しかた")
struct ParticleEmissionTests {
    @Test("低いレートでも、長い目で見て頼んだ数が出る")
    func carriesTheFractionSoLowRatesStillEmit() {
        // **1 フレームだけ見ると 0 個。** 切り捨てる作りだと、ここが永久に 0 のままになる
        var single = EmissionCadence()
        #expect(single.take(rate: 0.5, over: 1.0 / 60, upTo: 1000) == 0)

        // 毎秒 0.5 個を 10 秒ぶん (600 フレーム) 回せば 5 個
        var cadence = EmissionCadence()
        var total = 0
        for _ in 0..<600 { total += cadence.take(rate: 0.5, over: 1.0 / 60, upTo: 1000) }
        #expect(total == 5)
    }

    @Test("高いレートでも、出る数はレートどおり")
    func emitsWhatTheRateAsksFor() {
        var cadence = EmissionCadence()
        var total = 0
        for _ in 0..<60 { total += cadence.take(rate: 90, over: 1.0 / 60, upTo: 1000) }
        #expect(total == 90)
    }

    @Test("1 フレームで枠を超える注文は、繰り越さずに切る")
    func doesNotCarryBeyondTheCapacity() {
        var cadence = EmissionCadence()
        #expect(cadence.take(rate: 100_000, over: 1, upTo: 10) == 10)
        // **貯め込まない。** 貯めると、レートを下げたあとも出続ける
        #expect(cadence.carried == 0)
        #expect(cadence.take(rate: 0, over: 1, upTo: 10) == 0)
    }

    @Test("進まない時間・出ないレートでは、何も出ない")
    func emitsNothingWithoutRateOrTime() {
        var cadence = EmissionCadence()
        #expect(cadence.take(rate: 0, over: 1.0 / 60, upTo: 10) == 0)
        #expect(cadence.take(rate: 60, over: 0, upTo: 10) == 0)
        #expect(cadence.take(rate: .infinity, over: 1.0 / 60, upTo: 10) == 0)
    }

    @Test("遠ざける力は、引く力の符号を返したもの")
    func repelIsAttractWithTheSignFlipped() {
        // 枝を 2 本持たない。名前が 2 つあるだけ
        #expect(Force.repel(3, 4, strength: 5) == .attract(3, 4, strength: -5))
    }

    @Test("力の並びは、先頭が種類")
    func packsTheKindFirst() {
        #expect(Force.gravity(1, 2, 3).packed == [0, 1, 2, 3, 0, 0, 0, 0])
        #expect(Force.attract(1, 2, strength: 9).packed == [1, 1, 2, 0, 9, 0, 0, 0])
        #expect(Force.wander(strength: 9).packed == [2, 0, 0, 0, 9, 0, 0, 0])
        #expect(Force.swirl(1, 2, strength: 9).packed == [3, 1, 2, 0, 9, 0, 0, 0])
        #expect(Force.drag(9).packed == [4, 0, 0, 0, 9, 0, 0, 0])
        // 幅が揃っていないと、2 つめ以降の力が別の力として読まれる
        #expect(Force.gravity(0, 0).packed.count == Force.slotCount)
    }
}

/// 粒。GPU を要する。
@Suite(
    "粒",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ParticleTests {
    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 絵の指紋。**食い違ったときに画素が丸ごと並ばない**ようにするため、比べるのは
    /// 数万個の数ではなくこの 1 本にする。
    private func fingerprint(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// 絵のいちばん明るいところ。**不透明度の桁は見ない** — 背景が不透明なので、
    /// 4 つおきの桁は常に 255 になり、そのまま見ると「何か写っている」と読めてしまう。
    private func brightest(_ bytes: [UInt8]) -> UInt8 {
        var peak: UInt8 = 0
        for (index, value) in bytes.enumerated() where index % 4 != 3 {
            peak = max(peak, value)
        }
        return peak
    }

    /// 1 フレームぶんの絵と動きを回す。
    private func spray(
        on canvas: Canvas, _ dust: Particles, randomness: inout Randomness, frames: Int
    ) throws {
        for _ in 0..<frames {
            var stream = randomness
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.emit(
                    dust, from: .point(32, 12), rate: 600, speed: 20...45,
                    angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                    color: .opaque(red: 1, green: 0.6, blue: 0.2), using: &stream)
                canvas.force(dust, [.gravity(0, 60), .drag(0.5)])
                canvas.particles(dust)
            }
            randomness = stream
        }
    }

    // MARK: - 配置

    /// **CPU と GPU が同じ配置を見ていることを、機械で守る** (親 #385 の条件 3)。
    ///
    /// 大きさを両側に手で書いて突き合わせる形では、両方が同時にずれたときに黙って通る。
    /// ここは GPU 自身に「自分の見ている項目」を名前で書かせ、CPU が数の並びとして
    /// 読み比べる — 順序が入れ替わっても・項目が増減しても・間隔が違っても落ちる。
    @Test("粒と置き場所の配置が、CPU と GPU で一致する")
    func agreesOnTheLayoutWithTheGPU() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        let probe = try canvas.makeComputation(
            gpu.bundledShaderSource(named: Canvas.particleShaderName),
            name: Canvas.particleLayoutKernelName)
        let particleProbe = try canvas.makeNumbers(count: 64)
        let placeProbe = try canvas.makeNumbers(count: 128)

        var particleValues: [Float] = []
        var placeValues: [Float] = []
        try canvas.draw {
            canvas.compute(probe, over: 1, writes: [particleProbe, placeProbe])
            particleValues = canvas.read(particleProbe)
            placeValues = canvas.read(placeProbe)
        }

        // 粒。GPU は項目へ 1…14 を名前で入れた
        let particleFloats = MemoryLayout<Particle>.stride / MemoryLayout<Float>.stride
        #expect(
            Array(particleValues[0..<particleFloats])
                == (1...particleFloats).map { Float($0) })
        // 2 つめの先頭。**間隔がずれれば、この値の居場所がずれる**
        #expect(particleValues[particleFloats] == 101)
        // CPU 側も、同じ並びを項目として読めている
        let particle = particleValues.withUnsafeBytes { $0.load(as: Particle.self) }
        #expect(particle.x == 1)
        #expect(particle.vx == 4)
        #expect(particle.life == 7)
        #expect(particle.alpha == 13)
        #expect(particle.seed == 14)

        // 置き場所
        let placeFloats = MemoryLayout<SolidInstance>.stride / MemoryLayout<Float>.stride
        #expect(Array(placeValues[0..<placeFloats]) == (0..<placeFloats).map { Float($0) })
        #expect(placeValues[placeFloats] == 100)
        #expect(placeFloats * MemoryLayout<Float>.stride == SolidInstance.expectedStride)
    }

    // MARK: - 2 つの経路

    @Test("速い経路と参照の経路は、同じ絵を出す")
    func bothRoutesDrawTheSamePicture() throws {
        func picture(_ route: Canvas.ParticleRoute) throws -> [UInt8] {
            let canvas = try makeCanvas()
            canvas.particleRoute = route
            var randomness = Randomness(seed: 20_260_829)
            let dust = try canvas.makeParticles(count: 256)
            try spray(on: canvas, dust, randomness: &randomness, frames: 10)
            return try canvas.target.encodeForDisplay().bytes
        }

        let fast = try picture(.instanced)
        let reference = try picture(.reference)
        // 何も描けていないと「同じ」も成り立ってしまうので、粒が出ていることを先に見る
        #expect(brightest(fast) > 32)
        #expect(fingerprint(fast) == fingerprint(reference))
    }

    @Test("速い経路は、粒を読み戻さない")
    func theFastRouteNeverReadsBack() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 3)
        let dust = try canvas.makeParticles(count: 128)
        try spray(on: canvas, dust, randomness: &randomness, frames: 5)
        #expect(dust.state.readbackAllocations == 0)
    }

    // MARK: - 動きそのもの

    @Test("同じ入力からは、2 回とも同じ列が出る")
    func drawsTheSameSeriesTwice() throws {
        func series() throws -> [String] {
            let canvas = try makeCanvas()
            var randomness = Randomness(seed: 91)
            let dust = try canvas.makeParticles(count: 200)
            var frames: [String] = []
            for _ in 0..<6 {
                try spray(on: canvas, dust, randomness: &randomness, frames: 1)
                frames.append(fingerprint(try canvas.target.encodeForDisplay().bytes))
            }
            return frames
        }

        let first = try series()
        let second = try series()
        // 列そのものが動いていること (全部同じ絵なら、一致しても意味が無い)
        #expect(Set(first).count == first.count)
        #expect(first == second)
    }

    @Test("寿命が尽きた粒は、1 画素も出さない")
    func drawsNothingOnceTheLifeIsSpent() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 5)
        let dust = try canvas.makeParticles(count: 16)

        func advance(emitting: Bool) throws -> [UInt8] {
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                if emitting {
                    canvas.emit(
                        dust, from: .point(32, 32), rate: 60, speed: 0...0,
                        angle: 0...0, life: 0.05...0.05, size: 24...24,
                        color: .opaque(red: 1, green: 1, blue: 1), using: &randomness)
                }
                canvas.particles(dust)
            }
            return try canvas.target.encodeForDisplay().bytes
        }

        let lit = try advance(emitting: true)
        #expect(brightest(lit) > 200)

        // 0.05 秒ぶん進めれば尽きる (1 フレーム 60 分の 1 秒)
        var spent: [UInt8] = []
        for _ in 0..<4 { spent = try advance(emitting: false) }
        #expect(brightest(spent) <= 8)
    }

    // MARK: - 断る・積み上げない

    @Test("持てない数の指定は、確保の失敗として返る")
    func refusesACountItCannotHold() throws {
        let canvas = try makeCanvas()
        // 数え切れない (掛け算が回り込む)
        #expect(throws: RenderFailure.self) { try canvas.makeParticles(count: Int.max) }
        // 数えられるが確保できない
        #expect(throws: RenderFailure.self) {
            try canvas.makeParticles(count: 2_000_000_000)
        }
        // **途中で止まらない。** 断ったあとも普通に使える
        let dust = try canvas.makeParticles(count: 8)
        #expect(dust.capacity == 8)
    }

    @Test("枠をひと回りして生きている粒を上書きしたら、理由を知らせる")
    func tellsWhenItOverwritesALivingParticle() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 11)
        let dust = try canvas.makeParticles(count: 4)

        // 枠 4 個に、長生きする粒を 4 個。ここではまだ上書きしていない
        try canvas.draw {
            canvas.emit(
                dust, from: .point(32, 32), rate: 240, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
        }
        #expect(!dust.warnedOverwrite)

        try canvas.draw {
            canvas.emit(
                dust, from: .point(32, 32), rate: 60, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
        }
        #expect(dust.warnedOverwrite)
    }

    @Test("効かせられる数を超えた力は、断って知らせる")
    func refusesMoreForcesThanItCanApply() throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        try canvas.draw {
            for _ in 0..<(Particles.maximumForces + 2) {
                canvas.force(dust, [.drag(0.1)])
            }
        }
        #expect(dust.warnedTooManyForces)
    }

    @Test("長く回しても、置き場の確保が積み上がらない")
    func doesNotGrowWhileItRuns() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 17)
        let dust = try canvas.makeParticles(count: 512)

        try spray(on: canvas, dust, randomness: &randomness, frames: 1)
        let tables = try canvas.computePipeline().tablesBuilt

        try spray(on: canvas, dust, randomness: &randomness, frames: 200)
        // **単発では出ない。** 毎フレーム確保していれば、ここで増える
        #expect(try canvas.computePipeline().tablesBuilt == tables)
        #expect(dust.state.readbackAllocations == 0)
        // 1 フレームに開く口は 1 つ (頼んでいる計算が 1 つなので)
        #expect(canvas.computeEncodersOpened == 201)
        #expect(canvas.computeEncodersClosed == canvas.computeEncodersOpened)
    }

    @Test("描くところの外から扱っても、何も起きない")
    func ignoresParticlesOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        canvas.particles(dust)
        #expect(canvas.warnedParticlesOutsideFrame)
        #expect(canvas.computeEncodersOpened == 0)
    }
}
