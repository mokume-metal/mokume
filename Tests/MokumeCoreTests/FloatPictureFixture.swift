// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// 32 ビット浮動小数の絵 (HDR の資材) を、検査の中で作って書き出す。
///
/// **資材はコミットしない。** 値は検査が渡すので、期待値を保存された画像ではなく
/// 仕様から導ける ([ADR-0019] 決定 4)。1 画素が 8 ビットに収まらない (白を越える・
/// 半精度の上限を越える) 絵を作れるのは、浮動小数の文脈へ直に画素を置くからである。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
enum FloatPictureFixture {
    /// 書き出す形式。どちらも浮動小数の成分を持てる。
    enum Format: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case tiff = "TIFF"
        case openEXR = "OpenEXR"

        var testDescription: String { rawValue }

        fileprivate var identifier: String {
            switch self {
            case .tiff: UTType.tiff.identifier
            case .openEXR: "com.ilm.openexr-image"
            }
        }

        fileprivate var pathExtension: String {
            switch self {
            case .tiff: "tiff"
            case .openEXR: "exr"
            }
        }
    }

    /// 成分を書く色空間。**作業空間 (線形の Display P3) だけは、読み込みが色を変換しない。** 他は
    /// 読み込みが作業空間へ変換するので、成分をまたいで値が混ざる (符号も変わりうる)。
    enum Space: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case working = "線形 Display P3 (作業空間)"
        case linearSRGB = "線形 sRGB"
        case linearRec2020 = "線形 Rec.2020"
        case extendedSRGB = "拡張 sRGB (ガンマ付き)"

        var testDescription: String { rawValue }

        fileprivate var name: CFString {
            switch self {
            case .working: CGColorSpace.extendedLinearDisplayP3
            case .linearSRGB: CGColorSpace.extendedLinearSRGB
            case .linearRec2020: CGColorSpace.extendedLinearITUR_2020
            case .extendedSRGB: CGColorSpace.extendedSRGB
            }
        }
    }

    /// 色つきの絵を書く組み合わせ。**OpenEXR は書くときに線形 sRGB へ変換して持つ**ので、TIFF と
    /// 別の道 (書くときの変換と読むときの変換) を通る。
    nonisolated struct Coloured: CustomTestStringConvertible, Sendable {
        var format: Format
        var space: Space

        var testDescription: String { "\(format.rawValue) / \(space.rawValue)" }

        nonisolated static let all: [Coloured] = [
            Coloured(format: .tiff, space: .linearSRGB),
            Coloured(format: .tiff, space: .linearRec2020),
            Coloured(format: .tiff, space: .extendedSRGB),
            Coloured(format: .openEXR, space: .linearSRGB),
            Coloured(format: .openEXR, space: .linearRec2020),
            Coloured(format: .openEXR, space: .extendedSRGB),
        ]
    }

    /// 書けなかった理由。
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// 全画素が同じ色の絵を書く。**成分は乗算済み**で、`space` の値として渡す (既定は作業空間)。
    static func write(
        _ texel: SIMD4<Float>, width: Int, height: Int, as format: Format,
        in space: Space = .working
    ) throws -> URL {
        try write(
            [SIMD4<Float>](repeating: texel, count: width * height), width: width, height: height,
            as: format, in: space)
    }

    /// 画素を並べて書く。並びの先頭は絵の上端 (読み込みが返す並びと同じ)。
    static func write(
        _ texels: [SIMD4<Float>], width: Int, height: Int, as format: Format,
        in space: Space = .working
    ) throws -> URL {
        precondition(texels.count == width * height)
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(format.identifier) else {
            throw Failure(description: "\(format.rawValue) をこの環境は書き出せない")
        }

        var texels = texels
        let made: CGImage? = texels.withUnsafeMutableBytes { buffer in
            guard let colorSpace = CGColorSpace(name: space.name),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 32, bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            return context.makeImage()
        }
        guard let made else { throw Failure(description: "浮動小数の文脈を作れなかった") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-float-\(UUID().uuidString).\(format.pathExtension)")
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, format.identifier as CFString, 1, nil)
        else { throw Failure(description: "\(format.rawValue) の書き出し先を作れなかった") }
        CGImageDestinationAddImage(destination, made, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "\(format.rawValue) を書き出せなかった")
        }
        return url
    }
}
