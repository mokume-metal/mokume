// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// `beginContour` で穴を開けた形が、形どおりに塗られるかの検査。GPU を要する。
///
/// **物差しは画素の中心で数えた回り数である。** 穴は外周と逆に回るので、穴の中は回り数 0
/// になる。回り数 ±1 なのに塗られていない画素を「塗り漏れ」、0 なのに塗られた画素を
/// 「はみ出し」と数える。縁から 1 画素以内の画素は、ラスタライズの規則しだいでどちらにも
/// 転ぶので数えない。
///
/// 穴を外周へつなぐ橋が穴そのものや他の穴を横切ると、畳んだ周が自己交差して塗りが
/// 途中で止まる ([#1530])。
///
/// [#1530]: https://github.com/mokume-metal/mokume/issues/1530
@Suite(
    "穴を開けた形の塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ContourFillTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let size = 160

    /// 起票の形。矩形の外周に、外周と逆回りの六角形の穴。
    private let square: [SIMD2<Float>] = [
        SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150),
    ]
    private let hexagon: [SIMD2<Float>] = [
        SIMD2(70, 80), SIMD2(60, 62), SIMD2(40, 62),
        SIMD2(30, 80), SIMD2(40, 98), SIMD2(60, 98),
    ]

    private struct Tally {
        var painted = 0
        /// 回り数 ±1 なのに塗られていない画素。
        var missing = 0
        /// 回り数 0 なのに塗られた画素。
        var spilled = 0
    }

    /// 周を並べて塗り、回り数と突き合わせる。
    ///
    /// - Parameters:
    ///   - rings: 最初が外周、残りが穴。画面の座標で渡す。
    ///   - draw: 周の置き方。既定は平面の `vertex(x, y)` で並べる。
    private func tally(
        _ rings: [[SIMD2<Float>]],
        drawing draw: ((Canvas, [[SIMD2<Float>]]) -> Void)? = nil
    ) throws -> Tally {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            if let draw {
                draw(canvas, rings)
            } else {
                placeFlat(canvas, rings)
            }
        }
        let pixels = try canvas.target.readPixels()
        var result = Tally()
        for y in 0..<size {
            for x in 0..<size {
                let painted = pixels.components[(y * size + x) * 4] > 0.5
                if painted { result.painted += 1 }
                let center = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                if isNearAnEdge(center, rings) { continue }
                let inside = winding(center, rings) != 0
                if inside, !painted { result.missing += 1 }
                if !inside, painted { result.spilled += 1 }
            }
        }
        return result
    }

    private func placeFlat(_ canvas: Canvas, _ rings: [[SIMD2<Float>]]) {
        canvas.beginShape()
        for point in rings[0] { canvas.vertex(point.x, point.y) }
        for hole in rings.dropFirst() {
            canvas.beginContour()
            for point in hole { canvas.vertex(point.x, point.y) }
            canvas.endContour()
        }
        canvas.endShape(.close)
    }

    /// 奥行きを持つ経路。周を外周のなす平面へ落としてから三角形へ分ける。
    private func placeWithDepth(_ canvas: Canvas, _ rings: [[SIMD2<Float>]]) {
        canvas.beginShape()
        for point in rings[0] { canvas.vertex(point.x, point.y, 0) }
        for hole in rings.dropFirst() {
            canvas.beginContour()
            for point in hole { canvas.vertex(point.x, point.y, 0) }
            canvas.endContour()
        }
        canvas.endShape(.close)
    }

    private func winding(_ point: SIMD2<Float>, _ rings: [[SIMD2<Float>]]) -> Int {
        var total = 0
        for ring in rings {
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
                if a.y <= point.y, b.y > point.y, side > 0 { total += 1 }
                if a.y > point.y, b.y <= point.y, side < 0 { total -= 1 }
            }
        }
        return total
    }

    private func isNearAnEdge(_ point: SIMD2<Float>, _ rings: [[SIMD2<Float>]]) -> Bool {
        for ring in rings {
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                let t = simd_clamp(dot(point - a, b - a) / length_squared(b - a), 0, 1)
                if distance(point, a + t * (b - a)) <= 1 { return true }
            }
        }
        return false
    }

    /// 中心と半径から、`sides` 角形を時計回り (画面の座標で外周と逆回り) に並べる。
    private func polygon(center: SIMD2<Float>, radius: Float, sides: Int) -> [SIMD2<Float>] {
        (0..<sides).map { step in
            let angle = -Float(step) / Float(sides) * 2 * .pi
            return center + radius * SIMD2(cos(angle), sin(angle))
        }
    }

    // MARK: - 検査

    @Test("起票の再現: 矩形の六角形の穴を、穴の位置によらず形どおりに抜く")
    func aHexagonalHoleIsPunchedWherever() throws {
        let reported = try tally([square, hexagon])
        #expect(reported.painted == 18520)  // 19600 - 1080
        #expect(reported.missing == 0)
        #expect(reported.spilled == 0)

        // 右へ 60 ずらすと、直す前から正しく抜けていた。同じ数になる
        let shifted = try tally([square, hexagon.map { $0 + SIMD2(60, 0) }])
        #expect(shifted.painted == reported.painted)
    }

    @Test("穴の右端が外周の左の点に近い 16 角形の穴も抜く")
    func aRoundHoleNearTheLeftIsPunched() throws {
        let result = try tally([square, polygon(center: SIMD2(45, 80), radius: 20, sides: 16)])
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }

    /// 右の穴からいちばん近い外周の点 (10, 40) へ架けると、**まだ畳んでいない左の穴**を
    /// 横切る。どちらの穴も単独なら正しく抜ける。
    @Test("右の穴の橋が、まだ畳んでいない左の穴を跨がない")
    func aBridgeDoesNotCrossAHoleNotYetMerged() throws {
        let outer: [SIMD2<Float>] = [
            SIMD2(10, 40), SIMD2(150, 40), SIMD2(150, 120), SIMD2(10, 120),
        ]
        let right: [SIMD2<Float>] = [
            SIMD2(70, 75), SIMD2(60, 75), SIMD2(60, 85), SIMD2(70, 85),
        ]
        let left: [SIMD2<Float>] = [
            SIMD2(30, 45), SIMD2(20, 45), SIMD2(20, 55), SIMD2(30, 55),
        ]
        let result = try tally([outer, right, left])
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }

    /// 奥行きを持つ頂点は外周のなす平面の座標で畳むので、「いちばん右」が画面の右とは
    /// 限らない。起票の形そのものは壊れず、90 度回した形が壊れていた。回す向きは両方見る。
    @Test("奥行きを持つ頂点で置いた、90 度回した形も抜く", arguments: [1, -1] as [Float])
    func aRotatedHoleWithDepthIsPunched(_ turn: Float) throws {
        let center = SIMD2<Float>(80, 80)
        func rotated(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let offset = point - center
            return center + SIMD2(-turn * offset.y, turn * offset.x)
        }
        let result = try tally(
            [square.map(rotated), hexagon.map(rotated)], drawing: placeWithDepth)
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }

    @Test("createShape で記録して置いた形も抜く")
    func aRecordedShapeIsPunched() throws {
        let result = try tally([square, hexagon]) { canvas, rings in
            let shape = canvas.createShape { placeFlat(canvas, rings) }
            canvas.shape(shape)
        }
        #expect(result.painted == 18520)
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }
}
