// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 書き出しの `.mov` に載る音の流れ全体 (#3125): 再生 (`SoundFile`)・合成した音・エフェクトを通した音。
/// 走っているスケッチの中で回して書き出し、符号化を通った実物を読み戻すので GPU を要する。
@Suite(
    "書き出しの音声トラック (音の流れ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundTrackTests {
    /// 頭に鋭い立ち上がりのある短い音 (キック)。0.25 秒で 0.5 の矩形に近い。標本の位置を読み戻して突き合わせる。
    static let kick: [Float] = (0..<12_000).map { $0 < 480 ? 0.5 : 0 }

    private func temporaryMovie() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sound-track-\(UUID().uuidString).mov")
    }

    /// 走らせて閉じる。`setup` と `draw` はスケッチへ渡す手続き。`begins`・`ends` は録りの頼み (番号は `frameCount`)。
    private func record(
        to url: URL, fps: Int = 60, begins: Int = 1, ends: Int, setup: @escaping (SoundSketch) throws -> Void,
        draw: @escaping (SoundSketch) -> Void = { _ in }
    ) throws {
        SoundSketch.onSetup = setup
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == begins { sketch.beginRecord(url.path) }
            draw(sketch)
            if sketch.frameCount == ends { sketch.endRecord() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: fps))
        for _ in 0..<ends { try runtime.advance() }
        runtime.closePlugins()
    }

    /// 書いた `.mov` の音声トラックの左チャンネルと、トラックの数・長さ。
    private struct Heard {
        var tracks: Int
        var left: [Float]
        var right: [Float]
        var duration: Double
        var videoDuration: Double
        var sampleRate: Double
        var channels: UInt32
    }

    private func hear(_ url: URL) async throws -> Heard {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoDuration = try await video.load(.timeRange).duration.seconds
        guard let track = tracks.first else {
            return Heard(
                tracks: 0, left: [], right: [], duration: 0, videoDuration: videoDuration, sampleRate: 0,
                channels: 0)
        }
        let range = try await track.load(.timeRange)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        try #require(reader.startReading(), "音声を読み始められない: \(String(describing: reader.error))")
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
        let frames = interleaved.count / 2
        return Heard(
            tracks: tracks.count, left: (0..<frames).map { interleaved[2 * $0] },
            right: (0..<frames).map { interleaved[2 * $0 + 1] }, duration: range.duration.seconds,
            videoDuration: videoDuration, sampleRate: basic.mSampleRate, channels: basic.mChannelsPerFrame)
    }

    /// 立ち上がりの標本の番号 — 0.01 を越える標本のうち、直前の 1000 標本が無音のもの。
    private func onsets(_ samples: [Float]) -> [Int] {
        samples.indices.filter { index in
            abs(samples[index]) > 0.01
                && (index == 0 || samples[max(0, index - 1000)..<index].allSatisfy { abs($0) <= 0.01 })
        }
    }

    // MARK: - 再生した音

    /// 0.5 秒ごとに鳴らすキック。フレームの番号 0・30・60・90 (60 fps) で鳴らす。
    @Test("鳴らしたキックの立ち上がりが、読み戻した音声の標本 0・24000・48000・72000 番目にある (±0)。トラックは時刻 0 から映像と同じ長さ")
    func playedKicksLandOnTheWindows() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var kickSound: SoundFile?
        try record(
            to: url, ends: 121,
            setup: { kickSound = try $0.loadSound(wav.path) },
            draw: { sketch in
                if (sketch.frameCount - 1) % 30 == 0 { kickSound?.play() }
            })

        let heard = try await hear(url)
        #expect(heard.tracks == 1)
        #expect(heard.sampleRate == 48_000 && heard.channels == 2)
        try #require(heard.left.count == 96_000, "\(heard.left.count) 標本")
        #expect(abs(heard.duration - 2) < 1e-3 && abs(heard.videoDuration - 2) < 1e-3)
        #expect(onsets(heard.left) == [0, 24_000, 48_000, 72_000], "\(onsets(heard.left))")
        // 鳴った音そのもの (左右とも同じ音を書いてある)
        for start in [0, 24_000, 48_000, 72_000] {
            let worst = (0..<12_000).map { abs(heard.left[start + $0] - Self.kick[$0]) }.max() ?? 1
            #expect(worst < 1e-6, "\(start) 番目からのキックが元の音と違う")
        }
        #expect(heard.left == heard.right)
    }

    @Test("144 fps・48000 Hz で 144 フレーム録ると、音声は 48000 標本ちょうど (窓の長さを丸めて足すと 47952)。同じスケッチを 2 回書くと標本が全部一致する")
    func windowsAreExactAndRepeatable() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        func once() async throws -> Heard {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            try record(
                to: url, fps: 144, ends: 145,
                setup: { sound = try $0.loadSound(wav.path) },
                draw: { sketch in
                    // 窓の継ぎ目の途中 (⌊N·48000/144⌋ が整数にならないフレーム) で鳴らす
                    if sketch.frameCount == 7 || sketch.frameCount == 80 { sound?.play() }
                })
            return try await hear(url)
        }
        let first = try await once()
        #expect(first.left.count == 48_000, "\(first.left.count) 標本")
        // 立ち上がりは、窓の先頭 ⌊N·48000/144⌋ (N = 6・79) の標本にある
        let expected = [6, 79].map { Int((Double($0) * 48_000 / 144).rounded(.down)) }
        #expect(onsets(first.left) == expected, "\(onsets(first.left)) 対 \(expected)")
        let second = try await once()
        #expect(second.left == first.left && second.right == first.right)
    }

    // MARK: - 合成した音

    @Test("合成した音 (オシレータ・包絡) も載る。鳴らした操作は、その窓の先頭から効く")
    func synthesizedSoundIsCarried() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var osc: SinOsc?
        try record(
            to: url, ends: 61,
            setup: { osc = $0.createSinOsc() },
            draw: { sketch in
                // 31 フレーム目 (番号 30 = 標本 24000) の draw() で鳴らす
                if sketch.frameCount == 31 { osc?.play(1000, 0.5) }
            })
        let heard = try await hear(url)
        try #require(heard.tracks == 1 && heard.left.count == 48_000, "音声トラック \(heard.tracks) 本・\(heard.left.count) 標本")
        // 24000 番目の前は無音、そこから鳴る (約 5 ミリ秒の立ち上がりを含む)
        #expect(heard.left[0..<24_000].allSatisfy { abs($0) < 1e-6 })
        #expect(heard.left[24_000..<26_000].contains { abs($0) > 0.01 })
        #expect(heard.left[40_000..<48_000].map { abs($0) }.max() ?? 0 > 0.3)
    }

    @Test("エフェクトに通した音声ファイルも載る (ラックの節が鳴らす)")
    func aRoutedFileIsCarried() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        try record(
            to: url, ends: 61,
            setup: { sketch in
                sound = try sketch.loadSound(wav.path)
                let filter = sketch.createLowPass()
                filter.freq(20_000)
                if let sound { filter.process(sound) }
            },
            draw: { sketch in
                if sketch.frameCount == 11 { sound?.play() }
            })
        let heard = try await hear(url)
        #expect(heard.tracks == 1 && heard.left.count == 48_000)
        // 11 フレーム目 (番号 10 = 標本 8000) から鳴る
        let first = onsets(heard.left).first
        #expect(first != nil && abs((first ?? 0) - 8_000) < 300, "\(String(describing: first))")
    }

    /// `mokume render` は最初のフレームより前に撮り始め (`runtime.beginRecord`)、決めた枚数を回して閉じる。
    /// 頼んだ番号は 0 で、トラックは窓 0 から始まり、窓の数は絵の数と同じ。
    @Test("最初のフレームより前に録り始める (mokume render と同じ形) と、トラックは標本 0 から、窓の数は絵の数と同じ")
    func renderStyleRecordingStartsAtFrameZero() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        SoundSketch.onSetup = { sound = try $0.loadSound(wav.path) }
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == 1 { sound?.play() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        runtime.beginRecord(url.path)
        for _ in 0..<60 { try runtime.advance() }
        runtime.closePlugins()

        let heard = try await hear(url)
        #expect(heard.tracks == 1)
        #expect(heard.left.count == 48_000, "\(heard.left.count) 標本")
        #expect(abs(heard.duration - 1) < 1e-3 && abs(heard.videoDuration - 1) < 1e-3)
        #expect(onsets(heard.left) == [0])
    }

    /// 音声トラックが始まる (鳴らさずに数で進めていた音源が、機材に出さない流れへ切り替わる) 前後で、位置と解析の値が
    /// 途切れない: 録りを途中で始めて途中で止めた回と、録らない回で、全フレームの位置と値が一致する。
    @Test("録りを途中で始め・止めても、音声ファイルの位置と解析の値は、録らない回と全フレームで一致する")
    func switchingToTheTrackKeepsPositionsAndValues() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }

        func run(recording: Bool) throws -> [[Float]] {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            var seen: [[Float]] = []
            SoundSketch.onSetup = { sketch in
                sound = try sketch.loadSound(wav.path)
                sound?.loop()
            }
            SoundSketch.onDraw = { sketch in
                if let sound {
                    seen.append([Float(sound.samplePosition), sound.level, sound.peak, sound.rms])
                }
                if recording, sketch.frameCount == 11 { sketch.beginRecord(url.path) }
                if recording, sketch.frameCount == 31 { sketch.endRecord() }
                // 途中で飛ぶ・音量を変える操作も、切り替えの前後で同じに効く
                if sketch.frameCount == 20 { sound?.jump(0.2) }
                if sketch.frameCount == 25 { sound?.amp(0.5) }
            }
            let runtime = try SketchRuntime(
                sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
            for _ in 0..<50 { try runtime.advance() }
            runtime.closePlugins()
            return seen
        }
        let plain = try run(recording: false)
        let recorded = try run(recording: true)
        #expect(plain.count == 50 && recorded.count == 50)
        for (index, pair) in zip(plain, recorded).enumerated() {
            #expect(pair.0 == pair.1, "frame \(index): 録らない回 \(pair.0) 対 録った回 \(pair.1)")
        }
        #expect(plain[49][0] > 0 && Set(plain.map { $0[1] }).count > 5)
    }

    /// 鳴らしたフレームの次のフレームで、解析の値が反応する (円が膨らみ始めるのは、鳴らしたフレームの次のフレーム)。
    @Test("鳴らしたフレームの level は 0 のまま、次のフレームで立ち上がる")
    func theLevelRisesOnTheFrameAfterThePlay() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        var levels: [Float] = []
        try record(
            to: url, ends: 121,
            setup: { sound = try $0.loadSound(wav.path) },
            draw: { sketch in
                levels.append(sound?.level ?? -1)
                if (sketch.frameCount - 1) % 30 == 0 { sound?.play() }
            })
        for frame in [0, 30, 60, 90] {
            #expect(levels[frame] == 0, "frame \(frame): 鳴らす前の level \(levels[frame])")
            #expect(levels[frame + 1] > 0.5, "frame \(frame + 1): 鳴らした次のフレームの level \(levels[frame + 1])")
        }
    }

    // MARK: - 窓の割り方・配りの遅れに依らない

    /// 配りを遅らせても結果は変わらない: 何もしない出口を付け、1 フレーム目に `save()` した回と、何もしない回で、
    /// トラックの有無も標本も同じ。
    @Test("絵の配りが変わっても (出口が付く・save() がある)、音声トラックの有無と標本は同じ")
    func deliveryTimingDoesNotChangeTheTrack() async throws {
        final class Idle: Outlet {
            func receive(_ frame: OutputFrame) {}
        }
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let still = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sound-track-still-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: still) }

        func once(busy: Bool) async throws -> Heard {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            let idle = Idle()
            try record(
                to: url, begins: 3, ends: 43,
                setup: { sketch in
                    sound = try sketch.loadSound(wav.path)
                    if busy { sketch.attach(idle) }
                },
                draw: { sketch in
                    if busy, sketch.frameCount == 1 { sketch.save(still.path) }
                    if sketch.frameCount == 10 { sound?.play() }
                })
            return try await hear(url)
        }
        let plain = try await once(busy: false)
        let busy = try await once(busy: true)
        #expect(plain.tracks == 1 && busy.tracks == 1)
        #expect(plain.left.count == 40 * 800 && busy.left == plain.left && busy.right == plain.right)
        // 10 フレーム目 (番号 9) で鳴らす。録りは番号 2 から: 窓 7 つ後 = 標本 5600 から
        #expect(onsets(plain.left) == [(9 - 2) * 800])
    }

    @Test("録りの途中で足した音源は、音声トラックがあれば載る")
    func aSourceAddedDuringTheRecordingIsCarried() async throws {
        let silentWav = try writeWAV([Float](repeating: 0, count: 960), sampleRate: 48_000)
        let lateWav = try writeWAV(Self.kick.map { $0 / 2 }, sampleRate: 48_000)
        defer {
            try? FileManager.default.removeItem(at: silentWav)
            try? FileManager.default.removeItem(at: lateWav)
        }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var late: SoundFile?
        try record(
            to: url, ends: 61,
            // 音源が居るので、トラックが付く (最初の音源は無音)
            setup: { _ = try $0.loadSound(silentWav.path) },
            draw: { sketch in
                // 31 フレーム目 (番号 30 = 標本 24000) の draw() で、音源を足して鳴らす
                if sketch.frameCount == 31 {
                    late = try? sketch.loadSound(lateWav.path)
                    late?.play()
                }
            })
        let heard = try await hear(url)
        try #require(heard.tracks == 1 && heard.left.count == 48_000)
        #expect(onsets(heard.left) == [24_000], "\(onsets(heard.left))")
        #expect(abs(heard.left[24_000] - 0.25) < 1e-6)
    }

    /// 窓ごとに描いても、一括で描いても同じ標本: 144 fps (窓の長さが 333・334 標本と揺れる) の窓で描いた流れと、
    /// 同じ操作を一括で描いた流れが、全標本一致する。機材にも許可にも GPU にも触れない。
    @Test("機材に出さない流れは、窓ごとに描いても一括で描いても全標本が一致する (144 fps の窓)")
    func windowedRenderingEqualsOneShot() throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let loaded = try AudioFile.load(wav, path: "kick.wav")

        func flow() throws -> (SoundFlow, FilePlayer) {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            let player = try #require(FilePlayer(flow: flow, buffer: loaded))
            player.play(from: 0, looping: true)
            return (flow, player)
        }
        let (windowed, playerA) = try flow()
        let (oneShot, playerB) = try flow()
        defer {
            playerA.leave()
            playerB.leave()
        }
        var pieces: [Float] = []
        for frame in 0..<144 {
            pieces += try render(windowed, SoundWindow.count(ofFrame: frame, frameRate: 144))
        }
        let whole = try render(oneShot, 48_000)
        #expect(pieces.count == 48_000 && whole.count == 48_000)
        #expect(pieces == whole)
        #expect(whole.map { abs($0) }.max() ?? 0 > 0.4)
    }

    @Test("音源が居ない録りの途中で足した音源は載せず、そのことを 1 度だけ名乗る")
    func aSourceAddedWithoutATrackIsNamedOnce() throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        SoundSketch.onSetup = { _ in }
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == 3 { sketch.beginRecord(url.path) }
            if sketch.frameCount == 6 { sketch.createSinOsc().play(440, 0.5) }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<9 { try runtime.advance() }
        let warnings = try #require(runtime.recorderWarnings)
        #expect(warnings.count { if case .soundAddedLate = $0 { true } else { false } } == 1)
        #expect(warnings.message(for: .soundAddedLate)?.contains("added after the recording began") == true)
        runtime.closePlugins()
    }

    /// 音源が 1 つも流れへ入れなかったとき (読み直せるファイルが無い) も、窓は描け、音声トラックは無音で付く。
    /// 機材に出さない流れは、節が 1 つも無いと描けずに落ちるので、無音の節を繋いである。
    @Test("読み直せない音声ファイルだけでも、落ちずに音声トラック (無音) が付き、載せられなかったことを 1 度だけ知らせる")
    func aFileThatCannotBeReadAgainLeavesASilentTrack() async throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var notices: [String] = []
        try record(
            to: url, ends: 31,
            setup: { sketch in
                // ファイルから作ったのではない (読み直す先が無い)
                let buffer = try AudioFile.load(wav, path: "kick.wav")
                let sound = SoundFile(
                    name: "kick.wav", buffer: buffer, owner: sketch, flow: nil, warn: { notices.append($0) })
                sketch.attach(sound)
                sound.play()
            })
        let heard = try await hear(url)
        try #require(heard.tracks == 1 && heard.left.count == 30 * 800)
        #expect(heard.left.allSatisfy { $0 == 0 })
        #expect(notices.count == 1 && notices.first?.contains("could not be read again") == true, "\(notices)")
    }

    // MARK: - 載せない・名乗る

    @Test("音源の無いスケッチは、音声トラックを付けない (映像だけ)")
    func noSourceNoTrack() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try record(to: url, ends: 21, setup: { _ in })
        let heard = try await hear(url)
        #expect(heard.tracks == 0 && heard.videoDuration > 0.3)
    }

    @Test("連番・実時間の時計の録りに音源が居るときは、載せないことを 1 度だけ名乗る")
    func uncarriedRecordingsSayWhy() throws {
        let wav = try writeWAV(Self.kick, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sound-track-seq-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sound: SoundFile?
        SoundSketch.onSetup = { sound = try $0.loadSound(wav.path) }
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == 1 { sketch.beginRecord(folder.appendingPathComponent("f-###.png").path) }
            if sketch.frameCount == 5 { sketch.endRecord() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<3 { try runtime.advance() }
        let warnings = try #require(runtime.recorderWarnings)
        #expect(warnings.count { if case .soundNotCarried = $0 { true } else { false } } == 1)
        #expect(warnings.message(for: .soundNotCarried)?.contains("does not carry sound") == true)
        runtime.closePlugins()
        _ = sound
    }
}
