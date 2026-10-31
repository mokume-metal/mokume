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
/// ## 不透明度は呼ぶ側が決める (``Alpha``)
///
/// カメラの BGRA に不透明度の意味は無い (絵は不透明) ので、**行き先から不透明度を外し、
/// 255 で埋める** (``Alpha/opaque``)。動画は透過を持ちうる (ProRes 4444 の演出素材) ので、
/// **乗算していない (straight) まま運ぶ** (``Alpha/straight``) — ``DisplayImage`` の
/// 約束がそれである。不透明度を外した行き先へ変換すると、vImage は透けた画素を黒へ平坦化して
/// しまう (半透明の色が暗くなり、透明な所は黒い不透明になる。#2881)。
///
/// **スレッドを持たない。** 1 つの変換器を呼ぶのは 1 本の流れだけで (カメラは受け取りの
/// 待ち行列 — ``CameraSource``、動画は main actor — ``MovieReader`` と、先読みの係 — ``MoviePrefetcher``
/// が、それぞれ自分の 1 つを持つ)、この型はその上に閉じている。
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

    /// 元の絵の不透明度の扱い。
    enum Alpha: Equatable {
        /// 不透明として扱う。元の不透明度は読まず、すべての画素を 255 で埋める (カメラ)。
        case opaque
        /// 元の不透明度を、乗算していないまま運ぶ (動画)。元が乗算済みを名乗れば、乗算を戻してから変換する。
        case straight
    }

    let width: Int
    let height: Int
    let alpha: Alpha

    /// 持ち回している変換器と、それを作ったときの元の形式。
    private var cached: (key: Key, converter: vImageConverter, sourceCount: Int)?

    private struct Key: Equatable {
        let pixelFormat: OSType
        let colorSpace: String?
    }

    /// 毎枚確保しない器。**足りないときだけ取り直す** (4K で 1 枚 33 MB)。
    private struct Reusable {
        private var storage: (pointer: UnsafeMutableRawPointer, capacity: Int)?

        /// 先頭のアドレス (まだ確保していなければ `nil`)。検査が「取り直していない」を見るための口。
        var address: UnsafeRawPointer? { storage.map { UnsafeRawPointer($0.pointer) } }

        /// `byteCount` バイト以上の器。**中身は前の枚のまま**で、0 では埋めない (呼ぶ側が全部書く)。
        mutating func pointer(byteCount: Int) -> UnsafeMutableRawPointer {
            if let storage, storage.capacity >= byteCount { return storage.pointer }
            storage?.pointer.deallocate()
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            storage = (pointer, byteCount)
            return pointer
        }

        func release() { storage?.pointer.deallocate() }
    }

    /// 乗算を戻した元を置く器。
    private var straightened = Reusable()

    /// 大きさが違う元を、元の大きさのまま変換して置く器 (切り取って縮める前)。
    ///
    /// ``straightened`` とは別にする — 乗算を戻した元は、同じ呼び出しの中で変換の入力として
    /// 読まれ続けるので、変換の行き先にはできない。**代償:** 大きさが違う元が一度でも来たら、
    /// このインスタンスが生きている間、元の大きさ 1 枚分 (4K で 33 MB) を持ち続ける。
    private var resized = Reusable()

    /// 検査用: 大きさが違う元の変換に使う器の先頭のアドレス。続けて呼んで変わらなければ、取り直していない。
    var resizedBufferAddress: UnsafeRawPointer? { resized.address }

    deinit {
        straightened.release()
        resized.release()
    }

    init(width: Int, height: Int, alpha: Alpha = .opaque) {
        self.width = width
        self.height = height
        self.alpha = alpha
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

        // **乗算済みを名乗る元 (アルファ付きの HEVC) は、乗算を戻してから変換する。** 色の変換は
        // 曲線を掛けるので、乗算したまま掛けると半透明の色が狂う。vImage は元の乗算の有無を
        // 読まない (名乗りの無い BGRA と同じく、乗算していないものとして扱う)
        if alpha == .straight, sourceCount == 1, Self.declaresPremultipliedAlpha(buffer) {
            let rowBytes = Int(sources[0].width) * 4
            var target = vImage_Buffer(
                data: straightened.pointer(byteCount: rowBytes * Int(sources[0].height)),
                height: sources[0].height, width: sources[0].width, rowBytes: rowBytes)
            let unpremultiplied = vImageUnpremultiplyData_RGBA8888(
                &sources[0], &target, vImage_Flags(kvImageNoFlags))
            guard unpremultiplied == kvImageNoError else { throw .conversion(unpremultiplied) }
            sources[0] = target
        }

        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        if sourceWidth == width, sourceHeight == height {
            return try Self.picture(width: width, height: height, alpha: alpha) { destination in
                vImageConvert_AnyToAny(converter, &sources, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        // 大きさが違えば、元の大きさで変換してから切り取って縮める。**変換の行き先は持ち回しの器**
        // (毎枚 0 埋めで確保しない)。全部を書き直すので、前の枚の中身は誰も読まない
        let full = resized.pointer(byteCount: sourceWidth * sourceHeight * 4)
        var destination = vImage_Buffer(
            data: full, height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * 4)
        let converted = vImageConvert_AnyToAny(
            converter, &sources, &destination, nil, vImage_Flags(kvImageNoFlags))
        guard converted == kvImageNoError else { throw .conversion(converted) }
        return try Self.picture(width: width, height: height, alpha: alpha, scaled: true) { destination in
            var whole = vImage_Buffer(
                data: full, height: vImagePixelCount(sourceHeight),
                width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * 4)
            // **縮めるあいだは乗算する。** 乗算していないまま混ぜると、透明な画素の色が
            // 不透明な画素の縁へにじむ
            if alpha == .straight {
                let premultiplied = vImagePremultiplyData_RGBA8888(
                    &whole, &whole, vImage_Flags(kvImageNoFlags))
                guard premultiplied == kvImageNoError else { return premultiplied }
            }
            var crop = Self.centreCrop(
                of: full, width: sourceWidth, height: sourceHeight, toAspectOf: width, height)
            return vImageScale_ARGB8888(&crop, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
    }

    /// バッファが、不透明度を乗算済みと名乗っているか。
    private static func declaresPremultipliedAlpha(_ buffer: CVPixelBuffer) -> Bool {
        guard let mode = CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil)
        else { return false }
        return CFEqual(mode, kCVImageBufferAlphaChannelMode_PremultipliedAlpha)
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
        // **`.opaque` は元の不透明度を読ませない。** 不透明度を持たない行き先へ変換すると、
        // vImage は透けた画素を黒へ平坦化する (半透明の色が暗くなる)。「不透明」の合図で抑える
        if alpha == .opaque { vImageCVImageFormat_SetAlphaHint(format, 1) }
        let colorSpace = vImageCVImageFormat_GetColorSpace(reading)?.takeUnretainedValue()
        let key = Key(pixelFormat: pixelFormat, colorSpace: colorSpace?.name as String?)
        if let cached, cached.key == key { return (cached.converter, cached.sourceCount) }

        var destination = Self.destinationFormat(alpha)
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

    /// 行き先の形式: Display P3・1 画素 4 バイトを赤・緑・青・不透明度の順で。
    ///
    /// ``Alpha/opaque`` は不透明度を飛ばして受け、変換の後で 255 に埋める (カメラの絵は不透明)。
    /// ``Alpha/straight`` は乗算していない不透明度を受ける (``DisplayImage`` の約束)。
    private static func destinationFormat(_ alpha: Alpha) -> vImage_CGImageFormat {
        let info =
            switch alpha {
            case .opaque: CGImageAlphaInfo.noneSkipLast
            case .straight: CGImageAlphaInfo.last
            }
        return vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.displayP3)!),
            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
    }

    /// 詰め物の無い `width * height * 4` の器を作り、`fill` に書かせて返す。
    ///
    /// **器は 0 で埋めずに確保する** (録画側の読み戻しと同じ・#2372)。`fill` が全画素を書き、
    /// 不透明度も続く処理が決めるので、前の中身は誰も読まない。vImage が失敗したら 1 バイトも
    /// 書けたことにせず (`initializedCount` を 0 のまま)、空の配列を捨てて断る。
    ///
    /// - Parameters:
    ///   - alpha: ``Alpha/opaque`` なら不透明度を 255 に埋める。
    ///   - scaled: `fill` が乗算したまま縮めた絵を書くとき `true`。乗算を戻す。
    ///   - fill: 器へ書き、vImage の結果を返す。
    ///
    /// 検査が失敗の道を直に突くため、`private` にしていない。
    static func picture(
        width: Int, height: Int, alpha: Alpha, scaled: Bool = false,
        fill: (inout vImage_Buffer) -> vImage_Error
    ) throws(Failure) -> DisplayImage {
        var status = kvImageNoError
        let bytes = [UInt8](unsafeUninitializedCapacity: width * height * 4) { buffer, initializedCount in
            initializedCount = 0
            var destination = vImage_Buffer(
                data: buffer.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 4)
            status = fill(&destination)
            if status == kvImageNoError {
                switch alpha {
                case .opaque:
                    // 1 画素 4 バイトのうち最後 (不透明度) だけを埋める。vImage の印は先頭の
                    // バイトが 0x8、最後のバイトが 0x1
                    status = vImageOverwriteChannelsWithScalar_ARGB8888(
                        255, &destination, &destination, 0x1, vImage_Flags(kvImageNoFlags))
                case .straight:
                    if scaled {
                        status = vImageUnpremultiplyData_RGBA8888(
                            &destination, &destination, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
            if status == kvImageNoError { initializedCount = buffer.count }
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
