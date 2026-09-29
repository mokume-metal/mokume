// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import Testing

@testable import MokumeCore

/// 符号化器へ渡す並び (BGRA) へ写す段。**GPU も符号化器も要さない** — 写す関数を直接呼ぶ。
///
/// vImage で写した結果を、1 バイトずつ写すループ (以前の実装そのもの) と全バイトで
/// 突き合わせる (#1754)。
@Suite("符号化器へ渡す並び")
struct MovieFileSwizzleTests {

    /// 詰め物の目印。写す側が詰め物へ書けば、この値が崩れる。
    private static let untouched: UInt8 = 0xA5

    /// 全バイトの値と、境界の値 (0・1・254・255・透明なのに色がある画素) が現れる元の絵。
    private func source(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let edges: [UInt8] = [0, 1, 254, 255]
        for index in bytes.indices {
            // チャンネルごとに違う値にする。並びを取り違えれば必ず食い違う
            bytes[index] = UInt8(truncatingIfNeeded: index &* 7 &+ index / 4 &* 13)
        }
        for pixel in 0..<min(width * height, 64) {
            let base = pixel * 4
            // 1 画素の中でもチャンネルごとに違う値にする (1×1 でも取り違えに気付ける)
            bytes[base] = edges[pixel % 4]
            bytes[base + 1] = edges[(pixel + 1) % 4]
            bytes[base + 2] = edges[(pixel / 4 + 2) % 4]
            // 16 画素ごとに不透明度 0 の画素を置く (straight alpha では色が残る)
            bytes[base + 3] = pixel % 16 == 15 ? 0 : edges[(pixel + 3) % 4]
        }
        return bytes
    }

    /// 行の終わりに詰め物を持つ器へ写し、器ごと返す。
    private func write(
        _ source: [UInt8], width: Int, height: Int, stride: Int,
        with writer: (UnsafeBufferPointer<UInt8>, UnsafeMutablePointer<UInt8>) -> Void
    ) -> [UInt8] {
        var destination = [UInt8](repeating: Self.untouched, count: stride * height)
        source.withUnsafeBufferPointer { from in
            destination.withUnsafeMutableBufferPointer { to in
                writer(from, to.baseAddress!)
            }
        }
        return destination
    }

    @Test(
        "vImage で写した並びが、1 バイトずつ写したものと全バイトで一致し、詰め物に触れない",
        arguments: [(1, 1), (641, 37), (1920, 1080)])
    func thePermutedBytesMatchTheLoop(_ size: (Int, Int)) {
        let (width, height) = size
        // 符号化器の器と同じく、行を 64 バイト境界へ揃えたうえで、さらに詰め物を足す
        let stride = (width * 4 + 63) / 64 * 64 + 16
        let bytes = source(width: width, height: height)

        let permuted = write(bytes, width: width, height: height, stride: stride) { from, to in
            MovieFile.writeBGRA(from: from, width: width, height: height, into: to, stride: stride)
        }
        let looped = write(bytes, width: width, height: height, stride: stride) { from, to in
            MovieFile.writeBGRAByLoop(
                from: from, width: width, height: height, into: to, stride: stride)
        }
        #expect(permuted == looped)

        // ループそのものの取り違えにも気付けるよう、並びを直接も確かめる
        var wrongPixels = 0
        var touchedPadding = 0
        for y in 0..<height {
            for x in 0..<width {
                let to = y * stride + x * 4
                let from = (y * width + x) * 4
                if permuted[to] != bytes[from + 2] || permuted[to + 1] != bytes[from + 1]
                    || permuted[to + 2] != bytes[from] || permuted[to + 3] != bytes[from + 3]
                {
                    wrongPixels += 1
                }
            }
            for padding in (y * stride + width * 4)..<((y + 1) * stride)
            where permuted[padding] != Self.untouched {
                touchedPadding += 1
            }
        }
        #expect(wrongPixels == 0)
        #expect(touchedPadding == 0)
    }

    @Test("vImage が断ったときは、ループで写し直して同じ並びになる")
    func aRefusedPermutationFallsBackToTheLoop() {
        let (width, height) = (641, 37)
        let stride = width * 4 + 60
        let bytes = source(width: width, height: height)

        let fallenBack = write(bytes, width: width, height: height, stride: stride) { from, to in
            MovieFile.writeBGRA(
                from: from, width: width, height: height, into: to, stride: stride,
                permute: { _, _, _, destination, _ in
                    // 途中まで書き散らしてから断る。写し直しが全部を上書きすることを見る
                    destination.update(repeating: 0, count: width * 4)
                    return kvImageInternalError
                })
        }
        let looped = write(bytes, width: width, height: height, stride: stride) { from, to in
            MovieFile.writeBGRAByLoop(
                from: from, width: width, height: height, into: to, stride: stride)
        }
        #expect(fallenBack == looped)
    }
}
