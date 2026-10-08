// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ (合成した音の用)。
final class SynthSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (SynthSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (SynthSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { try? Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 1 フレームで聞こえたもの。
struct Sounded: Equatable {
    var rms: Float
    var level: Float
    var spectrum: [Float]
    var spectrumLevels: [Float]

    init(_ sound: SynthSound) {
        rms = sound.rms
        level = sound.level
        spectrum = sound.spectrum
        spectrumLevels = sound.spectrumLevels
    }

    /// いちばん大きい帯域の番号。
    var peakBand: Int {
        spectrum.enumerated().max { $0.element < $1.element }?.offset ?? 0
    }
}

/// 合成した音の、スケッチの中での振る舞い (#1980)。走っているスケッチの中で回すので GPU を要する。
///
/// 書き出しの経路 (固定の時計) は鳴らさずに回る。鳴らす経路は、manual rendering (offline) の
/// 流れを差し込んで回す — 出力の機材には出さない。
@Suite(
    "合成した音",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SynthSoundTests {
    /// 60 fps・48 kHz の 1 フレームぶんの標本の数。
    private static let perFrame = 800

    private func run(
        frames: Int, clock: Clock? = nil, setup: @escaping (SynthSketch) throws -> Void,
        draw: @escaping (SynthSketch) -> Void = { _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> SketchRuntime {
        SynthSketch.onSetup = setup
        SynthSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: SynthSketch(), gpu: try RenderDevice(), clock: clock)
        for frame in 1...frames {
            try runtime.advance()
            try between(frame)
        }
        return runtime
    }

    /// 作った音を回し、`draw()` で聞こえたものをフレームごとに返す。`act` は記録の後に、そのフレームの
    /// 番号で呼ぶ。
    private func record(
        frames: Int, clock: Clock? = nil, flow: SoundFlow? = nil,
        _ make: @escaping (SynthSketch, SynthStage) throws -> SynthSound,
        act: @escaping (SynthSound, Int) -> Void = { _, _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> [Sounded] {
        var sound: SynthSound?
        var heard: [Sounded] = []
        let runtime = try run(
            frames: frames, clock: clock,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: flow)
                sound = try make(sketch, stage)
            },
            draw: { sketch in
                guard let sound else { return }
                heard.append(Sounded(sound))
                act(sound, sketch.frameCount)
            },
            between: between)
        runtime.closePlugins()
        return heard
    }

    /// 1000 Hz・音量 0.4 の正弦波を鳴らす作り方 (音量は既定の 0.5 と違う値にしてある)。
    private let sine: (SynthSketch, SynthStage) throws -> SynthSound = { _, stage in
        let osc = SinOsc(stage: stage)
        osc.play(1000, 0.4)
        return osc
    }

    /// 同じ設定を、ラックだけで進めたときの `frame` 番目 (0 始まり) のフレームの解析の値。
    private func expected(
        frame: Int, perFrame: Int = Self.perFrame, _ build: (SynthRack) throws -> RackNode
    ) throws -> AudioLevels {
        let rack = SynthRack(sampleRate: 48_000)
        let node = try build(rack)
        rack.advance(frames: frame * perFrame)
        return AudioAnalysis.analyze(node.meter.latest(AudioAnalysis.windowSize))
    }

    // MARK: - 書き出し (固定の時計) の窓

    @Test("固定の時計で回すと、鳴らし始めてからの標本で終わる窓が解析され、帯域は周波数のところにある")
    func exportAnalyzesTheRenderedWindow() throws {
        let heard = try record(frames: 8, sine)
        #expect(heard.count == 8)
        #expect(heard[0].level == 0)
        for (index, frame) in heard.enumerated() {
            let levels = try expected(frame: index) { rack in
                let node = try addSource(
                    rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.4])
                return node
            }
            #expect(frame.level == levels.level, "frame \(index + 1)")
            #expect(frame.spectrum == levels.spectrum, "frame \(index + 1)")
        }
        // 1000 Hz は帯域 1000 × 1024 ÷ 48000 ≈ 21.3。落ち着いた後はそこがいちばん大きい
        #expect(heard.suffix(4).allSatisfy { $0.peakBand == 21 })
        // 振幅 0.4 の正弦波の RMS は 0.4 / √2
        #expect(abs(heard[7].rms - 0.4 / Float(2).squareRoot()) < 0.01)
    }

    @Test("固定の時計で 2 度書き出すと、全部のフレームで同じ値になる")
    func exportIsRepeatable() throws {
        let make: (SynthSketch, SynthStage) throws -> SynthSound = { _, stage in
            let noise = PinkNoise(stage: stage)
            let band = BandPass(stage: stage)
            noise.play(0.4)
            band.process(noise, 900, 300)
            let reverb = Reverb(stage: stage)
            reverb.process(band, 0.8, 0.4, 0.5)
            return reverb
        }
        let first = try record(frames: 10, make)
        let second = try record(frames: 10, make)
        #expect(first == second)
        #expect(Set(first.map(\.level)).count > 1)
        #expect(first.last?.level ?? 0 > 0)
    }

    @Test("周波数をスケッチから変えると、窓の帯域がそれに追いつく (マウスの位置で音程を動かす形)")
    func frequencyFollowsTheSketch() throws {
        let heard = try record(
            frames: 24, sine,
            act: { sound, frame in
                // 12 フレームまでは 500 Hz、その後は 1500 Hz
                (sound as? SinOsc)?.freq(frame < 12 ? 500 : 1500)
            })
        // 500 Hz → 帯域 10.7、1500 Hz → 帯域 32.0
        #expect(heard[10].peakBand == 11)
        #expect(heard[23].peakBand == 32)
    }

    @Test("書き出しの位置は、作品の宣言ではなく書き出しの時計の fps で進み、時刻を止めても音は進む")
    func exportFollowsTheClockRate() throws {
        var rendered: [Int] = []
        _ = try record(
            frames: 3, clock: .frameIndex(frameRate: 30), sine,
            act: { sound, _ in rendered.append(sound.stage.rack.rendered) })
        #expect(rendered == [0, 1600, 3200])

        var stopped: [Int] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let osc = SinOsc(stage: SynthStage.stage(for: sketch))
                osc.play(440, 0.5)
                sketch.pauseTime()
            },
            draw: { sketch in
                stopped.append(SynthStage.stage(for: sketch).rack.rendered)
            })
        #expect(stopped == [0, 800, 1600, 2400])
        runtime.closePlugins()
    }

    // MARK: - 実際に鳴らす流れ

    @Test("実時間の速さで鳴らした再生は、書き出しと同じ値を取り、鳴った音も同じ設定のラックの音になる")
    func playbackMatchesExport() throws {
        let exported = try record(frames: 8, sine)

        // 1 フレームぶんずつ描かせる流れ = 実時間の再生を、機材に出さずに回す
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var heardSound = Stereo()
        let played = try record(
            frames: 8, flow: flow, sine,
            between: { _ in
                let piece = try renderStereo(flow, Self.perFrame)
                heardSound.left += piece.left
                heardSound.right += piece.right
            })
        #expect(played == exported)

        // 鳴った音は、同じ設定のラックが作る音そのもの
        let rack = SynthRack(sampleRate: 48_000)
        _ = try addSource(rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.4])
        let pure = render(rack, 8 * Self.perFrame)
        let worst = zip(heardSound.left, pure.left).map { abs($0 - $1) }.max() ?? 1
        #expect(heardSound.left.count == 8 * Self.perFrame)
        #expect(worst < 1e-6)
        #expect(heardSound.left.map { abs($0) }.max() ?? 0 > 0.2)
    }

    // MARK: - 音源とエフェクトの操作

    @Test("エフェクトを通した音の解析は、エフェクトの出口の音で、高い帯域が切れ目で小さくなる")
    func effectOutputIsAnalyzed() throws {
        var noises: [Sounded] = []
        var filtered: [Sounded] = []
        var noise: WhiteNoise?
        var filter: LowPass?
        let runtime = try run(
            frames: 12,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                noise = WhiteNoise(stage: stage)
                filter = LowPass(stage: stage)
                noise?.play(0.3)
                if let noise { filter?.process(noise, 500) }
            },
            draw: { _ in
                if let noise, let filter {
                    noises.append(Sounded(noise))
                    filtered.append(Sounded(filter))
                }
            })
        runtime.closePlugins()

        func power(_ sounded: Sounded, _ range: Range<Int>) -> Float {
            sounded.spectrum[range].reduce(0) { $0 + $1 * $1 }
        }
        let before = try #require(noises.last)
        let after = try #require(filtered.last)
        // 低い帯域 (94〜330 Hz) は残り、高い帯域 (2.3〜12 kHz) は小さくなる
        let low = power(after, 2..<7) / power(before, 2..<7)
        let high = power(after, 50..<256) / power(before, 50..<256)
        #expect(low > 0.5 && low < 2, "low \(low)")
        #expect(high < 0.01, "high \(high)")
        // 通した音は直には出ず、白色雑音そのものの解析はそのまま読める
        #expect(power(before, 50..<256) > 0)
        #expect(after.level < before.level)
    }

    @Test("包絡をかけると、形の間だけ音が出て、終わった後は無音に戻る。鳴っていなければ鳴らし始める")
    func envelopeTriggersAndEnds() throws {
        var env: Env?
        let heard = try record(
            frames: 12,
            { sketch, stage in
                env = sketch.createEnv()
                return SinOsc(stage: stage)
            },
            act: { sound, frame in
                // 2 フレーム目に、0.02 秒で立ち上がり、0.03 秒保ち、0.03 秒で下がる (計 0.08 秒 = 5 フレーム弱)
                if frame == 2, let osc = sound as? SinOsc { env?.play(osc, 0.02, 0.03, 0.8, 0.03) }
            })
        #expect(heard[0].level == 0 && heard[1].level == 0)
        #expect(heard[3].level > 0.5)
        #expect(heard[4].level > 0.5)
        // 形が終わってから窓 (約 21 ミリ秒) が過ぎた後は無音
        #expect(heard[10].level == 0 && heard[11].level == 0)
    }

    @Test("範囲の外の値は端へ丸め、数でない値は無視して、どちらも 1 度だけ知らせる")
    func invalidValuesAreWarnedOnce() throws {
        var messages: [String] = []
        let runtime = try run(
            frames: 2,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, warn: { messages.append($0) })
                let osc = SinOsc(stage: stage)
                osc.freq(.nan)
                osc.freq(.infinity)
                osc.amp(3)
                osc.amp(-1)
                osc.add(5)
                osc.pan(-9)
                osc.freq(1e9)
                let delay = Delay(stage: stage)
                delay.process(osc, 0.5)
                delay.time(2)
                delay.feedback(4)
                let filter = LowPass(stage: stage)
                filter.freq(1)
                filter.res(0)
                Env().play(osc, -1, .nan, 2, 0.1)
            })
        runtime.closePlugins()
        #expect(messages.count == 11)
        #expect(Set(messages).count == messages.count)
        #expect(messages.filter { $0.hasPrefix("freq() got a value") }.count == 1)
        #expect(messages.filter { $0.hasPrefix("amp() takes") }.count == 1)
        #expect(messages.contains { $0.hasPrefix("time() takes a delay time from 0.0 to 0.5") })
        #expect(messages.contains { $0.hasPrefix("Env.play() got a value that is not a number") })
    }

    @Test("エフェクトの出口を、その入力へ戻す通し方は拒み、エフェクトごとに 1 度だけ知らせる")
    func cyclesAreWarned() throws {
        var messages: [String] = []
        let runtime = try run(
            frames: 2,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, warn: { messages.append($0) })
                let osc = SinOsc(stage: stage)
                let filter = LowPass(stage: stage)
                let reverb = Reverb(stage: stage)
                filter.process(osc)
                reverb.process(filter)
                filter.process(reverb)
                filter.process(reverb)
                reverb.process(reverb)
                reverb.process(reverb)
            })
        runtime.closePlugins()
        // 低域通過 (輪になる通し方) と、リバーブ (自分自身) が 1 度ずつ
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.hasPrefix("process() was given a sound") })
        #expect(messages.contains { $0.contains("this LowPass") })
        #expect(messages.contains { $0.contains("this Reverb") })
    }

    @Test("作れる数の上限を越えると、1 度だけ知らせ、何も鳴らさない音を返す")
    func capacityIsReportedOnce() throws {
        var messages: [String] = []
        var extras: [SinOsc] = []
        let runtime = try run(
            frames: 3,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, warn: { messages.append($0) })
                for _ in 0..<(SynthRack.capacity + 3) {
                    let osc = SinOsc(stage: stage)
                    osc.play(440, 0.1)
                    if osc.node == nil { extras.append(osc) }
                }
            })
        runtime.closePlugins()
        #expect(extras.count == 3)
        #expect(messages.count == 1)
        #expect(extras.allSatisfy { $0.level == 0 && $0.rms == 0 })
    }

    @Test("スケッチが終わると値は無音になり、その後の操作は捨てられる")
    func closeSilencesAndForgets() throws {
        var osc: SinOsc?
        var firstStage: SynthStage?
        let runtime = try run(
            frames: 6,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                firstStage = stage
                osc = SinOsc(stage: stage)
                osc?.play(1000, 0.5)
            })
        #expect(osc?.level ?? 0 > 0)
        runtime.closePlugins()
        #expect(osc?.level == 0 && osc?.rms == 0)
        let before = firstStage?.rack.rendered ?? -1
        // 閉じた後の操作は何も起こさない (投げもしない)
        osc?.freq(2000)
        osc?.stop()
        #expect(firstStage?.isClosed == true)
        #expect(firstStage?.rack.rendered == before)
    }

    @Test("閉じずに捨てられたスケッチの番地を、別のスケッチが引き継いでも、前のステージは持ち越さない")
    func reusedAddressDoesNotInheritTheStage() throws {
        // 同じ参照スケッチを、閉じずに何度も組む (台帳の検査がしている形)。手放された番地は
        // 次のスケッチに使い回されやすく、ステージを番地だけで探すと前の回のラックを引き継ぐ
        for round in 0..<40 {
            var startedAt = -1
            _ = try run(
                frames: 3,
                setup: { sketch in
                    let stage = SynthStage.stage(for: sketch)
                    startedAt = stage.rack.rendered
                    SinOsc(stage: stage).play(440, 0.5)
                })
            #expect(startedAt == 0, "round \(round)")
        }
    }

    @Test("手放した音は、ラックの節として鳴り続ける")
    func droppedSoundsKeepPlaying() throws {
        var reverb: Reverb?
        weak var dropped: SinOsc?
        let runtime = try run(
            frames: 8,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                let fx = Reverb(stage: stage)
                // 残響の割合 0 では、通した音がそのまま出る
                fx.set(0.5, 0.5, 0)
                reverb = fx
                do {
                    // 変数に残さない
                    let osc = SinOsc(stage: stage)
                    osc.play(1000, 0.4)
                    fx.process(osc)
                    dropped = osc
                }
            })
        #expect(dropped == nil)
        // 手放した音は、エフェクトの入力として鳴っている
        #expect((reverb?.level ?? 0) > 0.7)
        #expect(reverb?.sampleRate == 48_000)
        runtime.closePlugins()
    }

    @Test("解析の値の名前は AudioIn と同じで、書き出しの音を 1 つ 1 つ読める")
    func readoutsMatchTheAnalysis() throws {
        let heard = try record(frames: 6, sine)
        let last = try #require(heard.last)
        #expect(last.spectrum.count == AudioAnalysis.bandCount)
        #expect(last.spectrumLevels.count == AudioAnalysis.bandCount)
        let rebuilt = try expected(frame: 5) { rack in
            try addSource(rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.4])
        }
        #expect(last.rms == rebuilt.rms)
        #expect(last.spectrumLevels == rebuilt.spectrumLevels)
    }
}
