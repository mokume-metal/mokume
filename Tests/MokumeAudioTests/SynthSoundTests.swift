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
    func setup() throws { try Self.onSetup(self) }
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

    /// 同じ設定を、ラックだけで進めたときの `frame` 番目 (0 始まり) のフレームの解析の値。前のフレームから
    /// このフレームまでに出口に出た標本が区間で、最初のフレームは標本が進んでいない空の区間 (無音のまま)。
    private func expected(
        frame: Int, perFrame: Int = Self.perFrame, _ build: (SynthRack) throws -> RackNode
    ) throws -> AudioLevels {
        let rack = SynthRack(sampleRate: 48_000)
        let node = try build(rack)
        guard frame > 0 else { return .silence }
        // 区間は実装の取り出し (`snapshot(since:)`) を通さず、1 フレームずつ集めた出口の標本から切る
        var stream: [Float] = []
        for _ in 0..<frame {
            rack.advance(frames: perFrame)
            stream += node.meter.snapshot(perFrame).samples
        }
        return AudioAnalysis.analyze(span(of: stream, from: (frame - 1) * perFrame, to: frame * perFrame))
    }

    // MARK: - 走っている実行の外から作る (#2740)

    /// **音の流れを先に足してあれば、外 (`draw()` で起こした `Task` など) から作った合成音も、その流れに入って
    /// 解析され、警告は出ない** ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。ステージは
    /// スケッチごとに 1 つで、既にあれば走っているかを見ずに返す。外で作ると鳴らない音を返すのは、流れをまだ
    /// 足していないときだけである (`AudioOutsideRunTests`)。フレームとフレームの間は走っている実行の外にあたる。
    @Test("setup() で合成音を作って流れを足した後なら、外から作った合成音もその流れで解析され、警告は出ない (#2740)")
    func aSoundMadeOutsideJoinsAnExistingStage() throws {
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            var sketch: SynthSketch?
            var late: SinOsc?
            var heard: [Float] = []
            let runtime = try run(
                frames: 8,
                setup: { made in
                    sketch = made
                    _ = made.createSinOsc()
                },
                draw: { _ in if let late { heard.append(late.level) } },
                between: { frame in
                    guard frame == 1, let sketch else { return }
                    #expect(runningSketch == nil, "フレームの間は走っている実行の外")
                    let osc = sketch.createSinOsc()
                    osc.play(1000, 0.4)
                    late = osc
                })
            runtime.closePlugins()
            #expect(log.message(for: "createSinOsc()") == nil)
            #expect(heard.count == 7)
            #expect(heard.last ?? 0 > 0, "外で作った音が、先に足した流れで解析されていない")
        }
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

    /// `draw()` の中で毎フレーム `hit(440)` (作って包絡をかけて手放す) を 600 フレーム回す。
    ///
    /// 作った音の節を検査が掴んでおき、次のフレームで、その節の出口の写しに立ち上がりが出ているかを読む
    /// (掴むのは節であって音ではない — 音を掴むと手放せない)。
    private func discardEveryFrame(frames: Int = 600) throws -> (
        made: Int, onsets: [Float], notices: [String], peakOccupied: Int
    ) {
        var notices: [String] = []
        var made = 0
        var onsets: [Float] = []
        var peakOccupied = 0
        var env: Env?
        var stage: SynthStage?
        var previous: RackNode?
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                stage = SynthStage.stage(for: sketch, warn: { notices.append($0) })
                env = sketch.createEnv()
            },
            draw: { sketch in
                // 前のフレームで作った音は、このフレームの頭に 1 フレームぶん進んでいる
                if let previous {
                    onsets.append(previous.meter.latest(Self.perFrame).map { abs($0) }.max() ?? 0)
                }
                let node = hit(sketch, env)
                if node != nil { made += 1 }
                previous = node
                peakOccupied = max(peakOccupied, stage?.rack.occupiedCount ?? 0)
            })
        runtime.closePlugins()
        return (made, onsets, notices, peakOccupied)
    }

    /// 毎フレーム作って捨てる音。`osc` はこの関数が返ると手放される。節を返す。
    private func hit(_ sketch: SynthSketch, _ env: Env?) -> RackNode? {
        let osc = sketch.createTriOsc()
        osc.freq(440)
        env?.play(osc, 0.005, 0.05, 0.6, 0.3)
        return osc.node
    }

    @Test("draw() の中で毎フレーム作って捨てる音は、600 フレーム続けても毎回鳴り、容量の知らせは出ない (#2763)")
    func discardingInDrawNeverRunsOut() throws {
        let first = try discardEveryFrame()
        #expect(first.made == 600, "作れなかった音がある")
        #expect(first.notices.isEmpty, "知らせ: \(first.notices)")
        // 作った次のフレームごとに、立ち上がりがラックの出口に出ている (変更前は 65 個目から出ない)
        #expect(first.onsets.count == 599)
        #expect(first.onsets.allSatisfy { $0 > 0.01 }, "立ち上がりが出なかったフレームがある")
        // 同時に生きているのは 0.355 秒 × 60 ≈ 22 個と、返す番号を受け取るまでの数フレームぶん
        #expect(first.peakOccupied < 40, "同時に埋まった数: \(first.peakOccupied)")

        // 2 回回すと一致する (ADR-0025 の水準 2)
        let second = try discardEveryFrame()
        #expect(second.onsets == first.onsets)
        #expect(second.peakOccupied == first.peakOccupied)
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

    /// 閉じずに捨てたスケッチのステージが生きている間に、その番地を別のスケッチが引き継ぐと、ステージを
    /// 番地だけで探す形では前の回のラックを引き継ぐ。照らし合わせる持ち主 (``SynthStage`` の `owner`) が
    /// それを止める。
    ///
    /// **番地の引き継ぎは待たずに、検査が作る** ([#2711])。引き継ぎは割り当て器しだいで、専用機では
    /// 40 回組み直しても起きない回があった。前の回のステージを、次のスケッチの番地の鍵の下へ置き直して
    /// (``SynthStage/stages``)、引き継いだときと同じ状態にしてから次のスケッチのステージを求める。
    ///
    /// **前の回のステージは、検査が掴んで生かしておく。** ステージはスケッチの音が強く持つだけなので、
    /// 掴まなければスケッチと一緒に解放され、探す先に何も残らない — 持ち主の照らし合わせを消しても緑の
    /// ままになる (#2711 の反証で見つけた)。
    ///
    /// [#2711]: https://github.com/mokume-metal/mokume/issues/2711
    @Test("閉じずに捨てられたスケッチの番地を、別のスケッチが引き継いでも、前のステージは持ち越さない")
    func reusedAddressDoesNotInheritTheStage() throws {
        // 前の回: 閉じずに捨てる (台帳の検査がしている形)。ステージだけを掴む
        var dropped: SynthStage?
        _ = try run(
            frames: 3,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                dropped = stage
                SinOsc(stage: stage).play(440, 0.5)
            })
        let previous = try #require(dropped)
        try #require(!previous.isClosed, "前の回のステージが閉じている (探す先として残っていない)")
        try #require(previous.rack.rendered > 0, "前の回のラックが進んでいない (持ち越しを見分けられない)")

        // 次の回: 前の回のステージを、このスケッチの番地の鍵の下へ置いてから求める
        var inherited = false
        var startedAt = -1
        _ = try run(
            frames: 3,
            setup: { sketch in
                SynthStage.stages[ObjectIdentifier(sketch)] = SynthStage.Weak(stage: previous)
                let stage = SynthStage.stage(for: sketch)
                inherited = stage === previous
                startedAt = stage.rack.rendered
                SinOsc(stage: stage).play(440, 0.5)
            })
        #expect(!inherited, "前のスケッチのステージを引き継いだ")
        #expect(startedAt == 0)
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

    // MARK: - 解析は読まれたときだけ (#2379)

    /// **値を読まない音は解析されず、読む音は 1 フレームに 1 回だけ解析される。** 鳴らした音は止めた後も
    /// 毎フレーム窓を切るが、解くのは読まれたときだけである ([#2379])。解析は共有の解析器
    /// (``AudioAnalyzer``) を通る。
    ///
    /// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
    @Test("値を読まない音は解析されず、読む音は 1 フレームに何度読んでも 1 回だけ解析される")
    func onlyTheValuesThatAreReadGetAnalyzed() throws {
        let frames = 6
        var unread: SynthSound?
        var read: SynthSound?
        let analyzerBefore = AudioAnalyzer.shared.analyses
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: nil)
                let first = SinOsc(stage: stage)
                first.play(1000, 0.4)
                let second = SinOsc(stage: stage)
                second.play(500, 0.4)
                unread = first
                read = second
            },
            draw: { _ in
                guard let read else { return }
                _ = read.level
                _ = read.spectrum
                _ = read.rms
            })
        runtime.closePlugins()

        #expect(unread?.analyses == 0)
        // 最初のフレームは標本が進んでいない空の区間で、解く物が無い
        #expect(read?.analyses == frames - 1)
        #expect(AudioAnalyzer.shared.analyses - analyzerBefore == frames - 1, "解析は共有の解析器を通る")
    }

    /// **遅らせた解析は、フレームの頭の窓を解く。** 読む前に音だけが先へ進んでも (実時間の再生では
    /// 音の側が先へ進む)、値は毎フレーム解析していたときと同じで、進んだ分の標本は拾わない。
    @Test("読む前に音が先へ進んでも、値はフレームの頭の窓のものでビット一致する")
    func aLateReadStillSolvesTheWindowFromTheStartOfTheFrame() throws {
        let frames = 6
        var sound: SynthSound?
        var stage: SynthStage?
        var heard: [Sounded] = []
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                let made = SynthStage.stage(for: sketch, flow: nil)
                let osc = SinOsc(stage: made)
                osc.play(1000, 0.4)
                sound = osc
                stage = made
            },
            draw: { sketch in
                guard let sound, let stage else { return }
                // フレームの頭の後、読む前に、音だけが 1700 標本先へ進む (最後のフレームだけ。
                // 以後に進める位置は、この検査が終わるので影響しない)
                if sketch.frameCount == frames { stage.rack.advance(frames: 1_700) }
                heard.append(Sounded(sound))
            })
        runtime.closePlugins()

        #expect(heard.count == frames)
        for (index, frame) in heard.enumerated() {
            let levels = try expected(frame: index) { rack in
                try addSource(rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.4])
            }
            #expect(frame.rms == levels.rms, "frame \(index + 1)")
            #expect(frame.level == levels.level, "frame \(index + 1)")
            #expect(frame.spectrum == levels.spectrum, "frame \(index + 1)")
            #expect(frame.spectrumLevels == levels.spectrumLevels, "frame \(index + 1)")
        }
    }
}
