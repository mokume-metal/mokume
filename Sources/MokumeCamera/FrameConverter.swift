// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import CoreGraphics
import CoreVideo
import MokumeCore

/// 外から来た 1 枚 (カメラ・動画ファイルの `CVPixelBuffer`) を、本体が絵にできる形
/// (``DisplayImage``) にする。
///
/// ## 色を作業空間の原色へ移す
///
/// ``DisplayImage`` の値は、**Display P3 の原色**に sRGB の曲線を掛けたものとして読まれる
/// (``Image/write(_:)`` は曲線を外すだけで、原色は変えない)。カメラの絵は Rec.709 / sRGB の
/// 原色で届くので、そのまま渡すと彩度が上がって見える。ここで、バッファが名乗る色空間から
/// Display P3 へ移す ([ADR-0011] の入口の表 — 絵が宣言した原色から作業空間へ移す)。
/// 名乗りが無いバッファは sRGB とみなす。
///
/// ## 変換は vImage の 1 回
///
/// 行の詰め物・並び (BGRA → RGBA)・色空間を、vImage の変換器 1 本でまとめて扱う。
/// 変換器は作るのが重いので、色空間が同じ間は持ち回す。
///
/// **受けるのは 32BGRA だけである。** 420v を vImage で直に変換すると、色差が中立の
/// 灰色が緑になった (#1977 の実機の確認で踏んだ)。YpCbCr から RGB へはカメラ側
/// (AVFoundation) に変換させ (``CameraSource/videoSettings(width:height:)``)、ここに来た
/// 別の形式は黙って違う色にせず、変換できないとして断る。
///
/// 大きさが頼んだものと違って届いたときは、真ん中を頼んだ縦横比で切り取ってから縮める
/// (ゆがめない)。
///
/// **スレッドを持たない。** 1 つの変換器を呼ぶのは 1 本の流れだけで (カメラは受け取りの
/// 待ち行列 — ``CameraSource``、動画は main actor — ``MovieReader``)、この型はその上に閉じている。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
nonisolated final class FrameConverter {
    /// 変換できなかった理由。
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(OSType)
        case conversion(vImage_Error)

        var description: String {
            switch self {
            case .unsupportedFormat(let format): "the pixel format \(format) cannot be converted"
            case .conversion(let error): "vImage failed with \(error)"
            }
        }
    }

    let width: Int
    let height: Int

    /// 持ち回している変換器と、それを作ったときの元の形式。
    private var cached: (key: Key, converter: vImageConverter, sourceCount: Int)?

    private struct Key: Equatable {
        let pixelFormat: OSType
        let colorSpace: String?
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// 1 枚を変換する。
    func convert(_ buffer: CVPixelBuffer) throws(Failure) -> DisplayImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let (converter, sourceCount) = try converter(for: buffer)
        var sources = [vImage_Buffer](repeating: vImage_Buffer(), count: sourceCount)
        let initialized = vImageBuffer_InitForCopyFromCVPixelBuffer(
            &sources, converter, buffer, vImage_Flags(kvImageNoAllocate))
        guard initialized == kvImageNoError else { throw .conversion(initialized) }

        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        if sourceWidth == width, sourceHeight == height {
            return try Self.picture(width: width, height: height) { destination in
                vImageConvert_AnyToAny(converter, &sources, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        // 大きさが違えば、元の大きさで変換してから切り取って縮める
        var full = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        let converted = full.withUnsafeMutableBytes { raw in
            var destination = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(sourceHeight),
                width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * 4)
            return vImageConvert_AnyToAny(converter, &sources, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
        guard converted == kvImageNoError else { throw .conversion(converted) }
        return try Self.picture(width: width, height: height) { destination in
            full.withUnsafeMutableBytes { raw in
                var crop = Self.centreCrop(
                    of: raw.baseAddress!, width: sourceWidth, height: sourceHeight,
                    toAspectOf: width, height)
                return vImageScale_ARGB8888(&crop, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    // MARK: - 変換器

    private func converter(for buffer: CVPixelBuffer) throws(Failure) -> (vImageConverter, Int) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else { throw .unsupportedFormat(pixelFormat) }
        guard let format = vImageCVImageFormat_CreateWithCVPixelBuffer(buffer)?.takeRetainedValue()
        else { throw .unsupportedFormat(pixelFormat) }
        // 色空間を名乗らないバッファは sRGB とみなす。YpCbCr で色差の位置を名乗らない
        // ものは真ん中とみなす (どちらも決めないと変換器が作れない)
        // 読み取りの口は const の型を取る (同じものを指す CF の型で、名前だけが違う)
        let reading = unsafeBitCast(format, to: vImageConstCVImageFormat.self)
        if vImageCVImageFormat_GetColorSpace(reading) == nil {
            vImageCVImageFormat_SetColorSpace(format, CGColorSpace(name: CGColorSpace.sRGB))
        }
        if vImageCVImageFormat_GetChromaSiting(reading) == nil {
            vImageCVImageFormat_SetChromaSiting(format, kCVImageBufferChromaLocation_Center)
        }
        let colorSpace = vImageCVImageFormat_GetColorSpace(reading)?.takeUnretainedValue()
        let key = Key(pixelFormat: pixelFormat, colorSpace: colorSpace?.name as String?)
        if let cached, cached.key == key { return (cached.converter, cached.sourceCount) }

        var destination = Self.destinationFormat
        var error = kvImageNoError
        guard
            let made = vImageConverter_CreateForCVToCGImageFormat(
                format, &destination, nil, vImage_Flags(kvImageNoFlags), &error)?
                .takeRetainedValue(),
            error == kvImageNoError
        else { throw .unsupportedFormat(pixelFormat) }
        let count = Int(vImageConverter_GetNumberOfSourceBuffers(made))
        cached = (key, made, count)
        return (made, count)
    }

    /// 行き先の形式: Display P3・1 画素 4 バイトを赤・緑・青・(飛ばす) の順で。
    ///
    /// 不透明度は飛ばして受け、変換の後で 255 に埋める (カメラの絵は不透明)。
    private static var destinationFormat: vImage_CGImageFormat {
        vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.displayP3)!),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
    }

    /// 詰め物の無い `width * height * 4` の器を作り、`fill` に書かせ、不透明度を 255 に埋めて返す。
    ///
    /// - Parameter fill: 器へ書き、vImage の結果を返す。
    private static func picture(
        width: Int, height: Int, fill: (inout vImage_Buffer) -> vImage_Error
    ) throws(Failure) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let status = bytes.withUnsafeMutableBytes { raw in
            var destination = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 4)
            let filled = fill(&destination)
            guard filled == kvImageNoError else { return filled }
            // 1 画素 4 バイトのうち最後 (不透明度) だけを埋める。vImage の印は先頭の
            // バイトが 0x8、最後のバイトが 0x1
            return vImageOverwriteChannelsWithScalar_ARGB8888(
                255, &destination, &destination, 0x1, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { throw .conversion(status) }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    /// 真ん中を、頼んだ縦横比で切り取った範囲。
    static func centreCrop(
        of base: UnsafeMutableRawPointer, width: Int, height: Int,
        toAspectOf targetWidth: Int, _ targetHeight: Int
    ) -> vImage_Buffer {
        var cropWidth = width
        var cropHeight = height
        // 幅 / 高さ を比べる。掛け算で比べて割り算の丸めを避ける
        if width * targetHeight > height * targetWidth {
            cropWidth = max(1, height * targetWidth / targetHeight)
        } else {
            cropHeight = max(1, width * targetHeight / targetWidth)
        }
        let x = (width - cropWidth) / 2
        let y = (height - cropHeight) / 2
        return vImage_Buffer(
            data: base + y * width * 4 + x * 4, height: vImagePixelCount(cropHeight),
            width: vImagePixelCount(cropWidth), rowBytes: width * 4)
    }
}
