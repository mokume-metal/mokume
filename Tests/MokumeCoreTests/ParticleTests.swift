// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Metal
import Testing
import simd

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
        #expect(single.take(rate: 0.5, over: .frame(perSecond: 60), upTo: 1000) == 0)

        // 毎秒 0.5 個を 10 秒ぶん (600 フレーム) 回せば 5 個
        var cadence = EmissionCadence()
        var total = 0
        for _ in 0..<600 { total += cadence.take(rate: 0.5, over: .frame(perSecond: 60), upTo: 1000) }
        #expect(total == 5)

        // 秒で数える刻み (実時間の時計・直に回す面) でも同じ
        var bySeconds = EmissionCadence()
        var secondsTotal = 0
        for _ in 0..<600 {
            secondsTotal += bySeconds.take(rate: 0.5, over: .seconds(Double(Float(1.0 / 60))), upTo: 1000)
        }
        #expect(secondsTotal == 5)
    }

    @Test("高いレートでも、出る数はレートどおり")
    func emitsWhatTheRateAsksFor() {
        var cadence = EmissionCadence()
        var total = 0
        for _ in 0..<60 { total += cadence.take(rate: 90, over: .frame(perSecond: 60), upTo: 1000) }
        #expect(total == 90)
    }

    /// フレーム番号から導く時計 (`fps`) が 1 枚ごとに渡す刻みで、`rate` の `emit` を
    /// `frames` 枚数え、各枚までの累計を返す。**刻みは時計から受け取る** — 手で 1/fps を
    /// 書くと、時計と数える側の間の受け渡しの丸めを飛ばしてしまう。
    private func cumulativeCounts(rate: Float, fps: Int, frames: Int) -> [Int] {
        let timing = FrameTiming(clock: .frameIndex(frameRate: fps), now: { 0 })
        var cadence = EmissionCadence()
        var total = 0
        var totals: [Int] = []
        for _ in 0..<frames {
            timing.advance()
            total += cadence.take(rate: rate, over: timing.step, upTo: 1_000_000)
            totals.append(total)
        }
        return totals
    }

    /// [#1640] の完了条件 1。**毎秒 fps 個を fps 枚回せば fps 個出て、1 枚目に 1 個出る。**
    /// fps 1…120 のすべてで見る。刻みを単精度で渡していた頃は、`Float(1/fps)` が 1/fps
    /// より小さくなる 33 の fps (25・50・100 …) で、合計が fps − 1 個・1 枚目が 0 個だった。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    @Test("フレーム番号の時計のどの fps でも、毎秒 fps 個を 1 秒回せば fps 個出て、1 枚目に 1 個出る")
    func emitsTheRatePerSecondAtEveryFrameRate() {
        var broken: [String] = []
        for fps in 1...120 {
            let totals = cumulativeCounts(rate: Float(fps), fps: fps, frames: fps)
            if totals.first != 1 || totals.last != fps {
                broken.append("fps \(fps): 1 枚目 \(totals.first ?? -1) 個・合計 \(totals.last ?? -1) 個")
            }
        }
        #expect(broken.isEmpty, "頼んだ数どおりに出ない fps が \(broken.count) 個: \(broken)")
    }

    /// [#1640] の完了条件 2。**不足も超過もしない** — `n` 枚目までの累計が、有理数で計算した
    /// ⌊rate·n ÷ fps⌋ に等しい。`rate` は fps の倍数でないもの (0.5・10) と fps。**これらの
    /// rate の端数は整数から十分離れているので、丸めに遊びを持たせる作りの超過はここでは
    /// 出ない** — 超過は次の `fractionalRatesNeitherRunOverNorFallShort` が見る (#1640 の反証 2)。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    @Test("刻みの揃った時計では、何枚目までの累計も ⌊rate·n ÷ fps⌋ に等しい")
    func cumulativeCountsNeverFallShortNorRunOver() {
        var broken: [String] = []
        for fps in 1...120 {
            // rate = numerator ÷ denominator (どれも単精度で厳密に表せる)
            for (numerator, denominator) in [(1, 2), (10, 1), (fps, 1)] {
                let rate = Float(numerator) / Float(denominator)
                let totals = cumulativeCounts(rate: rate, fps: fps, frames: 2 * fps)
                for (index, total) in totals.enumerated() {
                    let n = index + 1
                    let expected = numerator * n / (denominator * fps)
                    if total != expected {
                        broken.append("fps \(fps)・rate \(rate)・\(n) 枚目: \(total) 個 (頼んだ数 \(expected))")
                        break
                    }
                }
            }
        }
        #expect(broken.isEmpty, "累計が頼んだ数と違う組が \(broken.count) 個: \(broken.prefix(12))")
    }

    /// ⌊`rate`·n ÷ fps⌋ を**整数で**求める。`rate` は `Float` で、その値は m·2^−k (m・k は
    /// 整数) と厳密に書けるので、割り算を丸めずに済む — 実装の倍精度の式を写さない。
    private static func requested(rate: Float, frames n: Int, fps: Int) -> Int {
        // 仮数を整数にする桁 (1 未満の rate も含めて、2^k 倍で整数になる最小の k 以上)
        let shift = max(0, Int(Float.significandBitCount) - Int(rate.exponent))
        let numerator = Int(Double(rate) * Double(1 << shift))
        return numerator * n / ((1 << shift) * fps)
    }

    /// [#1640] の反証 1・2。**丸めの誤差に遊びを持たせる直し方は、整数のわずか下にある
    /// 端数を 1 個に数えて超過する。** 反証役が見つけた組 (fps 120 の `rate: 71.563` は 6206 枚目、
    /// 59.99999・29.99999・119.9999 は 1 枚目から) と、小数 4 桁の `rate` を fps 120 で 60 秒
    /// 回した 64 本を、整数で求めた累計と枚ごとに比べる。遊び 1e-6 の作りはここで赤くなる。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    @Test("端数の rate でも、累計は ⌊rate·n ÷ fps⌋ を 1 枚も越えず、1 枚も下回らない")
    func fractionalRatesNeitherRunOverNorFallShort() {
        var cases: [(rate: Float, fps: Int, frames: Int)] = [
            (71.563, 120, 6300), (59.99999, 60, 120), (29.99999, 30, 60), (119.9999, 120, 240),
        ]
        var randomness = Randomness(seed: 1640)
        for _ in 0..<64 {
            let tenThousandths = Int(randomness.unitValue() * 1_200_000)
            cases.append((Float(tenThousandths) / 10_000, 120, 7200))
        }
        var broken: [String] = []
        for (rate, fps, frames) in cases {
            let totals = cumulativeCounts(rate: rate, fps: fps, frames: frames)
            for (index, total) in totals.enumerated() {
                let expected = Self.requested(rate: rate, frames: index + 1, fps: fps)
                if total != expected {
                    broken.append("rate \(rate)・fps \(fps)・\(index + 1) 枚目: \(total) 個 (頼んだ数 \(expected))")
                    break
                }
            }
        }
        #expect(broken.isEmpty, "累計が頼んだ数と違う組が \(broken.count) 個: \(broken.prefix(8))")
    }

    /// 端数を整数で求める式そのものの確かめ。**検査の物差しが外れていれば、上の検査は
    /// 何も言わない。**
    @Test("整数で求めた頼んだ数は、有理数で書ける例と一致する")
    func theRequestedCountIsExact() {
        #expect(Self.requested(rate: 0.5, frames: 600, fps: 60) == 5)
        #expect(Self.requested(rate: 0.5, frames: 119, fps: 60) == 0)
        #expect(Self.requested(rate: 50, frames: 1, fps: 50) == 1)
        #expect(Self.requested(rate: 10, frames: 4, fps: 50) == 0)
        #expect(Self.requested(rate: 10, frames: 5, fps: 50) == 1)
        // 71.563 の単精度の値は 71.56300354…で、6206 枚では 3700.99999975 個 (整数の下)
        #expect(Self.requested(rate: 71.563, frames: 6206, fps: 120) == 3700)
    }

    @Test("1 フレームで枠を超える注文は、繰り越さずに切る")
    func doesNotCarryBeyondTheCapacity() {
        var cadence = EmissionCadence()
        #expect(cadence.take(rate: 100_000, over: .seconds(1), upTo: 10) == 10)
        // **貯め込まない。** 貯めると、レートを下げたあとも出続ける
        #expect(cadence.carried == 0)
        #expect(cadence.take(rate: 0, over: .seconds(1), upTo: 10) == 0)
    }

    @Test("進まない時間・出ないレートでは、何も出ない")
    func emitsNothingWithoutRateOrTime() {
        var cadence = EmissionCadence()
        #expect(cadence.take(rate: 0, over: .frame(perSecond: 60), upTo: 10) == 0)
        #expect(cadence.take(rate: 60, over: .seconds(0), upTo: 10) == 0)
        #expect(cadence.take(rate: .infinity, over: .frame(perSecond: 60), upTo: 10) == 0)
    }

    @Test("遠ざける力は、引く力の符号を返したもの")
    func repelIsAttractWithTheSignFlipped() {
        // 枝を 2 本持たない。名前が 2 つあるだけ
        #expect(Force.repel(3, 4, strength: 5) == .attract(3, 4, strength: -5))
        // 弱まり始める距離は、符号を返さずにそのまま渡る
        #expect(
            Force.repel(3, 4, strength: 5, weakeningBeyond: 6)
                == .attract(3, 4, strength: -5, weakeningBeyond: 6))
    }

    @Test("力の並びは、先頭が種類")
    func packsTheKindFirst() {
        #expect(Force.gravity(1, 2, 3).packed == [0, 1, 2, 3, 0, 0, 0, 0])
        #expect(Force.attract(1, 2, strength: 9).packed == [1, 1, 2, 0, 9, 0, 0, 0])
        // 弱まり始める距離は 6 つ目の枠。省いたときの 0 は「弱まらない」と読まれる
        #expect(
            Force.attract(1, 2, 3, strength: 9, weakeningBeyond: 4).packed == [1, 1, 2, 3, 9, 4, 0, 0])
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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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
    ///
    /// `looking` は背景の直後に呼ぶ。視点や変換を置くときに使う。
    private func spray(
        on canvas: Canvas, _ dust: Particles, randomness: inout Randomness, frames: Int,
        rate: Float = 600, looking: (Canvas) -> Void = { _ in }
    ) throws {
        for _ in 0..<frames {
            var stream = randomness
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                looking(canvas)
                canvas.emit(
                    dust, from: .point(32, 12), rate: rate, speed: 20...45,
                    angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                    color: .linear(red: 1, green: 0.6, blue: 0.2), using: &stream)
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
            gpu.shaders.bundledShaderSource(named: Canvas.particleShaderName),
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

    /// 回した視点と、倍率を掛けて回した変換。板の向きと列の長さを両方踏む。
    @Test("視点と変換を回しても、速い経路と参照の経路は同じ絵を出す")
    func bothRoutesAgreeUnderATurnedView() throws {
        func picture(_ route: Canvas.ParticleRoute) throws -> [UInt8] {
            let canvas = try makeCanvas()
            canvas.particleRoute = route
            var randomness = Randomness(seed: 1043)
            let dust = try canvas.makeParticles(count: 257)
            try spray(on: canvas, dust, randomness: &randomness, frames: 10) { canvas in
                let distance = Camera.fittingDistance(height: 64)
                canvas.camera(
                    32 + distance * sin(0.9), 32, distance * cos(0.9), 32, 32, 0, 0, 1, 0)
                canvas.translate(32, 32, 0)
                canvas.rotateY(0.6)
                canvas.scale(1.5, 1.5, 1.5)
                canvas.translate(-32, -32, 0)
            }
            return try canvas.target.encodeForDisplay().bytes
        }

        let fast = try picture(.instanced)
        let reference = try picture(.reference)
        #expect(brightest(fast) > 32)
        #expect(fingerprint(fast) == fingerprint(reference))
    }

    // MARK: - 置く時点の状態を受けない (#1649・#1650)
    //
    // 粒の板は保持した形なので、区間の設定 (混ぜ方・貼る絵の面・塗り) は作った時点に記録した
    // ものを使う。置く時点の `texture()` / `shader()` は受けず、2 経路は同じ絵を出す。

    /// 粒を置く時点に置いたままにしておく状態。
    enum PlacingState: String, CaseIterable, CustomTestStringConvertible {
        case nothing
        case texture
        case shader
        case both

        var testDescription: String {
            switch self {
            case .nothing: "何も置かない"
            case .texture: "texture(描き場所) を貼ったまま"
            case .shader: "shader(値を渡す断片) を当てたまま"
            case .both: "両方"
            }
        }

        var textures: Bool { self == .texture || self == .both }
        var shades: Bool { self == .shader || self == .both }
    }

    /// `state` を置いたまま、`body` で粒を置く 1 フレームを描く手順を組む。
    ///
    /// 貼る絵は赤く塗った描き場所、当てる断片は値で緑を出す断片である。どちらも粒の白い板を
    /// 別の色に変えるので、効いてしまえば絵に出る。
    private func placing(
        _ state: PlacingState, on canvas: Canvas
    ) throws -> (_ body: () -> Void) throws -> Void {
        let red = try canvas.createGraphics(8, 8)
        let green = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(0.0, values.level, 0.0, 1.0);
            }
            """,
            values: ["level": 1])
        return { body in
            try canvas.draw {
                red.beginDraw()
                red.background(.linear(red: 1, green: 0, blue: 0))
                red.endDraw()
                canvas.background(.display(red: 0, green: 0, blue: 0))
                if state.textures { canvas.texture(red) }
                if state.shades { canvas.shader(green) }
                body()
                canvas.noTexture()
                canvas.resetShader()
            }
        }
    }

    /// #1649・#1650 の本文の再現。**1 点に止まった白い板を、貼った・当てたまま描く。**
    @Test(
        "texture() / shader() を置いたままでも、既定の経路の粒は置かない絵と同じに出る",
        arguments: [PlacingState.texture, .shader])
    func theFastRouteIgnoresTheStateAtPlacement(_ state: PlacingState) throws {
        func picture(_ state: PlacingState) throws -> [UInt8] {
            let canvas = try makeCanvas()
            let dust = try canvas.makeParticles(count: 512)
            var randomness = Randomness(seed: 1649)
            try placing(state, on: canvas)({
                canvas.emit(
                    dust, from: .point(32, 32), rate: 3000, speed: 0...0, angle: 0...0,
                    life: 5...5, size: 20...20, color: .linear(red: 1, green: 1, blue: 1),
                    using: &randomness)
                canvas.particles(dust)
            })
            return try canvas.target.encodeForDisplay().bytes
        }

        let plain = try picture(.nothing)
        // 白い板の真ん中。何も出ていないと「同じ」も成り立つので、先に板が白いことを見る
        let middle = (32 * 64 + 32) * 4
        #expect(Array(plain[middle..<(middle + 3)]) == [255, 255, 255])
        let placed = try picture(state)
        #expect(Array(placed[middle..<(middle + 3)]) == [255, 255, 255])
        #expect(fingerprint(placed) == fingerprint(plain))
    }

    /// #1649 の完了条件 2。**置く時点に何を置いていても、2 経路は同じ絵を出す。** 何も置かない
    /// 絵とも一致する — 両経路が同じだけ受けてしまう壊れ方も落とす。
    @Test("置く時点の texture() / shader() を振っても、速い経路と参照の経路は同じ絵を出す",
          arguments: PlacingState.allCases)
    func bothRoutesAgreeWhateverIsSetAtPlacement(_ state: PlacingState) throws {
        func picture(_ route: Canvas.ParticleRoute, _ state: PlacingState) throws -> [UInt8] {
            let canvas = try makeCanvas()
            canvas.particleRoute = route
            let dust = try canvas.makeParticles(count: 257)
            let frame = try placing(state, on: canvas)
            var randomness = Randomness(seed: 1650)
            for _ in 0..<10 {
                var stream = randomness
                try frame {
                    canvas.emit(
                        dust, from: .point(32, 12), rate: 600, speed: 20...45,
                        angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                        color: .linear(red: 1, green: 0.6, blue: 0.2), using: &stream)
                    canvas.force(dust, [.gravity(0, 60), .drag(0.5)])
                    canvas.particles(dust)
                }
                randomness = stream
            }
            return try canvas.target.encodeForDisplay().bytes
        }

        let fast = try picture(.instanced, state)
        let reference = try picture(.reference, state)
        #expect(brightest(fast) > 32)
        #expect(fingerprint(fast) == fingerprint(reference))
        #expect(fingerprint(fast) == fingerprint(try picture(.instanced, .nothing)))
    }

    /// `bake` で塗りを置いてから粒を作り、塗りを外してから 2 フレーム描く。板は 1 点に止める。
    ///
    /// `between` はフレームの間 (1 枚目を描いた後・2 枚目を描く前) に呼ぶ。`whilePlaced` は
    /// 2 枚目のフレームの中で、粒を置いた直後に呼ぶ。返すのは 2 枚目の板の真ん中の色。
    /// **2 枚目を見るのは、作った直後のフレームでは隠れる壊れ方があるため**である (#914 —
    /// 作った直後は立体の列が開いたままで、面を選び直す手順が早く返る)。
    private func bakedPaint(
        _ route: Canvas.ParticleRoute, bake: (Canvas) throws -> Void,
        between: () -> Void = {}, whilePlaced: (Canvas) -> Void = { _ in }
    ) throws -> [UInt8] {
        let canvas = try makeCanvas()
        canvas.particleRoute = route
        try bake(canvas)
        let dust = try canvas.makeParticles(count: 64)
        canvas.resetShader()
        canvas.noTexture()
        canvas.resetNumbers()
        var randomness = Randomness(seed: 788)
        for frame in 0..<2 {
            if frame == 1 { between() }
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.emit(
                    dust, from: .point(32, 32), rate: 600, speed: 0...0, angle: 0...0,
                    life: 5...5, size: 20...20, color: .linear(red: 1, green: 1, blue: 1),
                    using: &randomness)
                canvas.particles(dust)
                if frame == 1 { whilePlaced(canvas) }
            }
        }
        let bytes = try canvas.target.encodeForDisplay().bytes
        let middle = (32 * 64 + 32) * 4
        return Array(bytes[middle..<(middle + 3)])
    }

    /// #1649 の完了条件 3 の前半。**作る前に当てた塗りは、粒に焼き付く** (`createShape` と同じ)。
    /// 置く前に `resetShader()` しても、両経路とも焼き付いた断片で塗る。
    @Test("粒を作る前に当てた断片が、両経路の粒に焼き付く")
    func bothRoutesBakeTheShaderSetBeforeMaking() throws {
        let body = "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"
        for route in [Canvas.ParticleRoute.instanced, .reference] {
            let color = try bakedPaint(route, bake: { canvas in
                canvas.shader(try canvas.makeShader(body))
            })
            #expect(color == [0, 255, 0], "\(route)")
        }
    }

    /// **作る前に貼った絵は、フレームをまたいでも粒に残る** (#1649 の反証 5)。置く前に
    /// `noTexture()` しても、両経路とも貼った絵で出る。直す前の速い経路は、2 枚目のフレームで
    /// 置く側の貼る絵 (無し) へ面を選び直し、白い板になっていた (#914 と同じ形)。
    @Test("粒を作る前に貼った絵が、フレームをまたいでも両経路の粒に残る")
    func bothRoutesKeepTheTextureSetBeforeMaking() throws {
        for route in [Canvas.ParticleRoute.instanced, .reference] {
            let color = try bakedPaint(route, bake: { canvas in
                let picture = try canvas.createImage(8, 8)
                picture.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.texture(picture)
            })
            #expect(color == [255, 0, 0], "\(route)")
        }
    }

    /// #1649 の完了条件 3 の後半 (#1253 の形)。**作った後で書き換えた面の絵は、次のフレームの
    /// 粒に出る。** 書き換えない絵と比べて、書き換えが絵を変えることも見る。
    ///
    /// **送りは置いた時点で頼む** (#1649 の反証 4)。描き切りも閉じた列すべての面を整える
    /// (#1766) ので、色だけを見ると、置き直す口が面を整えなくても通ってしまう。置いた直後に
    /// 登録簿に載ったかも見る (`ShapeTests` の「書き換えていない絵を読む形は、置き直しても
    /// 送りを頼まない」と同じ見方)。書き換えていないフレームでは載らないことも見る。
    @Test("粒を作った後で断片の面の絵を書き換えると、次のフレームの粒に書き換えた色が出る")
    func bothRoutesReadAPictureRewrittenAfterMaking() throws {
        let body = """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.tone, in.place);
            }
            """
        for route in [Canvas.ParticleRoute.instanced, .reference] {
            var picture: Image?
            let bake: (Canvas) throws -> Void = { canvas in
                let made = try canvas.createImage(8, 8)
                made.fill(.linear(red: 1, green: 0, blue: 0))
                picture = made
                canvas.shader(try canvas.makeShader(body, surfaces: ["tone": .image(made)]))
            }
            var queued: Bool?
            let untouched = try bakedPaint(route, bake: bake, whilePlaced: { _ in
                queued = picture?.isQueuedForUpload
            })
            #expect(untouched == [255, 0, 0], "\(route)")
            #expect(queued == false, "\(route) が書き換えていない絵の送りを頼んでいる")

            queued = nil
            let rewritten = try bakedPaint(
                route, bake: bake,
                between: { picture?.fill(.linear(red: 0, green: 0, blue: 1)) },
                whilePlaced: { _ in queued = picture?.isQueuedForUpload })
            #expect(rewritten == [0, 0, 255], "\(route) の粒に書き換えた絵が出ない")
            #expect(queued == true, "\(route) が置いた時点で書き換えた絵の送りを頼んでいない")
        }
    }

    /// **焼き付くのは断片に渡した値も同じで、動かすなら数の並びを使う** (#1649 の反証 3)。
    /// 作る前に並びを置いておけば、作った後に並びへ書いた値が次に描く粒に出る。
    /// `Sketch.makeParticles(count:)` の説明が名乗る逃げ道で、これが効かなければ説明が嘘になる。
    @Test("粒を作る前に置いた数の並びへ、作った後に書いた値が両経路の粒に出る")
    func bothRoutesReadNumbersWrittenAfterMaking() throws {
        let body = """
            float4 paint(Fragment in, Values values) {
                float v = in.numbers[0];
                return float4(1.0 - v, v, 0.0, 1.0);
            }
            """
        for route in [Canvas.ParticleRoute.instanced, .reference] {
            var level: Numbers?
            let bake: (Canvas) throws -> Void = { canvas in
                let made = try canvas.makeNumbers(count: 1)
                made.fill(0)
                level = made
                canvas.shader(try canvas.makeShader(body))
                canvas.numbers(made)
            }
            #expect(try bakedPaint(route, bake: bake) == [255, 0, 0], "\(route)")
            let written = try bakedPaint(route, bake: bake, between: { level?.fill(1) })
            #expect(written == [0, 255, 0], "\(route) の粒に並びへ書いた値が出ない")
        }
    }

    // MARK: - 板の向き

    /// 1 点に止まった粒を 1 フレーム描いて、粒が占める画素の数を返す。
    ///
    /// 大きさ 12 の板なので、正対していれば 12 × 12 = 144 画素前後になる。
    private func coverage(looking: (Canvas) -> Void, at origin: (Float, Float)) throws -> Int {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 1043)
        let dust = try canvas.makeParticles(count: 256)
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            looking(canvas)
            canvas.emit(
                dust, from: .point(origin.0, origin.1), rate: 600, speed: 0...0, angle: 0...0,
                life: 5...5, size: 12...12, color: .linear(red: 1, green: 1, blue: 1),
                using: &randomness)
            canvas.particles(dust)
        }
        let bytes = try canvas.target.encodeForDisplay().bytes
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 1] > 128 }.count
    }

    /// **3 次元で視点を回すと、板が横を向いて痩せていた** (#1043)。板は視点の枠に沿うので、
    /// 真横から見ても正面と同じ大きさで写る。
    @Test("視点を真横へ回しても、粒は痩せない")
    func particlesFaceTheCameraFromTheSide() throws {
        let front = try coverage(looking: { _ in }, at: (32, 32))
        let side = try coverage(
            looking: { canvas in
                // 同じ距離から、同じ場所を +x の側から見る
                canvas.camera(32 + Camera.fittingDistance(height: 64), 32, 0, 32, 32, 0, 0, 1, 0)
            }, at: (32, 32))
        #expect(front > 100, "正面から見た粒が写っていない — 比べる前提が崩れている")
        #expect(Double(side) > Double(front) * 0.8, "真横から見た粒が痩せた (\(side) / \(front) 画素)")
        #expect(Double(side) < Double(front) * 1.25, "真横から見た粒が太った (\(side) / \(front) 画素)")
    }

    /// 雲ごと `rotateY()` で回す書き方でも痩せない。**変換からは倍率だけを受け取る**ので、
    /// 回転は板の向きに効かない。
    @Test("変換で真横へ回しても、粒は痩せない")
    func particlesIgnoreTheTurnOfTheTransform() throws {
        let front = try coverage(looking: { canvas in canvas.translate(32, 32, 0) }, at: (0, 0))
        let turned = try coverage(
            looking: { canvas in
                canvas.translate(32, 32, 0)
                canvas.rotateY(Float.pi / 2)
            }, at: (0, 0))
        #expect(front > 100, "正面から見た粒が写っていない — 比べる前提が崩れている")
        #expect(Double(turned) > Double(front) * 0.8, "回した粒が痩せた (\(turned) / \(front) 画素)")
        #expect(Double(turned) < Double(front) * 1.25, "回した粒が太った (\(turned) / \(front) 画素)")
    }

    @Test("描き切りが待てなかったら粒の状態へ書かず、次に描けたフレームで置く")
    func holdsParticlesBackWhileTheWaitFails() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 934)
        let dust = try canvas.makeParticles(count: 128)
        try spray(on: canvas, dust, randomness: &randomness, frames: 1)
        let placed = dust.cursor
        #expect(placed > 0, "1 フレーム目で粒が出ていない — 以降の比較が成り立たない")
        try canvas.gpu.settle()
        let before = dust.state.snapshot()

        canvas.failureForTesting = .timedOut(seconds: 5)
        #expect(throws: RenderFailure.self) {
            try spray(on: canvas, dust, randomness: &randomness, frames: 1)
        }
        canvas.failureForTesting = nil
        try canvas.gpu.settle()

        // **置き場へは触らない** (#934)。書き込みは控えに残る (#749) ので、枠は進んでよい
        #expect(dust.state.snapshot() == before, "描き切りが投げたのに、粒の区画へ書いている")
        let held = dust.cursor
        #expect(held > placed, "投げたフレームで出した粒を、控えに積んでいない")

        try spray(on: canvas, dust, randomness: &randomness, frames: 1)
        let state = canvas.read(dust.state)
        let floats = Particles.particleFloats
        let lifeOffset = MemoryLayout.offset(of: \Particle.life)! / MemoryLayout<Float>.stride
        // 投げたフレームで出した粒が生きている = 次の描き切りが控えを届けた
        for slot in placed..<held {
            #expect(state[slot * floats + lifeOffset] > 0, "枠 \(slot) の粒が届いていない")
        }
    }

    @Test("環を回り込んで出しても、区画を取り違えない")
    func emittingAcrossTheWrapKeepsEachSlot() throws {
        func state(writingDirectly: Bool) throws -> [Float] {
            let canvas = try makeCanvas()
            var randomness = Randomness(seed: 7_490)
            let dust = try canvas.makeParticles(count: 16)
            // **1 フレームで容量いっぱいを出す** と、枠の区間が末尾と先頭の 2 つに割れる。
            // 物差しは、同じ粒を控えに積まず 1 つずつその場で書いたもの (区間の上限 0)
            if writingDirectly { dust.state.dirtyRangeLimit = 0 }
            try spray(on: canvas, dust, randomness: &randomness, frames: 3, rate: 1_500)
            return canvas.read(dust.state)
        }
        let staged = try state(writingDirectly: false)
        #expect(staged.contains { $0 != 0 }, "粒が 1 つも置かれていない")
        #expect(staged == (try state(writingDirectly: true)))
    }

    /// まとめて書く置き方を見る場面 (#1748)。容量・噴き口・1 フレームで何回出すかを変える。
    enum PlacementScene: String, CaseIterable, Sendable {
        /// 容量に届かない数を点から出す。
        case underCapacity
        /// 1 フレームでちょうど容量ぶんを出す。
        case fillsTheRing
        /// 1 フレームに 3 回出して、同じ枠を 2 度以上書く。
        case overflowsTheRing
        /// 数フレームかけて環を何周か回り込む。
        case wrapsAcrossFrames
        /// 線と円から出す。
        case lineAndCircle
        /// 数でない位置に落ちる噴き口を、正しい噴き口の間に挟む (枠を進めない粒が混ざる)。
        case unplaceableInBetween
    }

    /// まとめて書く上限を `chunk` にして場面を回し、粒の状態と枠と乱数の続きを返す。
    private func placed(
        _ scene: PlacementScene, chunk: Int
    ) throws -> (state: [Float], cursor: Int, next: Float, overwrote: Bool, refused: Bool) {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 1748)
        let capacity = scene == .underCapacity ? 200 : 16
        let dust = try canvas.makeParticles(count: capacity)
        dust.placementChunk = chunk
        let rate: Float =
            switch scene {
            case .underCapacity: 600
            case .fillsTheRing, .overflowsTheRing: 960
            case .wrapsAcrossFrames, .lineAndCircle, .unplaceableInBetween: 420
            }
        let sources: [Emitter] =
            switch scene {
            case .underCapacity, .fillsTheRing, .wrapsAcrossFrames: [.point(32, 12)]
            case .overflowsTheRing: [.point(32, 12), .point(8, 40), .point(50, 50)]
            case .lineAndCircle: [.line(4, 4, 60, 30), .circle(32, 32, radius: 20)]
            case .unplaceableInBetween:
                [.point(32, 12), .circle(3e38, 0, radius: 3e38), .line(4, 4, 60, 30)]
            }
        let frames = scene == .wrapsAcrossFrames ? 5 : 2
        for _ in 0..<frames {
            try canvas.draw {
                for source in sources {
                    canvas.emit(
                        dust, from: source, rate: rate, speed: 20...45,
                        angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                        color: .linear(red: 1, green: 0.6, blue: 0.2), using: &randomness)
                }
            }
        }
        return (
            canvas.read(dust.state), dust.cursor, randomness.unitValue(),
            dust.warnings.hasWarned(.overwrite), dust.warnings.hasWarned(.unacceptableEmission)
        )
    }

    @Test(
        "続いた枠をまとめて書いても、1 粒ずつ書いたのと同じ粒・枠・乱数の続き・注意になる",
        arguments: PlacementScene.allCases, [3, 1024])
    func placingInRunsMatchesPlacingOneByOne(_ scene: PlacementScene, chunk: Int) throws {
        // 物差しは 1 粒ずつ書く置き方 (以前の実装と同じ書き込みの列)
        let reference = try placed(scene, chunk: 1)
        let batched = try placed(scene, chunk: chunk)
        #expect(reference.cursor > 0, "粒が 1 つも置かれていない — 比べる前提が崩れている")
        #expect(batched.state == reference.state)
        #expect(batched.cursor == reference.cursor)
        #expect(batched.next == reference.next)
        #expect(batched.overwrote == reference.overwrote)
        #expect(batched.refused == reference.refused)
        switch scene {
        case .overflowsTheRing, .wrapsAcrossFrames:
            #expect(reference.cursor > 16, "環を回り込んでいない — 場面が崩れている")
        case .unplaceableInBetween:
            #expect(reference.refused, "数でない位置の粒を断っていない — 場面が崩れている")
        default: break
        }
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
                        color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
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

    // MARK: - 1 つの粒へ何か所から出す (#1468)

    /// 1 つの粒へ毎フレーム `rates.count` 回 `emit` し、`frames` フレームで呼んだ順ごとに
    /// 出た数を返す。数えるのは各 `emit` の前後の ``Particles/cursor`` の差で、環を
    /// 回り込まないだけの容量を取る。
    ///
    /// `inOneLoop` なら同じ 1 行 (`for` の中) から呼び、そうでなければ別々の行から呼ぶ
    /// (`rates` は 2 つ)。**呼んだ位置で分ける作りでは、同じ 1 行から呼ぶ形が直らない**
    /// — `Sketches/SparksAndForces.swift` がその書き方をしている。
    private func emittedCounts(
        rates: [Float], step: Float, frames: Int, inOneLoop: Bool
    ) throws -> [Int] {
        let canvas = try makeCanvas()
        canvas.deltaTime = step
        var randomness = Randomness(seed: 1468)
        let dust = try canvas.makeParticles(count: 256)
        var counts = Array(repeating: 0, count: rates.count)
        for _ in 0..<frames {
            try canvas.draw {
                if inOneLoop {
                    for (index, rate) in rates.enumerated() {
                        let before = dust.cursor
                        canvas.emit(
                            dust, from: .point(32, 32), rate: rate, speed: 0...0, angle: 0...0,
                            life: 0.2...0.2, size: 1...1,
                            color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                        counts[index] += dust.cursor - before
                    }
                } else {
                    let first = dust.cursor
                    canvas.emit(
                        dust, from: .point(16, 32), rate: rates[0], speed: 0...0, angle: 0...0,
                        life: 0.2...0.2, size: 1...1,
                        color: .linear(red: 1, green: 0.5, blue: 0), using: &randomness)
                    let second = dust.cursor
                    canvas.emit(
                        dust, from: .point(48, 32), rate: rates[1], speed: 0...0, angle: 0...0,
                        life: 0.2...0.2, size: 1...1,
                        color: .linear(red: 0, green: 0.5, blue: 1), using: &randomness)
                    counts[0] += second - first
                    counts[1] += dust.cursor - second
                }
                canvas.particles(dust)
            }
        }
        // 環を回り込んでいない (差をそのまま足してよい前提)
        try #require(counts.reduce(0, +) < dust.capacity, "出た数 \(counts) が容量を超えた")
        return counts
    }

    /// [#1468] の完了条件 1・3。**1 つの粒へ 2 か所から出しても、それぞれが頼んだ数を出す。**
    /// 刻み 1/30 で 60 フレーム (2 秒) — `rate: 15` を 2 か所なら 30 個ずつ、`rate: 3` と
    /// `rate: 45` なら 6 個と 90 個。
    ///
    /// 繰り越しが 1 つだと取り合う。15 と 15 なら、1 か所目が 0.5 を足して 0 個、2 か所目が
    /// 1 に届いて 1 個、を毎フレーム繰り返して (0, 60) になる。3 と 45 では (0, 96)。
    /// 合計は合っていて、配り方だけが崩れる。
    ///
    /// [#1468]: https://github.com/mokume-metal/mokume/issues/1468
    @Test(
        "1 つの粒へ 2 か所から出しても、それぞれが頼んだ数を出す",
        arguments: [([Float(15), 15], [30, 30]), ([Float(3), 45], [6, 90])])
    func twoEmittersOnOneParticlesEachGetTheirRate(rates: [Float], expected: [Int]) throws {
        let counts = try emittedCounts(rates: rates, step: 1 / 30, frames: 60, inOneLoop: false)
        #expect(counts == expected, "レート \(rates) の噴き口が出した数 \(counts) — 頼んだ数は \(expected)")
    }

    /// fps 50 で毎秒 50 個 (1 枚に 1 個) の粒を、毎秒 1200 画素で右へ飛ばす。粒は 24 画素
    /// おきに 1 行に並ぶ ([#1640] の本文の再現)。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    final class EmitPerSecond: Sketch {
        static let fps = 50
        var settings: SketchSettings {
            SketchSettings(width: 1300, height: 20, frameRate: Self.fps)
        }
        var dots: Particles?
        init() {}

        func setup() { dots = try? makeParticles(count: 1000) }

        func draw() {
            background(0)
            guard let dots else { return }
            emit(
                dots, from: .point(5, 10), rate: Float(Self.fps), speed: 1200...1200,
                angle: 0...0, life: 100...100, size: 2...2,
                color: LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 1))
            particles(dots)
        }
    }

    /// `frames` 枚回した後、行の上で粒を数える。
    private func dotsOnTheRow(after frames: Int) throws -> Int {
        let runtime = try SketchRuntime(sketch: EmitPerSecond(), gpu: RenderDevice())
        defer { runtime.closePlugins() }
        for _ in 0..<frames { try runtime.advance() }
        let pixels = try runtime.target.readPixels()
        var (count, inside) = (0, false)
        for x in 0..<pixels.width {
            let on = pixels[x, pixels.height / 2].red > 0.3
            if on && !inside { count += 1 }
            inside = on
        }
        return count
    }

    /// [#1640] の完了条件 3。**時計から `emit` までを `SketchRuntime` ごと通す** —
    /// 数える側だけを見る検査は、時計と面の間の受け渡しで刻みが丸まるのを見落とす。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    @Test("fps 50 で毎秒 50 個なら、1 枚目に 1 個・50 枚目に 50 個が並ぶ")
    func theRuntimeEmitsTheRatePerSecondAtFifty() throws {
        #expect(try dotsOnTheRow(after: 1) == 1)
        #expect(try dotsOnTheRow(after: EmitPerSecond.fps) == EmitPerSecond.fps)
    }

    /// [#1468] の完了条件 2。**同じ 1 行から 2 回呼んでも、繰り越しは分かれる。** 呼んだ
    /// 位置 (`#line` など) で分ける作りでは、ここが (0, 60) のまま直らない。
    ///
    /// [#1468]: https://github.com/mokume-metal/mokume/issues/1468
    @Test("同じ 1 行から何度 emit しても、それぞれが頼んだ数を出す")
    func emittingInALoopStillSplitsTheCarry() throws {
        let counts = try emittedCounts(rates: [15, 15], step: 1 / 30, frames: 60, inOneLoop: true)
        #expect(counts == [30, 30], "同じ行から呼んだ 2 回が出した数 \(counts)")
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
                    color: .linear(red: 1, green: 0.5, blue: 0.2), using: &randomness)
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

        let living = dust.living(
            from: canvas.read(dust.state), transform: matrix_identity_float4x4,
            basis: matrix_identity_float3x3)
        #expect(living.count == tenth * 2)
        let arguments = drawArguments(of: dust, on: canvas)
        #expect(arguments.instanceCount == living.count)
        #expect(arguments.vertexCount == dust.quad.runs.first?.count)
        #expect(arguments.baseInstance == 0)

        // 詰めた置き場所は、枠の番号順に読んだ生きている粒と 1 つずつ一致する。
        // 行列の 4 列目が位置、[0][0] が大きさ (変換も視点の枠も単位行列なので、GPU と
        // CPU の式が 1 ビットまで揃う)
        let places = canvas.read(dust.instances)
        let placeFloats = MemoryLayout<SolidInstance>.stride / MemoryLayout<Float>.stride
        var mismatched = 0
        for (index, particle) in living.enumerated() {
            let base = index * placeFloats
            let matrix = particle.matrix
            if places[base] != matrix.columns.0.x || places[base + 12] != matrix.columns.3.x
                || places[base + 13] != matrix.columns.3.y || places[base + 15] != 1
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
        let uploadReallocations = canvas.uploadStorage.reallocations

        try spray(on: canvas, dust, randomness: &randomness, frames: 200)
        // **単発では出ない。** 毎フレーム確保していれば、ここで増える
        #expect(try canvas.computePipeline().tablesBuilt == tables)
        #expect(dust.state.readbackAllocations == 0)
        // 書き込みの控え (#749) も毎フレーム確保しない — 影は 1 度、置き場は伸びきったまま
        #expect(canvas.uploadStorage.reallocations == uploadReallocations)
        #expect(dust.state.shadowAllocations == 1)
        #expect(dust.parameters.shadowAllocations == 1)
        #expect(canvas.uploadBarriersEncoded == 201, "控えを届けていないフレームがある")
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

    // MARK: - 同じフレームに何度も置く (#1651)
    //
    // `particles(p)` は呼ぶたびに 1 刻み進め、呼んだ時点の変換で描く。同じ群を同じ面で
    // 1 フレームに 2 回呼んでも、面をまたいで呼んでも同じである。直す前は、毎回の指定と
    // 置き場所が群で 1 つずつで、描き切りの頭で GPU へ届くのは最後に書いた指定だけ、描くのは
    // 最後の計算が書いた置き場所だけだった — 1 回目の雲が消え、1 回目の前に積んだ力も効かない。

    /// 同じフレームに 2 回置く検査の刻み。**2 のべき**なので、速さを掛けても丸めが入らない。
    private static let twiceStep: Float = 1.0 / 64

    /// 動かない (か、右へまっすぐ進む) 白い粒を (0, 80) に 100 個出す (寿命 5 秒・大きさ 20)。
    ///
    /// 出る所が 1 点で向きも一定なので、`speed` を倍にした群を 1 刻み進めた位置は、同じ群を
    /// 2 刻み進めた位置と**丸めなしで**一致する (x = 2 · speed · Δt)。描く板が読むのは位置・
    /// 大きさ・色だけなので、絵も一致する。
    private func release(
        _ dust: Particles, speed: Float, on canvas: Canvas, using randomness: inout Randomness
    ) {
        canvas.emit(
            dust, from: .point(0, 80), rate: (100 / Self.twiceStep).nextUp,
            speed: speed...speed, angle: 0...0, life: 5...5, size: 20...20,
            color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
    }

    /// 本文の再現の場面を 1 フレーム描く。1 つ目の群を `translate(20, 0)` の下に置き、
    /// `sameGroup` なら同じ群を、そうでなければ同じ放出を倍の速さでした別の群を
    /// `translate(90, 0)` の下に置く。
    private func twoClouds(
        route: Canvas.ParticleRoute, speed: Float, sameGroup: Bool
    ) throws -> [UInt8] {
        let canvas = try makeCanvas(width: 160, height: 160)
        canvas.particleRoute = route
        canvas.deltaTime = Self.twiceStep
        let first = try canvas.makeParticles(count: 512)
        let second = try canvas.makeParticles(count: 512)
        let randomness = Randomness(seed: 1651)
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            // 2 つの群へ同じ流れで出す (同じ粒になる)
            var stream = randomness
            release(first, speed: speed, on: canvas, using: &stream)
            if !sameGroup {
                stream = randomness
                release(second, speed: 2 * speed, on: canvas, using: &stream)
            }
            canvas.push()
            canvas.translate(20, 0)
            canvas.particles(first)
            canvas.pop()
            canvas.push()
            canvas.translate(90, 0)
            canvas.particles(sameGroup ? first : second)
            canvas.pop()
        }
        return try canvas.target.encodeForDisplay().bytes
    }

    /// 2 枚の絵で、成分の差が表示の 1 段を越える画素の数。
    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: min(a.count, b.count), by: 4).count { start in
            (0..<4).contains { abs(Int(a[start + $0]) - Int(b[start + $0])) > 1 }
        }
    }

    /// 絵の (x, y) のいちばん明るい色の成分。
    private func brightness(_ bytes: [UInt8], width: Int, at x: Int, _ y: Int) -> UInt8 {
        let start = (y * width + x) * 4
        return bytes[start..<(start + 3)].max() ?? 0
    }

    @Test(
        "同じ群を 1 フレームに 2 回置くと、別の群を 1 回ずつ置いた絵と同じになる",
        arguments: [Canvas.ParticleRoute.instanced, .reference], [Float(0), 512])
    func drawingTheSameGroupTwiceMatchesTwoGroups(
        route: Canvas.ParticleRoute, speed: Float
    ) throws {
        let same = try twoClouds(route: route, speed: speed, sameGroup: true)
        let separate = try twoClouds(route: route, speed: speed, sameGroup: false)
        // 比べる側に両方の雲が出ていること (1 刻みで 1 つ目は x = 20 + speed·Δt、2 つ目は
        // 90 + 2·speed·Δt)。何も出ていなければ「同じ」も成り立ってしまう
        let shift = Int(speed * Self.twiceStep)
        #expect(brightness(separate, width: 160, at: 20 + shift, 80) > 250)
        #expect(brightness(separate, width: 160, at: 90 + 2 * shift, 80) > 250)
        #expect(
            differingPixels(same, separate) == 0,
            "1 つ目の雲の中心の明るさ: 同じ群 \(brightness(same, width: 160, at: 20 + shift, 80))")
    }

    @Test("同じ群を 1 フレームに 2 回置いても、速い経路と参照の経路は同じ絵を出す", arguments: [Float(0), 512])
    func bothRoutesAgreeWhenTheSameGroupIsDrawnTwice(speed: Float) throws {
        let fast = try twoClouds(route: .instanced, speed: speed, sameGroup: true)
        let reference = try twoClouds(route: .reference, speed: speed, sameGroup: true)
        #expect(brightest(fast) > 250)
        #expect(fingerprint(fast) == fingerprint(reference))
    }

    @Test("同じ群を毎フレーム 2 回置いても、置き場の確保が積み上がらない")
    func drawingTwiceEveryFrameDoesNotGrow() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 1651)
        let dust = try canvas.makeParticles(count: 512)
        func frame() throws {
            var stream = randomness
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.emit(
                    dust, from: .point(32, 12), rate: 600, speed: 20...45,
                    angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                    color: .linear(red: 1, green: 0.6, blue: 0.2), using: &stream)
                canvas.force(dust, [.gravity(0, 60)])
                canvas.particles(dust)
                canvas.translate(8, 0)
                canvas.particles(dust)
            }
            randomness = stream
        }

        try frame()
        // 2 回目のための組が 1 つ足された
        #expect(dust.draws.count == 2)
        let tables = try canvas.computePipeline().tablesBuilt
        let uploadReallocations = canvas.uploadStorage.reallocations

        for _ in 0..<200 { try frame() }
        // **単発では出ない。** 毎フレーム足していれば、ここで増える
        #expect(dust.draws.count == 2)
        for draw in dust.draws { #expect(draw.parameters.shadowAllocations == 1) }
        #expect(try canvas.computePipeline().tablesBuilt == tables)
        #expect(canvas.uploadStorage.reallocations == uploadReallocations)
        // 2 回目の旗は 1 回目が進めた状態を読むので、そこで口が切れる。口の数は 1 回ずつの 2 倍
        #expect(canvas.computeEncodersOpened == 201 * 2 * dust.dispatchCount)
    }

    @Test("毎フレーム 1 回だけ置く群は、組を足さない")
    func drawingOnceEveryFrameKeepsOneDraw() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 17)
        let dust = try canvas.makeParticles(count: 512)
        try spray(on: canvas, dust, randomness: &randomness, frames: 20)
        #expect(dust.draws.count == 1)
        #expect(canvas.computeEncodersOpened == 20 * dust.dispatchCount)
    }

    /// 本体と描き場所で 1 つの群を置く。本体は `translate(90, 0)`、描き場所は `translate(20, 0)`。
    /// 返すのは 2 つの面の絵と、フレームの後の粒 1 つ目。
    private func acrossSurfaces(
        layerFirst: Bool, speed: Float
    ) throws -> (main: [UInt8], layer: [UInt8], particle: Particle) {
        let canvas = try makeCanvas(width: 160, height: 160)
        canvas.deltaTime = Self.twiceStep
        let layer = try canvas.createGraphics(160, 160)
        let dust = try canvas.makeParticles(count: 512)
        var randomness = Randomness(seed: 1651)
        func onLayer() {
            layer.beginDraw()
            layer.background(.display(red: 0, green: 0, blue: 0))
            layer.translate(20, 0)
            layer.particles(dust)
            layer.endDraw()
        }
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            release(dust, speed: speed, on: canvas, using: &randomness)
            if layerFirst { onLayer() }
            canvas.push()
            canvas.translate(90, 0)
            canvas.particles(dust)
            canvas.pop()
            if !layerFirst { onLayer() }
        }
        let particle = canvas.read(dust.state).withUnsafeBytes { raw in
            raw.bindMemory(to: Particle.self)[0]
        }
        return (
            try canvas.target.encodeForDisplay().bytes, try layer.target.encodeForDisplay().bytes,
            particle
        )
    }

    /// 直す前は、本体で先に置くと本体の指定が描き場所の指定で上書きされ (控えの登録簿は面を
    /// またいで 1 つ)、本体の雲が描き場所の変換の下に出た。描き場所が先なら直す前も成り立つ。
    ///
    /// 動く粒でどちらの面がどちらの刻みを描くかは見ない。本体が先の順では、GPU で先に進むのが
    /// 描き場所の刻みなので、本体は 2 刻み後の状態を描く ([#1870])。
    ///
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    @Test(
        "本体と描き場所で 1 つの群を置いても、どちらの面にも呼んだ時点の変換で出て、群は 2 刻み進む",
        arguments: [true, false])
    func sharingAGroupAcrossSurfaces(layerFirst: Bool) throws {
        // 動かない粒で、どちらの面にもその面で置いた所に雲が出る
        let still = try acrossSurfaces(layerFirst: layerFirst, speed: 0)
        #expect(brightness(still.main, width: 160, at: 90, 80) > 250, "本体の雲が出ていない")
        #expect(brightness(still.main, width: 160, at: 20, 80) < 5, "本体に描き場所の雲が出た")
        #expect(brightness(still.layer, width: 160, at: 20, 80) > 250, "描き場所の雲が出ていない")
        #expect(brightness(still.layer, width: 160, at: 90, 80) < 5, "描き場所に本体の雲が出た")

        // 動く粒で、群が 2 刻み進んだ (x = 2 · speed · Δt)。丸めの入らない値なので完全一致
        let speed: Float = 512
        let moving = try acrossSurfaces(layerFirst: layerFirst, speed: speed)
        #expect(moving.particle.x == 2 * speed * Self.twiceStep)
        #expect(moving.particle.life == 5 - 2 * Self.twiceStep)
    }

    @Test("2 回目のための組を足せなければ、その呼び出しは進めも描きもせず、1 度だけ知らせる")
    func failingToAddADrawSkipsThatCall() throws {
        let canvas = try makeCanvas(width: 160, height: 160)
        canvas.deltaTime = Self.twiceStep
        let dust = try canvas.makeParticles(count: 512)
        dust.drawAllocationFailureForTesting = .bufferUnavailable(byteCount: 0)
        var randomness = Randomness(seed: 1651)
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                release(dust, speed: 0, on: canvas, using: &randomness)
                canvas.push()
                canvas.translate(20, 0)
                canvas.particles(dust)
                canvas.pop()
                canvas.force(dust, [.gravity(0, 64)])
                canvas.push()
                canvas.translate(90, 0)
                canvas.particles(dust)
                canvas.pop()
            }
        }
        let picture = try canvas.target.encodeForDisplay().bytes
        #expect(dust.warnings.hasWarned(.drawUnavailable))
        #expect(dust.draws.count == 1)
        // 1 回目は描かれ、2 回目は描かれない
        #expect(brightness(picture, width: 160, at: 20, 80) > 250)
        #expect(brightness(picture, width: 160, at: 90, 80) < 5)
        // 2 回目の前に積んだ力は取り出されず、次のフレームの 1 回目に効いた (群は 2 フレームで
        // 2 刻みだけ進み、2 刻み目に重力が効いている)
        let particle = canvas.read(dust.state).withUnsafeBytes { raw in
            raw.bindMemory(to: Particle.self)[0]
        }
        #expect(particle.life == 5 - 2 * Self.twiceStep)
        #expect(particle.vy == 64 * Self.twiceStep)
        #expect(dust.pendingForceCount == 1)
    }

    // MARK: - 作るときに触らないもの (#1041)
    //
    // 粒の板は `createShape` で作る。組み立ての退避がフレームに縛られていると、
    // `setup()` で粒を作るだけで、利用者が触っていない警告が出て、置いた塗りが白へ変わる。

    @Test("フレームの外で粒を作っても、積み降ろしの警告は出ない")
    func makingParticlesOutsideTheFrameSaysNothingAboutStyle() throws {
        let canvas = try makeCanvas()
        _ = try canvas.makeParticles(count: 4)
        #expect(!canvas.warnings.hasWarned(.styleOutsideFrame))
        #expect(!canvas.warnings.hasWarned(.transformOutsideFrame))
    }

    @Test("フレームの外で置いた塗りは、粒を作ったあとも残る")
    func makingParticlesKeepsTheFillSetOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        canvas.fill(.linear(red: 1, green: 0, blue: 0))
        _ = try canvas.makeParticles(count: 8)
        #expect(canvas.style.fill == .linear(red: 1, green: 0, blue: 0))
    }

    /// **焼き付くのは仕様である。** 粒の板は保持した形なので、作った瞬間の混ぜ方で描かれる —
    /// `draw()` で後から置いた混ぜ方は届かない。「`setup()` からは混ぜ方を選べない」と
    /// 取り違えないよう、作る前に置けば届くことを固定しておく。
    @Test("粒を作る前に置いた混ぜ方が、粒に焼き付く")
    func particlesBakeTheBlendModeSetBeforeMaking() throws {
        let canvas = try makeCanvas()
        canvas.blendMode(.add)
        let dust = try canvas.makeParticles(count: 4)
        #expect(dust.quad.runs.first?.mode == .add)
    }
}
