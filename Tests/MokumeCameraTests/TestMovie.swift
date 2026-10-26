// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import AVFoundation
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import MokumeCamera
import MokumeCore

/// 検査のための動画を、検査の中で作る。**動画はリポジトリに置けない** (`scripts/check-no-binaries.sh`)
/// ので、毎回 `AVAssetWriter` で一時ディレクトリへ書く。
///
/// 書くのは H.264 (いちばんよく出会う形)。色は Rec.709 と名乗らせる — 名乗らない動画は
/// AVFoundation が色空間を推し量るので、検査の結果がその推し量りに依る。
nonisolated enum TestMovie {
    /// この機械に H.264 の符号化器があるか。無ければ動画を作る検査は飛ぶ。
    static let canWrite: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 64, height: 48, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// この機械に HEVC の符号化器があるか。
    static let canWriteHEVC: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 64, height: 48, codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// 一時ディレクトリの中の、重ならない名前。
    static func temporaryURL(_ suffix: String = "mov") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-movie-\(UUID().uuidString).\(suffix)")
    }

    /// `frames` 枚の動画を `fps` で書く。`index` 枚目の画素 (x, y) の BGR は `pixel(index, x, y)`。
    ///
    /// `keyFrameInterval` を渡すと、鍵のコマ (それだけで復号できるコマ) をその枚数ごとに置く。そのときは
    /// 次の 2 つで、置く位置を揺らさない (どれも実測):
    ///
    /// - **ソフトの符号化器で書く。** ハードの符号化器は、検査が並んで枠が埋まると余計な鍵のコマを置く
    ///   (24 本を同時に書くと `[0, 1, 31, 61]` が混ざる)。枠が無ければ黙ってソフトへ落ちもする
    /// - **並べ替え (B フレーム) を止める。** ハードで並べ替えを許すと、30 を頼んでも H.264 で 29 枚・
    ///   HEVC で 28 枚ごとに置く。`reordersFrames` で許せる
    ///
    /// 絵は穏やかに動くもの (``stripe``・128×96 以上) にする。小さな絵で大きく変わる柄は、ソフトの
    /// 符号化器が場面の変わり目と見て鍵のコマを足す。
    static func write(
        frames: Int, fps: Int32 = 30, width: Int = 32, height: Int = 16, codec: AVVideoCodecType = .h264,
        keyFrameInterval: Int? = nil, reordersFrames: Bool = false,
        pixel: (Int, Int, Int) -> (blue: UInt8, green: UInt8, red: UInt8) = TestMovie.grey
    ) async throws -> URL {
        try await write(
            frames: frames, fps: fps, width: width, height: height, codec: codec,
            keyFrameInterval: keyFrameInterval, reordersFrames: reordersFrames
        ) { buffer, index in
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let (blue, green, red) = pixel(index, x, y)
                    let at = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                    at[0] = blue
                    at[1] = green
                    at[2] = red
                    at[3] = 255
                }
            }
        }
    }

    /// `frames` 枚の動画を書く。`index` 枚目の 32BGRA の器を `paint(buffer, index)` が塗る (器は
    /// 錠を掛けて渡す)。大きな動画を画素ごとの呼び出しなしに書くための口。`keyFrameInterval` の扱いは
    /// 上の `write(…pixel:)` と同じで、`hardware` なら位置を揺らさない 2 つを外し、ハードの符号化器に
    /// 並べ替えも任せる (普通の動画に近い。性能を測る動画)。`bitRate` (bit/s) を渡さなければ符号化器の既定。
    static func write(
        frames: Int, fps: Int32 = 30, width: Int, height: Int, codec: AVVideoCodecType = .h264,
        keyFrameInterval: Int? = nil, reordersFrames: Bool = false, hardware: Bool = false, bitRate: Int? = nil,
        paint: (CVPixelBuffer, Int) -> Void
    ) async throws -> URL {
        let url = temporaryURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression: [String: Any] = [:]
        if let keyFrameInterval {
            compression[AVVideoMaxKeyFrameIntervalKey] = keyFrameInterval
            if !hardware { compression[AVVideoAllowFrameReorderingKey] = reordersFrames }
        }
        if let bitRate { compression[AVVideoAverageBitRateKey] = bitRate }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
        if keyFrameInterval != nil, !hardware {
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // **刻みを書き手へ渡す** (#2307)。`CMTime` を fps の刻みで作るだけでは、トラックも容れ物も
        // 既定の 600 で書かれ、600 を割り切らない fps (48 など) の時刻が丸まる
        input.mediaTimeScale = fps
        writer.movieTimeScale = fps
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            try #require(CVPixelBufferGetBaseAddress(buffer) != nil)
            paint(buffer, index)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// この機械に ProRes 4444 の符号化器が (専用回路を使わない側で) あるか。無ければ透過の動画を作る検査は飛ぶ。
    static let canWriteTransparent: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 64, height: 48, codecType: kCMVideoCodecType_AppleProRes4444,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]
                as CFDictionary,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// この機械に、アルファ付きの HEVC の符号化器があるか。
    static let canWriteHEVCWithAlpha: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 64, height: 64, codecType: kCMVideoCodecType_HEVCWithAlpha, encoderSpecification: nil,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// 乗算していない RGBA の 1 画素 (`alpha` を含む)。
    typealias Straight = (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)

    /// 透過の動画を書く。`pixel(index, x, y)` は **乗算していない** RGBA。
    ///
    /// 既定の ProRes 4444 は、mokume 自身が書き出す動画と同じく、乗算していないアルファのまま
    /// 符号化器へ渡す (`StraightAlpha`)。`hevcWithAlpha` は乗算済みを受けるので、乗算して渡す
    /// (読むと `PremultipliedAlpha` を名乗って届く)。
    static func writeTransparent(
        codec: AVVideoCodecType = .proRes4444, frames: Int, fps: Int32 = 30, width: Int = 8,
        height: Int = 4, pixel: @Sendable (Int, Int, Int) -> Straight
    ) async throws -> URL {
        let url = temporaryURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let straight = codec == .proRes4444
        var settings: [String: Any] = [:]
        if straight {
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false
            ]
            settings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_StraightAlpha as String
            ]
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings.merging([
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                // 作業空間と同じ Display P3 を名乗らせる (mokume の書き出しと同じ)。
                // 名乗りが同じなら、色空間の変換は動かさない
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]) { current, _ in current })
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = fps
        writer.movieTimeScale = fps
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    var value = pixel(index, x, y)
                    if !straight {
                        func multiplied(_ channel: UInt8) -> UInt8 {
                            UInt8((Double(channel) * Double(value.alpha) / 255).rounded())
                        }
                        value = (multiplied(value.red), multiplied(value.green), multiplied(value.blue), value.alpha)
                    }
                    let at = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                    at[0] = value.blue
                    at[1] = value.green
                    at[2] = value.red
                    at[3] = value.alpha
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// 行ごとの縞の上に、枚ごとに 1 画素ずつ右へ動く白い帯を置く (`write(…paint:)` に渡す)。青の
    /// 階調も枚ごとに変わる。**動きが穏やかなので、符号化器が場面の変わり目と見て鍵のコマを足さない**
    /// — 枚ごとに絵が丸ごと変わる柄 (``noise``) や、小さな絵で大きく跳ぶ帯では、ソフトの符号化器
    /// (検査が並ぶとハードの枠が埋まって落ちてくる) が鍵のコマを足す (実測)。128×96 以上で使う。
    static func stripe(_ buffer: CVPixelBuffer, _ index: Int) {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bar = max(1, min(64, width / 8))
        let barX = index % max(1, width - bar)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            let level = UInt32(truncatingIfNeeded: (y * 2) & 0xff)
            row.update(
                repeating: 0xff00_0000 | level << 16 | UInt32((y >> 2) & 0xff) << 8 | UInt32((index * 2) & 0xff),
                count: width)
            (row + barX).update(repeating: 0xffff_ffff, count: bar)
        }
    }

    /// 動画の鍵のコマ (完全なもの) の表示時刻を、目録から順に全部引く。**検査の前提を確かめる。**
    static func keyFrameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let cursor = try #require(track.makeSampleCursor(presentationTimeStamp: .zero))
        var times: [Double] = []
        repeat {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                times.append(cursor.presentationTimeStamp.seconds)
            }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return times.sorted()
    }

    /// 枚ごとに明るさの違う一色 (8 階調ずつ)。32 枚までは重ならない。
    static func grey(_ index: Int, _ x: Int, _ y: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
        let level = UInt8(min(255, index * 8))
        return (level, level, level)
    }

    /// 枚ごと・画素ごとに違う乱れ (同じ引数からはいつも同じ値)。標本が大きくなるので、途中を
    /// 壊しても容れ物の索引 (`moov`) に当たらない。
    static func noise(_ index: Int, _ x: Int, _ y: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
        var state = UInt32(truncatingIfNeeded: index &* 73_856_093 ^ x &* 19_349_663 ^ y &* 83_492_791)
        state = state &* 1_103_515_245 &+ 12345
        let value = UInt8(truncatingIfNeeded: state >> 16)
        return (value, UInt8(truncatingIfNeeded: index * 4), UInt8(truncatingIfNeeded: x * 8))
    }

    /// ファイルの `from`〜`to` (長さに対する割合) を壊したものを、別の名前で書く。
    static func damaged(_ url: URL, from: Double, to: Double) throws -> URL {
        var data = try Data(contentsOf: url)
        let start = Int(Double(data.count) * from)
        let end = Int(Double(data.count) * to)
        for index in start..<end { data[index] = UInt8(truncatingIfNeeded: index &* 31) }
        let broken = temporaryURL()
        try data.write(to: broken)
        return broken
    }

    /// 映像の無い (音声だけの) ファイル。
    static func soundOnly() throws -> URL {
        let url = temporaryURL("wav")
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        try file.write(from: buffer)
        return url
    }

    /// 動画ではない中身のファイル。
    static func garbage() throws -> URL {
        let url = temporaryURL()
        try Data("this is not a movie".utf8).write(to: url)
        return url
    }

    /// 動画を頭から順に全部読み、枚ごとの表示時刻と絵を返す。**比べる相手で、読み手とは別に読む。**
    ///
    /// **読み進める同期の待ち (`copyNextSampleBuffer`) は、Swift の協調プールの外で回す** (#3196)。
    /// 協調プールのスレッドはコア数 (ホストの runner で 3 本) しか無く、並列の幅を広げると、
    /// この待ちが全部を塞ぐ。そのとき main で `MovieReader.inspect` が待つ読み込みの仕事 (`Task.detached`)
    /// が走れず、検査全体が止まった (#3199 の run 40159542555)。GCD のキューは協調プールと別に
    /// スレッドを足せる
    static func reference(_ url: URL) async throws -> [(time: Double, picture: DisplayImage)] {
        let asset = AVURLAsset(url: url)
        // トラックを読み込みの側へ渡す箱。**渡した後は、こちらからは触らない**
        nonisolated final class Handoff: @unchecked Sendable {
            let track: AVAssetTrack
            init(_ track: AVAssetTrack) { self.track = track }
        }
        let handoff = Handoff(try #require(try await asset.loadTracks(withMediaType: .video).first))
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try readAll(asset, handoff.track) })
            }
        }
    }

    private static func readAll(
        _ asset: AVURLAsset, _ track: AVAssetTrack
    ) throws -> [(time: Double, picture: DisplayImage)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try #require(reader.startReading())
        var frames: [(time: Double, picture: DisplayImage)] = []
        var converter: FrameConverter?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let made = converter ?? FrameConverter(
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), alpha: .straight)
            converter = made
            frames.append(
                (CMSampleBufferGetPresentationTimeStamp(sample).seconds, try made.convert(buffer)))
        }
        return frames
    }
}
