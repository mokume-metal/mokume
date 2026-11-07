// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 細い線 (描く画素で太さ 1 未満) の角の片 (`thinCarving` の `addJoin`) の検査 (#2376)。GPU を要する。
///
/// `addJoin` は角に来る 2 本の帯の太さの半分と覆いから、角の形 (円板・尖り・面取り) を作る。
/// 片の数と、引き算の後に残る面積の和を、ジグザグの折れ線 (角が全部鋭角) で固定する。値は
/// 書き換え (`Optional.map` を `if let` に替える) の前後で動いていない (書き換え前の版でも同じ値になる)。角の形のどれかの太さや覆いを
/// 取り違えると、面積の和が動く。
///
/// #2172 で、細い帯を「列 (行) が帯を切る長さを整数にする」広げ方に替えたので、値を測り直した (miter・bevel
/// 343.155 → 339.941、round 344.268 → 341.032)。ジグザグの帯の向き (7, 50) は縦寄りで、行が帯を切る長さ
/// 0.5 / 0.990 が 1 未満なので、帯の幅は 1 から 0.990 (向きの縦の成分) へ細る。片の数は動いていない。
///
/// #3793 で、細い帯を「縁を写しにした本体と両端の片」に割ったので、7 本の帯がそれぞれ 3 つの片になり、片の数が
/// 14 増えた (miter・bevel 21 → 35、round 33 → 47)。帯の領域は割る前と同じなので、面積の和は動いていない。
@Suite(
    "細い線の角の片",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ThinStrokeCornersTests {
    /// 凸多角形の面積 (反時計回りで正)。
    private static func area(_ points: ArraySlice<SIMD2<Float>>) -> Double {
        var twice = 0.0
        let ring = Array(points)
        for index in ring.indices {
            let (a, b) = (ring[index], ring[(index + 1) % ring.count])
            twice += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return twice / 2
    }

    @Test(
        "ジグザグの角を集めて引くと、片の数と面積の和は決まった値になる",
        arguments: [
            (StrokeJoin.miter, 35, 339.9406328188452), (.round, 47, 341.03212605478984),
            (.bevel, 35, 339.9406328188452),
        ])
    func zigzagCornersCarveToAFixedArea(
        join: StrokeJoin, expectedPieces: Int, expectedArea: Double
    ) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        var points: [SIMD2<Float>] = []
        for index in 0..<8 {
            points.append(SIMD2(20 + Float(index) * 7, index.isMultiple(of: 2) ? 40 : 90))
        }
        let outline = Canvas.Outline(points: points, isClosed: false, fills: false)
        let thin = try #require(
            canvas.thinOutline(outline, weight: 0.5, placedBy: matrix_identity_float4x4),
            "太さ 0.5 は描く画素で 1 未満なので補う")
        canvas.strokeJoin(join)

        let built = canvas.thinCarving(outline, thin: thin)
        var pieces = 0
        var total = 0.0
        built.carving.carved { points, rim, _, _ in
            pieces += 1
            total += Self.area(points[rim])
        }
        #expect(pieces == expectedPieces)
        #expect(abs(total - expectedArea) < 1e-3, "面積の和 \(total)")
    }
}
