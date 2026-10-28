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
    func setup() throws { try Self.onSetup(self) }
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
        frames: Int, clock: Clock? = nil, setup: @escaping (EffectSketch) throws -> Void,
        draw: @escaping (EffectSketch) -> Void = { _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> SketchRuntime {
        EffectSketch.onSetup = setup
        EffectSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: EffectSketch(), gpu: try RenderDevice(), clock: clock)
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
        var rms: Float
        var peak: Float
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
        /// ファイルの `isBeat` が立ったフレーム (`frameCount`)。
        var beats: [Int] = []
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
        frames: Int, flow: SoundFlow? = nil, clock: Clock? = nil, url: URL, stageFirst: Bool = true,
        route: Bool = true,
        routeAt: Int? = nil, cutoff: Float = 20_000,
        start: @escaping (SoundFile) -> Void = { $0.loop() },
        act: @escaping (SoundFile, Int) -> Void = { _, _ in }
    ) throws -> Take {
        var result = Take()
        var song: SoundFile?
        var filter: LowPass?
        let runtime = try run(
            frames: frames, clock: clock,
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
                        level: song.level, rms: song.rms, peak: song.peak, spectrum: song.spectrum))
                result.effect.append(
                    Effected(rms: filter.rms, level: filter.level, spectrum: filter.spectrum))
                if song.isBeat { result.beats.append(sketch.frameCount) }
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
        // ステージをファイルより後に作っても (ファイルの `supply()` が先に呼ばれても) 同じ
        let lateStage = try take(frames: frames, url: url, stageFirst: false, act: Self.operations)
        #expect(lateStage.file == plain.file)
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

    @Test("ループで何周かした後にエフェクトへ通しても、通した番号の付け直しで拍の履歴を捨てず、通さないときと同じフレームに拍が出る")
    func routingALoopedFileKeepsTheBeatHistory() throws {
        // 0.5 秒 (24000 標本) の音に 1 つのクリック。60 fps で 1 周 30 フレーム
        let url = try writeWAV(AudioFeatureTests.clicks(at: [3_000], count: 24_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try take(frames: 150, url: url, route: false)
        #expect(plain.beats.count >= 4, "\(plain.beats)")
        // 2 周と少し (75 フレーム目) で通す。通した後の周でも、拍は通さないときと同じフレームに出る
        let late = try take(frames: 150, url: url, routeAt: 75)
        #expect(late.beats == plain.beats, "\(late.beats) / \(plain.beats)")
    }

    /// 通した後のフレームの `Moment` を、通さない回と比べて、食い違った項目を `フレーム番号:項目` で返す (#3268)。
    private func mismatches(_ late: Take, _ plain: Take, from frame: Int) -> [String] {
        var found: [String] = []
        for index in frame..<min(late.file.count, plain.file.count) {
            let (a, b) = (late.file[index], plain.file[index])
            if a.level != b.level { found.append("\(index):level") }
            if a.rms != b.rms { found.append("\(index):rms") }
            if a.peak != b.peak { found.append("\(index):peak") }
            if a.spectrum != b.spectrum { found.append("\(index):spectrum") }
            if a.position != b.position || a.isPlaying != b.isPlaying { found.append("\(index):position") }
        }
        return found
    }

    /// 通した回と通さない回を比べる形 (#3268)。
    enum RoutedAnalysis: CaseIterable, CustomTestStringConvertible {
        case afterOneLap, afterTwoLaps, afterManyLaps, nearTheSeam, firstLap, playedOnce, afterJump
        /// 止めて途中から鳴らし直した区切りは、始まりより前を 0 で埋める。再開の 1 フレーム後・2 フレーム後に通す
        case resumedOneFrameBefore, resumedTwoFramesBefore
        /// 止まっている間に飛んでから鳴らし直した区切り
        case jumpedWhileStopped
        /// ループで何周かした後に、止めて鳴らし直してすぐ通す
        case resumedAfterLaps

        var testDescription: String {
            switch self {
            case .afterOneLap: "1 周した後"
            case .afterTwoLaps: "2 周した後"
            case .afterManyLaps: "5 周した後"
            case .nearTheSeam: "ちょうど 2 周した継ぎ目 (窓の頭が前の周に掛かる)"
            case .firstLap: "1 周目"
            case .playedOnce: "ループしない"
            case .afterJump: "jump の後 (ループ)"
            case .resumedOneFrameBefore: "止めて鳴らし直した 1 フレーム後"
            case .resumedTwoFramesBefore: "止めて鳴らし直した 2 フレーム後"
            case .jumpedWhileStopped: "止まっている間に飛んで鳴らし直した 1 フレーム後"
            case .resumedAfterLaps: "何周かした後に止めて鳴らし直した 1 フレーム後"
            }
        }

        var frames: Int { self == .afterManyLaps ? 330 : 200 }
        /// 通すフレーム。1 周は 60 フレーム (1 秒の雑音を 60 fps・800 標本で)。
        var routeAt: Int {
            switch self {
            case .afterOneLap: 80
            case .afterTwoLaps: 130
            case .afterManyLaps: 305
            case .nearTheSeam: 121
            case .firstLap: 30
            case .playedOnce: 20
            case .afterJump: 150
            case .resumedOneFrameBefore, .jumpedWhileStopped: 51
            case .resumedTwoFramesBefore: 52
            case .resumedAfterLaps: 136
            }
        }
        var start: (SoundFile) -> Void { self == .playedOnce ? { $0.play() } : { $0.loop() } }
        var act: (SoundFile, Int) -> Void {
            switch self {
            case .afterJump:
                { song, frame in if frame == 40 { song.jump(0.3) } }
            case .resumedOneFrameBefore, .resumedTwoFramesBefore:
                { song, frame in
                    if frame == 40 { song.pause() }
                    if frame == 50 { song.loop() }
                }
            case .jumpedWhileStopped:
                { song, frame in
                    if frame == 40 { song.pause() }
                    if frame == 41 { song.jump(0.3) }
                    if frame == 50 { song.loop() }
                }
            case .resumedAfterLaps:
                { song, frame in
                    if frame == 130 { song.pause() }
                    if frame == 135 { song.loop() }
                }
            default:
                { _, _ in }
            }
        }
    }

    @Test(
        "ループ再生のファイルを何周かした後に通しても、通した後のすべてのフレームの level・rms・peak・spectrum が通さないときと一致する",
        arguments: RoutedAnalysis.allCases, [false, true])
    func routingKeepsTheAnalysis(_ shape: RoutedAnalysis, offlineFlow: Bool) throws {
        // 1 秒 (48000 標本) の雑音。格子の間隔 (512) で割り切れないので、通し番号と位置の番号の食い違いが値に出る
        let url = try writeWAV(Self.noise, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try take(
            frames: shape.frames, flow: offlineFlow ? try offline() : nil, url: url, route: false,
            start: shape.start, act: shape.act)
        let late = try take(
            frames: shape.frames, flow: offlineFlow ? try offline() : nil, url: url,
            routeAt: shape.routeAt, start: shape.start, act: shape.act)
        // 値が動いている (一致が自明でない)
        #expect(Set(plain.file.map(\.level)).count > 10)
        let found = mismatches(late, plain, from: shape.routeAt)
        #expect(found.isEmpty, "食い違い \(found.count) 件: \(found.prefix(8))")
    }

    /// 音声トラックが始まって、鳴らさずに数で進めていたファイルが機材に出さない流れの `FilePlayer` へ切り替わる (#3125)
    /// ときも、ループで何周かした後で、載せない回と同じ値になる (#3268 の兄弟の口)。
    @Test(
        "音声トラックへ載せても、載せた後のすべてのフレームの level・rms・peak・spectrum が載せないときと一致する",
        arguments: RoutedAnalysis.allCases)
    func joiningTheTrackKeepsTheAnalysis(_ shape: RoutedAnalysis) throws {
        let url = try writeWAV(Self.noise, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = shape.frames
        let joinAt = shape.routeAt
        func moments(join: Bool) throws -> [Moment] {
            var seen: [Moment] = []
            var song: SoundFile?
            let flow = try offline()
            let runtime = try run(
                frames: frames,
                setup: { sketch in
                    let loaded = try sketch.loadSound(url.path)
                    shape.start(loaded)
                    song = loaded
                },
                draw: { sketch in
                    guard let song else { return }
                    seen.append(
                        Moment(
                            isPlaying: song.isPlaying, position: song.samplePosition, level: song.level,
                            rms: song.rms, peak: song.peak, spectrum: song.spectrum))
                    if join, sketch.frameCount == joinAt { song.joinTrack(flow) }
                    shape.act(song, sketch.frameCount)
                },
                between: { frame in
                    if join, frame >= joinAt { _ = try renderStereo(flow, Self.perFrame) }
                })
            runtime.closePlugins()
            return seen
        }
        let plain = try moments(join: false)
        let joined = try moments(join: true)
        var found: [String] = []
        for index in joinAt..<frames {
            let (a, b) = (joined[index], plain[index])
            if a.level != b.level { found.append("\(index):level") }
            if a.rms != b.rms { found.append("\(index):rms") }
            if a.peak != b.peak { found.append("\(index):peak") }
            if a.spectrum != b.spectrum { found.append("\(index):spectrum") }
            if a.position != b.position { found.append("\(index):position") }
        }
        #expect(found.isEmpty, "食い違い \(found.count) 件: \(found.prefix(8))")
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

    // MARK: - 手放す・順序・時計・満杯

    @Test("外したファイルは節を返し、足し直して通しても節は 1 つ (入力にも残らない)")
    func detachingReturnsTheNode() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var stage: SynthStage?
        var song: SoundFile?
        var filter: LowPass?
        var occupied: [Int] = []
        var wired: [Int] = []
        let runtime = try run(
            frames: 40,
            setup: { sketch in
                let made = SynthStage.stage(for: sketch)
                let loaded = try sketch.loadSound(url.path)
                let low = LowPass(stage: made)
                low.process(loaded)
                loaded.loop()
                stage = made
                song = loaded
                filter = low
            },
            draw: { sketch in
                guard let stage, let song, let filter, let node = filter.node else { return }
                occupied.append(stage.rack.occupiedCount)
                wired.append(stage.rack.inputs(of: node.id).nonzeroBitCount)
                switch sketch.frameCount {
                case 5: sketch.detach(song)
                case 20:
                    sketch.attach(song)
                    filter.process(song)
                    song.loop()
                default: break
                }
            })
        runtime.closePlugins()
        // 通している間は、エフェクトとファイルの 2 つ
        #expect(occupied[2] == 2 && wired[2] == 1)
        // 外すと、止まって消えきった後に節が返る (約 5 ミリ秒の時定数のあと数フレーム)
        #expect(occupied[15] == 1 && wired[15] == 0, "外した後の置き場 \(occupied[15])・入力 \(wired[15])")
        // 足し直して通すと、節は 1 つ取り直す。2 つ目が増えない
        #expect(occupied[30] == 2 && wired[30] == 1)
        #expect(occupied.max() == 2, "置き場の数の最大 \(occupied.max() ?? 0)")
    }

    @Test("足し直してすぐエフェクトへ通すときは、器を読み直さない (ファイルが消えていても知らせず、節が鳴らす)")
    func reattachThenProcessDoesNotReadTheFileAgain() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var notices: [String] = []
        var stage: SynthStage?
        var song: SoundFile?
        var filter: LowPass?
        var occupied: [Int] = []
        let runtime = try run(
            frames: 12,
            setup: { sketch in
                let made = SynthStage.stage(for: sketch)
                let loaded = try AudioFile.load(url, path: "ten.wav")
                let file = SoundFile(
                    name: "ten.wav", buffer: loaded, owner: sketch, flow: flow, source: url,
                    warn: { notices.append($0) })
                sketch.attach(file)
                let low = LowPass(stage: made)
                low.process(file)
                file.loop()
                stage = made
                song = file
                filter = low
            },
            draw: { sketch in
                guard let stage, let song, let filter else { return }
                occupied.append(stage.rack.occupiedCount)
                switch sketch.frameCount {
                case 3: sketch.detach(song)
                case 8:
                    // 外している間に消えたファイルは、読み直そうとすれば知らせが出る
                    try? FileManager.default.removeItem(at: url)
                    sketch.attach(song)
                    filter.process(song)
                    song.loop()
                default: break
                }
            })
        let said = runtime.blockingLoads.message(for: "play() or loop() on a SoundFile attached again")
        let playing = song?.isPlaying
        runtime.closePlugins()
        #expect(notices.isEmpty, "通すだけなら読み直さない: \(notices)")
        #expect(said == nil)
        #expect(occupied.last == 2, "足し直して通した節が鳴っている: \(occupied)")
        #expect(playing == true)
    }

    @Test("鳴っている最中に通すとき、節を入力に選ぶ操作が、鳴らし始める操作より先に音の側へ届く")
    func theInputIsChosenBeforeTheNodeSounds() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var log: [SynthCommand] = []
        var recording = false
        var song: SoundFile?
        var filter: LowPass?
        let runtime = try run(
            frames: 6,
            setup: { sketch in
                let stage = SynthStage.stage(for: sketch)
                stage.rack.observePost = { if recording { log.append($0) } }
                let loaded = try sketch.loadSound(url.path)
                loaded.loop()
                song = loaded
                filter = LowPass(stage: stage)
            },
            draw: { sketch in
                guard sketch.frameCount == 3, let song, let filter else { return }
                recording = true
                filter.process(song)
                recording = false
            })
        runtime.closePlugins()
        let effect = try #require(filter?.node).id
        let activate = try #require(log.firstIndex { $0.op == .activate })
        let file = Int(log[activate].node)
        let inputs = try #require(
            log.firstIndex { $0.op == .inputs && Int($0.node) == effect && $0.bits & (1 << UInt64(file)) != 0 })
        let segment = try #require(log.firstIndex { $0.op == .segment && Int($0.node) == file })
        #expect(activate < inputs, "節を足してから入力に選ぶ: \(log.map(\.op))")
        #expect(inputs < segment, "入力に選んでから鳴らし始める: \(log.map(\.op))")
    }

    @Test("実時間の時計で 2 秒を超えて止まっても、位置は聞こえている音とずれない (ラックの打ち切りに従う)")
    func positionFollowsTheRackClockWhenTheClockStalls() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var now: TimeInterval = 0
        var stage: SynthStage?
        var song: SoundFile?
        var positions: [Int] = []
        var rendered: [Int] = []
        var playing: [Bool] = []
        let runtime = try run(
            frames: 12,
            setup: { sketch in
                let made = SynthStage.stage(for: sketch, now: { now })
                // 出力が開けないときの形 (実時間で進める)
                made.pace = .realTime(origin: 0, base: made.rack.rendered)
                let loaded = try sketch.loadSound(url.path)
                let low = LowPass(stage: made)
                low.process(loaded)
                loaded.play()
                stage = made
                song = loaded
            },
            draw: { _ in
                guard let stage, let song else { return }
                positions.append(song.samplePosition)
                rendered.append(stage.rack.rendered)
                playing.append(song.isPlaying)
            },
            between: { frame in now += frame == 3 ? 5 : 1.0 / 60 })
        runtime.closePlugins()
        #expect(positions == rendered, "位置 \(positions) と、ラックが作った数 \(rendered)")
        // 5 秒止まった後の 1 回の進みは 2 秒で打ち切られている (1 回に 96000 標本まで)
        let steps = zip(rendered, rendered.dropFirst()).map { $1 - $0 }
        #expect(steps.max() ?? 0 <= 96_000 && steps.max() ?? 0 >= 90_000, "1 回の進み \(steps)")
        #expect(playing.allSatisfy { $0 }, "1 度だけ鳴らす音が早く切れていない: \(playing)")
    }

    // MARK: - 操作の列が詰まっているとき

    /// 帯域 100 以降を落とさない (20 kHz の) 濾波器で、傾きの付いたファイルを鳴らして回す。`congest` を呼んだ
    /// フレームで、操作の列を満杯にして控えを積む。聞こえた音は、フレームごとに最後の標本を残す。
    private struct Congested {
        var positions: [Int] = []
        var promised: [Float] = []
        var lastHeard: [Float] = []
        var heard = Stereo()
        var song: SoundFile?
        var filter: LowPass?
        var notices: [String] = []
    }

    /// 0.2 から 0.9 まで一定の傾きで上がる 10 秒のファイル。**聞こえた標本の値から、鳴っている位置が読める。**
    private static let slope: [Float] = (0..<480_000).map { 0.2 + Float($0) / 700_000 }

    private func congested(
        frames: Int, at congestionFrame: Int, held: Int = 9000, routedAtSetup: Bool = true,
        act: @escaping (SoundFile, LowPass, Int) -> Void
    ) throws -> Congested {
        let url = try writeWAV(Self.slope, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = try offline()
        var result = Congested()
        var stage: SynthStage?
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                let made = SynthStage.stage(for: sketch, flow: flow)
                let buffer = try AudioFile.load(url, path: "slope.wav")
                let loaded = SoundFile(
                    name: "slope.wav", buffer: buffer, owner: sketch, flow: flow,
                    warn: { result.notices.append($0) })
                sketch.attach(loaded)
                let low = LowPass(stage: made)
                low.freq(20_000)
                if routedAtSetup { low.process(loaded) }
                loaded.loop()
                stage = made
                result.song = loaded
                result.filter = low
            },
            draw: { sketch in
                guard let stage, let song = result.song, let filter = result.filter,
                    let node = filter.node
                else { return }
                result.positions.append(song.samplePosition)
                result.promised.append(song.position)
                result.lastHeard.append(result.heard.left.last ?? 0)
                if sketch.frameCount == congestionFrame {
                    // 列を満杯にして、控えを積む (描き出しごとに 4096 ずつしか載らない)
                    while stage.rack.heldCount < held {
                        stage.rack.set(node.id, .cutoff, 20_000)
                    }
                }
                act(song, filter, sketch.frameCount)
            },
            between: { _ in
                result.heard.left += try renderStereo(flow, Self.perFrame).left
            })
        runtime.closePlugins()
        return result
    }

    @Test("列が詰まっている間の止める・鳴らし直す操作は、位置と一緒に控え、聞こえている音と位置がずれない")
    func positionFollowsTheSoundWhileTheQueueIsCongested() throws {
        let run = try congested(frames: 14, at: 3) { song, _, frame in
            if frame == 3 {
                song.pause()
                song.play()
                // 控えた操作は、まだ効いていない (聞こえている音は鳴り続けている)
                #expect(song.isPlaying)
            }
        }
        // 位置は、詰まっている間 (3〜5 フレーム目) も、操作が効いた後も、1 フレームに 800 標本ずつ進む
        #expect(run.positions == (0..<14).map { $0 * Self.perFrame }, "\(run.positions)")
        // 聞こえている音は、位置の 1 つ手前の標本 (傾きのある値) と同じ。凍った位置と音のずれを見逃さない
        for frame in 4..<14 {
            let expected = (0.2 + Float(run.positions[frame] - 1) / 700_000) * Self.center
            #expect(
                abs(run.lastHeard[frame] - expected) < 1e-4,
                "フレーム \(frame + 1): 聞こえた \(run.lastHeard[frame]) と位置から読める \(expected)")
        }
    }

    @Test("列が詰まっている間の jump は、呼んだ直後から飛び先を返し、詰まりが解けたら飛び先から続ける")
    func jumpWhileTheQueueIsCongested() throws {
        var promised: Float = 0
        let run = try congested(frames: 14, at: 3) { song, _, frame in
            if frame == 3 {
                song.jump(5)
                promised = song.position
            }
        }
        #expect(promised == 5)
        // 詰まっている間 (4・5 フレーム目) も、飛び先を返す。聞こえている音は飛ぶ前のまま続いている
        #expect(run.promised[3] == 5 && run.promised[4] == 5, "\(run.promised)")
        #expect(run.positions[3] == 3 * Self.perFrame && run.positions[4] == 4 * Self.perFrame)
        // 詰まりが解けた (6 フレーム目) 後は、飛び先から 800 標本ずつ
        let landed = try #require(run.positions.firstIndex { $0 >= 240_000 })
        #expect(landed >= 5)
        #expect(
            zip(run.positions[landed...], run.positions[landed...].dropFirst()).allSatisfy {
                $1 - $0 == Self.perFrame
            })
        let settled = run.positions.count - 1
        let expected = (0.2 + Float(run.positions[settled] - 1) / 700_000) * Self.center
        #expect(abs(run.lastHeard[settled] - expected) < 1e-4)
    }

    @Test("列が詰まっているとき、エフェクトへは通さず (何も変えず) 知らせ、詰まりが解けた後に通せる")
    func routingWhileTheQueueIsCongestedIsRefused() throws {
        var effectInputs: [UInt64] = []
        var refusedHeard: Float = 0
        let run = try congested(frames: 12, at: 3, routedAtSetup: false) { song, filter, frame in
            guard let node = filter.node else { return }
            if frame == 3 { filter.process(song) }
            if frame == 4 { effectInputs.append(filter.stage.rack.inputs(of: node.id)) }
            if frame == 5 { filter.process(song) }
            if frame == 6 {
                effectInputs.append(filter.stage.rack.inputs(of: node.id))
            }
            if frame == 10 { filter.process(song) }
            if frame == 11 { effectInputs.append(filter.stage.rack.inputs(of: node.id)) }
        }
        // 詰まっている間は通らず、エフェクトは入力を持たない。ファイルは直に鳴り続けている
        #expect(effectInputs.count == 3)
        #expect(effectInputs[0] == 0 && effectInputs[1] == 0, "\(effectInputs)")
        refusedHeard = run.heard.left[(4 * Self.perFrame)..<(5 * Self.perFrame)].map { abs($0) }.max() ?? 0
        #expect(refusedHeard > 0.1, "通せなかったファイルは直に鳴っている: \(refusedHeard)")
        // 置き場の上限の知らせとは別の知らせで、1 度だけ
        #expect(run.notices.count == 1, "\(run.notices)")
        #expect(run.notices.first?.contains("right now") == true)
        #expect(run.notices.first?.contains("at most") == false)
        // 詰まりが解けた後は通る
        #expect(effectInputs[2] != 0, "\(effectInputs)")
    }

    @Test("標本化率がラックと違い、fps が 48000 を割り切れないとき、通した位置は通さないときと最大 1 標本しかずれない")
    func positionAgreesWithinOneSampleWhenTheRatesDoNotDivide() throws {
        // 44100 Hz のファイル。144 fps は 48000 ÷ 144 が整数にならない (333.33 標本)
        let url = try writeWAV(Self.slope, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 40
        for fps in [144, 60, 30, 24, 100] {
            let clock = Clock.frameIndex(frameRate: fps)
            let plain = try take(frames: frames, clock: clock, url: url, route: false)
            let routed = try take(frames: frames, clock: clock, url: url)
            let gaps = zip(plain.file, routed.file).map { abs($0.position - $1.position) }
            #expect(gaps.max() ?? 0 <= 1, "\(fps) fps で最大 \(gaps.max() ?? 0) 標本: \(gaps)")
            if 48_000 % fps == 0 {
                // 割り切れるなら、通しても同じ (掛けてから割って、割り切れる所で 1 標本低くならない)
                #expect(gaps.max() == 0, "\(fps) fps は割り切れるので同じ位置: \(gaps)")
            }
        }
    }

    /// エフェクトへ通すと、解析済みの終わりを引き継ぐ値 (`continuedCoverage`) を立てる。入力に選ばれるまでの間に
    /// `play()`・`loop()` で頭から鳴らし直すと、その区切りの始まりは頭なのに、古い位置が解析済みの終わりとして残り、
    /// 最初の区間が欠ける。
    @Test("通した後、入力に選ばれる前に loop() で頭から鳴らし直しても、最初の区間は頭から解析される")
    func restartingBeforeTheInputIsChosenDropsTheInheritedCoverage() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var song: SoundFile?
        var stage: SynthStage?
        var seen: [(level: Float, position: Int)] = []
        let runtime = try run(
            frames: 6,
            setup: { sketch in
                stage = SynthStage.stage(for: sketch)
                let loaded = try sketch.loadSound(url.path)
                loaded.loop()
                song = loaded
            },
            draw: { sketch in
                guard let song, let stage else { return }
                seen.append((song.level, song.samplePosition))
                if sketch.frameCount == 4 {
                    // 通す (節を入力に選ぶ前) → 頭から鳴らし直す
                    _ = song.route(into: stage)
                    song.loop()
                }
            })
        runtime.closePlugins()
        #expect(seen.count == 6)
        // フレーム 5 の区間は、頭から鳴った分 [0, 位置)。古い位置 (3200) が解析済みの終わりとして残ると、区間が空になって
        // フレーム 4 の値のまま動かない
        let position = seen[4].position
        #expect(position > 0 && position < 3200, "頭から鳴らし直した位置: \(position)")
        let head = AudioAnalysis.analyze(span(of: chord, from: 0, to: position, loops: true))
        #expect(head.level > 0)
        #expect(seen[4].level == head.level, "最初の区間が欠けた: \(seen[4].level) 対 \(head.level)")
    }
}
