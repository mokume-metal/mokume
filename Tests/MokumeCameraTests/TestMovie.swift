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

    /// 一時ディレクトリの中の、重ならない名前。
    static func temporaryURL(_ suffix: String = "mov") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-movie-\(UUID().uuidString).\(suffix)")
    }

    /// `frames` 枚の動画を `fps` で書く。`index` 枚目の画素 (x, y) の BGR は `pixel(index, x, y)`。
    static func write(
        frames: Int, fps: Int32 = 30, width: Int = 32, height: Int = 16,
        pixel: (Int, Int, Int) -> (blue: UInt8, green: UInt8, red: UInt8) = TestMovie.grey
    ) async throws -> URL {
        let url = temporaryURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
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
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
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
    static func reference(_ url: URL) async throws -> [(time: Double, picture: DisplayImage)] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
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
