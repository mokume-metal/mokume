// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 絵をファイルへ書き出すときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public enum ImageWriteFailure: Error, Equatable, Sendable {
    /// 画素の数が幅・高さと合っていない。
    case malformedImage(width: Int, height: Int, byteCount: Int)
    /// 書き出し先を開けない。
    case destinationUnavailable(path: String)
    /// 書き込みに失敗した。
    case writeFailed(path: String)
}

extension ImageWriteFailure: CustomStringConvertible {
    /// 人が読む文面。**1 行で、行き先は載せない** — 書き出しの警告 (`"Could not write <行き先>: …"`)・観測の
    /// 書き出しの結末・``Image/save(_:)`` の ``ImageFailure/unwritable(path:reason:)`` は、どれも行き先を別に
    /// 持っているので、この句を理由として入れる。文面の正本はここ 1 つ ([#2401])。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    public var description: String {
        switch self {
        case .malformedImage(let width, let height, let byteCount):
            "the picture is malformed (\(width)x\(height), \(byteCount) bytes)"
        case .destinationUnavailable: "the destination could not be opened"
        case .writeFailed: "the file could not be written"
        }
    }
}

/// 絵を PNG として書き出す。
///
/// **隔離の外に置く** — 読む側の `ImageFile` と対称にしておくと、書き出しを
/// フレームの外へ逃がす経路 (`FrameWriter`) がそのまま呼べる ([ADR-0010] 決定 4)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public nonisolated enum PNGFile {
    /// 表示できる形の絵を PNG として書き出す。
    ///
    /// **書き込みが終わってから返る。** 開始しただけで返る形にすると、呼び出した側は
    /// ファイルができたかどうかを確かめられず、検査が成立しない。
    ///
    /// 埋め込む色空間は作業空間と同じ Display P3 ([ADR-0011] 決定 1)。色域を広く取ると
    /// 決めておきながら、書き出す時に狭い色域へ落とすと決定 1 が意味を失う。
    ///
    /// アルファは乗算していない表現で書く ([ADR-0011] 決定 4 の境界)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public static func write(_ image: DisplayImage, to url: URL) throws(ImageWriteFailure) {
        guard image.bytes.count == image.width * image.height * 4 else {
            throw .malformedImage(
                width: image.width, height: image.height, byteCount: image.bytes.count)
        }

        let data = Data(image.bytes)
        guard let provider = CGDataProvider(data: data as CFData),
            let cgImage = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: image.width * 4,
                space: DisplayImage.colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            throw .destinationUnavailable(path: url.path)
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw .destinationUnavailable(path: url.path)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw .writeFailed(path: url.path)
        }
    }
}
