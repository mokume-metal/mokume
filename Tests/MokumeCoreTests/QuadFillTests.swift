// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// `quad()` が、凸でない四角形も与えた順に結んだ形どおりに塗るかの検査。GPU を要する。
///
/// **物差しは画素の中心で数えた回り数である。** 回り数が 0 でないのに塗られていない画素を
/// 「塗り漏れ」、0 なのに塗られた画素を「はみ出し」と数える。辺が交差した四角形は、
/// nonzero でも even-odd でも回り数 ±1 の三角形 2 つ (砂時計) になるので、どちらの規則でも
/// 同じ物差しで見られる。縁から 1 画素以内の画素は、ラスタライズの規則しだいでどちらにも
/// 転ぶので数えない。
///
/// 最初の点から扇に割ると、対角線 `points[0]`–`points[2]` が形の外を通る四角形 (凹んだ点が
/// 2 つ目か 4 つ目) でへこみまで塗り、交差した四角形は砂時計にならない ([#1534])。
///
/// [#1534]: https://github.com/mokume-metal/mokume/issues/1534
@Suite(
    "四角形の塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct QuadFillTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let size = 160

    /// 起票の矢じり。(60, 80) が凹んだ点。
    private let arrowhead: [SIMD2<Float>] = [
        SIMD2(20, 20), SIMD2(140, 80), SIMD2(20, 140), SIMD2(60, 80),
    ]

    private func render(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    private func quad(_ canvas: Canvas, _ points: [SIMD2<Float>]) {
        canvas.quad(
            points[0].x, points[0].y, points[1].x, points[1].y,
            points[2].x, points[2].y, points[3].x, points[3].y)
    }

    private func red(_ pixels: PixelBuffer, _ x: Int, _ y: Int) -> Float {
        Float(pixels.components[(y * size + x) * 4])
    }

    private func painted(_ pixels: PixelBuffer, _ x: Int, _ y: Int) -> Bool {
        red(pixels, x, y) > 0.5
    }

    /// 回り数と突き合わせた、塗り漏れとはみ出しの数。
    private func mismatches(_ pixels: PixelBuffer, _ ring: [SIMD2<Float>]) -> (
        missing: Int, spilled: Int
    ) {
        var missing = 0
        var spilled = 0
        for y in 0..<size {
            for x in 0..<size {
                let center = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                if isNearAnEdge(center, ring) { continue }
                let inside = winding(center, ring) != 0
                if inside, !painted(pixels, x, y) { missing += 1 }
                if !inside, painted(pixels, x, y) { spilled += 1 }
            }
        }
        return (missing, spilled)
    }

    private func winding(_ point: SIMD2<Float>, _ ring: [SIMD2<Float>]) -> Int {
        var total = 0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
            if a.y <= point.y, b.y > point.y, side > 0 { total += 1 }
            if a.y > point.y, b.y <= point.y, side < 0 { total -= 1 }
        }
        return total
    }

    private func isNearAnEdge(_ point: SIMD2<Float>, _ ring: [SIMD2<Float>]) -> Bool {
        ring.indices.contains { index in
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let t = simd_clamp(dot(point - a, b - a) / length_squared(b - a), 0, 1)
            return distance(point, a + t * (b - a)) <= 1
        }
    }

    // MARK: - 検査

    /// 始点を回して、凹んだ点 (60, 80) が 0〜3 番目に来る 4 通りの並びを見る。
    @Test("凹んだ四角形は、凹んだ点が何番目でも同じ 4 点を並べた形と同じに塗る", arguments: 0..<4)
    func aConcaveQuadMatchesTheSameVerticesAsAShape(_ concaveAt: Int) throws {
        // 凹んだ点は arrowhead の 3 番目。concaveAt 番目に来るように始点をずらす
        let points = (0..<4).map { arrowhead[($0 + 3 - concaveAt) % 4] }
        #expect(points[concaveAt] == SIMD2(60, 80))

        let byQuad = try render { quad($0, points) }
        let byShape = try render { canvas in
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y) }
            canvas.endShape(.close)
        }
        var differing = 0
        for y in 0..<size {
            for x in 0..<size where painted(byQuad, x, y) != painted(byShape, x, y) {
                differing += 1
            }
        }
        #expect(differing == 0)
        let dentPainted = painted(byQuad, 30, 80)  // へこみの中
        #expect(!dentPainted)
        let (missing, spilled) = mismatches(byQuad, points)
        #expect(missing == 0)
        #expect(spilled == 0)
    }

    @Test(
        "辺の交差した四角形は砂時計に塗る",
        arguments: [
            [SIMD2(20, 20), SIMD2(140, 20), SIMD2(20, 140), SIMD2(140, 140)],
            [SIMD2(20, 20), SIMD2(140, 140), SIMD2(140, 20), SIMD2(20, 140)],
            [SIMD2(30, 20), SIMD2(150, 50), SIMD2(10, 130), SIMD2(120, 150)],
        ] as [[SIMD2<Float>]])
    func aCrossedQuadIsAnHourglass(_ points: [SIMD2<Float>]) throws {
        let pixels = try render { quad($0, points) }
        let (missing, spilled) = mismatches(pixels, points)
        #expect(missing == 0)
        #expect(spilled == 0)
    }

    @Test("起票の交差した四角形は、三角形 2 枚で描いた砂時計と縁のほかは一致する")
    func theReportedCrossedQuadMatchesTwoTriangles() throws {
        let points: [SIMD2<Float>] = [
            SIMD2(20, 20), SIMD2(140, 20), SIMD2(20, 140), SIMD2(140, 140),
        ]
        let byQuad = try render { quad($0, points) }
        let byTriangles = try render { canvas in
            canvas.triangle(20, 20, 140, 20, 80, 80)
            canvas.triangle(20, 140, 140, 140, 80, 80)
        }
        var differing = 0
        for y in 0..<size {
            for x in 0..<size {
                let center = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                if isNearAnEdge(center, points) { continue }
                if painted(byQuad, x, y) != painted(byTriangles, x, y) { differing += 1 }
            }
        }
        #expect(differing == 0)
    }

    /// 扇で割ると、へこみの上に三角形が 2 枚重なり、塗られないはずの所が濃く出ていた。
    @Test("半透明の凹んだ四角形は、へこみを塗らず、形の中を 1 度だけ塗る")
    func aTranslucentConcaveQuadCoversEachPixelOnce() throws {
        let pixels = try render { canvas in
            canvas.fill(255, 128)
            quad(canvas, arrowhead)
        }
        #expect(red(pixels, 30, 80) == 0)  // へこみの中は下地のまま
        #expect(red(pixels, 100, 80) > 0)
        #expect(red(pixels, 100, 80) == red(pixels, 40, 40))
    }
}
