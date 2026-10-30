// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import MokumeTestSupport
import Testing
import VideoToolbox

@testable import MokumeAudio
@testable import MokumeCamera
@testable import MokumeCore

/// 動画ファイルの音を `loadSound` で鳴らす道 (#3452) のための、検査の中で書く動画。**動画はリポジトリに置けない**
/// (`scripts/check-no-binaries.sh`) ので、毎回 `AVAssetWriter` で一時ディレクトリへ書く。
nonisolated enum MovieSoundFixture {
    /// 音声トラックの作り方。
    enum Track {
        /// 16 bit の整数の LPCM。標本が量子化の幅 (1/32768) の中で元と一致する。
        case lpcm
        /// AAC。不可逆なので、長さ (符号化の最小の単位 1024 標本の中) と周波数で突き合わせる。
        case aac
    }

    static let sampleRate = 48_000
    static let amplitude: Float = 0.5

    /// この機械に H.264 の符号化器があるか。無ければ動画を書く検査は飛ぶ (hosted の機械に無い場合に赤にしない)。
    static let canWrite: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 64, height: 48, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// 映像 `frames` 枚 (`fps`) と、`seconds` 秒の正弦波 (モノラル・48 kHz) を持つ動画を書く。音声トラックは `tones`
    /// (Hz) の数だけ、この順に付ける。音声の標本は、映像の頭から `audioOffset` 標本遅れて始める。
    /// `index` 枚目の映像は灰色で、明るさは `(index % 6) * 40 + 20` (枚ごとに見分けがつく)。
    static func writeMovie(
        fileType: AVFileType, track: Track, tones: [Float] = [1000], audioOffset: Int = 0, frames: Int = 30,
        fps: Int32 = 30, seconds: Double = 1
    ) async throws -> URL {
        let url = TestScratch.path("mokume-movie-sound", pathExtension: fileType == .mp4 ? "mp4" : "mov")
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
        let audioSettings: [String: Any] =
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
        let audios = tones.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) }
        writer.add(video)
        for audio in audios {
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
        }
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(Self.sampleRate))
        let sources = tones.map { Self.sine(count: total, tone: $0) }
        let chunk = Self.sampleRate / Int(fps)
        var audioAt = 0
        var audioFinished = false
        func appendAudio(upTo limit: Int) async throws {
            let end = min(total, limit)
            if audioAt < end {
                for (audio, source) in zip(audios, sources) {
                    try await Self.waitReady(audio)
                    let sample = try Self.sampleBuffer(Array(source[audioAt..<end]), at: audioAt + audioOffset)
                    #expect(audio.append(sample))
                }
                audioAt = end
            }
            // 音を渡し終えたら、すぐ閉じる。閉じないと書き手は「まだ音が来るかもしれない」と、時刻が先の映像を待たせる
            if audioAt >= total, !audioFinished {
                audioFinished = true
                for audio in audios { audio.markAsFinished() }
            }
        }
        for index in 0..<frames {
            try await Self.waitReady(video)
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
            // 音を映像より 2 枚ぶん先行させて渡す。書き手は映像と音を時刻の順に交互に書くので、音が遅れると
            // 映像の入力が待たされ、長い動画では詰まる
            try await appendAudio(upTo: (index + 3) * chunk)
        }
        try await appendAudio(upTo: total)
        video.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(seconds: seconds + Double(audioOffset) / Double(Self.sampleRate), preferredTimescale: 48_000))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// 書き手が次の入力を受けるまで待つ。**待つ側が期限を持つ** — 書き手は映像と音を時刻の順に交互に書くので、
    /// 片方の渡し方が遅れると、もう片方が待ち続けて検査全体が止まる。
    static func waitReady(_ input: AVAssetWriterInput) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !input.isReadyForMoreMediaData {
            try #require(ContinuousClock.now < deadline, "書き手が 20 秒たっても次の入力を受けない")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// 書く標本 (16 bit の整数)。
    static func sine(count: Int, tone: Float) -> [Int16] {
        (0..<count).map { index in
            let value = Double(Self.amplitude) * sin(2 * .pi * Double(tone) * Double(index) / Double(Self.sampleRate))
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
            try await Self.waitReady(video)
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

    /// 標本列の零交差の数から、周波数を割り出す。
    static func frequency(_ samples: [Float], sampleRate: Float) -> Float {
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        return Float(crossings) / 2 / (Float(samples.count) / sampleRate)
    }
}

/// `loadSound` が動画の容器の音声トラックを読むこと (#3452)。`loadSound` の読み込みは `AudioFile.load` で、ここは
/// それを直に呼ぶので、スケッチも GPU も要らない (`loadSound` を通す検査は ``MovieSoundRenderTests``)。
@Suite("動画の容器の音声トラックを読む", .serialized, .enabled(if: MovieSoundFixture.canWrite, "この機械には H.264 の符号化器が無い"))
struct MovieSoundFileTests {
    private typealias Fixture = MovieSoundFixture

    @Test("映像と音声を持つ .mov (LPCM) の標本が、長さ・標本化率とも書いたものと一致する")
    func readsLinearPCMInAMov() async throws {
        let url = try await Fixture.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try AudioFile.read(url, path: "talk.mov")
        #expect(read.sampleRate == 48_000)
        #expect(read.samples.count == Fixture.sampleRate, "\(read.samples.count) 標本")
        let written = Fixture.sine(count: Fixture.sampleRate, tone: 1000).map { Float($0) / 32768 }
        let worst = zip(read.samples, written).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1.0 / 32768, "最大 \(worst) ずれた")
    }

    @Test(
        "映像と音声を持つ .mov・.mp4 (AAC) の長さが音声トラックと符号化の 1 単位 (1024 標本) の中で一致し、周波数が書いたものと同じ",
        arguments: [AVFileType.mov, AVFileType.mp4])
    func readsAACInAContainer(fileType: AVFileType) async throws {
        let url = try await Fixture.writeMovie(fileType: fileType, track: .aac)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try AudioFile.read(url, path: "talk")
        #expect(read.sampleRate == 48_000)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let trackSeconds = try await track.load(.timeRange).duration.seconds
        let seconds = Double(read.samples.count) / Double(read.sampleRate)
        #expect(abs(seconds - trackSeconds) < 1024.0 / 48_000, "読んだ \(seconds) 秒・音声トラック \(trackSeconds) 秒")
        #expect(abs(Fixture.frequency(read.samples, sampleRate: read.sampleRate) - 1000) < 10)
    }

    @Test("音声トラックの無い動画は、読めない音声 (unreadable) として断り、落ちない")
    func aMovieWithoutAudioIsRefused() async throws {
        let url = try await Fixture.writeMovieWithoutAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        var failure: AudioFailure?
        do throws(AudioFailure) { _ = try AudioFile.load(url, path: "silent.mov") } catch { failure = error }
        #expect(failure == .unreadable(path: "silent.mov"))
    }

    @Test("音声トラックが 2 本あれば、1 本目だけを読む (2 本目の音は混ざらない)")
    func readsOnlyTheFirstOfSeveralAudioTracks() async throws {
        let url = try await Fixture.writeMovie(fileType: .mov, track: .lpcm, tones: [1000, 2500])
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try AudioFile.read(url, path: "two.mov")
        #expect(read.samples.count == Fixture.sampleRate, "\(read.samples.count) 標本")
        let tone = Fixture.frequency(read.samples, sampleRate: read.sampleRate)
        #expect(abs(tone - 1000) < 10, "周波数 \(tone) Hz")
    }

    @Test("音声が映像より遅れて始まる (頭に空の編集区間のある) 動画は、音声トラックの頭から読む (遅れた分の無音は足されない)")
    func theAudioTrackIsReadFromItsOwnHead() async throws {
        // 音声の標本が映像の頭から 0.5 秒遅れて始まる (編集リストや開始時刻のずれのある動画の形)
        let url = try await Fixture.writeMovie(fileType: .mov, track: .lpcm, audioOffset: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // 書いた動画の音声トラックが、本当に 0.5 秒遅れて始まっている
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        // 動画の容器の側では、音声トラックの頭に 0.5 秒の空の区間 (編集リスト) がある
        let segments = try await track.load(.segments)
        let head = try #require(segments.first)
        try #require(
            head.isEmpty && abs(head.timeMapping.target.duration.seconds - 0.5) < 0.01,
            "音声トラックの頭の区間 \(segments.map { "\($0.timeMapping.target.start.seconds)+\($0.timeMapping.target.duration.seconds) empty=\($0.isEmpty)" })")
        let read = try AudioFile.read(url, path: "late.mov")
        #expect(read.samples.count == Fixture.sampleRate, "\(read.samples.count) 標本")
        // 頭の標本から音が立ち上がっている (0.5 秒の無音は付かない)
        #expect(read.samples[0..<2000].contains { abs($0) > 0.1 })
    }
}

/// 動画の音を `loadSound` で鳴らす道 (#3452)。`Movie` は音を鳴らさず、同じファイルを `loadSound` で開いて
/// `jump(_:)` で合わせる。ここは、`loadSound` を通して読めることと、固定の時計で映像と音がどう揃うかを確かめる。
///
/// 走っているスケッチの中で回すので GPU を要する。
@Suite(
    "動画の音を loadSound で鳴らす",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(if: MovieSoundFixture.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MovieSoundRenderTests {
    private typealias Fixture = MovieSoundFixture

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

    @Test("loadSound を通すと、.mov の音の長さ・標本化率・標本が書いたものと一致する。音声トラックの無い動画は断る")
    func loadSoundReadsTheAudioTrack() async throws {
        let url = try await Fixture.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: url) }
        let sound = try load(url)
        #expect(sound.sampleRate == 48_000)
        #expect(abs(sound.duration - 1) < 1e-6)
        let written = Fixture.sine(count: Fixture.sampleRate, tone: 1000).map { Float($0) / 32768 }
        let worst = zip(sound.samples, written).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1.0 / 32768, "最大 \(worst) ずれた")

        let silent = try await Fixture.writeMovieWithoutAudio()
        defer { try? FileManager.default.removeItem(at: silent) }
        var failure: AudioFailure?
        SoundSketch.onSetup = { sketch in
            do throws(AudioFailure) { _ = try sketch.loadSound(silent.path) } catch { failure = error }
        }
        SoundSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: nil)
        try runtime.advance()
        runtime.closePlugins()
        #expect(failure == .unreadable(path: silent.path))
    }

    // MARK: - 書き出しでの映像と音の頭のずれ

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
        // 書き出しの音声は 2 チャンネル (左右) で載る。読み出しもそれを指定して、左を取り出す
        let audioOut = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2,
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

    /// `play()` を呼ぶ場面。
    enum Where: Sendable, CustomTestStringConvertible {
        /// `setup()` の中。
        case setup
        /// 最初の `draw()` の中 (録りを頼むのと同じフレーム)。
        case draw
        var testDescription: String { self == .setup ? "setup()" : "draw()" }
    }

    /// 書き出しの `fps`・`play()` を呼ぶ場面・音を鳴らす遅れ (フレーム) ごとの、音の頭と映像の頭の差 (窓の数。負なら音が早い)。
    struct HeadCase: CustomTestStringConvertible, Sendable {
        var fps: Int
        var at: Where
        var delay: Int
        var expected: Int
        var testDescription: String { "\(fps) fps・\(at)・音を \(delay) フレーム遅らせる → 差 \(expected)" }
    }

    @Test(
        "書き出しの音の頭は、clip.play() と song.play() を draw() で呼ぶと映像の頭より 1 フレーム早く、setup() で呼ぶと揃う。draw() では song.play() を 1 フレーム遅らせれば揃う",
        arguments: [
            HeadCase(fps: 30, at: .draw, delay: 0, expected: -1), HeadCase(fps: 60, at: .draw, delay: 0, expected: -1),
            HeadCase(fps: 30, at: .draw, delay: 1, expected: 0), HeadCase(fps: 60, at: .draw, delay: 1, expected: 0),
            HeadCase(fps: 30, at: .setup, delay: 0, expected: 0), HeadCase(fps: 60, at: .setup, delay: 0, expected: 0),
        ])
    func headOffsetBetweenVideoAndSoundInARender(_ item: HeadCase) async throws {
        let source = try await Fixture.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: source) }
        let out = TestScratch.path("mokume-movie-sound-out", pathExtension: "mov")
        defer { try? FileManager.default.removeItem(at: out) }
        var clip: Movie?
        var song: SoundFile?
        SoundSketch.onSetup = { sketch in
            clip = try sketch.createVideo(source.path)
            song = try sketch.loadSound(source.path)
            if item.at == .setup {
                clip?.play()
                song?.play()
            }
        }
        // 書き出す長さは、元の映像が次の明るさへ変わるまで (1/30 秒) を越えて、6 枚が見える長さ
        let recorded = item.fps / 30 * 8
        SoundSketch.onDraw = { sketch in
            // 映像は、映したコマを窓いっぱいに描いて書き出しへ載せる
            if let clip { sketch.image(clip.image, 0, 0, 8, 8) }
            if sketch.frameCount == 1 {
                sketch.beginRecord(out.path)
                if item.at == .draw { clip?.play() }
            }
            if item.at == .draw, sketch.frameCount == 1 + item.delay { song?.play() }
            if sketch.frameCount == recorded + 1 { sketch.endRecord() }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: item.fps))
        for _ in 0..<(recorded + 1) { try runtime.advance() }
        runtime.closePlugins()

        let heard = try await watch(out, frames: recorded)
        try #require(heard.levels.count == recorded, "映像 \(heard.levels.count) 枚")
        // 音の頭: 立ち上がりの標本がいちばん近い窓の番号 (1 窓 = 48000 ÷ fps 標本)。窓の境界から離れた
        // 窓の中ほどで判定するため、四捨五入する
        let window = Fixture.sampleRate / item.fps
        let onset = try #require(heard.audio.firstIndex { abs($0) > 0.01 })
        let audioHead = (onset + window / 2) / window
        // 映像の頭: 元の 0 枚目から動き出した枚。元の 1 枚目 (1/30 秒後) の明るさに変わる枚から、
        // その 1/30 秒ぶんのフレーム数を引く。元の 0 枚目は止まって見える
        let change = try #require(heard.levels.indices.first { abs(heard.levels[$0] - heard.levels[0]) > 15 })
        let videoHead = change - item.fps / 30
        #expect(
            audioHead - videoHead == item.expected,
            "音の頭 \(audioHead) 窓・映像の頭 \(videoHead) 枚 (明るさ \(heard.levels)・立ち上がり \(onset) 標本)")
    }

    // MARK: - jump で合わせた後のずれ

    /// 合わせ直しの書き方。
    enum Recipe: Sendable, CustomTestStringConvertible {
        /// `song.jump(clip.time)`
        case plain
        /// `song.jump(clip.time + deltaTime)` (`jump` は次のフレームの頭で効くので、そのぶんを先取りする)
        case ahead
        var testDescription: String { self == .plain ? "jump(clip.time)" : "jump(clip.time + deltaTime)" }
    }

    @Test(
        "音を映像の位置へ jump で合わせ直した後、音と映像のずれは jump(clip.time) で 1 フレーム (遅れ)、jump(clip.time + deltaTime) で 0",
        arguments: [(30, Recipe.plain), (30, Recipe.ahead), (60, Recipe.plain), (60, Recipe.ahead)])
    func jumpingBackLeavesAtMostOneFrame(fps: Int, recipe: Recipe) async throws {
        let source = try await Fixture.writeMovie(fileType: .mov, track: .lpcm)
        defer { try? FileManager.default.removeItem(at: source) }
        var clip: Movie?
        var song: SoundFile?
        SoundSketch.onSetup = { sketch in
            clip = try sketch.createVideo(source.path)
            song = try sketch.loadSound(source.path)
            clip?.play()
            song?.play()
        }
        var gaps: [Float] = []
        var jumps = 0
        SoundSketch.onDraw = { sketch in
            guard let clip, let song else { return }
            gaps.append(song.position - clip.time)
            if sketch.frameCount == 10 {
                // 音を 0.3 秒先へずらして、ずれを作る
                song.jump(clip.time + 0.3)
            } else if abs(song.position - clip.time) > 0.1 {
                jumps += 1
                song.jump(recipe == .plain ? clip.time : clip.time + sketch.deltaTime)
            }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: fps))
        for _ in 0..<20 { try runtime.advance() }
        runtime.closePlugins()

        let frame = 1 / Float(fps)
        #expect(jumps >= 1, "ずれを作った後、合わせ直しが 1 回も起きていない: \(gaps)")
        // 10 フレーム目のずれを直し切った後 (15 フレーム目以降) のずれ
        let settled = Array(gaps[14...])
        let expected: Float = recipe == .plain ? -frame : 0
        #expect(settled.allSatisfy { abs($0 - expected) < 1e-3 }, "期待 \(expected) 秒・実際 \(settled)")
    }
}
