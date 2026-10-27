// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 書き出しの `.mov` に載る音の、操作が効く窓と、形のいろいろ (#3125・#3245)。走っているスケッチの中で回して
/// 書き出し、符号化を通った実物を読み戻すので GPU を要する。
@Suite(
    "書き出しの音声トラック (操作と形)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundTrackOperationsTests {
    /// 標本の番号だけで決まる、0 を取らない値。鳴った位置が値から読める。
    static func value(_ index: Int) -> Float { Float(index % 997 + 1) / 2000 }

    private func temporaryMovie() -> URL {
        TestScratch.path("mokume-sound-ops", pathExtension: "mov")
    }

    /// 書いた `.mov` の音声トラック。
    private struct Heard {
        var tracks = 0
        var left: [Float] = []
        var right: [Float] = []
    }

    private func hear(_ url: URL) async throws -> Heard {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Heard() }
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
            tracks: 1, left: (0..<frames).map { interleaved[2 * $0] },
            right: (0..<frames).map { interleaved[2 * $0 + 1] })
    }

    /// 走らせて閉じる。`draw` は `frameCount - 1` (フレームの番号) を受ける。フレーム 0 から `frames - 1` の窓までを録る
    /// (`frames` 枚目の `draw()` で止めるので、窓は `frames - 1` 個)。
    private func record(
        to url: URL, fps: Int = 60, frames: Int, setup: @escaping (SoundSketch) throws -> Void,
        draw: @escaping (SoundSketch, Int) -> Void
    ) throws {
        SoundSketch.onSetup = setup
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == 1 { sketch.beginRecord(url.path) }
            draw(sketch, sketch.frameCount - 1)
            if sketch.frameCount == frames { sketch.endRecord() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: fps))
        for _ in 0..<frames { try runtime.advance() }
        runtime.closePlugins()
    }

    private func window(_ samples: [Float], _ index: Int, count: Int = 800) -> ArraySlice<Float> {
        samples[(index * count)..<((index + 1) * count)]
    }

    /// 窓 `index` が `expected(k)` (窓の中の k 番目) と 1e-6 以内で一致するか。`nil` は無音。
    private func matches(
        _ samples: [Float], window index: Int, count: Int = 800, expected: (Int) -> Float?
    ) -> Bool {
        window(samples, index, count: count).enumerated().allSatisfy { offset, sample in
            abs(sample - (expected(offset) ?? 0)) < 1e-6
        }
    }

    // MARK: - 操作が効く窓

    /// ADR-0042 の「操作が効く時刻」の表そのもの: 鳴らす・止める・音量は窓 N の先頭から、飛ぶは窓 N + 1 の先頭から。
    @Test("SoundFile の操作が効く窓: play・pause・stop・amp はフレーム N の窓の先頭から、鳴っている間の jump は窓 N+1 の先頭から")
    func eachOperationTakesEffectAtItsWindow() async throws {
        let wav = try writeWAV((0..<48_000).map(Self.value), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        try record(
            to: url, frames: 26,
            setup: { sound = try $0.loadSound(wav.path) },
            draw: { _, frame in
                switch frame {
                case 3: sound?.play()
                case 6: sound?.amp(0.5)
                case 9: sound?.pause()
                case 12: sound?.play()
                case 15: sound?.jump(20_000.0 / 48_000.0)
                case 18: sound?.stop()
                case 21: sound?.play()
                default: break
                }
            })
        let heard = try await hear(url)
        try #require(heard.tracks == 1 && heard.left.count == 25 * 800, "\(heard.left.count) 標本")
        let left = heard.left
        // 鳴らす前は無音
        for index in 0..<3 { #expect(matches(left, window: index) { _ in nil }, "窓 \(index)") }
        // 窓 3 から鳴る (鳴らしたフレームの窓の先頭から)。窓 6 から音量が半分へ (音量も窓の先頭から)
        for index in 3..<6 {
            #expect(matches(left, window: index) { Self.value((index - 3) * 800 + $0) }, "窓 \(index) の play")
        }
        // 音量は窓 6 で変わる。約束は「窓 6 より前は前の音量 (上の 3..<6)・窓 6 の終わりには新しい音量・その間は一方向」
        // だけで、変わり方の形 (直線か曲線か) と長さ (窓の何標本かけるか) は OS の実装に依るので決め打ちしない
        let ratios = (0..<800).map { left[6 * 800 + $0] / Self.value(3 * 800 + $0) }
        #expect(ratios.allSatisfy { $0 > 0.5 - 1e-3 && $0 < 1 + 1e-3 }, "窓 6 の音量は 1 倍と 0.5 倍の間にある")
        #expect(zip(ratios, ratios.dropFirst()).allSatisfy { $0 >= $1 - 1e-6 }, "音量は一方向に変わる")
        #expect(abs(ratios[799] - 0.5) < 1e-6, "窓 6 の終わりには新しい音量に着いている (\(ratios[799]))")
        for index in 7..<9 {
            #expect(matches(left, window: index) { 0.5 * Self.value((index - 3) * 800 + $0) }, "窓 \(index) の amp")
        }
        // 窓 9 から止まる (止めたフレームの窓から無音)
        for index in 9..<12 { #expect(matches(left, window: index) { _ in nil }, "窓 \(index) の pause") }
        // 窓 12 から、止めた位置 (6 窓ぶん進んだ 4800) から鳴る
        for index in 12..<16 {
            #expect(
                matches(left, window: index) { 0.5 * Self.value(4_800 + (index - 12) * 800 + $0) },
                "窓 \(index) の play (止めた位置から)")
        }
        // 飛ぶのは窓 16 から。頼んだフレーム 15 の窓は、飛ぶ前の位置のまま (上の 12..<16 に入っている)
        for index in 16..<18 {
            #expect(
                matches(left, window: index) { 0.5 * Self.value(20_000 + (index - 16) * 800 + $0) },
                "窓 \(index) の jump (頼んだ次のフレームの窓から)")
        }
        // 窓 18 から止まり (止めたフレームの窓から無音)、窓 21 から頭から鳴る
        for index in 18..<21 { #expect(matches(left, window: index) { _ in nil }, "窓 \(index) の stop") }
        for index in 21..<25 {
            #expect(matches(left, window: index) { 0.5 * Self.value((index - 21) * 800 + $0) }, "窓 \(index) の play (頭から)")
        }
        #expect(heard.left == heard.right)
    }

    @Test("loop() の折り返しが標本に出る: 2.5 窓の長さの音を鳴らし続けると、窓の途中で頭へ戻る")
    func loopWrapsInsideAWindow() async throws {
        let wav = try writeWAV((0..<2_000).map(Self.value), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        try record(
            to: url, frames: 13,
            setup: { sound = try $0.loadSound(wav.path) },
            draw: { _, frame in if frame == 2 { sound?.loop() } })
        let heard = try await hear(url)
        try #require(heard.left.count == 12 * 800)
        for index in 0..<2 { #expect(matches(heard.left, window: index) { _ in nil }) }
        for index in 2..<12 {
            #expect(
                matches(heard.left, window: index) { Self.value(((index - 2) * 800 + $0) % 2_000) },
                "窓 \(index) (折り返しの前後)")
        }
    }

    /// 合成の変更も窓 N の先頭から効く: 音量を変える操作を窓 8 の頼みにした回と、変えない回で、窓 8 の途中までは
    /// 同じ標本で、窓 8 のうちに違い始める。
    @Test("合成した音の変更 (amp) は、頼んだフレームの窓の先頭から効く")
    func aSynthChangeTakesEffectInItsOwnWindow() async throws {
        func once(change: Bool) async throws -> [Float] {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var osc: SinOsc?
            try record(
                to: url, frames: 15,
                setup: { osc = $0.createSinOsc() },
                draw: { _, frame in
                    if frame == 2 { osc?.play(440, 0.5) }
                    if change, frame == 8 { osc?.amp(0.1) }
                })
            return try await hear(url).left
        }
        let plain = try await once(change: false)
        let changed = try await once(change: true)
        try #require(plain.count == 14 * 800 && changed.count == plain.count)
        let first = try #require(plain.indices.first { plain[$0] != changed[$0] })
        #expect(first >= 8 * 800 && first < 9 * 800, "違い始めたのは標本 \(first) (窓 8 は 6400〜7199)")
        #expect(plain[(2 * 800)..<(8 * 800)].contains { abs($0) > 0.1 })
    }

    // MARK: - 形のいろいろ

    /// 左右の違うステレオと、モノラルのファイル。
    private func writeChannels(_ channels: [[Float]], sampleRate: Double) throws -> URL {
        let url = TestScratch.path("mokume-sound-ops", pathExtension: "wav")
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels.count),
                interleaved: false))
        let count = channels[0].count
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for (channel, samples) in channels.enumerated() {
                let data = try #require(buffer.floatChannelData)[channel]
                for (index, sample) in samples.enumerated() { data[index] = sample }
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test("左右の違うステレオは左右のまま載り、モノラルは左右に同じ音が載る")
    func stereoKeepsItsChannelsAndMonoIsCentred() async throws {
        let left = (0..<24_000).map { Self.value($0) }
        let right = (0..<24_000).map { 0.25 * Self.value($0) }
        let stereo = try writeChannels([left, right], sampleRate: 48_000)
        let mono = try writeChannels([left], sampleRate: 48_000)
        defer {
            try? FileManager.default.removeItem(at: stereo)
            try? FileManager.default.removeItem(at: mono)
        }
        func once(_ file: URL) async throws -> Heard {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            try record(
                to: url, frames: 11,
                setup: { sound = try $0.loadSound(file.path) },
                draw: { _, frame in if frame == 2 { sound?.play() } })
            return try await hear(url)
        }
        let heardStereo = try await once(stereo)
        try #require(heardStereo.left.count == 10 * 800)
        #expect(matches(heardStereo.left, window: 4) { Self.value(2 * 800 + $0) }, "左は左のまま")
        #expect(matches(heardStereo.right, window: 4) { 0.25 * Self.value(2 * 800 + $0) }, "右は右のまま")

        let heardMono = try await once(mono)
        try #require(heardMono.left.count == 10 * 800)
        #expect(heardMono.left == heardMono.right, "モノラルは左右に同じ音が載る")
        let peak = heardMono.left[(2 * 800)..<(3 * 800)].map { abs($0) }.max() ?? 0
        #expect(peak > 0.1, "モノラルの音が載っていない (最大 \(peak))")
        #expect(heardMono.left[0..<(2 * 800)].allSatisfy { $0 == 0 })
    }

    @Test("44.1 kHz の音声ファイルも載る: 窓の位置から鳴り、位置と解析の値は録らない回と全フレームで一致する")
    func a44100HzFileIsCarried() async throws {
        let kick = (0..<11_025).map { $0 < 441 ? Float(0.5) : 0 }
        let wav = try writeWAV(kick, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: wav) }

        func run(recording: Bool) async throws -> (seen: [[Float]], heard: Heard) {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var sound: SoundFile?
            var seen: [[Float]] = []
            SoundSketch.onSetup = { sound = try $0.loadSound(wav.path) }
            SoundSketch.onDraw = { sketch in
                if let sound { seen.append([Float(sound.samplePosition), sound.level, sound.peak, sound.rms]) }
                if recording, sketch.frameCount == 1 { sketch.beginRecord(url.path) }
                if sketch.frameCount == 5 { sound?.play() }
                if recording, sketch.frameCount == 40 { sketch.endRecord() }
            }
            let runtime = try SketchRuntime(
                sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
            for _ in 0..<40 { try runtime.advance() }
            runtime.closePlugins()
            return (seen, recording ? try await hear(url) : Heard())
        }
        let plain = try await run(recording: false)
        let recorded = try await run(recording: true)
        for (index, pair) in zip(plain.seen, recorded.seen).enumerated() {
            #expect(pair.0 == pair.1, "frame \(index): 録らない回 \(pair.0) 対 録った回 \(pair.1)")
        }
        let heard = recorded.heard
        try #require(heard.left.count == 39 * 800, "\(heard.left.count) 標本")
        // 立ち上がりは窓 4 の先頭 (3200)。変換の前後の揺れ (数標本) を許す
        let onset = try #require(heard.left.firstIndex { abs($0) > 0.01 })
        #expect(abs(onset - 4 * 800) < 16, "立ち上がりが標本 \(onset) (窓 4 の先頭は 3200)")
        let peak = heard.left.map { abs($0) }.max() ?? 0
        #expect(peak > 0.4 && peak < 0.65, "音の大きさ \(peak)")
    }

    // MARK: - 割り切れない fps の解析

    @Test("録りを途中で始め・止めても、音声ファイルの位置と解析の値は録らない回と全フレームで一致する (60・144・24 fps)")
    func switchingToTheTrackKeepsValuesAtEveryFrameRate() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }

        func run(recording: Bool, fps: Int) throws -> [[Float]] {
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
                // 割り切れない fps では、録りを頼むフレームが窓の継ぎ目の途中にある
                if recording, sketch.frameCount == 11 { sketch.beginRecord(url.path) }
                if recording, sketch.frameCount == 31 { sketch.endRecord() }
                if sketch.frameCount == 20 { sound?.jump(0.2) }
                if sketch.frameCount == 25 { sound?.amp(0.5) }
            }
            let runtime = try SketchRuntime(
                sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: fps))
            for _ in 0..<50 { try runtime.advance() }
            runtime.closePlugins()
            return seen
        }
        for fps in [60, 144, 24] {
            let plain = try run(recording: false, fps: fps)
            let recorded = try run(recording: true, fps: fps)
            #expect(plain.count == 50 && recorded.count == 50)
            for (index, pair) in zip(plain, recorded).enumerated() {
                #expect(pair.0 == pair.1, "\(fps) fps, frame \(index): 録らない回 \(pair.0) 対 録った回 \(pair.1)")
            }
            #expect(Set(plain.map { $0[1] }).count > 5, "\(fps) fps")
        }
    }

    // MARK: - 載せない録り・載せられない音源

    /// 実時間の時計の `.mov` に組み込みの音源が居るとき、載せないことを 1 度だけ名乗る。音源は、機材に触れないよう
    /// 機材に出さない流れへ差し込む。
    @Test("実時間の時計の .mov に、組み込みの音源 (SoundFile・合成した音) が居ると、載せないことを 1 度だけ名乗る")
    func aWallClockMovieNamesTheBuiltInSources() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        for kind in ["SoundFile", "SynthSound"] {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var kept: [AnyObject] = []
            SoundSketch.onSetup = { sketch in
                let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
                if kind == "SoundFile" {
                    let sound = SoundFile(
                        name: "chord.wav", buffer: try AudioFile.load(wav, path: "chord.wav"), owner: sketch,
                        flow: flow, warn: { _ in })
                    sketch.attach(sound)
                    kept.append(sound)
                } else {
                    kept.append(SynthStage.stage(for: sketch, flow: flow, warn: { _ in }))
                    kept.append(sketch.createSinOsc())
                }
                kept.append(flow)
            }
            SoundSketch.onDraw = { sketch in
                if sketch.frameCount == 2 { sketch.beginRecord(url.path) }
            }
            let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: .wallClock)
            for _ in 0..<5 { try runtime.advance() }
            let warnings = try #require(runtime.recorderWarnings)
            #expect(
                warnings.count { if case .soundNotCarried = $0 { true } else { false } } == 1,
                "\(kind): 実時間の時計の録りが、音源が居るのに載せないことを名乗らない")
            #expect(warnings.message(for: .soundNotCarried)?.contains("does not carry sound") == true)
            runtime.closePlugins()
            _ = kept
        }
    }

    /// 音声トラックの流れが音源を受けつけないとき (出力が開けない相当)、録りの間も解析の位置は数で進み続ける。
    /// 鳴らさず実時間へ落とすと、その録りの間だけ位置が壁時計で進み、同じ設定から同じ値にならない。
    @Test("音声トラックの流れが音源を受けなくても、位置と解析の値は録らない回と全フレームで一致し、事情どおりに 1 度だけ知らせる")
    func aFlowThatRefusesTheSourcesKeepsCountingByFrames() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }

        func run(recording: Bool) throws -> (seen: [[Float]], notices: [String]) {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var notices: [String] = []
            var sound: SoundFile?
            var osc: SinOsc?
            var seen: [[Float]] = []
            SoundSketch.onSetup = { sketch in
                let file = SoundFile(
                    name: "chord.wav", buffer: try AudioFile.load(wav, path: "chord.wav"), owner: sketch,
                    flow: nil, source: wav, warn: { notices.append($0) })
                sketch.attach(file)
                file.loop()
                sound = file
                _ = SynthStage.stage(for: sketch, warn: { notices.append($0) })
                osc = sketch.createSinOsc()
                osc?.play(440, 0.5)
                // 音声トラックの流れを、音源を受けつけない流れにする
                SoundTrackMixer.mixer(for: sketch)?.flowMadeForTesting = { $0.refusesNodesForTesting = true }
            }
            SoundSketch.onDraw = { sketch in
                if let sound, let osc {
                    seen.append([Float(sound.samplePosition), sound.level, sound.peak, osc.level, osc.rms])
                }
                if recording, sketch.frameCount == 11 { sketch.beginRecord(url.path) }
                if recording, sketch.frameCount == 31 { sketch.endRecord() }
            }
            let runtime = try SketchRuntime(
                sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
            for _ in 0..<45 { try runtime.advance() }
            runtime.closePlugins()
            return (seen, notices)
        }
        let plain = try run(recording: false)
        let recorded = try run(recording: true)
        #expect(plain.notices.isEmpty, "\(plain.notices)")
        #expect(plain.seen.count == 45 && recorded.seen.count == 45)
        for (index, pair) in zip(plain.seen, recorded.seen).enumerated() {
            #expect(pair.0 == pair.1, "frame \(index): 録らない回 \(pair.0) 対 録った回 \(pair.1)")
        }
        // 事情どおりの知らせ: 録りに載せられなかったと言い、「出力が開けない」とは言わない
        let said = recorded.notices
        #expect(said.filter { $0.contains("could not be put in the recording") }.count == 2, "\(said)")
        #expect(said.contains { $0.contains("synthesized sounds could not be put in the recording") })
        #expect(!said.contains { $0.contains("No audio output") }, "\(said)")
    }

    @Test("録りの頭で音声ファイルを読み直すのは同期の読み込みだが、書き出し (画面へ出さない固定の時計) では知らせない。録っても録らなくても出ない")
    func rereadingTheFileForTheRecordingIsNotNoticedWhenRendering() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let call = "beginRecord() on a sketch with a SoundFile (the file is read again for the recording)"

        func run(recording: Bool) throws -> (said: String?, trackBegun: Bool) {
            let url = temporaryMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            var trackBegun = false
            SoundSketch.onSetup = { sketch in try sketch.loadSound(wav.path).loop() }
            SoundSketch.onDraw = { sketch in
                if recording, sketch.frameCount == 3 { sketch.beginRecord(url.path) }
                if recording, sketch.frameCount == 5 {
                    trackBegun = SoundTrackMixer.mixer(for: sketch)?.track != nil
                }
                if recording, sketch.frameCount == 8 { sketch.endRecord() }
            }
            let runtime = try SketchRuntime(
                sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
            for _ in 0..<10 { try runtime.advance() }
            let said = runtime.blockingLoads.message(for: call)
            runtime.closePlugins()
            return (said, trackBegun)
        }
        // 録りは本当に始まって (器は読み直されている)、読み直しの知らせだけが出ない
        let recorded = try run(recording: true)
        #expect(recorded.trackBegun, "音声トラックが始まっていない")
        #expect(recorded.said == nil)
        #expect(try run(recording: false).said == nil)
    }

    @Test("画面へ出す実行では、録りの頭の読み直しを、loadSound と同じく 1 度だけ知らせる")
    func rereadingTheFileForTheRecordingIsNoticedOnScreen() throws {
        let wav = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let call = "beginRecord() on a sketch with a SoundFile (the file is read again for the recording)"

        var file: SoundFile?
        SoundSketch.onSetup = { sketch in file = try sketch.loadSound(wav.path) }
        SoundSketch.onDraw = { sketch in
            if sketch.frameCount == 3 { file?.noticeRereadForTrack() }
        }
        // 実時間の時計は画面へ出す扱い
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: .wallClock)
        #expect(runtime.isOnScreen)
        for _ in 0..<5 { try runtime.advance() }
        #expect(runtime.blockingLoads.message(for: call) == BlockingLoads.notice(call, instead: nil))
        runtime.closePlugins()
    }
}
