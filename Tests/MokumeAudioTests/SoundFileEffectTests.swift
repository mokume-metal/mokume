// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ (音声ファイルをエフェクトに通す用)。
final class EffectSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (EffectSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (EffectSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { try? Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// `SoundFile` を合成した音と同じエフェクトに通す (#2220)。走っているスケッチの中で回すので GPU を要する。
///
/// 書き出しの経路 (固定の時計) は鳴らさずに回り、鳴らす経路は manual rendering (offline) の流れを
/// 差し込んで回す — 出力の機材には出さない。
@Suite(
    "音声ファイルをエフェクトに通す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundFileEffectTests {
    /// 60 fps・48 kHz の 1 フレームぶんの標本の数。
    private static let perFrame = 800
    /// 中央に定位した出口の係数。
    private static let center = Float(0.5).squareRoot()

    /// 10 秒・48 kHz の音 (拍で揺れる和音を繰り返す)。
    private static let tenSeconds: [Float] = (0..<480_000).map { chord[$0 % chord.count] }

    /// 白色雑音 (1 秒・48 kHz)。種が決まっているので、何度作っても同じ。
    private static let noise: [Float] = {
        var state: UInt32 = 12_345
        return (0..<48_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
        }
    }()

    // MARK: - 回し方

    private func run(
        frames: Int, setup: @escaping (EffectSketch) throws -> Void,
        draw: @escaping (EffectSketch) -> Void = { _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> SketchRuntime {
        EffectSketch.onSetup = setup
        EffectSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: EffectSketch(), gpu: try RenderDevice())
        for frame in 1...frames {
            try runtime.advance()
            try between(frame)
        }
        return runtime
    }

    /// 1 フレームで聞こえた、ファイル自身の値。
    private struct Moment: Equatable {
        var isPlaying: Bool
        var position: Int
        var level: Float
        var spectrum: [Float]
    }

    /// 1 フレームで聞こえた、エフェクトの出口の値。
    private struct Effected: Equatable {
        var rms: Float
        var level: Float
        var spectrum: [Float]
    }

    private struct Take {
        var file: [Moment] = []
        var effect: [Effected] = []
        /// 流れを差し込んだとき、フレームごとに描かせた左右の音。
        var heard = Stereo()
        var filter: LowPass?
        var song: SoundFile?
    }

    /// ファイルを読み、`LowPass` を足して回し、フレームごとの値を返す。
    ///
    /// - Parameters:
    ///   - flow: 実際に鳴らす流れ (差し込むと、フレームごとに 1 フレームぶん描かせる)。`nil` なら固定の時計。
    ///   - stageFirst: 音のステージ (エフェクトを作る前提) を、ファイルを読む前に足すか。
    ///   - route: エフェクトへ通すか。通さなければ、エフェクトは作るが入力は無い。
    ///   - routeAt: 通すフレーム。`nil` なら `setup()` で通す。
    ///   - start: `setup()` で、通した後に呼ぶ操作。
    ///   - act: `draw()` の記録の後に、フレームの番号で呼ぶ操作。
    private func take(
        frames: Int, flow: SoundFlow? = nil, url: URL, stageFirst: Bool = true, route: Bool = true,
        routeAt: Int? = nil, cutoff: Float = 20_000,
        start: @escaping (SoundFile) -> Void = { $0.loop() },
        act: @escaping (SoundFile, Int) -> Void = { _, _ in }
    ) throws -> Take {
        var result = Take()
        var song: SoundFile?
        var filter: LowPass?
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                var stage = stageFirst ? SynthStage.stage(for: sketch, flow: flow) : nil
                let loaded = try flow.map { try sketch.loadSound(url.path, flow: $0) }
                    ?? sketch.loadSound(url.path)
                if stage == nil { stage = SynthStage.stage(for: sketch, flow: flow) }
                let low = LowPass(stage: try #require(stage))
                low.freq(cutoff)
                if route, routeAt == nil { low.process(loaded) }
                start(loaded)
                song = loaded
                filter = low
            },
            draw: { sketch in
                guard let song, let filter else { return }
                result.file.append(
                    Moment(
                        isPlaying: song.isPlaying, position: song.samplePosition,
                        level: song.level, spectrum: song.spectrum))
                result.effect.append(
                    Effected(rms: filter.rms, level: filter.level, spectrum: filter.spectrum))
                if route, let routeAt, sketch.frameCount == routeAt { filter.process(song) }
                act(song, sketch.frameCount)
            },
            between: { _ in
                guard let flow else { return }
                let piece = try renderStereo(flow, Self.perFrame)
                result.heard.left += piece.left
                result.heard.right += piece.right
            })
        runtime.closePlugins()
        result.filter = filter
        result.song = song
        return result
    }

    private func offline(sampleRate: Double = 48_000) throws -> SoundFlow {
        try SoundFlow.offline(sampleRate: sampleRate, channels: 2, maximumFrames: 4096)
    }

    /// 帯域 `100..<512` の大きさの二乗平均の平方根 (振幅の単位)。
    private func highBandLevel(_ heard: [Float]) -> Float {
        let spectrum = AudioAnalysis.analyze(Array(heard.suffix(AudioAnalysis.windowSize))).spectrum
        let high = spectrum[100..<512]
        return (high.map { $0 * $0 }.reduce(0, +) / Float(high.count)).squareRoot()
    }

    /// 位置・秒・ループ・飛ぶを混ぜた操作の列 (#2464)。
    private static let operations: (SoundFile, Int) -> Void = { song, frame in
        switch frame {
        case 12: song.pause()
        case 16: song.play()
        case 20: song.jump(5)
        case 23: song.pause()
        case 24: song.jump(2.5)
        case 26: song.play()
        case 30: song.jump(7)
        case 34: song.stop()
        case 36: song.loop()
        default: break
        }
    }

    // MARK: - 1: 7 つの形すべてが SoundFile を受ける

    @Test("process の 7 つの形が、どれも SoundFile を受けて、エフェクトが動き出す")
    func everyShapeTakesASoundFile() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var effects: [SoundEffect] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let song = try sketch.loadSound(url.path)
                let stage = SynthStage.stage(for: sketch)
                let low = LowPass(stage: stage)
                let high = HighPass(stage: stage)
                let band = BandPass(stage: stage)
                let reverb = Reverb(stage: stage)
                let delay = Delay(stage: stage)
                low.process(song)
                high.process(song, 800)
                let again = LowPass(stage: stage)
                again.process(song, 800, 2)
                band.process(song, 1000, 200)
                reverb.process(song, 0.8, 0.3, 0.5)
                delay.process(song, 2)
                let echo = Delay(stage: stage)
                echo.process(song, 2, 0.5)
                // 合成した音も、エフェクトも、いままでどおり通る
                let osc = SinOsc(stage: stage)
                let after = Reverb(stage: stage)
                after.process(osc)
                after.process(low)
                effects = [low, high, again, band, reverb, delay, echo, after]
                song.loop()
            })
        #expect(effects.count == 8)
        #expect(effects.allSatisfy { $0.isActive })
        runtime.closePlugins()
    }

    // MARK: - 2: 通した音がエフェクトを通る

    @Test("白色雑音のファイルを切れ目 800 Hz の LowPass に通すと、高い帯域が 40 dB 以上下がり、直には聞こえない")
    func theEffectFiltersTheFile() throws {
        let url = try writeWAV(Self.noise, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 20
        let direct = try take(frames: frames, flow: try offline(), url: url, route: false)
        let routed = try take(frames: frames, flow: try offline(), url: url, cutoff: 800)

        let before = highBandLevel(direct.heard.left)
        let after = highBandLevel(routed.heard.left)
        #expect(before > 0.001, "通さない雑音は高い帯域に音がある: \(before)")
        let drop = 20 * log10(before / max(after, 1e-12))
        #expect(drop >= 40, "高い帯域が \(drop) dB しか下がらない")

        // 聞こえたのは、エフェクトの出口の音だけ (ファイルの音が直に混ざっていない)
        let node = try #require(routed.filter?.node)
        let outlet = node.meter.latest(AudioAnalysis.windowSize)
        let tail = Array(routed.heard.left.suffix(AudioAnalysis.windowSize))
        let worst = zip(tail, outlet).map { abs($0 - $1 * Self.center) }.max() ?? 1
        #expect(worst < 1e-5, "出口と聞こえた音のずれ \(worst)")
        #expect(mismatch(routed.heard.left, routed.heard.right) == nil, "左右は畳まれて同じ")
    }

    // MARK: - 3: 決定論

    @Test("ファイル → 濾波器 → リバーブを offline の流れで 2 度回すと同じ標本で、流れの描かせる長さを変えても同じ")
    func offlineIsRepeatable() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        func heard(chunk: Int) throws -> Stereo {
            let flow = try offline()
            var result = Stereo()
            let runtime = try run(
                frames: 1,
                setup: { sketch in
                    let stage = SynthStage.stage(for: sketch, flow: flow)
                    let song = try sketch.loadSound(url.path, flow: flow)
                    let low = LowPass(stage: stage)
                    let reverb = Reverb(stage: stage)
                    low.process(song, 600)
                    reverb.process(low, 0.8, 0.3, 0.5)
                    song.loop()
                },
                between: { _ in result = try renderStereo(flow, 12_288, chunk: chunk) })
            runtime.closePlugins()
            return result
        }
        let first = try heard(chunk: 4096)
        let second = try heard(chunk: 4096)
        #expect(mismatch(first, second) == nil)
        #expect(mismatch(try heard(chunk: 1000), first) == nil)
        #expect(first.left.map { abs($0) }.max() ?? 0 > 0.05, "音が出ている")
    }

    @Test("固定の時計で 2 度書き出すと、全フレームでエフェクトの解析値が同じで、フレームごとに動く")
    func exportIsRepeatable() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        func effects() throws -> [Effected] {
            var seen: [Effected] = []
            var reverb: Reverb?
            let runtime = try run(
                frames: 10,
                setup: { sketch in
                    let stage = SynthStage.stage(for: sketch)
                    let song = try sketch.loadSound(url.path)
                    let low = LowPass(stage: stage)
                    let wash = Reverb(stage: stage)
                    low.process(song, 600)
                    wash.process(low, 0.8, 0.3, 0.5)
                    song.loop()
                    reverb = wash
                },
                draw: { _ in
                    guard let reverb else { return }
                    seen.append(Effected(rms: reverb.rms, level: reverb.level, spectrum: reverb.spectrum))
                })
            runtime.closePlugins()
            return seen
        }
        let first = try effects()
        let second = try effects()
        #expect(first.count == 10)
        #expect(first == second)
        #expect(Set(first.map(\.level)).count > 1)
        #expect(first.last?.level ?? 0 > 0)
    }

    // MARK: - 4: 位置が 2 経路で同じ

    @Test("通した SoundFile と通さない SoundFile で、同じ操作の列 (jump も) から、位置も解析値も毎フレーム同じ")
    func positionIsTheSameThroughTheEffect() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 44
        // 固定の時計 (鳴らさない)
        let plain = try take(
            frames: frames, url: url, route: false, act: Self.operations)
        let framed = try take(frames: frames, url: url, act: Self.operations)
        #expect(framed.file == plain.file)
        // 実際に鳴らす流れ (位置は節が描いた数から読む)
        let playedPlain = try take(
            frames: frames, flow: try offline(), url: url, route: false, act: Self.operations)
        let played = try take(
            frames: frames, flow: try offline(), url: url, act: Self.operations)
        #expect(played.file == playedPlain.file)
        #expect(played.file == plain.file)
        // 操作の列が効いている (止まって・飛んで・動いた)
        let positions = plain.file.map(\.position)
        #expect(positions.contains(240_000) || positions.contains(240_800), "5 秒へ飛んでいる")
        #expect(plain.file.map(\.isPlaying).contains(false))
    }

    @Test("鳴っている最中にエフェクトへ通しても、位置は頭へ戻らず、通さないときと同じに進む")
    func routingWhilePlayingKeepsThePosition() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 40
        let plain = try take(frames: frames, flow: try offline(), url: url, route: false)
        let late = try take(frames: frames, flow: try offline(), url: url, routeAt: 20)
        #expect(late.file == plain.file)
        let positions = late.file.map(\.position)
        #expect(positions == positions.sorted(), "頭へ戻っていない")
        #expect(positions[20] == 20 * Self.perFrame)
        // 固定の時計でも同じ
        let framedPlain = try take(frames: frames, url: url, route: false)
        let framedLate = try take(frames: frames, url: url, routeAt: 20)
        #expect(framedLate.file == framedPlain.file)
        // 通した後は、エフェクトの出口に音が出ている
        #expect(late.effect[30].level > 0)
        // 通す前に直に鳴っていた音は止まり、聞こえるのはエフェクトの出口の音だけになる
        let outlet = try #require(late.filter?.node).meter.latest(AudioAnalysis.windowSize)
        let tail = Array(late.heard.left.suffix(AudioAnalysis.windowSize))
        let worst = zip(tail, outlet).map { abs($0 - $1 * Self.center) }.max() ?? 1
        #expect(worst < 1e-5, "通した後も、ファイルの音が直に聞こえている: \(worst)")
    }

    @Test("止めるとエフェクトの出口も無音になり、鳴らし直すと戻る (固定の時計でも実際に鳴らす流れでも)")
    func pausingSilencesTheEffect() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let act: (SoundFile, Int) -> Void = { song, frame in
            switch frame {
            case 10: song.pause()
            case 20: song.play()
            case 30: song.stop()
            default: break
            }
        }
        let flows: [SoundFlow?] = [nil, try offline()]
        for flow in flows {
            let heard = try take(frames: 40, flow: flow, url: url, act: act)
            let levels = heard.effect.map(\.level)
            #expect(levels[5] > 0, "鳴っている間は出口に音がある")
            #expect(levels[12..<20].allSatisfy { $0 == 0 }, "止めた間は無音: \(levels[12..<20])")
            #expect(levels[24] > 0, "鳴らし直すと戻る")
            #expect(levels[33...].allSatisfy { $0 == 0 }, "止めて頭へ戻すと無音")
        }
    }

    @Test("固定の時計と実際に鳴らす流れで、ステージとファイルのどちらを先に作っても、エフェクトの出口は毎フレーム同じ")
    func effectOutputMatchesBetweenTheClocks() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 44
        let played = try take(
            frames: frames, flow: try offline(), url: url, act: Self.operations)
        let framed = try take(frames: frames, url: url, act: Self.operations)
        let lateStage = try take(frames: frames, url: url, stageFirst: false, act: Self.operations)
        #expect(framed.effect == played.effect)
        #expect(lateStage.effect == played.effect)
        // 飛んだ後・止めた後・鳴らし直した後の値が、確かに動いている
        #expect(Set(played.effect.map(\.level)).count > 5)
        #expect(played.effect.contains { $0.level == 0 } || played.effect.contains { $0.level < 0.01 })
    }

    // MARK: - 5: 標本化率の変換

    @Test("44100 Hz のファイルを 48000 Hz のラックで通すと、440 Hz の帯域に出て、約 1 秒で止まる")
    func resamplesToTheRackRate() throws {
        let tone = (0..<44_100).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        let url = try writeWAV(tone, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = try offline()
        var heard = Stereo()
        var effectBand = 0
        let runtime = try run(
            frames: 1,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: flow)
                let song = try sketch.loadSound(url.path, flow: flow)
                let low = LowPass(stage: stage)
                low.process(song, 20_000)
                song.play()
            },
            between: { _ in heard = try renderStereo(flow, 50_000) })
        runtime.closePlugins()

        // 440 Hz は 48000 Hz の窓では帯域 9 (中心 421.9 Hz) に当たる
        let middle = Array(heard.left[20_000..<(20_000 + AudioAnalysis.windowSize)])
        let spectrum = AudioAnalysis.analyze(middle).spectrum
        effectBand = spectrum.indices.max { spectrum[$0] < spectrum[$1] } ?? -1
        #expect(effectBand == 9, "いちばん大きい帯域が \(effectBand)")

        // 鳴っていた長さは 1 秒 (48000 標本) で、±1 区切り (512) の内
        let loud = heard.left.indices.filter { abs(heard.left[$0]) > 1e-3 }
        let last = try #require(loud.last)
        #expect(abs((last + 1) - 48_000) <= 512, "最後の音が \(last + 1) 標本目")
        #expect(heard.left[(last + 1)...].allSatisfy { abs($0) <= 1e-3 })
    }

    // MARK: - 6〜8: いままでどおり・断る・音量・複数

    @Test("通していない SoundFile は、同じスケッチでエフェクトを作っても、いままでどおり直に鳴る")
    func anUnroutedFileStillPlaysDirectly() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let direct = try take(frames: 8, flow: try offline(), url: url, route: false)
        let worst = zip(direct.heard.left, chord).map { abs($0 - $1) }.max() ?? 1
        #expect(direct.heard.left.count == 8 * Self.perFrame)
        #expect(worst < 1e-6, "ファイルの音がそのまま出ている")
        #expect(direct.effect.allSatisfy { $0.level == 0 }, "入力の無いエフェクトは無音")
    }

    @Test("音量は通した後も効き、1 つのファイルを複数のエフェクトへ通すと、出口が足し合わされる")
    func volumeAndSeveralEffects() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        func rms(_ samples: [Float]) -> Float {
            (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        }
        let full = try take(frames: 20, flow: try offline(), url: url)
        let half = try take(
            frames: 20, flow: try offline(), url: url, start: { $0.amp(0.5); $0.loop() })
        // 音量は 5 ミリ秒かけて追うので、頭の数フレームは外す
        let settled = 10 * Self.perFrame
        let ratio = rms(Array(half.heard.left[settled...])) / rms(Array(full.heard.left[settled...]))
        #expect(abs(ratio - 0.5) < 0.02, "音量 0.5 で \(ratio) 倍")

        let flow = try offline()
        var stages: (SynthStage, LowPass, HighPass)?
        var heard = Stereo()
        let runtime = try run(
            frames: 12,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: flow)
                let song = try sketch.loadSound(url.path, flow: flow)
                let low = LowPass(stage: stage)
                let high = HighPass(stage: stage)
                low.process(song, 400)
                high.process(song, 400)
                // 同じ音を何度通しても、入力は 1 つ
                low.process(song)
                song.loop()
                stages = (stage, low, high)
            },
            between: { _ in
                let piece = try renderStereo(flow, Self.perFrame)
                heard.left += piece.left
                heard.right += piece.right
            })
        let (stage, low, high) = try #require(stages)
        #expect(stage.rack.inputs(of: try #require(low.node).id).nonzeroBitCount == 1)
        let lowTail = try #require(low.node).meter.latest(AudioAnalysis.windowSize)
        let highTail = try #require(high.node).meter.latest(AudioAnalysis.windowSize)
        let tail = Array(heard.left.suffix(AudioAnalysis.windowSize))
        let worst = zip(tail, zip(lowTail, highTail)).map { abs($0 - ($1.0 + $1.1) * Self.center) }.max() ?? 1
        #expect(worst < 1e-5, "聞こえた音が 2 つの出口の和でない: \(worst)")
        runtime.closePlugins()
    }

    @Test("エフェクトをやめても、通したファイルはラックで中央のまま鳴り続ける")
    func stoppingTheEffectLeavesTheFileInTheRack() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // 10 フレーム目にやめる
        var after = Stereo()
        let flow = try offline()
        var filter: LowPass?
        let runtime = try run(
            frames: 20,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: flow)
                let song = try sketch.loadSound(url.path, flow: flow)
                let low = LowPass(stage: stage)
                low.process(song, 300)
                song.loop()
                filter = low
            },
            draw: { sketch in if sketch.frameCount == 10 { filter?.stop() } },
            between: { frame in
                let piece = try renderStereo(flow, Self.perFrame)
                if frame > 12 { after.left += piece.left }
            })
        runtime.closePlugins()
        let loud = (after.left.map { $0 * $0 }.reduce(0, +) / Float(after.left.count)).squareRoot()
        #expect(loud > 0.1, "やめた後も鳴っている: \(loud)")
    }

    @Test("別のスケッチのファイルと、動いていないファイルは通さず、そのことを 1 度だけ知らせる")
    func refusesWhatItCannotTake() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var notices: [String] = []
        let runtime = try run(
            frames: 2,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                let low = LowPass(stage: stage)
                let buffer = try AudioFile.load(url, path: "loose.wav")
                // 作ったスケッチへ足していない・持ち主のいないファイル
                let loose = SoundFile(
                    name: "loose.wav", buffer: buffer, owner: nil, flow: nil,
                    warn: { notices.append($0) })
                low.process(loose)
                low.process(loose, 800)
                #expect(!low.isActive, "断ったので、エフェクトは動き出さない")
                loose.loop()
                #expect(loose.isPlaying)
            })
        runtime.closePlugins()
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?.contains("process() could not take") == true)
    }

    @Test("ラックの節が埋まっていると、ファイルは通らず、直に鳴り続けて、1 度だけ知らせる")
    func refusesWhenTheRackIsFull() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var notices: [String] = []
        var results: [(first: Bool, second: Bool)] = []
        var fillers: [SinOsc] = []
        let flow = try offline()
        var heard = Stereo()
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch, flow: flow)
                let low = LowPass(stage: stage)
                // 残りの置き場を、止めたままの音源で埋める。ファイルが入れるのは 1 つだけ残す
                for _ in 0..<(SynthRack.capacity - 2) { fillers.append(SinOsc(stage: stage)) }
                let file: (String) throws -> SoundFile = { name in
                    let buffer = try AudioFile.load(url, path: name)
                    let sound = SoundFile(
                        name: name, buffer: buffer, owner: sketch, flow: flow,
                        warn: { notices.append($0) })
                    sketch.attach(sound)
                    return sound
                }
                let first = try file("first.wav")
                let second = try file("second.wav")
                low.process(first)
                let inputs = stage.rack.inputs(of: try #require(low.node).id).nonzeroBitCount
                let before = inputs
                low.process(second)
                let after = stage.rack.inputs(of: try #require(low.node).id).nonzeroBitCount
                results.append((before == 1, after == 1))
                first.loop()
                second.loop()
            },
            between: { _ in
                let piece = try renderStereo(flow, Self.perFrame)
                heard.left += piece.left
            })
        runtime.closePlugins()
        #expect(fillers.count == SynthRack.capacity - 2)
        #expect(results.count == 1 && results[0].first && results[0].second, "\(results)")
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?.contains("at most 64") == true)
        // 通せなかった方は、直に鳴っている (エフェクトの出口だけではない)
        #expect(heard.left.map { abs($0) }.max() ?? 0 > 0.1)
    }
}
