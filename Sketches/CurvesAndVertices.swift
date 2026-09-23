// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 通過点を結ぶ曲線・2 次の曲線・頂点の並べ方。
///
/// **上の段は同じ 6 つの点を、曲がり方だけ変えて 3 度結ぶ。** 張り (`curveTightness`) を
/// 上げるほど直線に近づき、刻み (`curveDetail`) を落とすと角が見える。灰色の丸が
/// 置いた点で、端の点を 2 度置いているので両端まで描かれる。
///
/// **下の段は同じ 6 つの頂点を、並べ方だけ変えて渡す。** 点・2 つずつの線・3 つずつの
/// 三角形・1 つ目を要にした扇 — 頂点の列は同じで、`beginShape` に渡す種類が絵を決める。
final class CurvesAndVertices: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "curves and vertices")

    /// 上の段で結ぶ点 (1 本ぶんの左端を原点とした座標)。
    private let knots: [SIMD2<Float>] = [
        [0, 120], [50, 30], [110, 100], [170, 20], [230, 110], [280, 40],
    ]

    func draw() {
        background(18, 20, 26)

        // 通過点を結ぶ曲線 — 張りと刻みを変えて 3 本
        let variants: [(tightness: Float, detail: Int, ink: (Int, Int, Int))] = [
            (0, 20, (242, 115, 64)),
            (0.7, 20, (89, 191, 242)),
            (0, 3, (242, 217, 89)),
        ]
        for (index, variant) in variants.enumerated() {
            let left = Float(40 + index * 310)
            noStroke()
            fill(89, 97, 115)
            for knot in knots { circle(left + knot.x, 40 + knot.y, 10) }
            curveTightness(variant.tightness)
            curveDetail(variant.detail)
            noFill()
            stroke(variant.ink.0, variant.ink.1, variant.ink.2)
            strokeWeight(4)
            beginShape()
            curveVertex(left + knots[0].x, 40 + knots[0].y)
            for knot in knots { curveVertex(left + knot.x, 40 + knot.y) }
            curveVertex(left + knots[knots.count - 1].x, 40 + knots[knots.count - 1].y)
            endShape()
        }
        curveTightness(0)
        curveDetail(20)

        // 2 次の曲線 — 制御点 1 つで波を繋ぐ
        noFill()
        stroke(153, 128, 230)
        strokeWeight(4)
        beginShape()
        vertex(40, 250)
        for index in 0..<8 {
            let x = Float(40 + index * 110)
            quadraticVertex(x + 55, index % 2 == 0 ? 190 : 310, x + 110, 250)
        }
        endShape()

        // 頂点の並べ方 — 同じ 6 つの頂点を 4 通りに
        let corners: [SIMD2<Float>] = [
            [0, 0], [90, 20], [170, 0], [180, 100], [90, 150], [10, 110],
        ]
        let kinds: [(kind: VertexKind, ink: (Int, Int, Int))] = [
            (.points, (217, 230, 255)),
            (.lines, (242, 115, 64)),
            (.triangles, (102, 217, 128)),
            (.triangleFan, (230, 102, 153)),
        ]
        for (index, entry) in kinds.enumerated() {
            let left = Float(50 + index * 230)
            let top: Float = 350
            // 扇は要の頂点 (1 つ目) を中心へ寄せる。要から残りの頂点へ向けて面が開く
            let points = entry.kind == .triangleFan
                ? [SIMD2<Float>(90, 70)] + corners : corners
            stroke(entry.ink.0, entry.ink.1, entry.ink.2)
            strokeWeight(entry.kind == .points ? 10 : 3)
            if entry.kind == .points || entry.kind == .lines {
                noFill()
            } else {
                fill(entry.ink.0, entry.ink.1, entry.ink.2, 140)
            }
            beginShape(entry.kind)
            for spot in points { vertex(left + spot.x, top + spot.y) }
            endShape()
        }
    }
}
