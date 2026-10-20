// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 配る形 (GIF・MP4) へ書く前に、絵を sRGB の 8 ビットへ写す ([#2440])。
///
/// 道具の絵は Display P3 で持つ ([ADR-0011] 決定 1)。GIF には色空間の印が無く、MP4 も再生側が
/// P3 の印を読むとは限らない。**配る相手の画面が最も広く想定する sRGB へ、書く前に写す。**
/// 写さずに書くと、読む側は sRGB と見なし、Display P3 の値が sRGB の値として読まれて彩度が落ちる。
/// P3 の外へ出る色 (sRGB に収まらない色) は、色空間の変換が sRGB の範囲へ収める。
///
/// 色の変換は CoreGraphics に任せる。**変換は乗算しない色で行う** — 絵のアルファは (straight)、
/// 乗算済みの色へ直すと半透明の画素の色が黒へ寄る。アルファは色の変換とは別に、下の
/// ``Alpha`` の規則で決める。
///
/// 隔離の外に置く (符号化はフレームの外で走る)。
///
/// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
nonisolated enum DistributionColor {
    /// 透けた画素の書き方。
    enum Alpha {
        /// 透けを書かない (MP4)。透けた画素も色だけを書く (**乗算せず、色はそのまま**) ので、
        /// 透けた画素の色が黒でも白でもなく、絵が持っていた色で出る。
        case drop
        /// 透けを 1 ビットで書く (GIF)。**``gifThreshold`` 以上の画素は不透明、未満は透明** —
        /// 半透明は書けない。透明にした画素の色は 0 にする (読み手によらず同じバイト列にする)。
        case threshold
    }

    /// GIF で、この値以上のアルファを不透明として書く (半分)。
    ///
    /// **この線を OS に任せない。** ImageIO は線を持つが、値は文書に無く (測ると 50 と 64 の間だった)、
    /// 版で変わりうる。線を自分で引けば、透けた画素の行き先は OS の版によらず同じで、
    /// 説明にも書ける。
    static let gifThreshold: UInt8 = 128

    /// 絵を sRGB へ写した絵を返す。大きさは変わらない。
    ///
    /// - Parameters:
    ///   - image: Display P3・乗算していないアルファの絵。
    ///   - alpha: 透けた画素の書き方。
    static func srgb(_ image: DisplayImage, alpha: Alpha) -> DisplayImage {
        let width = image.width
        let height = image.height
        let count = width * height * 4
        // 元のアルファを色の変換から切り離す。`noneSkipLast` は 4 バイト目を読まない (詰め物として
        // 扱う) ので、色だけが sRGB へ写る。出力の 4 バイト目は、下で決める
        var converted = [UInt8](repeating: 0, count: count)
        let convertedOK: Bool = image.bytes.withUnsafeBufferPointer { source -> Bool in
            guard let base = source.baseAddress,
                let provider = CGDataProvider(
                    dataInfo: nil, data: base, size: count, releaseData: { _, _, _ in }),
                let from = CGColorSpace(name: CGColorSpace.displayP3),
                let to = CGColorSpace(name: CGColorSpace.sRGB),
                let picture = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: from,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
            else { return false }
            return converted.withUnsafeMutableBytes { destination in
                guard
                    let context = CGContext(
                        data: destination.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: to,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                context.interpolationQuality = .none
                context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
        }
        // 変換の器を作れなければ、色は変えずに書く (器を作れない機械は想定していないが、落とさない)
        if !convertedOK { converted = image.bytes }

        image.bytes.withUnsafeBufferPointer { source in
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                let sourceAlpha = source[offset + 3]
                switch alpha {
                case .drop:
                    converted[offset + 3] = 255
                case .threshold:
                    if sourceAlpha >= gifThreshold {
                        converted[offset + 3] = 255
                    } else {
                        converted[offset] = 0
                        converted[offset + 1] = 0
                        converted[offset + 2] = 0
                        converted[offset + 3] = 0
                    }
                }
            }
        }
        return DisplayImage(width: width, height: height, bytes: converted)
    }
}
