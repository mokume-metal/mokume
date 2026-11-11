// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ (包絡を掛けた音声ファイル用)。
final class EnvelopeSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (EnvelopeSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (EnvelopeSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() throws { try Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 台形 (ASR) の倍率を、包絡の約束 (``Env/play(_:_:_:_:_:)``) から独立に書いたもの。`n` は掛けてから鳴った標本の数。
private func trapezoid(_ n: Int, attack: Int, sustain: Int, release: Int, level: Float) -> Float {
    guard n >= 0 else { return 1 }
    if n < attack { return level * Float(n) / Float(attack) }
    if n < attack + sustain { return level }
    if n < attack + sustain + release {
        return level * (1 - Float(n - attack - sustain) / Float(release))
    }
    return 0
}

/// `Env.play` を `SoundFile` に掛ける (#3099)。走っているスケッチの中で回すので GPU を要する。
///
/// 書き出しの経路 (固定の時計) は鳴らさずに回り、鳴らす経路は manual rendering (offline) の流れを差し込んで
/// 回す — 出力の機材には出さない。描いた分だけ時間が進むので、決定論的に走る。
@Suite(
    "音声ファイルの包絡",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundFileEnvelopeTests {
    /// 60 fps・48 kHz の 1 フレームぶんの標本の数。
    private static let perFrame = 800
    /// 4 秒の正弦波 (約 1875 Hz・振れ幅 0.5)。
    private static let tone = sine(band: 40, amplitude: 0.5, count: 4 * 48_000)
    /// Issue の例 `env.play(song, 0.5, 2, 0.8, 1)` の倍率。
    private static func issueShape(_ n: Int) -> Float {
        trapezoid(n, attack: 24_000, sustain: 96_000, release: 48_000, level: 0.8)
    }

    /// 1 フレームで聞こえたもの。
    struct Frame: Equatable {
        var isPlaying: Bool
        var position: Int
        var level: Float
        var peak: Float
        var spectrum: [Float]
    }

    struct Take: Equatable {
        var frames: [Frame]
        /// 鳴らす経路で描かせた左の音 (書き出しの経路では空)。
        var sound: [Float]
    }

    /// `frames` フレーム回す。`flow` を渡すと鳴らす経路 (offline の流れ)、`nil` なら書き出しの経路。
    /// `start` は `setup()` で、`act` は `draw()` の記録の後に `frameCount` で呼ぶ。
    private func take(
        frames: Int, samples: [Float] = tone, audible: Bool, route: Bool = false,
        start: @escaping (SoundFile, Env) -> Void,
        act: @escaping (SoundFile, Env, Int) -> Void = { _, _, _ in }
    ) throws -> Take {
        let url = try writeWAV(samples, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = audible ? try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096) : nil
        var sound: SoundFile?
        var env: Env?
        var heard: [Frame] = []
        EnvelopeSketch.onSetup = { sketch in
            // 合成の音 (エフェクト) も同じ流れで鳴らす。最初に作るときだけ流れを差し込める
            if route { _ = SynthStage.stage(for: sketch, flow: flow) }
            let made = try flow.map { try sketch.loadSound(url.path, flow: $0) } ?? sketch.loadSound(url.path)
            let envelope = sketch.createEnv()
            if route {
                let filter = sketch.createLowPass()
                filter.freq(20_000)
                filter.process(made)
            }
            start(made, envelope)
            sound = made
            env = envelope
        }
        EnvelopeSketch.onDraw = { sketch in
            guard let sound, let env else { return }
            heard.append(
                Frame(
                    isPlaying: sound.isPlaying, position: sound.samplePosition, level: sound.level,
                    peak: sound.peak, spectrum: sound.spectrum))
            act(sound, env, sketch.frameCount)
        }
        let runtime = try SketchRuntime(sketch: EnvelopeSketch(), gpu: try RenderDevice(), clock: nil)
        var played: [Float] = []
        for _ in 0..<frames {
            try runtime.advance()
            if let flow { played += try render(flow, Self.perFrame) }
        }
        runtime.closePlugins()
        return Take(frames: heard, sound: played)
    }

    // MARK: - 形 (完了条件 1)

    @Test("env.play(song, 0.5, 2, 0.8, 1) は、音量 1 で鳴らした同じファイルの標本に 0→0.8 (0.5 秒)・0.8 (2 秒)・0.8→0 (1 秒) を掛けた音になり、2 回回すと標本が一致する")
    func theIssueShapeScalesTheSamples() throws {
        let frames = 220  // 176000 標本。形 (168000 標本) の後まで
        let plain = try take(frames: frames, audible: true, start: { song, _ in song.play() })
        let shaped = try take(
            frames: frames, audible: true, start: { song, env in env.play(song, 0.5, 2, 0.8, 1) })
        try #require(plain.sound.count == frames * Self.perFrame && shaped.sound.count == plain.sound.count)
        var worst: Float = 0
        var at = -1
        for n in plain.sound.indices {
            let gap = abs(shaped.sound[n] - plain.sound[n] * Self.issueShape(n))
            if gap > worst { (worst, at) = (gap, n) }
        }
        #expect(worst < 1e-6, "標本 \(at) で \(worst) ずれた")
        // 区切りごとの振れ幅 (形の上の目印)。0.25 秒で 0.4 倍、保つ間は 0.8 倍、下がりの中ほどで 0.4 倍、後は 0
        func peak(_ range: Range<Int>, _ sound: [Float]) -> Float { sound[range].map { abs($0) }.max() ?? 0 }
        let full = peak(60_000..<61_000, plain.sound)
        #expect(full > 0.45)
        #expect(abs(peak(60_000..<61_000, shaped.sound) - 0.8 * full) < 1e-3)
        #expect(abs(peak(143_500..<144_500, shaped.sound) - 0.4 * full) < 2e-2)
        #expect(shaped.sound[168_000...].allSatisfy { $0 == 0 }, "形が終わった後は無音")
        // 位置は形が終わった後も進み、再生は止まらない (完了条件 4)
        #expect(shaped.frames.map(\.position) == plain.frames.map(\.position))
        #expect(shaped.frames.allSatisfy { $0.isPlaying })
        // 何度回しても同じ (固定の時計で書き出すのと同じく、描いた分だけ進む)
        let again = try take(
            frames: frames, audible: true, start: { song, env in env.play(song, 0.5, 2, 0.8, 1) })
        #expect(again == shaped)
    }

    // MARK: - 解析 (完了条件 5)

    @Test("解析の値は包絡を掛けた後の音のもので、書き出しの経路と鳴らす経路が同じ値を出す")
    func analysisSeesTheShapedSound() throws {
        let frames = 40
        let start: (SoundFile, Env) -> Void = { song, env in env.play(song, 0.2, 0.1, 0.9, 0.2) }
        let exported = try take(frames: frames, audible: false, start: start)
        let played = try take(frames: frames, audible: true, start: start)
        #expect(exported.frames == played.frames)
        let shaped: (Int) -> Float = { n in
            Self.tone[n] * trapezoid(n, attack: 9600, sustain: 4800, release: 9600, level: 0.9)
        }
        for (index, frame) in exported.frames.enumerated() where index > 0 {
            let levels = AudioAnalysis.analyze(
                span(from: (index - 1) * Self.perFrame, to: index * Self.perFrame) { $0 < 0 ? 0 : shaped($0) })
            #expect(frame.level == levels.level, "frame \(index)")
            #expect(frame.peak == levels.peak, "frame \(index)")
            #expect(frame.spectrum == levels.spectrum, "frame \(index)")
        }
        // 形が終わった後 (24000 標本 = 30 フレーム目より後) は無音で、再生は続く
        #expect(exported.frames[31...].allSatisfy { $0.level == 0 && $0.peak == 0 && $0.isPlaying })
        #expect(exported.frames[20].level > 0)
    }

    @Test("エフェクトに通したファイルも、通さないときと同じ位置・解析の値になり、通した節の出口に形が載る")
    func aRoutedFileIsShapedToo() throws {
        let frames = 60
        let start: (SoundFile, Env) -> Void = { song, env in env.play(song, 0.1, 0.2, 1, 0.3) }
        let direct = try take(frames: frames, audible: false, start: start)
        let routed = try take(frames: frames, audible: false, route: true, start: start)
        #expect(routed.frames == direct.frames)
        // 鳴らす経路: 一定の値 (0.5) のファイルを、切れ目 20 kHz の低域通過に通す。形の無い回に倍率を掛けたものと揃う
        let flat = [Float](repeating: 0.5, count: 96_000)
        let plain = try take(frames: frames, samples: flat, audible: true, route: true, start: { song, _ in song.play() })
        let shaped = try take(frames: frames, samples: flat, audible: true, route: true, start: start)
        let gain: (Int) -> Float = { trapezoid($0, attack: 4800, sustain: 9600, release: 14_400, level: 1) }
        // 節の立ち上がり (約 5 ミリ秒) が済んだ後
        let worst = (4000..<plain.sound.count).map { abs(shaped.sound[$0] - plain.sound[$0] * gain($0)) }.max() ?? 1
        #expect(worst < 2e-3)
        #expect(plain.sound[20_000] > 0.1)
        #expect(shaped.sound[29_000...].allSatisfy { abs($0) < 1e-4 }, "形が終わった後は無音")
    }

    // MARK: - 鳴らし始める位置 (完了条件 3)

    @Test("鳴っていないファイルに掛けると、pause() の後は止めた位置から、stop() の後は頭から 1 度だけ鳴らす")
    func startsWhereplayWould() throws {
        let paused = try take(
            frames: 8, audible: false, start: { song, _ in song.play() },
            act: { song, env, frame in
                if frame == 3 { song.pause() }
                if frame == 5 { env.play(song, 0.01, 1, 1, 0.01) }
            })
        #expect(paused.frames.map(\.isPlaying) == [true, true, true, false, false, true, true, true])
        #expect(paused.frames.map(\.position) == [0, 800, 1600, 1600, 1600, 2400, 3200, 4000])
        let stopped = try take(
            frames: 8, audible: false, start: { song, _ in song.play() },
            act: { song, env, frame in
                if frame == 3 { song.stop() }
                if frame == 5 { env.play(song, 0.01, 1, 1, 0.01) }
            })
        #expect(stopped.frames.map(\.position) == [0, 800, 1600, 0, 0, 800, 1600, 2400])
        // 1 度だけ鳴らす: 2000 標本の短い音は末尾で止まる
        let short = Array(Self.tone.prefix(2000))
        let once = try take(
            frames: 6, samples: short, audible: false, start: { song, env in env.play(song, 0, 1, 1, 0) })
        #expect(once.frames.map(\.isPlaying) == [true, true, true, false, false, false])
    }

    @Test("鳴っているファイルに掛けても位置は動かず、ループも続く (play() は頭から鳴らし直す)")
    func playingFilesKeepTheirPosition() throws {
        let short = Array(Self.tone.prefix(2000))
        let looping = try take(
            frames: 8, samples: short, audible: false, start: { song, _ in song.loop() },
            act: { song, env, frame in if frame == 2 { env.play(song, 0.01, 1, 1, 0.01) } })
        #expect(looping.frames.map(\.position) == [0, 800, 1600, 400, 1200, 0, 800, 1600])
        #expect(looping.frames.allSatisfy { $0.isPlaying })
        let replayed = try take(
            frames: 8, samples: short, audible: false, start: { song, _ in song.loop() },
            act: { song, _, frame in if frame == 2 { song.loop() } })
        #expect(replayed.frames.map(\.position) == [0, 800, 800, 1600, 400, 1200, 0, 800])
    }

    // MARK: - 形の後 (完了条件 4)

    @Test("形が終わった後は、位置が進み続けても無音で、play() で鳴らし直しても戻らず、次の env.play で戻る")
    func silenceAfterTheShapeLastsUntilTheNextEnvelope() throws {
        // 0.01 秒で立ち上がり 0.02 秒保ち 0.01 秒で消える (1920 標本)
        let take = try take(
            frames: 24, audible: true, start: { song, env in env.play(song, 0.01, 0.02, 1, 0.01) },
            act: { song, env, frame in
                if frame == 10 { song.play() }  // 頭から鳴らし直す
                if frame == 18 { env.play(song, 0.01, 0.02, 1, 0.01) }
            })
        #expect(take.frames.allSatisfy { $0.isPlaying })
        // 形の間は鳴り、その後は鳴らし直しても無音
        #expect(take.sound[0..<1920].contains { abs($0) > 0.1 })
        // `frameCount` が k の draw() の後に描かせた音は、標本 (k - 1) × 800 から
        let again = 17 * Self.perFrame
        #expect(take.sound[1920..<again].allSatisfy { $0 == 0 })
        #expect(take.frames[4..<18].allSatisfy { $0.level == 0 })
        // 鳴らし直した (頭へ戻った) 位置から進み続ける
        #expect(take.frames[9].position == 9 * Self.perFrame && take.frames[10].position == Self.perFrame)
        // 次の env.play で戻る
        #expect(take.sound[again..<(again + 1920)].contains { abs($0) > 0.1 })
        #expect(take.frames[18].level > 0)
    }

    @Test("形は鳴った標本の数で進む — pause() の間は止まり、jump(_:) や鳴らし直しをまたいで続く")
    func theShapeFollowsThePlayedSamples() throws {
        // 一定の値 (0.5) のファイルに、1 秒かけて 1 から 0 へ下がる形を掛ける。鳴った音は位置に依らず形だけを映す
        let flat = [Float](repeating: 0.5, count: 96_000)
        let take = try take(
            frames: 50, samples: flat, audible: true, start: { song, env in env.play(song, 0, 0, 1, 1) },
            act: { song, _, frame in
                if frame == 10 { song.pause() }
                if frame == 20 { song.play() }  // 止めた位置から
                if frame == 30 { song.jump(1.5) }
                if frame == 40 { song.play() }  // 鳴っているので頭から
            })
        let heard = take.sound.filter { $0 != 0 }
        // 止めている 10 フレームぶんだけ鳴らず、鳴った標本は途切れずに形をなぞる
        #expect(heard.count == take.sound.count - 10 * Self.perFrame)
        let expected = (0..<heard.count).map {
            0.5 * trapezoid($0, attack: 0, sustain: 0, release: 48_000, level: 1)
        }
        let worst = zip(heard, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
    }

    // MARK: - 書き出しの音声トラック (完了条件 5・#3125)

    @Test("書き出しの音声トラックにも形が載る")
    func theSoundTrackCarriesTheShape() async throws {
        let flat = [Float](repeating: 0.5, count: 48_000)
        let wav = try writeWAV(flat, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        func record(shaped: Bool) async throws -> [Float] {
            let url = TestScratch.path("mokume-envelope-track", pathExtension: "mov")
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            var env: Env?
            EnvelopeSketch.onSetup = { sketch in
                sound = try sketch.loadSound(wav.path)
                env = sketch.createEnv()
            }
            EnvelopeSketch.onDraw = { sketch in
                if sketch.frameCount == 1 { sketch.beginRecord(url.path) }
                // 11 フレーム目 (標本 8000) から鳴らす
                if sketch.frameCount == 11, let sound, let env {
                    if shaped { env.play(sound, 0.1, 0.1, 0.5, 0.1) } else { sound.play() }
                }
                if sketch.frameCount == 61 { sketch.endRecord() }
            }
            let runtime = try SketchRuntime(
                sketch: EnvelopeSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
            for _ in 0..<61 { try runtime.advance() }
            runtime.closePlugins()
            return try await leftChannel(of: url)
        }
        let plain = try await record(shaped: false)
        let shaped = try await record(shaped: true)
        try #require(plain.count == 48_000 && shaped.count == plain.count)
        #expect(plain[30_000] > 0.1)
        let worst = plain.indices.map {
            abs(shaped[$0] - plain[$0] * trapezoid($0 - 8000, attack: 4800, sustain: 4800, release: 4800, level: 0.5))
        }.max() ?? 1
        #expect(worst < 1e-5)
        #expect(shaped[(8000 + 14_400)...].allSatisfy { abs($0) < 1e-6 })
    }

    /// 書いた `.mov` の音声トラックの左チャンネル。
    private func leftChannel(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        try #require(reader.startReading())
        var interleaved: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            interleaved += Array(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self),
                    count: length / MemoryLayout<Float>.size))
        }
        return (0..<(interleaved.count / 2)).map { interleaved[2 * $0] }
    }
}

/// 引数の検め (完了条件 6)。走らせないファイルで見るので、GPU も機材も要らない。
@Suite("音声ファイルの包絡の引数")
struct SoundFileEnvelopeArgumentTests {
    private func makeFile(_ warnings: @escaping (String) -> Void) throws -> SoundFile {
        SoundFile(
            name: "song.wav", buffer: try rampBuffer(48_000), owner: nil, flow: nil, warn: warnings)
    }

    /// 合成した音源と同じ関数 (``EnvelopeArguments``) が、このファイルの呼び名で言う知らせ。
    private func expected(
        _ attack: Float, _ sustain: Float, _ level: Float, _ release: Float
    ) -> [String] {
        var said: [String] = []
        _ = EnvelopeArguments.accept(
            attack: attack, sustain: sustain, level: level, release: release, sampleRate: 48_000,
            subject: "\"song.wav\"", notice: { _, message in said.append(message) })
        return said
    }

    @Test(
        "数でない値・標本の数で表せない長さは呼び出しごと無視し (鳴らさない)、負の秒・範囲の外の高さは丸めて鳴らす。どれも合成した音源と同じ文面で 1 度だけ知らせる",
        arguments: [
            (Float.nan, Float(1), Float(1), Float(1), false),
            (Float(1), Float.infinity, Float(1), Float(1), false),
            (Float(1), Float(1), Float.nan, Float(1), false),
            (Float(1), Float(1), Float(1), Float(1e15), false),
            (Float(-1), Float(1), Float(1), Float(1), true),
            (Float(1), Float(1), Float(2), Float(1), true),
        ])
    func argumentsAreCheckedLikeSynthesizedSources(
        attack: Float, sustain: Float, level: Float, release: Float, plays: Bool
    ) throws {
        var warnings: [String] = []
        let file = try makeFile { warnings.append($0) }
        let env = Env()
        env.play(file, attack, sustain, level, release)
        #expect(file.isPlaying == plays)
        let said = expected(attack, sustain, level, release)
        #expect(said.count == 1)
        #expect(warnings == said)
        // 同じ知らせは 2 度言わない
        env.play(file, attack, sustain, level, release)
        #expect(warnings == said)
    }

    @Test("文面は合成した音源のものと、音の呼び名だけが違う")
    func messagesMatchTheSynthesizedOnes() {
        var file: [String] = []
        var synth: [String] = []
        for subject in ["\"song.wav\"", "this SinOsc"] {
            _ = EnvelopeArguments.accept(
                attack: -1, sustain: 1, level: 2, release: 1, sampleRate: 48_000, subject: subject,
                notice: { _, message in
                    if subject == "this SinOsc" { synth.append(message) } else { file.append(message) }
                })
        }
        #expect(file.count == 2)
        #expect(file == synth.map { $0.replacingOccurrences(of: "this SinOsc", with: "\"song.wav\"") })
        #expect(synth.first == "Env.play() takes attackTime of 0 seconds or more, so -1.0 was changed to 0 for this SinOsc")
    }
}
