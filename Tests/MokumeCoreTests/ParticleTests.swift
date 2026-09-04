// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Metal
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

    /// 生存数を数える段は容量から一意に決まる。**GPU は要らない** — 段の数がそのまま
    /// 1 フレームに積む計算の数になるので、ここで形を固定する。
    @Test("数える段は、256 で割り上げて 1 になるまで重ねる")
    func stacksScanLevelsUntilOneRemains() {
        #expect(Particles.levelLengths(capacity: 1) == [1])
        #expect(Particles.levelLengths(capacity: 256) == [256, 1])
        // 区画を 1 つ超えた瞬間に段が 1 つ増える
        #expect(Particles.levelLengths(capacity: 257) == [257, 2, 1])
        #expect(Particles.levelLengths(capacity: 1_000_000) == [1_000_000, 3907, 16, 1])
        // 0 以下は 1 個として扱う (makeParticles と同じ丸め)
        #expect(Particles.levelLengths(capacity: 0) == [1])
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
        on canvas: Canvas, _ dust: Particles, randomness: inout Randomness, frames: Int,
        rate: Float = 600
    ) throws {
        for _ in 0..<frames {
            var stream = randomness
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.emit(
                    dust, from: .point(32, 12), rate: rate, speed: 20...45,
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
        let argumentProbe = try canvas.makeNumbers(count: 8)

        var particleValues: [Float] = []
        var placeValues: [Float] = []
        var argumentValues: [Float] = []
        try canvas.draw {
            canvas.compute(probe, over: 1, writes: [particleProbe, placeProbe, argumentProbe])
            particleValues = canvas.read(particleProbe)
            placeValues = canvas.read(placeProbe)
            argumentValues = canvas.read(argumentProbe)
        }

        // 描く引数。GPU は項目へ 1…4 を名前で入れた。Metal 自身の構造体として読めること
        let argumentWords = argumentValues.map(\.bitPattern)
        #expect(Array(argumentWords[0..<4]) == [1, 2, 3, 4])
        let arguments = argumentValues.withUnsafeBytes {
            $0.load(as: MTLDrawPrimitivesIndirectArguments.self)
        }
        #expect(arguments.vertexCount == 1)
        #expect(arguments.instanceCount == 2)
        #expect(arguments.vertexStart == 3)
        #expect(arguments.baseInstance == 4)
        #expect(
            MemoryLayout<MTLDrawPrimitivesIndirectArguments>.stride
                == Particles.argumentFloats * MemoryLayout<Float>.stride)
        // 2 つめの先頭はスキャンの区画の大きさ。**両側に手で書いた定数がここで突き合わさる**
        #expect(Int(argumentWords[4]) == Particles.scanBlock)

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

    /// 容量は数える段の数が変わるところを踏む: 1 (段 0)・256 (段 1)・257 (段 2)・
    /// 70000 (段 3)。最後は枠を全部使って出すので、区画をまたぐ順位の足し上げが絵に出る。
    @Test(
        "速い経路と参照の経路は、同じ絵を出す",
        arguments: [(1, Float(600)), (256, 600), (257, 600), (70_000, 4_000_000)])
    func bothRoutesDrawTheSamePicture(capacity: Int, rate: Float) throws {
        func picture(_ route: Canvas.ParticleRoute) throws -> [UInt8] {
            let canvas = try makeCanvas()
            canvas.particleRoute = route
            var randomness = Randomness(seed: 20_260_829)
            let dust = try canvas.makeParticles(count: capacity)
            try spray(on: canvas, dust, randomness: &randomness, frames: 10, rate: rate)
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

    // MARK: - 描く個数は GPU が決める

    /// GPU が書いた描く引数を読む。`UInt32` のビット列で置かれているのでそのまま読み替える。
    private func drawArguments(of dust: Particles, on canvas: Canvas) -> (
        vertexCount: Int, instanceCount: Int, vertexStart: Int, baseInstance: Int
    ) {
        let words = canvas.read(dust.arguments).map { Int($0.bitPattern) }
        return (words[0], words[1], words[2], words[3])
    }

    /// 1 フレームで `count` 個を寿命 `life` で出して進める。0 なら進めるだけ。
    private func emitBatch(
        on canvas: Canvas, _ dust: Particles, count: Int, life: Float,
        randomness: inout Randomness
    ) throws {
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            if count > 0 {
                canvas.emit(
                    dust, from: .point(32, 32), rate: Float(count) * 60, speed: 0...10,
                    angle: 0...(2 * Float.pi), life: life...life, size: 2...4,
                    color: .opaque(red: 1, green: 0.5, blue: 0.2), using: &randomness)
            }
            canvas.particles(dust)
        }
    }

    /// **描く数が容量ではなく生存数であること**と、**詰める順が枠の番号順であること**
    /// (#760)。順序が固定でないと、半透明の粒の重なりが毎フレーム動いて絵が動く。
    ///
    /// 容量は段の数が 2 と 3 のところを踏む。並びは 長生き 1 割 → すぐ尽きる 4 割 →
    /// 長生き 1 割 で、中抜けがあり、区画 (256) の境もまたぐ。
    @Test("描く個数は容量ではなく生存数で、詰める順は枠の番号順", arguments: [1000, 70_000])
    func drawsOnlyTheLivingInSlotOrder(capacity: Int) throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 760)
        let dust = try canvas.makeParticles(count: capacity)
        let tenth = capacity / 10
        try emitBatch(on: canvas, dust, count: tenth, life: 100, randomness: &randomness)
        try emitBatch(on: canvas, dust, count: tenth * 4, life: 0.02, randomness: &randomness)
        try emitBatch(on: canvas, dust, count: tenth, life: 100, randomness: &randomness)
        // 短い寿命が尽きるまで進める
        for _ in 0..<3 {
            try emitBatch(on: canvas, dust, count: 0, life: 1, randomness: &randomness)
        }

        let living = dust.living(from: canvas.read(dust.state))
        #expect(living.count == tenth * 2)
        let arguments = drawArguments(of: dust, on: canvas)
        #expect(arguments.instanceCount == living.count)
        #expect(arguments.vertexCount == dust.quad.runs.first?.count)
        #expect(arguments.baseInstance == 0)

        // 詰めた置き場所は、枠の番号順に読んだ生きている粒と 1 つずつ一致する。
        // 行列の 4 列目が位置、[0][0] が大きさ (変換は単位行列なので値がそのまま出る)
        let places = canvas.read(dust.instances)
        let placeFloats = MemoryLayout<SolidInstance>.stride / MemoryLayout<Float>.stride
        var mismatched = 0
        for (index, particle) in living.enumerated() {
            let base = index * placeFloats
            if places[base] != particle.scale || places[base + 12] != particle.x
                || places[base + 13] != particle.y || places[base + 15] != 1
            {
                mismatched += 1
            }
        }
        #expect(mismatched == 0)
    }

    /// 生存 0 は詰めた並びが空になる端で、描く個数 0 の indirect draw が通ることを見る。
    @Test("生きている粒が 1 つも無いフレームは、描く個数 0 で通る", arguments: [1, 300])
    func drawsNothingWhenNothingLives(capacity: Int) throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 0)
        let dust = try canvas.makeParticles(count: capacity)

        // 何も出していない
        try emitBatch(on: canvas, dust, count: 0, life: 1, randomness: &randomness)
        #expect(drawArguments(of: dust, on: canvas).instanceCount == 0)
        #expect(brightest(try canvas.target.encodeForDisplay().bytes) <= 8)

        // 出したものが全部尽きたあとも同じ
        try emitBatch(
            on: canvas, dust, count: min(capacity, 100), life: 0.02, randomness: &randomness)
        #expect(drawArguments(of: dust, on: canvas).instanceCount == min(capacity, 100))
        for _ in 0..<3 {
            try emitBatch(on: canvas, dust, count: 0, life: 1, randomness: &randomness)
        }
        #expect(drawArguments(of: dust, on: canvas).instanceCount == 0)
        #expect(brightest(try canvas.target.encodeForDisplay().bytes) <= 8)
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
        #expect(!dust.warnings.hasWarned(.overwrite))

        try canvas.draw {
            canvas.emit(
                dust, from: .point(32, 32), rate: 60, speed: 0...0, angle: 0...0,
                life: 10...10, size: 2...2, color: nil, using: &randomness)
        }
        #expect(dust.warnings.hasWarned(.overwrite))
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
        #expect(dust.warnings.hasWarned(.tooManyForces))
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
        // 1 フレームに開く口は積む計算の数 (旗 1 + 段 2 + 進める 1)。どれも前の計算が
        // 書いた並びに触れるので、1 つずつ口が切れる
        #expect(dust.dispatchCount == 4)
        #expect(canvas.computeEncodersOpened == 201 * dust.dispatchCount)
        #expect(canvas.computeEncodersClosed == canvas.computeEncodersOpened)
    }

    @Test("描くところの外から扱っても、何も起きない")
    func ignoresParticlesOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 4)
        canvas.particles(dust)
        #expect(canvas.warnings.hasWarned(.particlesOutsideFrame))
        #expect(canvas.computeEncodersOpened == 0)
    }
}
