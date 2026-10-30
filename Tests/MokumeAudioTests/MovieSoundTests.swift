// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCamera
@testable import MokumeCore

/// 動画ファイルの音を `loadSound` で鳴らす道 (#3452)。`Movie` は音を鳴らさず、同じファイルを
/// `loadSound` で開いて `jump(_:)` で合わせる。ここは、その道が成り立つこと — `.mov`・`.mp4` の音声
/// トラックを `loadSound` が読むこと — と、固定の時計で書き出したときの映像と音の頭のずれを確かめる。
///
/// 動画は検査の中で書く (動画はリポジトリに置けない)。走っているスケッチの中で回すので GPU を要する。
@Suite(
    "動画の音を loadSound で鳴らす",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MovieSoundTests {
    /// 音声トラックの作り方。
    enum Track {
        /// 16 bit の整数の LPCM。標本が量子化の幅 (1/32768) の中で元と一致する。
        case lpcm
        /// AAC。不可逆なので、長さ (符号化の最小の単位 1024 標本の中) と周波数で突き合わせる。
        case aac
    }

    static let sampleRate = 48_000
    static let tone: Float = 1000
    static let amplitude: Float = 0.5

    /// 映像 `frames` 枚 (`fps`) と、`seconds` 秒の 1000 Hz の正弦波 (モノラル・48 kHz) を持つ動画を書く。
    /// `index` 枚目の映像は灰色で、明るさは `(index % 6) * 40 + 20` (枚ごとに見分けがつく)。
    static func writeMovie(
        fileType: AVFileType, track: Track, frames: Int = 30, fps: Int32 = 30, seconds: Double = 1
    ) async throws -> URL {
        let url = TestScratch.path(
            "mokume-movie-sound", pathExtension: fileType == .mp4 ? "mp4" : "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
            ])
        var audioSettings: [String: Any] =
            switch track {
            case .lpcm:
                [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                ]
            case .aac:
                [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
                ]
            }
        audioSettings[AVSampleRateKey] = Self.sampleRate
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(Self.sampleRate))
        let source = Self.sine(count: total)
        let chunk = Self.sampleRate / Int(fps)
        var audioAt = 0
        for index in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let level = UInt8((index % 6) * 40 + 20)
            for row in 0..<48 {
                let line = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer))
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0..<64 {
                    line[column * 4] = level
                    line[column * 4 + 1] = level
                    line[column * 4 + 2] = level
                    line[column * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
            // 同じ区間の音を、映像と交互に渡す (書き手が片方の入力を待たせて詰まらないように)
            if audioAt < total {
                let end = min(total, audioAt + chunk)
                while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                let sample = try Self.sampleBuffer(Array(source[audioAt..<end]), at: audioAt)
                #expect(audio.append(sample))
                audioAt = end
            }
        }
        while audioAt < total {
            let end = min(total, audioAt + chunk)
            while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let sample = try Self.sampleBuffer(Array(source[audioAt..<end]), at: audioAt)
            #expect(audio.append(sample))
            audioAt = end
        }
        video.markAsFinished()
        audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 48_000))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// 書く標本 (16 bit の整数)。
    static func sine(count: Int) -> [Int16] {
        (0..<count).map { index in
            let value = Double(Self.amplitude) * sin(2 * .pi * Double(Self.tone) * Double(index) / Double(Self.sampleRate))
            return Int16((value * 32768).rounded())
        }
    }

    /// 16 bit・モノラルの LPCM の標本を、`start` 番目の標本の時刻から始まる 1 つの音声の器へ入れる。
    static func sampleBuffer(_ samples: [Int16], at start: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try #require(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        let length = samples.count * 2
        var block: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: length,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
        try samples.withUnsafeBytes { bytes in
            try #require(
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: try #require(block), offsetIntoDestination: 0,
                    dataLength: length) == noErr)
        }
        var made: CMSampleBuffer?
        try #require(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: try #require(format),
                sampleCount: samples.count,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Self.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &made) == noErr)
        return try #require(made)
    }

    /// 走っているスケッチの `setup()` の中で `loadSound` を呼び、読めた `SoundFile` を返す。
    private func load(_ url: URL) throws -> SoundFile {
        var loaded: SoundFile?
        SoundSketch.onSetup = { sketch in loaded = try sketch.loadSound(url.path) }
        SoundSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: nil)
        try runtime.advance()
        runtime.closePlugins()
        return try #require(loaded)
    }

    /// 標本列の零交差の数から、周波数を割り出す。
    private func frequency(_ samples: [Float], sampleRate: Float) -> Float {
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        return Float(crossings) / 2 / (Float(samples.count) / sampleRate)
    }

    // MARK: - 条件 1: loadSound が動画の容器の音を読む

    @Test("映像と音声を持つ .mov (LPCM) を loadSound で読むと、長さ・標本化率・標本が書いたものと一致する")
    func readsLinearPCMInAMov() async throws {
        let url = try await Self.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: url) }
        let sound = try load(url)
        #expect(sound.sampleRate == 48_000)
        #expect(sound.samples.count == Self.sampleRate, "\(sound.samples.count) 標本")
        #expect(abs(sound.duration - 1) < 1e-6)
        let written = Self.sine(count: Self.sampleRate).map { Float($0) / 32768 }
        let worst = zip(sound.samples, written).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1.0 / 32768, "最大 \(worst) ずれた")
    }

    @Test(
        "映像と音声を持つ .mov・.mp4 (AAC) を loadSound で読むと、長さが音声トラックと符号化の 1 単位 (1024 標本) の中で一致し、周波数が書いたものと同じ",
        arguments: [AVFileType.mov, AVFileType.mp4])
    func readsAACInAContainer(fileType: AVFileType) async throws {
        let url = try await Self.writeMovie(fileType: fileType, track: .aac)
        defer { try? FileManager.default.removeItem(at: url) }
        let sound = try load(url)
        #expect(sound.sampleRate == 48_000)
        // 音声トラックの長さ (秒) と読んだ標本の長さの食い違いは、AAC の 1 パケット (1024 標本) の中
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let trackSeconds = try await track.load(.timeRange).duration.seconds
        #expect(
            abs(Double(sound.duration) - trackSeconds) < 1024.0 / 48_000,
            "読んだ \(sound.duration) 秒・音声トラック \(trackSeconds) 秒")
        #expect(abs(frequency(sound.samples, sampleRate: sound.sampleRate) - Self.tone) < 10)
    }

    @Test("音声トラックの無い動画は、読めない音声として断る (落ちない)")
    func aMovieWithoutAudioIsRefused() async throws {
        let url = try await Self.writeMovieWithoutAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        var failure: AudioFailure?
        SoundSketch.onSetup = { sketch in
            do throws(AudioFailure) { _ = try sketch.loadSound(url.path) } catch { failure = error }
        }
        SoundSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: nil)
        try runtime.advance()
        runtime.closePlugins()
        #expect(failure != nil)
    }

    // MARK: - 条件 3: 書き出しでの映像と音の頭のずれ

    /// 書き出した `.mov` の、映像の先頭の `count` 枚の中央の画素の明るさ (緑) と、音声の標本 (左)。
    private func watch(_ url: URL, frames count: Int) async throws -> (levels: [Int], audio: [Float]) {
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try #require(reader.startReading())
        var levels: [Int] = []
        while levels.count < count, let buffer = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let rowBytes = CVPixelBufferGetBytesPerRow(image)
            let middle = CVPixelBufferGetBaseAddress(image)!
                .advanced(by: CVPixelBufferGetHeight(image) / 2 * rowBytes + CVPixelBufferGetWidth(image) / 2 * 4)
                .assumingMemoryBound(to: UInt8.self)
            levels.append(Int(middle[1]))
        }
        reader.cancelReading()

        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let sound = try AVAssetReader(asset: asset)
        let audioOut = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        sound.add(audioOut)
        try #require(sound.startReading())
        var interleaved: [Float] = []
        while let buffer = audioOut.copyNextSampleBuffer() {
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
        return (levels, (0..<interleaved.count / 2).map { interleaved[2 * $0] })
    }

    /// 書き出しの `fps`・音を鳴らす遅れ (フレーム) ごとの、音の頭と映像の頭の差 (窓の数。負なら音が早い)。
    struct HeadCase: CustomTestStringConvertible, Sendable {
        var fps: Int
        var delay: Int
        var expected: Int
        var testDescription: String { "\(fps) fps・音を \(delay) フレーム遅らせる → 差 \(expected)" }
    }

    @Test(
        "固定の時計で clip.play() を呼んだフレームに song.play() も呼ぶと、書き出しの音の頭は映像の頭より 1 フレーム早い (fps によらない)。song.play() を 1 フレーム遅らせれば揃う",
        arguments: [
            HeadCase(fps: 30, delay: 0, expected: -1), HeadCase(fps: 60, delay: 0, expected: -1),
            HeadCase(fps: 30, delay: 1, expected: 0), HeadCase(fps: 60, delay: 1, expected: 0),
        ])
    func headOffsetBetweenVideoAndSoundInARender(_ item: HeadCase) async throws {
        let source = try await Self.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: source) }
        let out = TestScratch.path("mokume-movie-sound-out", pathExtension: "mov")
        defer { try? FileManager.default.removeItem(at: out) }
        var clip: Movie?
        var song: SoundFile?
        SoundSketch.onSetup = { sketch in
            clip = try sketch.createVideo(source.path)
            song = try sketch.loadSound(source.path)
        }
        // 書き出す長さは、元の映像が次の明るさへ変わるまで (1/30 秒) を越えて、6 枚が見える長さ
        let recorded = item.fps / 30 * 8
        SoundSketch.onDraw = { sketch in
            // 映像は、映したコマを窓いっぱいに描いて書き出しへ載せる
            if let clip { sketch.image(clip.image, 0, 0, 8, 8) }
            if sketch.frameCount == 1 {
                sketch.beginRecord(out.path)
                clip?.play()
            }
            if sketch.frameCount == 1 + item.delay { song?.play() }
            if sketch.frameCount == recorded + 1 { sketch.endRecord() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: item.fps))
        for _ in 0..<(recorded + 1) { try runtime.advance() }
        runtime.closePlugins()

        let heard = try await watch(out, frames: recorded)
        try #require(heard.levels.count == recorded, "映像 \(heard.levels.count) 枚")
        // 音の頭: 立ち上がりの標本が入っている窓の番号 (1 窓 = 48000 ÷ fps 標本)
        let onset = try #require(heard.audio.firstIndex { abs($0) > 0.01 })
        let audioHead = onset / (Self.sampleRate / item.fps)
        // 映像の頭: 元の 0 枚目から動き出した枚。元の 1 枚目 (1/30 秒後) の明るさに変わる枚から、
        // その 1/30 秒ぶんのフレーム数を引く。元の 0 枚目は止まって見える
        let change = try #require(heard.levels.indices.first { abs(heard.levels[$0] - heard.levels[0]) > 15 })
        let videoHead = change - item.fps / 30
        #expect(
            audioHead - videoHead == item.expected,
            "音の頭 \(audioHead) 窓・映像の頭 \(videoHead) 枚 (明るさ \(heard.levels)・立ち上がり \(onset) 標本)")
    }

    /// 映像だけの .mov。
    static func writeMovieWithoutAudio() async throws -> URL {
        let url = TestScratch.path("mokume-movie-silent", pathExtension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
            ])
        writer.add(video)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            #expect(adaptor.append(try #require(made), withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 30))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }
}
