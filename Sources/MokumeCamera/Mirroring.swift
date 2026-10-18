// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import MokumeCore

extension DisplayImage {
    /// 左右を入れ替えた絵 (鏡に映したもの)。``Capture`` が `mirrored: true` のとき、届いた 1 枚に当てる。
    ///
    /// **機材の道も注入の道 (``Sketch/createCapture(frames:mirrored:)``) も、絵が ``Capture`` へ届いた後の
    /// 同じ所で当てる** ので、注入した絵で鏡像を機材なしに確かめられる。行の中の画素の並びだけを
    /// 反転し、色は動かさない (4 バイトの画素をそのまま入れ替える)。
    nonisolated func horizontallyReflected() -> DisplayImage {
        var source = bytes
        var reflected = [UInt8](repeating: 0, count: bytes.count)
        let status = source.withUnsafeMutableBytes { from in
            reflected.withUnsafeMutableBytes { to in
                var input = vImage_Buffer(
                    data: from.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(
                    data: to.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageHorizontalReflect_ARGB8888(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        // vImage が断ったときは、同じ結果を出す手で写す (毎フレーム呼ぶ口で、落とさない)
        guard status == kvImageNoError else { return reflectedByHand() }
        return DisplayImage(width: width, height: height, bytes: reflected)
    }

    private nonisolated func reflectedByHand() -> DisplayImage {
        var reflected = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            for x in 0..<width {
                let from = (y * width + x) * 4
                let to = (y * width + (width - 1 - x)) * 4
                for channel in 0..<4 { reflected[to + channel] = bytes[from + channel] }
            }
        }
        return DisplayImage(width: width, height: height, bytes: reflected)
    }
}
