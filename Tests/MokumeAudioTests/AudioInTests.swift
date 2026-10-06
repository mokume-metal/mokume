// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 何もしない出どころ。状態だけを始まりに置き、標本は 1 つも入れない。
final class SilentAudioSource: AudioSource {
    let initial: SourceState
    init(_ initial: SourceState) { self.initial = initial }
    var sampleRate: Float { 0 }
    func start(into input: ExternalInput<[Float]>, at time: Double) { input.setState(initial) }
    func pump(into input: ExternalInput<[Float]>, at time: Double) {}
    func stop() {}
}

/// 動いて大きな音を入れ、`after` 回の取り出しの後に抜かれる出どころ。
final class UnpluggedAudioSource: AudioSource {
    let after: Int
    private var pumped = 0
    init(after: Int) { self.after = after }
    var sampleRate: Float { 48_000 }
    func start(into input: ExternalInput<[Float]>, at time: Double) { input.setState(.running) }
    func pump(into input: ExternalInput<[Float]>, at time: Double) {
        pumped += 1
        if pumped > after {
            input.setState(.disconnected)
        } else {
            input.send(sine(band: 20))
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
    func setup() { try? Self.onSetup(self) }
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
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-audio-\(UUID().uuidString).wav")
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
        frames: Int, setup: @escaping (AudioSketch) throws -> Void,
        draw: @escaping (AudioSketch) -> Void = { _ in }
    ) throws -> SketchRuntime {
        AudioSketch.onSetup = setup
        AudioSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: AudioSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
        return runtime
    }

    /// 作る口で作った入り口を回し、フレームごとに受け取った値を返す。
    private func record(
        frames: Int, _ make: @escaping (AudioSketch) throws -> AudioIn
    ) throws -> (received: [Received], openedAt: Float) {
        var audio: AudioIn?
        var openedAt: Float = -1
        var received: [Received] = []
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                openedAt = sketch.time
                audio = try make(sketch)
            },
            draw: { sketch in
                guard let audio else { return }
                received.append(
                    Received(
                        time: sketch.time, level: audio.level, rms: audio.rms,
                        spectrum: audio.spectrum))
            })
        runtime.closePlugins()
        return (received, openedAt)
    }

    // MARK: - フレームの時刻の窓 (水準 2)

    @Test("標本列の解析は、開いてからそのフレームの時刻までで終わる窓の値になる")
    func samplesFollowFrameTime() throws {
        let (received, openedAt) = try record(frames: 6) {
            try $0.createAudioIn(samples: chord, sampleRate: 48_000)
        }
        #expect(received.count == 6)
        for frame in received {
            let expected = AudioAnalysis.analyze(
                AudioAnalysis.window(
                    of: chord, sampleRate: 48_000, endingAt: Double(frame.time) - Double(openedAt)))
            #expect(frame.level == expected.level)
            #expect(frame.spectrum == expected.spectrum)
        }
        // 拍で揺れているので、フレームごとに値が動いている
        #expect(Set(received.map(\.level)).count > 1)
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
            draw: { _ in
                #expect(audio?.isNewFrame == true)
                arrivals.append(audio?.lastArrival?.frame)
            })
        #expect(arrivals == [1, 2, 3])
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

    @Test("状態と最後に届いたフレームが、観測の応答の inputs に載る")
    func appearsInObservation() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
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
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-audio-\(UUID().uuidString).wav")
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
