// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing

@testable import MokumeCamera
import MokumeCore

/// 動画の回転の印を読んで絵へ当てる (#2451)。GPU も動画も要らない。
@Suite("動画の回転の印")
nonisolated struct VideoOrientationTests {
    /// 撮影機材が書く 8 通り (`tx`・`ty` は回した後の絵を原点へ寄せる平行移動で、読まない)。
    private static let transforms: [(name: String, transform: CGAffineTransform)] = [
        ("そのまま", CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
        ("時計回りに 90°", CGAffineTransform(rotationAngle: .pi / 2).concatenating(.init(translationX: 16, y: 0))),
        ("180°", CGAffineTransform(rotationAngle: .pi).concatenating(.init(translationX: 32, y: 16))),
        ("反時計回りに 90°", CGAffineTransform(rotationAngle: -.pi / 2).concatenating(.init(translationX: 0, y: 32))),
        ("左右反転", CGAffineTransform(scaleX: -1, y: 1).concatenating(.init(translationX: 32, y: 0))),
        ("上下反転", CGAffineTransform(scaleX: 1, y: -1).concatenating(.init(translationX: 0, y: 16))),
        ("斜めの軸で反転 (a)", CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
        ("斜めの軸で反転 (b)", CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 16, ty: 32)),
    ]

    @Test("8 通りの印を、回す回数と反転に読む。時計回りに 90° は 1 回 (iPhone で縦に撮った印)")
    func readsTheEightOrientations() {
        let read = Self.transforms.map { VideoOrientation($0.transform) }
        #expect(
            read == [
                VideoOrientation(quarterTurns: 0, isMirrored: false),
                VideoOrientation(quarterTurns: 1, isMirrored: false),
                VideoOrientation(quarterTurns: 2, isMirrored: false),
                VideoOrientation(quarterTurns: 3, isMirrored: false),
                VideoOrientation(quarterTurns: 0, isMirrored: true),
                VideoOrientation(quarterTurns: 2, isMirrored: true),
                VideoOrientation(quarterTurns: 3, isMirrored: true),
                VideoOrientation(quarterTurns: 1, isMirrored: true),
            ])
        #expect(read[1].swapsAxes && read[3].swapsAxes && !read[2].swapsAxes && !read[0].swapsAxes)
    }

    @Test("向きとして読めない変換 (斜め・拡縮・つぶれ) は当てない")
    func unreadableTransformsAreIgnored() {
        let diagonal = CGAffineTransform(rotationAngle: .pi / 4)
        #expect(VideoOrientation(diagonal) == .identity)
        #expect(VideoOrientation(CGAffineTransform(scaleX: 2, y: 2)) == .identity)
        #expect(VideoOrientation(CGAffineTransform(scaleX: 0, y: 1)) == .identity)
        #expect(VideoOrientation(CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)) == .identity)
    }

    /// 比べる相手: 変換を画素の中心の座標へ直に掛け、絵の中心を保って置いた先。
    private func expected(_ image: DisplayImage, by transform: CGAffineTransform) -> DisplayImage {
        let a = Int(transform.a.rounded()), b = Int(transform.b.rounded())
        let c = Int(transform.c.rounded()), d = Int(transform.d.rounded())
        let swaps = a == 0
        let outWidth = swaps ? image.height : image.width
        let outHeight = swaps ? image.width : image.height
        var bytes = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                // 中心を原点にした座標 (2 倍して整数のまま扱う)
                let cx = 2 * x + 1 - image.width
                let cy = 2 * y + 1 - image.height
                let nx = a * cx + c * cy
                let ny = b * cx + d * cy
                let px = (nx + outWidth - 1) / 2
                let py = (ny + outHeight - 1) / 2
                for channel in 0..<4 {
                    bytes[(py * outWidth + px) * 4 + channel] = image.bytes[(y * image.width + x) * 4 + channel]
                }
            }
        }
        return DisplayImage(width: outWidth, height: outHeight, bytes: bytes)
    }

    /// どの画素も違う、縦と横が違う絵。
    private var sample: DisplayImage {
        let width = 5, height = 3
        var bytes: [UInt8] = []
        for index in 0..<width * height {
            let base = UInt8(index * 10)
            bytes += [base, base + 1, base + 2, UInt8(255 - index)]
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    @Test("向きを当てた絵は、記録された変換を画素へ直に掛けたものと同じ (8 通り・vImage も手の写しも)")
    func orientingMatchesTheTransformApplied() {
        let image = sample
        for (name, transform) in Self.transforms {
            let orientation = VideoOrientation(transform)
            let want = expected(image, by: transform)
            #expect(image.oriented(orientation) == want, "\(name)")
            #expect(image.orientedByHand(orientation) == want, "\(name) (手の写し)")
            let size = orientation.size(width: image.width, height: image.height)
            #expect((want.width, want.height) == (size.width, size.height), "\(name) の大きさ")
        }
    }

    @Test("縦に撮った印 (時計回りに 90°) では、左上の画素が右上へ行き、縦と横が入れ替わる")
    func portraitMovesTheTopLeftToTheTopRight() {
        let image = sample
        let turned = image.oriented(VideoOrientation(quarterTurns: 1, isMirrored: false))
        #expect((turned.width, turned.height) == (3, 5))
        // 元の左上 (0, 0) → 右上 (2, 0)
        #expect(Array(turned.bytes[(2 * 4)..<(2 * 4 + 4)]) == Array(image.bytes[0..<4]))
        // 元の左下 (0, 2) → 左上 (0, 0)
        #expect(Array(turned.bytes[0..<4]) == Array(image.bytes[(2 * 5 * 4)..<(2 * 5 * 4 + 4)]))
    }

    @Test("何も当てない向きは、同じ絵をそのまま返す")
    func identityReturnsTheSameImage() {
        #expect(sample.oriented(.identity) == sample)
    }
}
