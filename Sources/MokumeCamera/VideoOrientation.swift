// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import CoreGraphics
import MokumeCore

/// 動画が記録している向き (トラックの `preferredTransform`)。縦に撮った動画は、横長の絵を
/// 90° 回して映すよう記録されている。
///
/// **90° 刻みの回転と、左右の反転を組み合わせた 8 通りだけを扱う。** 斜めの回転・拡縮・
/// 平行移動の混じった変換は、向きとして読めないので当てない (``identity``)。実際の撮影機材が書くのは
/// 8 通りのどれかで、平行移動 (`tx`・`ty`) は回した後の絵を原点へ寄せるだけなので読まない。
///
/// 当て方は「**まず左右を反転し (``isMirrored``)、その後で時計回りに 90° を ``quarterTurns`` 回す**」。
/// 座標は動画の画素の座標 (左上が原点・下向きが y) で、`CGAffineTransform` の
/// `(x, y) → (a x + c y + tx, b x + d y + ty)` をそのまま読む。
nonisolated struct VideoOrientation: Equatable {
    /// 時計回りに 90° を何回回すか (0〜3)。
    let quarterTurns: Int
    /// 回す前に左右を反転するか。
    let isMirrored: Bool

    /// 何も当てない。
    static let identity = VideoOrientation(quarterTurns: 0, isMirrored: false)

    init(quarterTurns: Int, isMirrored: Bool) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.isMirrored = isMirrored
    }

    /// 記録された変換から読む。向きとして読めなければ ``identity``。
    init(_ transform: CGAffineTransform) {
        // cos(π/2) などは 6e-17 のように届くので、近い整数へ丸めて読む。数でない値・大きな値は読めない
        // (整数へ直す前に断る — 直すと落ちる)
        let entries = [transform.a, transform.b, transform.c, transform.d]
        guard entries.allSatisfy({ abs($0) <= 1.001 && abs($0 - $0.rounded()) < 1e-3 }) else {
            self = .identity
            return
        }
        let a = Int(transform.a.rounded()), b = Int(transform.b.rounded())
        let c = Int(transform.c.rounded()), d = Int(transform.d.rounded())
        // 90° 刻みの回転と反転だけ: 各列がちょうど 1 つの軸を ±1 で指す
        let determinant = a * d - b * c
        guard abs(determinant) == 1, abs(a) + abs(b) == 1, abs(c) + abs(d) == 1 else {
            self = .identity
            return
        }
        // 反転があれば (行列式が負)、先に左右を反転した形に分けて、残りを回転として読む
        let mirrored = determinant < 0
        let cosine = mirrored ? -a : a
        let sine = mirrored ? -b : b
        let turns =
            switch (cosine, sine) {
            case (0, 1): 1
            case (-1, 0): 2
            case (0, -1): 3
            default: 0
            }
        self.init(quarterTurns: turns, isMirrored: mirrored)
    }

    /// 当てると縦と横が入れ替わるか (90° か 270° 回す)。
    var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// `width` × `height` の絵に当てた後の大きさ。
    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }
}

extension DisplayImage {
    /// 向きを当てた絵。``VideoOrientation/identity`` ならそのまま返す。
    ///
    /// 画素をそのまま入れ替えるだけで、色は動かさない (4 バイトの画素を 1 つの単位として動かす)。
    nonisolated func oriented(_ orientation: VideoOrientation) -> DisplayImage {
        guard orientation != .identity else { return self }
        var source = bytes
        let (outWidth, outHeight) = orientation.size(width: width, height: height)
        var rotated = [UInt8](repeating: 0, count: bytes.count)
        let status = source.withUnsafeMutableBytes { from in
            rotated.withUnsafeMutableBytes { to in
                var input = vImage_Buffer(
                    data: from.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(
                    data: to.baseAddress, height: vImagePixelCount(outHeight),
                    width: vImagePixelCount(outWidth), rowBytes: outWidth * 4)
                if orientation.isMirrored {
                    // 反転は大きさが変わらないので、入力の写しの上で先に済ませる
                    let reflected = vImageHorizontalReflect_ARGB8888(&input, &input, vImage_Flags(kvImageNoFlags))
                    guard reflected == kvImageNoError else { return reflected }
                }
                // vImage の回転の定数は反時計回り (`kRotate90DegreesCounterClockwise` が 1)。こちらは時計回りで数える
                let counterClockwise = UInt8((4 - orientation.quarterTurns) % 4)
                return vImageRotate90_ARGB8888(
                    &input, &output, counterClockwise, [0, 0, 0, 0],
                    vImage_Flags(kvImageNoFlags))
            }
        }
        // vImage が断ったときは、同じ結果を出す手で写す (毎フレーム呼ぶ口で、落とさない)
        guard status == kvImageNoError else { return orientedByHand(orientation) }
        return DisplayImage(width: outWidth, height: outHeight, bytes: rotated)
    }

    /// vImage が断ったときの写し。検査が vImage の結果と突き合わせるため `private` にしていない。
    nonisolated func orientedByHand(_ orientation: VideoOrientation) -> DisplayImage {
        let (outWidth, outHeight) = orientation.size(width: width, height: height)
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            for x in 0..<width {
                var (px, py) = (orientation.isMirrored ? width - 1 - x : x, y)
                var (w, h) = (width, height)
                // 時計回りに 90°: (x, y) → (h - 1 - y, x)
                for _ in 0..<orientation.quarterTurns {
                    (px, py) = (h - 1 - py, px)
                    (w, h) = (h, w)
                }
                let from = (y * width + x) * 4
                let to = (py * outWidth + px) * 4
                for channel in 0..<4 { result[to + channel] = bytes[from + channel] }
            }
        }
        return DisplayImage(width: outWidth, height: outHeight, bytes: result)
    }
}
