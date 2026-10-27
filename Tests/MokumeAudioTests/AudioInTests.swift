// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 何もしない出どころ。状態だけを始まりに置き、標本は 1 つも入れない。
final class SilentAudioSource: AudioSource {
    let initial: SourceState
    init(_ initial: SourceState) { self.initial = initial }
    var sampleRate: Float { 0 }
    func start(into input: ExternalInput<AudioSpan>, at clock: SourceClock) { input.setState(initial) }
    func pump(into input: ExternalInput<AudioSpan>, at clock: SourceClock) {}
    func stop() {}
}

/// 受け取った時計の位置を控えるだけの出どころ。
final class ClockSpyAudioSource: AudioSource {
    var sampleRate: Float { 48_000 }
    private(set) var opened: SourceClock?
    private(set) var pumped: [SourceClock] = []
    func start(into input: ExternalInput<AudioSpan>, at clock: SourceClock) {
        opened = clock
        input.setState(.running)
    }
    func pump(into input: ExternalInput<AudioSpan>, at clock: SourceClock) { pumped.append(clock) }
    func stop() {}
}

/// 動いて大きな音を入れ、`after` 回の取り出しの後に抜かれる出どころ。
final class UnpluggedAudioSource: AudioSource {
    let after: Int
    private var pumped = 0
    init(after: Int) { self.after = after }
    var sampleRate: Float { 48_000 }
    func start(into input: ExternalInput<AudioSpan>, at clock: SourceClock) { input.setState(.running) }
    func pump(into input: ExternalInput<AudioSpan>, at clock: SourceClock) {
        // 開いていない (止めた・開き直されていない) 出どころは何も入れない
        guard input.state == .running else { return }
        pumped += 1
        if pumped > after {
            input.setState(.disconnected)
        } else {
            input.send(AudioSpan(window: sine(band: 20)))
        }
    }
    func stop() {}
}

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class AudioSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (AudioSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (AudioSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() throws { try Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 1 フレームで受け取った値。
struct Received: Equatable {
    var time: Float
    var level: Float
    var rms: Float
    var peak: Float
    var spectrum: [Float]
}

/// 拍で大きさが揺れる和音 (1 秒・48 kHz)。
let chord: [Float] = (0..<48_000).map { index in
    let t = Float(index) / 48_000
    let tone = sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 660 * t)
    return 0.6 * tone * (0.5 + 0.5 * cos(2 * .pi * 3 * t))
}

/// 標本列を 2 チャンネルの 32 bit 浮動小数の WAV に書く (左右とも同じ)。
func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
    let url = TestScratch.path("mokume-audio", pathExtension: "wav")
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for channel in 0..<2 {
        let data = try #require(buffer.floatChannelData)[channel]
        for (index, sample) in samples.enumerated() { data[index] = sample }
    }
    try file.write(from: buffer)
    return url
}

/// 音の入り口 (#1978)。走っているスケッチの中で回すので GPU を要する。
@Suite(
    "音の入り口",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct AudioInTests {
    private func run(
        frames: Int, clock: Clock? = nil, setup: @escaping (AudioSketch) throws -> Void,
        draw: @escaping (AudioSketch) -> Void = { _ in }
    ) throws -> SketchRuntime {
        AudioSketch.onSetup = setup
        AudioSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: AudioSketch(), gpu: try RenderDevice(), clock: clock)
        for _ in 0..<frames { try runtime.advance() }
        return runtime
    }

    /// 作る口で作った入り口を回し、フレームごとに受け取った値を返す。
    private func record(
        frames: Int, clock: Clock? = nil, _ make: @escaping (AudioSketch) throws -> AudioIn
    ) throws -> (received: [Received], openedAt: Float) {
        var audio: AudioIn?
        var openedAt: Float = -1
        var received: [Received] = []
        let runtime = try run(
            frames: frames, clock: clock,
            setup: { sketch in
                openedAt = sketch.time
                audio = try make(sketch)
            },
            draw: { sketch in
                guard let audio else { return }
                received.append(
                    Received(
                        time: sketch.time, level: audio.level, rms: audio.rms, peak: audio.peak,
                        spectrum: audio.spectrum))
            })
        runtime.closePlugins()
        return (received, openedAt)
    }

    // MARK: - フレームの時刻の窓 (水準 2)

    @Test("標本列の解析は、固定の時計の 60・30・24・144 fps で、前のフレームの ⌊N·sr/fps⌋ から今の ⌊N·sr/fps⌋ までの区間の値になる。標本が進まない最初のフレームは無音")
    func samplesFollowTheFrameWindows() throws {
        for fps in [60, 30, 24, 144] {
            let (received, _) = try record(frames: 40, clock: .frameIndex(frameRate: fps)) {
                try $0.createAudioIn(samples: chord, sampleRate: 48_000)
            }
            #expect(received.count == 40)
            var covered = 0
            var expected = AudioLevels.silence
            for (index, frame) in received.enumerated() {
                // 絶対のフレーム番号から、整数で ⌊N·48000/fps⌋ (独立に数える。浮動小数の秒は通さない)
                let end = index * 48_000 / fps
                // 標本が進まなかったフレーム (開いた最初のフレーム) は、前の値 (最初は無音) のまま
                if end > covered {
                    expected = AudioAnalysis.analyze(span(of: chord, from: covered, to: end, loops: true))
                    covered = end
                }
                #expect(frame.level == expected.level, "\(fps) fps frame \(index)")
                #expect(frame.peak == expected.peak, "\(fps) fps frame \(index)")
                #expect(frame.spectrum == expected.spectrum, "\(fps) fps frame \(index)")
            }
            #expect(received[0].level == 0 && received[0].peak == 0)
            #expect(covered > 10_000)
            // 拍で揺れているので、フレームごとに値が動いている
            #expect(Set(received.map(\.level)).count > 1)
        }
    }

    /// 時刻を指定した観測の枚で、``SketchPart/time`` は観測の秒になる。標本列の入り口は、観測の枚には指定の秒で終わる
    /// 1 フレームぶんの区間の値を見せ (映すコマと音の窓だけが指定の秒で決まる)、通常の続きは作者の時計の枚の番号で
    /// 数える。観測の枚の後の通常の枚は、観測の無い回と同じ値になる。
    @Test("時刻を指定した観測の枚は、指定の秒で終わる 1 フレームぶんの区間の値を見せ、その後の通常の枚の値は観測の有無で変わらない")
    func anObservedFrameShowsTheIntervalEndingAtTheRequestedTime() throws {
        /// `pausing` を指定すると、その枚の `draw()` で時間を止める (観測の後の通常の枚の区間が空になる)
        func run(observingAt frame: Int?, pausingAt pausing: Int? = nil) throws -> [Float] {
            let facet = try TestScratch.directory("mokume-audio-observe")
            defer { try? FileManager.default.removeItem(at: facet) }
            var audio: AudioIn?
            var seen: [Float] = []
            AudioSketch.onSetup = { sketch in audio = try sketch.createAudioIn(samples: chord, sampleRate: 48_000) }
            AudioSketch.onDraw = { sketch in
                if let audio { seen.append(audio.level) }
                if sketch.frameCount == pausing { sketch.pauseTime() }
            }
            let runtime = try SketchRuntime(
                sketch: AudioSketch(), gpu: try RenderDevice(), clock: nil, now: { 0 },
                observer: FrameObserver(directory: facet))
            for index in 1...8 {
                if index == frame {
                    // この枚を、時刻 5 の観測の枚にする (作者の時計では 0.07 秒ほど)
                    try AtomicFile.write(
                        Data(#"{"id":"o","time":5}"#.utf8), to: facet.appendingPathComponent("request.json"))
                }
                try runtime.advance()
            }
            runtime.closePlugins()
            return seen
        }
        // 5 秒 = 60 fps の 300 フレーム目。その 1 フレーム前の頭 (299·800) から 300·800 までの区間 (ファイルは繰り返す)
        let shown = AudioAnalysis.analyze(span(of: chord, from: 299 * 800, to: 300 * 800, loops: true)).level
        for pausing in [nil, 2] as [Int?] {
            let plain = try run(observingAt: nil, pausingAt: pausing)
            let observed = try run(observingAt: 4, pausingAt: pausing)
            let label = pausing.map { "枚 \($0) で時間を止める" } ?? "止めない"
            #expect(plain.count == 8 && observed.count == 8, "\(label)")
            #expect(plain.last ?? 0 > 0, "\(label)")
            // 観測の枚 (4 番目) は、指定の秒で終わる区間の値
            #expect(observed[3] == shown, "\(label): 観測の枚の値 \(observed[3]) 対 \(shown)")
            #expect(plain[3] != shown, "\(label): 観測の値が通常の値と違うから、取り違えを見分けられる")
            // 他の枚は観測の有無で変わらない。時間を止めているときは、観測の枚の次の枚が空の区間で前の値を保つ
            for index in observed.indices where index != 3 {
                #expect(observed[index] == plain[index], "\(label): 枚 \(index + 1) が観測で変わった")
            }
        }
    }

    /// 観測の枚の `draw()` で作った入り口の起点が、観測の秒 (5 秒) になって残っていた。起点は作者の時計の秒
    /// (観測の枚の作者の時計 = 3/60 秒) で、次の枚が読む窓は、その起点から 1 枚ぶん進んだところで終わる
    /// ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。
    @Test("観測の枚の draw() で作った標本列の入り口は、作者の時計の秒を起点にする")
    func anInputMadeOnAnObservedFrameStartsOnTheAuthorsClock() throws {
        let facet = try TestScratch.directory("mokume-audio-observe")
        defer { try? FileManager.default.removeItem(at: facet) }
        var audio: AudioIn?
        var levels: [Float] = []
        var times: [Float] = []
        AudioSketch.onSetup = { _ in }
        AudioSketch.onDraw = { sketch in
            // 4 枚目 (時刻 5 の観測の枚) で作る
            if sketch.frameCount == 4 {
                do {
                    audio = try sketch.createAudioIn(samples: chord, sampleRate: 48_000)
                } catch {
                    Issue.record("音の入口を作れなかった: \(error)")
                }
            }
            if let audio {
                levels.append(audio.level)
                times.append(sketch.time)
            }
        }
        let runtime = try SketchRuntime(
            sketch: AudioSketch(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        for _ in 0..<3 { try runtime.advance() }
        try AtomicFile.write(
            Data(#"{"id":"o","time":5}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        try runtime.advance()
        runtime.closePlugins()

        // 観測の枚の draw() が見る時刻は観測の秒で、次の枚は作者の時計へ戻っている
        #expect(times == [5, Float(4.0 / 60)])
        // 次の枚が読む区間は、起点 (作者の時計の 3/60 秒) から 4/60 秒まで = 1 フレームぶん (800 標本) の頭からの区間
        let expected = AudioAnalysis.analyze(span(of: chord, from: 0, to: 800))
        #expect(expected.level > 0, "区間が空なら、起点の違いを見分けられない")
        #expect(levels.last == expected.level, "起点が観測の秒のままだと区間が空になる: \(levels)")
    }

    /// 出どころへ渡す時計の位置は、観測の枚でも作者の時計の秒・固定の時計の fps で、観測の秒は ``SourceClock/observed`` に
    /// 別に載る (観測の枚だけ)。
    @Test("時刻を指定した観測の枚でも、出どころへ渡す時計の秒は作者の時計のままで、観測の秒は観測の枚にだけ載る")
    func theSourceIsHandedTheAuthorsClockOnAnObservedFrame() throws {
        let facet = try TestScratch.directory("mokume-audio-observe")
        defer { try? FileManager.default.removeItem(at: facet) }
        let spy = ClockSpyAudioSource()
        AudioSketch.onSetup = { sketch in
            sketch.attach(AudioIn(device: nil, name: "spy", source: spy, owner: sketch, warn: { _ in }))
        }
        AudioSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(
            sketch: AudioSketch(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        for index in 1...6 {
            if index == 4 {
                try AtomicFile.write(
                    Data(#"{"id":"o","time":5}"#.utf8), to: facet.appendingPathComponent("request.json"))
            }
            try runtime.advance()
        }
        runtime.closePlugins()
        #expect(spy.pumped.count == 6)
        #expect(spy.pumped.allSatisfy { $0.perSecond == 60 })
        // 秒は作者の時計 (フレーム番号 ÷ 60)。観測の秒 (5) は観測の枚 (4 番目) の observed にだけ載る
        for (index, clock) in spy.pumped.enumerated() {
            #expect(abs(clock.seconds - Double(index) / 60) < 1e-9, "\(clock)")
            #expect(clock.observed == (index == 3 ? 5 : nil), "\(clock)")
        }
    }

    /// 水準 2 (ADR-0025): 同じスケッチを 2 回書き出すと同じ拍で光り、fps を変えても拍の数と標本位置は同じ。
    @Test("標本列の isBeat は、固定の時計で 2 度回すと同じフレームで立ち、60 fps と 24 fps で拍の数が同じ")
    func isBeatIsRepeatableUnderTheFixedClock() throws {
        let starts = [12_000, 36_511, 60_001, 84_479, 108_545]
        let clicks = AudioFeatureTests.clicks(at: starts, count: 144_000)
        func flags(fps: Int) throws -> [Bool] {
            var audio: AudioIn?
            var seen: [Bool] = []
            let runtime = try run(
                frames: fps * 3, clock: .frameIndex(frameRate: fps),
                setup: { audio = try $0.createAudioIn(samples: clicks, sampleRate: 48_000) },
                draw: { _ in seen.append(audio?.isBeat ?? false) })
            runtime.closePlugins()
            return seen
        }
        let first = try flags(fps: 60)
        #expect(first == (try flags(fps: 60)), "2 回目が違う")
        #expect(first.filter { $0 }.count == starts.count)
        let slow = try flags(fps: 24)
        #expect(slow == (try flags(fps: 24)))
        #expect(slow.filter { $0 }.count == starts.count)
    }

    /// 固定の時計 (`mokume render` と同じ数え方) でも、標本列の入り口は作者の時計の止める・飛ぶに従う。フレーム数ではなく
    /// 作者の時計の位置で区間を数えるので、止めた間は標本が進まず、飛んだら飛び先から数え直す。
    @Test("固定の時計でも、標本列の入り口は pauseTime()・playTime()・jumpTime(_:) に従う (144 fps)")
    func samplesFollowTheAuthorsClockOnTheFixedClock() throws {
        var audio: AudioIn?
        var heard: [(level: Float, peak: Float, isNew: Bool)] = []
        AudioSketch.onSetup = { sketch in audio = try sketch.createAudioIn(samples: chord, sampleRate: 48_000) }
        AudioSketch.onDraw = { sketch in
            guard let audio else { return }
            heard.append((audio.level, audio.peak, audio.isNewFrame))
            switch sketch.frameCount {
            case 4: sketch.pauseTime()
            case 7: sketch.playTime()
            case 10: sketch.jumpTime(15.0 / 128)  // 16.875 フレーム目 (Float で正確): フレームの途中へ飛ぶ
            case 13: sketch.jumpTime(7.0 / 128)  // 7.875 フレーム目: 過去へ飛ぶ
            default: break
            }
        }
        let runtime = try SketchRuntime(
            sketch: AudioSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 144))
        for _ in 0..<18 { try runtime.advance() }
        runtime.closePlugins()

        // 作者の時計の位置 (1/8 フレーム単位の整数)。枚 f (0 始まり) の位置を、実装を通さずに並べる:
        // 0〜3 は進み、4〜6 は 3 で止まり、7〜9 は 4・5・6、10 で 15/128 秒 (16.875 フレーム) へ飛び、
        // 13 で 7/128 秒 (7.875 フレーム) へ戻って、以後は 1 枚ずつ進む
        var units: [Int] = [0, 8, 16, 24, 24, 24, 24, 32, 40, 48, 135, 143, 151, 63]
        while units.count < 18 { units.append(units.last! + 8) }
        #expect(heard.count == 18)
        var covered = 0
        for (index, frame) in heard.enumerated() {
            // 1 フレーム = 48000/144 標本、位置は 1/8 フレーム単位なので units × 48000 ÷ (8 × 144)
            let end = units[index] * 48_000 / 1_152
            var expected: AudioLevels?
            if end < covered { covered = end }  // 過去へ飛んだら、そこから数え直す (空の区間)
            if end > covered {
                #expect(end - covered <= AudioAnalysis.maxSpan, "枚 \(index)")
                expected = AudioAnalysis.analyze(span(of: chord, from: covered, to: end, loops: true))
                covered = end
            }
            #expect(frame.isNew == (expected != nil), "枚 \(index): 標本が進んだ枚だけ新しい値")
            if let expected {
                #expect(frame.level == expected.level, "枚 \(index)")
                #expect(frame.peak == expected.peak, "枚 \(index)")
            } else if index > 0 {
                // 標本が進まなかった枚は、前の枚の値のまま
                #expect(frame.level == heard[index - 1].level, "枚 \(index)")
            }
        }
        // 止めた間 (4〜6) と、過去へ飛んだ直後 (13) は標本が進まない
        #expect(heard[4...6].allSatisfy { !$0.isNew } && !heard[13].isNew)
        // 例が意味を持つ: 区間のどれも空でなく、値が動いている
        #expect(Set(heard.map(\.level)).count > 3)
    }

    @Test("音声ファイルを固定の時計で 2 度回すと、同じフレームが同じ値を受け取る")
    func sameFileSameValues() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try record(frames: 8) { try $0.createAudioIn(file: url.path) }.received
        let second = try record(frames: 8) { try $0.createAudioIn(file: url.path) }.received
        #expect(first.count == 8)
        #expect(first == second)
        // ファイルは標本列と同じ窓を通る (読み込みで値が変わらない)
        let samples = try record(frames: 8) {
            try $0.createAudioIn(samples: chord, sampleRate: 48_000)
        }.received
        #expect(first == samples)
    }

    // MARK: - 状態と観測

    @Test("注入の入り口は動いていると名乗り、閉じれば止まって無音になる")
    func recordedReportsRunning() throws {
        var audio: AudioIn?
        var arrivals: [Int?] = []
        let runtime = try run(
            frames: 3,
            setup: { audio = try $0.createAudioIn(samples: chord, sampleRate: 48_000) },
            draw: { sketch in
                // 開いた最初のフレームは標本が進まない (区間が空) ので、何も届かない。2 フレーム目から届く
                #expect(audio?.isNewFrame == (sketch.frameCount > 1))
                arrivals.append(audio?.lastArrival?.frame)
            })
        #expect(arrivals == [nil, 2, 3])
        #expect(audio?.state == .running)
        #expect(audio?.report?.name == "audio (samples)")
        #expect(audio?.sampleRate == 48_000)
        #expect(audio?.device == nil)
        runtime.closePlugins()
        #expect(audio?.state == .stopped)
        #expect(audio?.level == 0)
    }

    @Test("stop() で閉じ、以後は無音になる")
    func stopCloses() throws {
        var audio: AudioIn?
        var levels: [Float] = []
        let runtime = try run(
            frames: 4,
            setup: { audio = try $0.createAudioIn(samples: sine(band: 40, count: 48_000), sampleRate: 48_000) },
            draw: { sketch in
                levels.append(audio?.level ?? -1)
                if sketch.frameCount == 2 { audio?.stop() }
            })
        // 1 は開いた時刻 (0 秒) で終わる窓なので、まだ鳴る前の無音。2 は鳴っている
        #expect(levels[0] == 0 && levels[1] > 0.9, "\(levels)")
        #expect(levels[2] == 0 && levels[3] == 0)
        #expect(audio?.state == .stopped)
        runtime.closePlugins()
    }

    @Test("機材が無い・抜かれた・拒まれたは、値が無音のまま状態で名乗る")
    func unavailableStatesAreSilent() throws {
        for state in [SourceState.unavailable, .disconnected, .denied] {
            var audio: AudioIn?
            var levels: [Float] = []
            let runtime = try run(
                frames: 2,
                setup: { sketch in
                    let made = AudioIn(
                        device: nil, name: "microphone", source: SilentAudioSource(state),
                        owner: sketch, warn: { _ in })
                    sketch.attach(made)
                    audio = made
                },
                draw: { _ in levels.append(audio?.level ?? -1) })
            #expect(levels == [0, 0])
            #expect(audio?.report?.state == state)
            runtime.closePlugins()
        }
    }

    @Test("動いていた機材が抜かれたら、最後の値に留まらず無音になる")
    func unpluggedFallsSilent() throws {
        var audio: AudioIn?
        var levels: [Float] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let made = AudioIn(
                    device: nil, name: "microphone", source: UnpluggedAudioSource(after: 2),
                    owner: sketch, warn: { _ in })
                sketch.attach(made)
                audio = made
            },
            draw: { _ in levels.append(audio?.level ?? -1) })
        #expect(levels[0] > 0.9 && levels[1] > 0.9, "\(levels)")
        #expect(levels[2] == 0 && levels[3] == 0, "\(levels)")
        #expect(audio?.state == .disconnected)
        runtime.closePlugins()
    }

    @Test("外して足し直した音の入り口は、外す前に届いて読まれなかった音を、足し直した最初のフレームに出さない (#3122)")
    func reattachedAudioDoesNotAnalyseTheSoundThatWaitedBeforeDetach() throws {
        var audio: AudioIn?
        var levels: [Float] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let made = AudioIn(
                    device: nil, name: "microphone", source: SilentAudioSource(.running),
                    owner: sketch, warn: { _ in })
                sketch.attach(made)
                audio = made
            },
            draw: { sketch in
                guard let audio else { return }
                switch sketch.frameCount {
                case 1:
                    // 届いたが、まだ読まれていない大きな音を残したまま外す
                    audio.input.send(AudioSpan(window: sine(band: 20)))
                    sketch.detach(audio)
                case 2:
                    sketch.attach(audio)
                default:
                    levels.append(audio.level)
                }
            })
        #expect(levels == [0, 0], "外す前の音が出た: \(levels)")
        runtime.closePlugins()
    }

    /// 足し直した後の 2 フレーム (3・4 フレーム目) の `(level, state, isNewFrame)`。1 フレーム目に `leave` で外し、
    /// 2 フレーム目に足し直す。出どころは毎回大きな音を入れる。
    private func afterReattach(
        leaving leave: @escaping (AudioSketch, AudioIn) -> Void
    ) throws -> (seen: [(level: Float, state: SourceState, new: Bool)], audio: AudioIn?) {
        var audio: AudioIn?
        var seen: [(level: Float, state: SourceState, new: Bool)] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let made = AudioIn(
                    device: nil, name: "microphone", source: UnpluggedAudioSource(after: 100),
                    owner: sketch, warn: { _ in })
                sketch.attach(made)
                audio = made
            },
            draw: { sketch in
                guard let audio else { return }
                switch sketch.frameCount {
                case 1: leave(sketch, audio)
                case 2: sketch.attach(audio)
                default: seen.append((audio.level, audio.state, audio.isNewFrame))
                }
            })
        runtime.closePlugins()
        return (seen, audio)
    }

    @Test("ランタイムが外しただけの音の入り口は、足し直せばまた受け取る。利用者が stop() したものは、足し直しても受け取らない (#3122)")
    func userStopSticksButRuntimeDetachDoesNot() throws {
        let detached = try afterReattach { sketch, audio in sketch.detach(audio) }
        #expect(detached.seen.count == 2)
        #expect(detached.seen.allSatisfy { $0.level > 0.9 && $0.state == .running && $0.new }, "\(detached.seen)")

        let stopped = try afterReattach { _, audio in audio.stop() }
        #expect(stopped.seen.count == 2)
        #expect(
            stopped.seen.allSatisfy { $0.level == 0 && $0.state == .stopped && !$0.new },
            "足し直しても戻らない: \(stopped.seen)")
    }

    @Test("実行の外・足していない入り口への stop() は何も止めず、利用者が止めた印も立てない (#3122)")
    func stopOutsideTheRunDoesNotStick() throws {
        var audio: AudioIn?
        let runtime = try run(
            frames: 1,
            setup: { sketch in
                // 足さずに持つ。走っている最中に呼んだ `stop()` も、並びに居ないので何も外さず、印を立てない
                audio = AudioIn(
                    device: nil, name: "microphone", source: UnpluggedAudioSource(after: 100),
                    owner: sketch, warn: { _ in })
                audio?.stop()
            })
        let loose = try #require(audio)
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) { loose.stop() }
        #expect(log.message(for: "AudioIn.stop()") != nil, "外で呼ぶと警告する: \(log.messages)")

        // 印が立っていなければ、開けば受け始める
        try loose.open()
        loose.supply()
        #expect(loose.state == .running)
        #expect(loose.level > 0.9)
        runtime.closePlugins()
    }

    @Test("状態と最後に届いたフレームが、観測の応答の inputs に載る")
    func appearsInObservation() throws {
        let facet = try TestScratch.directory("mokume-audio")
        AudioSketch.onSetup = { _ = try $0.createAudioIn(samples: chord, sampleRate: 48_000) }
        AudioSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(
            sketch: AudioSketch(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        try runtime.advance()
        try AtomicFile.write(
            Data(#"{"id":"a1"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let row = (report?["inputs"] as? [[String: Any]])?.first
        #expect(row?["name"] as? String == "audio (samples)")
        #expect(row?["state"] as? String == "running")
        #expect(row?["lastFrame"] as? Int == 2)
        runtime.closePlugins()
    }

    // MARK: - 作れないとき

    @Test("見つからない・読めない・空・標本化率が正でないときは、作るときに投げる")
    func failuresAreThrownAtCreation() throws {
        let garbage = TestScratch.path("mokume-audio", pathExtension: "wav")
        try Data("not audio".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        var failures: [AudioFailure] = []
        let runtime = try run(frames: 1, setup: { sketch in
            func attempt(_ make: () throws(AudioFailure) -> AudioIn) {
                do { _ = try make() } catch { failures.append(error) }
            }
            attempt { () throws(AudioFailure) in try sketch.createAudioIn(file: "no-such-sound.wav") }
            attempt { () throws(AudioFailure) in try sketch.createAudioIn(file: garbage.path) }
            attempt { () throws(AudioFailure) in try sketch.createAudioIn(samples: [], sampleRate: 48_000) }
            attempt { () throws(AudioFailure) in try sketch.createAudioIn(samples: [0], sampleRate: 0) }
            attempt { () throws(AudioFailure) in try sketch.createAudioIn(samples: [0], sampleRate: .nan) }
        })
        #expect(failures.count == 5)
        if case .notFound(let path, let searched) = failures.first {
            #expect(path == "no-such-sound.wav")
            #expect(!searched.isEmpty)
        } else {
            Issue.record("見つからないことが notFound にならない: \(failures)")
        }
        #expect(failures.dropFirst().first == .unreadable(path: garbage.path))
        #expect(failures.dropFirst(2).first == .empty)
        #expect(failures.dropFirst(3).first == .invalidSampleRate(0))
        if case .invalidSampleRate(let rate) = failures.last { #expect(rate.isNaN) }
        runtime.closePlugins()
    }

    @Test("ディレクトリと読む権利の無いファイルは、unopenable で開けない事情を名乗る (#2358)")
    func unopenableNamesWhy() throws {
        let places = UnopenablePlaces()
        defer { places.cleanUp() }
        let placed = try places.place("kick.wav")
        var failures: [AudioFailure] = []
        let runtime = try run(frames: 1, setup: { sketch in
            for (path, _) in placed {
                do throws(AudioFailure) { _ = try sketch.createAudioIn(file: path) } catch { failures.append(error) }
            }
        })
        runtime.closePlugins()
        #expect(failures == placed.map { .unopenable(path: $0.path, location: $0.path, reason: $0.reason) })
    }

    // MARK: - 来ないときの知らせ

    private func stuck(
        _ state: SourceState, clock: @escaping () -> Double, notices: @escaping (String) -> Void
    ) -> (AudioSketch) throws -> Void {
        { sketch in
            sketch.attach(
                AudioIn(
                    device: nil, name: "microphone", source: SilentAudioSource(state),
                    owner: sketch, now: clock, warn: notices))
        }
    }

    @Test("許可を待ったまま 3 秒経っても来なければ、マイクの許可の欄を 1 度だけ言う")
    func waitingTooLongIsNoticedOnce() throws {
        var now = 0.0
        var notices: [String] = []
        let runtime = try run(
            frames: 5,
            setup: stuck(.waitingForPermission, clock: { now }, notices: { notices.append($0) }),
            draw: { sketch in now = Double(sketch.frameCount) * 1.5 })
        #expect(notices.count == 1)
        #expect(notices.first?.contains("System Settings > Privacy & Security > Microphone") == true)
        runtime.closePlugins()
    }

    @Test("拒まれていれば、すぐに 1 度だけ言う")
    func deniedIsNoticedOnce() throws {
        var notices: [String] = []
        let runtime = try run(
            frames: 3, setup: stuck(.denied, clock: { 0 }, notices: { notices.append($0) }))
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Microphone access is denied") == true)
        runtime.closePlugins()
    }
}

/// 機材の一覧。機材の有無は機械によるので、形だけを見る。GPU は要らない。
@Suite("音の入力の機材")
struct AudioDeviceTests {
    @Test("一覧の識別子は重ならず、既定の入力があれば一覧に含まれる")
    func listIsConsistent() {
        let entries = CoreAudioDevices.inputs()
        #expect(Set(entries.map(\.device.id)).count == entries.count)
        if let fallback = CoreAudioDevices.defaultInput() {
            #expect(entries.contains { $0.object == fallback })
        }
    }
}
