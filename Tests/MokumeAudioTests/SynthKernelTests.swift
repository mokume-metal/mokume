// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 発振・ノイズ・包絡・濾波器・ディレイ・リバーブの素 (#1980)。機材にも時計にも触れない純粋な
/// 型なので、GPU も音の流れも要らない。値の確かめ方は、解析 (``AudioAnalysis``) を通して周波数の
/// 側から見るものと、標本の値そのものを見るものに分ける。
@Suite("合成の素")
struct SynthKernelTests {
    private static let rate = 48_000.0

    /// 周波数 `frequency` の波形を `count` 標本作る (位相は 0 から)。
    private func wave(
        _ waveform: Waveform, _ frequency: Double, count: Int, sampleRate: Double = rate
    ) -> [Float] {
        let step = frequency / sampleRate
        var phase = 0.0
        return (0..<count).map { _ in
            let value = WaveShape.sample(waveform, phase: phase, step: step)
            phase += step
            if phase >= 1 { phase -= 1 }
            return value
        }
    }

    /// 正弦波を `count` 標本作る。
    private func sine(_ frequency: Double, count: Int, sampleRate: Double = rate) -> [Float] {
        (0..<count).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// 標本列の後ろ半分の二乗平均の平方根 (落ち着いた後の大きさ)。
    private func settledRMS(_ samples: [Float]) -> Float {
        let tail = samples.suffix(samples.count / 2)
        return (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
    }

    // MARK: - 波形

    @Test("正弦波は標本ごとに sin(2π f n / 標本化率) になる")
    func sineFollowsTheFormula() {
        let made = wave(.sine, 1000, count: 4800)
        let worst = zip(made, sine(1000, count: 4800)).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-5)
    }

    @Test("三角波・のこぎり波・矩形波は、位相 0 で 0 (矩形は正の側) から始まり、決まった位置で山と谷になる")
    func waveShapesAtKnownPhases() {
        let step = 1e-6
        func value(_ waveform: Waveform, _ phase: Double) -> Float {
            WaveShape.sample(waveform, phase: phase, step: step)
        }
        #expect(abs(value(.triangle, 0)) < 1e-6)
        #expect(abs(value(.triangle, 0.25) - 1) < 1e-6)
        #expect(abs(value(.triangle, 0.5)) < 1e-6)
        #expect(abs(value(.triangle, 0.75) + 1) < 1e-6)
        #expect(abs(value(.saw, 0.25) - 0.5) < 1e-5)
        #expect(abs(value(.saw, 0.75) + 0.5) < 1e-5)
        #expect(abs(value(.saw, 0.4999) - 1) < 1e-3)
        #expect(abs(value(.square, 0.25) - 1) < 1e-6)
        #expect(abs(value(.square, 0.75) + 1) < 1e-6)
    }

    @Test("帯域の真ん中の周波数で鳴らすと、倍音の強さが波形の形どおりに並ぶ")
    func harmonicsFollowTheShape() {
        // 375 Hz は 1 周期が 128 標本で、1024 標本の窓にちょうど 8 周期入る。帯域 8k が k 次の倍音の真ん中
        func bands(_ waveform: Waveform) -> [Float] {
            AudioAnalysis.analyze(wave(waveform, 375, count: 1024)).spectrum
        }
        let sine = bands(.sine)
        #expect(abs(sine[8] - 1) < 0.01)
        #expect(sine[16] < 0.01 && sine[24] < 0.01)

        // 矩形波は奇数次だけで、k 次が基本の 1/k (基本は 4/π)
        let square = bands(.square)
        #expect(abs(square[8] - 4 / .pi) < 0.03)
        #expect(square[16] < 0.03)
        #expect(abs(square[24] - 4 / (3 * .pi)) < 0.03)

        // のこぎり波は全部の次数で、k 次が基本の 1/k (基本は 2/π)
        let saw = bands(.saw)
        #expect(abs(saw[8] - 2 / .pi) < 0.03)
        #expect(abs(saw[16] - 1 / .pi) < 0.03)
        #expect(abs(saw[24] - 2 / (3 * .pi)) < 0.03)

        // 三角波は奇数次だけで、k 次が基本の 1/k² (基本は 8/π²)
        let triangle = bands(.triangle)
        #expect(abs(triangle[8] - 8 / (.pi * .pi)) < 0.02)
        #expect(triangle[16] < 0.02)
        #expect(abs(triangle[24] - 8 / (9 * .pi * .pi)) < 0.02)
    }

    @Test("のこぎり波の不連続は、素朴に作ったときより小さな段差に丸められる")
    func bandLimitedSawHasSmallerJumps() {
        let frequency = 1000.0
        let step = frequency / Self.rate
        let smoothed = wave(.saw, frequency, count: 960)
        // 素朴なのこぎり波 (位相 0.5 で 1 から -1 へ落ちる)
        var phase = 0.0
        let naive: [Float] = (0..<960).map { _ in
            defer {
                phase += step
                if phase >= 1 { phase -= 1 }
            }
            return Float(2 * ((phase + 0.5).truncatingRemainder(dividingBy: 1)) - 1)
        }
        func biggestJump(_ samples: [Float]) -> Float {
            zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
        #expect(biggestJump(naive) > 1.9)
        #expect(biggestJump(smoothed) < 1.2)
        // 丸めても、山と谷は ±1 を大きく越えない
        #expect(smoothed.allSatisfy { abs($0) < 1.05 })
    }

    // MARK: - ノイズ

    @Test("ノイズは種が同じなら同じ列で、種が違えば違う列になる")
    func noiseFollowsTheSeed() {
        var first = NoiseKernel(seed: 7)
        var second = NoiseKernel(seed: 7)
        var other = NoiseKernel(seed: 8)
        let a = (0..<256).map { _ in first.next(.white) }
        let b = (0..<256).map { _ in second.next(.white) }
        let c = (0..<256).map { _ in other.next(.white) }
        #expect(a == b)
        #expect(a != c)
        // ピンクも同じ種から同じ列
        var pinkA = NoiseKernel(seed: 7)
        var pinkB = NoiseKernel(seed: 7)
        #expect((0..<256).map { _ in pinkA.next(.pink) } == (0..<256).map { _ in pinkB.next(.pink) })
    }

    @Test("白色雑音は -1 以上 1 未満で、平均が 0・分散が 1/3 (一様) に近い")
    func whiteNoiseIsUniform() {
        var kernel = NoiseKernel(seed: 1)
        let samples = (0..<100_000).map { _ in kernel.next(.white) }
        #expect(samples.allSatisfy { $0 >= -1 && $0 < 1 })
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(samples.count)
        #expect(abs(mean) < 0.02)
        #expect(abs(variance - 1.0 / 3) < 0.02)
    }

    @Test("オクターブごとの強さは、白色雑音では倍々に増え、ピンクノイズでは揃う")
    func noiseColorsHaveTheirSlopes() {
        /// 帯域の範囲 (帯域番号) ごとの平均のパワーを、窓 400 枚で平均して返す。
        func octavePowers(_ color: NoiseColor) -> [Float] {
            var kernel = NoiseKernel(seed: 3)
            // 帯域 4 (約 190 Hz) から上を見る。それより下は窓 (1024 標本) の幅に隠れる
            let ranges = [(4, 8), (8, 16), (16, 32), (32, 64), (64, 128), (128, 256)]
            var sums = [Float](repeating: 0, count: ranges.count)
            for _ in 0..<400 {
                let window = (0..<AudioAnalysis.windowSize).map { _ in kernel.next(color) }
                let spectrum = AudioAnalysis.analyze(window).spectrum
                for (index, range) in ranges.enumerated() {
                    sums[index] += spectrum[range.0..<range.1].reduce(0) { $0 + $1 * $1 }
                }
            }
            return sums
        }
        let white = octavePowers(.white)
        for index in 1..<white.count {
            // 1 オクターブ上がると、帯域の数が 2 倍になるぶんパワーが約 2 倍
            #expect(abs(white[index] / white[index - 1] - 2) < 0.15, "white \(index)")
        }
        let pink = octavePowers(.pink)
        for index in 1..<pink.count {
            #expect(abs(pink[index] / pink[index - 1] - 1) < 0.1, "pink \(index)")
        }
    }

    // MARK: - 包絡

    @Test("包絡は立ち上がり・保ち・下がりの台形で、終わった後は nil")
    func envelopeIsTrapezoid() {
        let shape = EnvelopeShape(
            attack: 4 / 48_000, sustain: 2 / 48_000, level: 0.5, release: 4 / 48_000,
            sampleRate: 48_000)
        #expect(shape.length == 10)
        let gains = (0..<10).map { shape.gain(at: $0) }
        #expect(gains == [0, 0.125, 0.25, 0.375, 0.5, 0.5, 0.5, 0.375, 0.25, 0.125])
        #expect(shape.gain(at: 10) == nil)
        #expect(shape.gain(at: -1) == nil)
    }

    @Test("立ち上がりが 0 秒なら最初の標本から保つ高さで、負の秒数と数でない高さは 0 へ寄せる")
    func envelopeBoundaries() {
        let instant = EnvelopeShape(
            attack: 0, sustain: 2 / 48_000, level: 1, release: 0, sampleRate: 48_000)
        #expect(instant.gain(at: 0) == 1)
        #expect(instant.gain(at: 1) == 1)
        #expect(instant.gain(at: 2) == nil)

        let odd = EnvelopeShape(
            attack: -1, sustain: .nan, level: .nan, release: .infinity, sampleRate: 48_000)
        #expect(odd.length == 0)
        #expect(odd.level == 0)
        #expect(EnvelopeShape(attack: 1, sustain: 0, level: 5, release: 0, sampleRate: 48_000).level == 1)
    }

    // MARK: - 濾波器

    private func filtered(
        _ shape: FilterShape, cutoff: Double, quality: Double, input frequency: Double
    ) -> Float {
        var biquad = Biquad()
        biquad.configure(shape, frequency: cutoff, quality: quality, sampleRate: Self.rate)
        let output = sine(frequency, count: 9600).map { biquad.process($0) }
        return settledRMS(output) / settledRMS(sine(frequency, count: 9600))
    }

    @Test("低域通過は、切れ目の下を通し、切れ目で約 -3 dB、2 オクターブ上で約 -24 dB 小さくする")
    func lowPassAttenuatesAbove() {
        let q = 0.7071
        #expect(abs(filtered(.lowPass, cutoff: 1000, quality: q, input: 100) - 1) < 0.02)
        #expect(abs(filtered(.lowPass, cutoff: 1000, quality: q, input: 1000) - 0.7071) < 0.02)
        let above = filtered(.lowPass, cutoff: 1000, quality: q, input: 4000)
        #expect(above < 0.08 && above > 0.03)
    }

    @Test("高域通過は、切れ目の上を通し、下を小さくする")
    func highPassAttenuatesBelow() {
        let q = 0.7071
        #expect(abs(filtered(.highPass, cutoff: 1000, quality: q, input: 10_000) - 1) < 0.02)
        #expect(abs(filtered(.highPass, cutoff: 1000, quality: q, input: 1000) - 0.7071) < 0.02)
        let below = filtered(.highPass, cutoff: 1000, quality: q, input: 250)
        #expect(below < 0.08 && below > 0.03)
    }

    @Test("帯域通過は、中心でほぼ 1 を通し、離れるほど小さくする。山の高さが高いほど細い")
    func bandPassPeaksAtTheCenter() {
        let wide = 2.0
        let narrow = 10.0
        #expect(abs(filtered(.bandPass, cutoff: 1000, quality: wide, input: 1000) - 1) < 0.02)
        #expect(filtered(.bandPass, cutoff: 1000, quality: wide, input: 125) < 0.15)
        #expect(filtered(.bandPass, cutoff: 1000, quality: wide, input: 8000) < 0.3)
        // 中心から少し外れた音は、細い帯域のほうがより小さくなる
        #expect(
            filtered(.bandPass, cutoff: 1000, quality: narrow, input: 1250)
                < filtered(.bandPass, cutoff: 1000, quality: wide, input: 1250))
    }

    @Test("係数を変えても状態は残り、リセットすると止まる")
    func biquadKeepsStateUntilReset() {
        var biquad = Biquad()
        biquad.configure(.lowPass, frequency: 1000, quality: 1, sampleRate: Self.rate)
        _ = (0..<100).map { _ in biquad.process(1) }
        biquad.configure(.lowPass, frequency: 2000, quality: 1, sampleRate: Self.rate)
        #expect(biquad.process(0) != 0)
        biquad.reset()
        #expect(biquad.process(0) == 0)
    }

    // MARK: - ディレイ

    @Test("ディレイはインパルスに、遅れごとに 1・feedback・feedback² … の反響を並べる")
    func echoRepeatsWithFeedback() {
        // 標本化率 8000 Hz・0.5 秒で、遅れがちょうど 4000 標本 (小数にならない)
        let kernel = EchoKernel(sampleRate: 8000)
        kernel.configure(time: 0.5, feedback: 0.5)
        let output = (0..<16_000).map { kernel.process($0 == 0 ? 1 : 0) }
        #expect(output[0] == 1)
        #expect(output[4000] == 1)
        #expect(output[8000] == 0.5)
        #expect(output[12_000] == 0.25)
        let others = output.enumerated().filter { ![0, 4000, 8000, 12_000].contains($0.offset) }
        #expect(others.allSatisfy { $0.element == 0 })
    }

    @Test("ディレイの遅れは 1 標本から上限までで、feedback は 0 から手前の 0.99 までへ丸める")
    func echoBoundaries() {
        let kernel = EchoKernel(sampleRate: 8000)
        kernel.configure(time: 0, feedback: 2)
        #expect(kernel.delay == 1)
        #expect(kernel.feedback == EchoKernel.maximumFeedback)
        kernel.configure(time: 100, feedback: -1)
        #expect(kernel.delay == EchoKernel.maximumSeconds * 8000)
        #expect(kernel.feedback == 0)
        // 遅れ 1 標本: 次の標本に反響が出る
        kernel.configure(time: 0, feedback: 0)
        kernel.reset()
        #expect(kernel.process(1) == 1)
        #expect(kernel.process(0) == 1)
        #expect(kernel.process(0) == 0)
    }

    // MARK: - リバーブ

    private func tail(_ reverb: ReverbKernel, from: Int, to: Int) -> Float {
        // 標本化率 8000 Hz。インパルスを入れて、[from, to) 標本の二乗和を返す
        var energy: Float = 0
        for index in 0..<to {
            let value = reverb.process(index == 0 ? 1 : 0)
            if index >= from { energy += value * value }
        }
        return energy
    }

    @Test("残響の割合が 0 なら、通した音がそのまま出る")
    func dryReverbPassesThrough() {
        let reverb = ReverbKernel(sampleRate: 8000)
        reverb.configure(room: 0.8, damp: 0.2, wet: 0)
        let input = sine(440, count: 2000, sampleRate: 8000)
        #expect(input.map { reverb.process($0) } == input)
    }

    @Test("残響は元の音が終わった後も続き、時間とともに小さくなる")
    func reverbTailDecays() {
        let early = ReverbKernel(sampleRate: 8000)
        early.configure(room: 0.5, damp: 0.5, wet: 1)
        let near = tail(early, from: 400, to: 1200)
        let late = ReverbKernel(sampleRate: 8000)
        late.configure(room: 0.5, damp: 0.5, wet: 1)
        let far = tail(late, from: 6000, to: 6800)
        #expect(near > 0)
        #expect(far > 0)
        #expect(near > far * 10)
    }

    @Test("部屋が大きいほど残響が長く残り、リセットすると尾が消える")
    func roomSizeAndReset() {
        let small = ReverbKernel(sampleRate: 8000)
        small.configure(room: 0.1, damp: 0.5, wet: 1)
        let large = ReverbKernel(sampleRate: 8000)
        large.configure(room: 0.95, damp: 0.5, wet: 1)
        #expect(tail(large, from: 4000, to: 6000) > tail(small, from: 4000, to: 6000) * 10)

        large.reset()
        #expect((0..<1000).allSatisfy { _ in large.process(0) == 0 })
    }

    /// **丸めたことは、端の値で組んだものと標本ごとに一致することで見る。** 出力の上限だけを
    /// 見ていた頃は、wet を丸め忘れても最初の標本が -8 で上限の内に収まり、通った (#2284)。
    @Test("残響の範囲の外の値は端へ丸められ、どの設定でも発散しない")
    func reverbStaysBounded() {
        func impulseResponse(room: Float, damp: Float, wet: Float) -> [Float] {
            let reverb = ReverbKernel(sampleRate: 8000)
            reverb.configure(room: room, damp: damp, wet: wet)
            return (0..<8000).map { reverb.process($0 == 0 ? 1 : 0) }
        }
        let above = impulseResponse(room: 5, damp: -3, wet: 9)
        #expect(above == impulseResponse(room: 1, damp: 0, wet: 1))
        // 下の端。wet が 0 だと部屋の設定が出口に出ないので、wet は分けて見る
        #expect(
            impulseResponse(room: -1, damp: 2, wet: 1) == impulseResponse(room: 0, damp: 1, wet: 1))
        #expect(
            impulseResponse(room: 0.5, damp: 0.5, wet: -1)
                == impulseResponse(room: 0.5, damp: 0.5, wet: 0))
        #expect(above.map(abs).max() ?? .infinity < 10)
    }
}
