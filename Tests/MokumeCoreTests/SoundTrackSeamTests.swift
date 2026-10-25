// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Testing

// **`@testable` を付けない。** 外のパッケージが音を載せる口 (``SoundSource``・``SoundWindow``) は公開で、
// 公開の口だけで音声トラックが付くことを見る ([#3125] の条件 10)。内部の口に触れると、ここで組めない。
//
// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
import MokumeCore

/// 書き出しの `.mov` への音声トラック (#3125)。外のパッケージが載せるのと同じ公開の口だけで、窓の標本を渡して
/// 音声トラックが付くことを見る。GPU を要する (スケッチを走らせて書き出す)。
@Suite(
    "書き出しの音声トラック (公開の口)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundTrackSeamTests {
    /// 標本の番号だけで決まる値。**読み戻した標本の位置を、番号で突き合わせるため** — 窓の継ぎ目が 1 標本ずれれば
    /// 読んだ値が合わない。左は番号の関数、右は逆符号。0 を避けて、窓の外の埋め (0) と見分ける。
    static func value(at sample: Int) -> Float {
        Float(sample % 997 + 1) / 1000
    }

    /// 公開の口だけで作った音源。外のパッケージが書く形と同じ。
    final class Probe: SoundSource {
        private(set) var begun: [Int] = []
        private(set) var windows: [(frame: Int, start: Int, count: Int)] = []
        private(set) var ended = 0

        func supply() {}
        func beginTrack(frameRate: Int) { begun.append(frameRate) }
        func endTrack() { ended += 1 }

        func mix(into window: inout SoundWindow) {
            windows.append((window.frame, window.start, window.count))
            for index in 0..<window.count {
                let value = SoundTrackSeamTests.value(at: window.start + index)
                window.left[index] += value
                window.right[index] -= value
            }
        }
    }

    /// 音源を足し、決めたフレームの間だけ `.mov` を撮るスケッチ。
    final class Recorder: Sketch {
        var path = ""
        var probe: Probe?
        var begins = 0
        var ends = 0
        var attachAt = 0
        init() {}
        convenience init(path: String, probe: Probe?, begins: Int, ends: Int, attachAt: Int = 0) {
            self.init()
            self.path = path
            self.probe = probe
            self.begins = begins
            self.ends = ends
            self.attachAt = attachAt
        }
        var settings: SketchSettings { SketchSettings(width: 64, height: 48, frameRate: 60) }
        func setup() {
            if attachAt == 0, let probe { attach(probe) }
        }
        func draw() {
            background(30, 30, 40)
            if attachAt > 0, frameCount == attachAt, let probe { attach(probe) }
            if frameCount == begins { beginRecord(path) }
            if frameCount == ends { endRecord() }
        }
    }

    /// 走らせて、止めるフレームの後で閉じる。
    private func run(
        _ sketch: Recorder, clock: Clock = .frameIndex(frameRate: 60), frames: Int,
        before close: (SketchRuntime) -> Void = { _ in }
    ) throws {
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: clock)
        for _ in 0..<frames { try runtime.advance() }
        close(runtime)
        runtime.closePlugins()
    }

    private func temporaryMovie() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sound-track-\(UUID().uuidString).mov")
    }

    /// 書いた `.mov` の音声トラックを、標本として読み戻す。**符号化を通った実物を読む。**
    struct Heard {
        var trackCount: Int
        var start: CMTime
        var duration: CMTime
        var videoStart: CMTime
        var videoDuration: CMTime
        var formatID: AudioFormatID
        var sampleRate: Double
        var channels: UInt32
        var bitsPerChannel: UInt32
        var isFloat: Bool
        /// 左右が交互の標本 (L0, R0, L1, R1, …)。
        var samples: [Float]
    }

    private func hear(_ url: URL) async throws -> Heard {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoRange = try await video.load(.timeRange)
        guard let track = tracks.first else {
            return Heard(
                trackCount: 0, start: .zero, duration: .zero, videoStart: videoRange.start,
                videoDuration: videoRange.duration,
                formatID: 0, sampleRate: 0, channels: 0, bitsPerChannel: 0, isFloat: false,
                samples: [])
        }
        let range = try await track.load(.timeRange)
        let descriptions = try await track.load(.formatDescriptions)
        let format = try #require(descriptions.first)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        try #require(reader.startReading(), "音声を読み始められない: \(String(describing: reader.error))")
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &pointer)
            guard let pointer else { continue }
            let floats = UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self),
                count: length / MemoryLayout<Float>.size)
            samples.append(contentsOf: floats)
        }
        return Heard(
            trackCount: tracks.count, start: range.start, duration: range.duration,
            videoStart: videoRange.start, videoDuration: videoRange.duration, formatID: basic.mFormatID,
            sampleRate: basic.mSampleRate, channels: basic.mChannelsPerFrame,
            bitsPerChannel: basic.mBitsPerChannel,
            isFloat: basic.mFormatFlags & kAudioFormatFlagIsFloat != 0, samples: samples)
    }

    // MARK: - 載る

    @Test("固定の時計で .mov を録ると、公開の口で足した音源の音が音声トラックに載る。形は LPCM・32 ビット浮動小数点・48 kHz・2 チャンネル")
    func theTrackIsAttached() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe()
        // 1 フレーム目から 61 フレーム目の手前まで (60 フレーム = 1 秒) 録る
        try run(Recorder(path: url.path, probe: probe, begins: 1, ends: 61), frames: 61)

        let heard = try await hear(url)
        #expect(heard.trackCount == 1)
        #expect(heard.formatID == kAudioFormatLinearPCM)
        #expect(heard.sampleRate == 48_000 && heard.channels == 2)
        #expect(heard.bitsPerChannel == 32 && heard.isFloat)
        // 音声トラックは時刻 0 から始まり、長さは映像と同じ (1.0 秒・48000 標本)
        #expect(heard.start == .zero, "\(heard.start)")
        #expect(heard.samples.count == 2 * 48_000, "\(heard.samples.count / 2) 標本")
        #expect(abs(heard.duration.seconds - 1) < 1e-3 && abs(heard.videoDuration.seconds - 1) < 1e-3)
        // 全標本が、番号の関数と一致する (窓の継ぎ目の欠けも重なりも無い)
        var worst = 0
        for sample in 0..<48_000 {
            let expected = Self.value(at: sample)
            if heard.samples[2 * sample] != expected || heard.samples[2 * sample + 1] != -expected {
                worst += 1
            }
        }
        #expect(worst == 0, "\(worst) 標本が違う")
        // 音源が受けた窓: 60 個・フレームの番号の順・窓の先頭は ⌊N·48000/60⌋ = 800N
        #expect(probe.begun == [60] && probe.ended == 1)
        #expect(probe.windows.count == 60)
        #expect(probe.windows.enumerated().allSatisfy { $1.frame == $0 && $1.start == 800 * $0 && $1.count == 800 })
    }

    @Test("録りを頼んだフレームが F (> 0) のとき、音声トラックは標本 ⌊F·sr/fps⌋ から始まり、映像の最初と同じ時刻を持つ")
    func theTrackStartsAtTheRequestedFrame() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe()
        // 11 フレーム目 (フレームの番号 10) から録る。20 フレーム録る
        try run(Recorder(path: url.path, probe: probe, begins: 11, ends: 31), frames: 31)

        let heard = try await hear(url)
        #expect(heard.trackCount == 1)
        #expect(heard.samples.count == 2 * 20 * 800)
        // 先頭は標本 8000 (= 10 × 800)。読み戻した最初の標本が value(8000)
        #expect(heard.samples.first == Self.value(at: 8_000))
        #expect(heard.samples[2 * 799] == Self.value(at: 8_000 + 799))
        // 映像の最初と同じ時刻に始まる (どちらも、録りの頭を時刻 0 として書く)
        #expect(heard.start == heard.videoStart, "音声 \(heard.start) 映像 \(heard.videoStart)")
        #expect(probe.windows.first?.frame == 10 && probe.windows.first?.start == 8_000)
    }

    @Test("音源が居ない録りは、音声トラックを付けない")
    func noSourceNoTrack() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try run(Recorder(path: url.path, probe: nil, begins: 1, ends: 21), frames: 21)
        let heard = try await hear(url)
        #expect(heard.trackCount == 0)
        #expect(heard.videoDuration.seconds > 0.3)
    }

    @Test("録りを頼んだフレームの draw() の中で足した音源は載り、録りの途中で足した音源は載せない (トラックが無い)")
    func theTrackIsDecidedAtTheEndOfTheRequestingFrame() async throws {
        // draw() の中 (録りを頼むのと同じフレーム) で足す: 載る
        let carried = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: carried) }
        let first = Probe()
        try run(Recorder(path: carried.path, probe: first, begins: 3, ends: 13, attachAt: 3), frames: 13)
        #expect(try await hear(carried).trackCount == 1)
        #expect(first.windows.count == 10)

        // 音源の居ない録りの途中で足す: 載らない
        let late = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: late) }
        let second = Probe()
        try run(Recorder(path: late.path, probe: second, begins: 3, ends: 13, attachAt: 6), frames: 13)
        #expect(try await hear(late).trackCount == 0)
        #expect(second.windows.isEmpty && second.begun.isEmpty)
    }

    @Test("実時間の時計で録った .mov には音を載せない")
    func aWallClockMovieCarriesNoSound() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe()
        try run(Recorder(path: url.path, probe: probe, begins: 1, ends: 11), clock: .wallClock, frames: 11)
        #expect(try await hear(url).trackCount == 0)
        #expect(probe.windows.isEmpty)
    }
}
