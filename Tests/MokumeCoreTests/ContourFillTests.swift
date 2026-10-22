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
    private let black = Color.linear(red: 0, green: 0, blue: 0)
    private let white = Color.linear(red: 1, green: 1, blue: 1)
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
        _ rings: [[SIMD2<Float>]], side: Int? = nil,
        drawing draw: ((Canvas, [[SIMD2<Float>]]) -> Void)? = nil
    ) throws -> Tally {
        let size = side ?? self.size
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

    /// 穴を縦に揃えて並べると、橋の線が別の穴の縦の辺と同じ直線に載り、三角形を取りこぼして
    /// 穴の外まで塗りが欠けた ([#2508])。三角形の取りこぼしは `AlignedHolesTests` が CPU だけで
    /// 数えるので、ここは画素に出ることを 3 場面で 1 回ずつ確かめる (GPU の描画を増やさない)。
    ///
    /// [#2508]: https://github.com/mokume-metal/mokume/issues/2508
    @Test("穴を縦に揃えて並べても、穴だけが抜ける (#2508)", arguments: AlignedScene.all)
    func holesInAColumnAreAllPunched(_ scene: AlignedScene) throws {
        // 穴は外周と逆回り
        let holes = scene.origins.map { origin in
            [
                origin, origin + SIMD2(0, 10), origin + SIMD2(10, 10), origin + SIMD2(10, 0),
            ]
        }
        let result = try tally([square] + holes)
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
        // 穴ごとに 100 画素が抜ける
        #expect(result.painted == 140 * 140 - 100 * holes.count)
    }

    /// 穴は一辺 10 で、26 おきに並べる (外周 10〜150 の中に 5 つ入る)。
    nonisolated struct AlignedScene: CustomTestStringConvertible, Sendable {
        var name: String
        var origins: [SIMD2<Float>]
        var testDescription: String { name }

        static let all: [AlignedScene] = [
            AlignedScene(
                name: "縦 1 列 5 個", origins: (0..<5).map { SIMD2(75, 20 + Float($0) * 26) }),
            AlignedScene(
                name: "5×5 の格子",
                origins: (0..<25).map { SIMD2(20 + Float($0 % 5) * 26, 20 + Float($0 / 5) * 26) }),
            AlignedScene(
                name: "1 つおきに 3 ずらした縦の列",
                origins: (0..<5).map { SIMD2(75 + ($0 % 2 == 1 ? 3 : 0), 20 + Float($0) * 26) }),
        ]
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

    /// 辺を共有する穴 ([#2647])。三角形の面積は `SharedEdgeHolesTests` が CPU だけで数えるので、
    /// ここは画素に出ることを 2 場面で 1 回ずつ確かめる。穴は外周と逆回り (画面の座標で)。
    ///
    /// [#2647]: https://github.com/mokume-metal/mokume/issues/2647
    @Test("辺を共有する 2 つの穴は、穴だけが抜ける (#2647)")
    func holesSharingAnEdgeArePunched() throws {
        func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [SIMD2<Float>] {
            [SIMD2(x0, y0), SIMD2(x0, y1), SIMD2(x1, y1), SIMD2(x1, y0)]
        }
        // 穴 A (30..40 × 30..50) と穴 B (20..40 × 50..80) が、y = 50 の x 30..40 の辺を共有する
        let result = try tally([square, box(30, 30, 40, 50), box(20, 50, 40, 80)])
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
        #expect(result.painted == 140 * 140 - 200 - 600)
    }

    @Test("辺を共有する穴が、別の 2 つの穴の角に触れても、穴だけが抜ける (#2647)")
    func aSharedEdgeBetweenTouchingHolesIsPunched() throws {
        func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [SIMD2<Float>] {
            [SIMD2(x0, y0), SIMD2(x0, y1), SIMD2(x1, y1), SIMD2(x1, y0)]
        }
        // H1 (90..120 × 80..90)・H2 (90..110 × 100..130)・H3 (70..90 × 90..100)・H4 (70..80 × 100..110)。
        // H3 は H1 と H2 の角に触れ、H4 の上辺が H3 の下辺に載る
        let result = try tally([
            square, box(90, 80, 120, 90), box(90, 100, 110, 130), box(70, 90, 90, 100),
            box(70, 100, 80, 110),
        ])
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
        #expect(result.painted == 140 * 140 - 300 - 600 - 200 - 100)
    }

    /// 穴が別の穴の辺の途中に T 字に触れ、離れた穴がもう 1 つ加わる形 ([#2655])。畳んだ周が辺の上の
    /// 点で耳を塞がれて耳切りが途中で止まり、塗りが大きく欠けた。三角形の面積は `TJunctionHolesTests`
    /// が CPU だけで数えるので、ここは画素に出ることを 1 場面で確かめる。座標は #2655 の入力の半分
    /// (穴は外周と逆回りに直してある)。
    ///
    /// [#2655]: https://github.com/mokume-metal/mokume/issues/2655
    @Test("穴が T 字に触れる 2 つに、離れた穴が加わっても、穴だけが抜ける (#2655)")
    func aTJunctionWithAThirdHoleIsPunched() throws {
        let first: [SIMD2<Float>] = [SIMD2(55, 45), SIMD2(45, 50), SIMD2(55, 35)]
        let second: [SIMD2<Float>] = [SIMD2(45, 60), SIMD2(45, 45), SIMD2(40, 55)]
        let third: [SIMD2<Float>] = [SIMD2(40, 70), SIMD2(30, 70), SIMD2(20, 50)]
        // 外周 `square` は画面で時計回り。穴は反時計回りに揃える
        func counterClockwise(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
            let area = (0..<ring.count).reduce(Float(0)) { total, index in
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                return total + a.x * b.y - b.x * a.y
            }
            return area > 0 ? ring.reversed() : ring
        }
        let result = try tally([square] + [first, second, third].map(counterClockwise))
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }

    /// 回した座標の、島を囲む穴 ([#2997])。#2656 の場面 (a) (外周と、T 字で触れ合って島を囲む 2 つの穴) を
    /// 43.3° 回すと、丸めで T 字が厳密には載らず、触れ方を組み直しへ送る判定が外れて、畳む道で島の塗りが
    /// 裏返った (塗りが 44,800 になり、期待の 36,800 を越えた)。CPU の検査 (`RotatedTouchingHolesTests`) の
    /// 写しが Canvas の道と同じ結果になることを、画素で 1 場面だけ確かめる。
    ///
    /// [#2997]: https://github.com/mokume-metal/mokume/issues/2997
    @Test("回した座標で T 字に触れ合って島を囲む穴も、穴だけが抜ける (#2997)")
    func aRotatedIslandIsPunched() throws {
        let rings = (
            [RotatedTouchingHolesTests.outer] + [
                RotatedTouchingHolesTests.arrowhead, RotatedTouchingHolesTests.beamT,
            ]
        ).map { RotatedTouchingHolesTests.rotated($0, by: 43.3) }
        let result = try tally(rings, side: 200)
        #expect(result.missing == 0)
        #expect(result.spilled == 0)
    }

    /// 2 つの穴が 2 点で触れ合って囲んだ島 ([#2656])。島は「穴と穴の間」で、外周と穴の間と同じに塗られる。
    /// 三角形の面積は `IslandHolesTests` が CPU だけで数えるので、ここは画素に出ることを 1 場面で確かめる。
    ///
    /// 穴 A (矢じり) の下の 2 つの角 (60,100)・(140,100) が、穴 B の辺 (40,100)–(160,100) の途中に載る
    /// (T 字)。島は (60,100)(100,80)(140,100)。どちらの穴も外周と逆回り。
    ///
    /// [#2656]: https://github.com/mokume-metal/mokume/issues/2656
    @Test("穴が 2 点で触れ合って囲んだ島は、塗られ、穴の内側だけが抜ける (#2656)")
    func anIslandBetweenTouchingHolesIsPainted() throws {
        let side = 200
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200)]
        let rings = [outer] + IslandHolesTests.tJunctions
        let result = try tally(rings, side: side)
        #expect(result.missing == 0)
        #expect(result.spilled == 0)

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: side, height: side)
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            placeFlat(canvas, rings)
        }
        let pixels = try canvas.target.readPixels()
        func isPainted(_ x: Int, _ y: Int) -> Bool { pixels.components[(y * side + x) * 4] > 0.5 }
        #expect(isPainted(100, 95), "島の内側")
        #expect(!isPainted(100, 70), "穴 A の内側")
        #expect(!isPainted(100, 120), "穴 B の内側")
        #expect(isPainted(100, 30), "穴の外")
    }
}
