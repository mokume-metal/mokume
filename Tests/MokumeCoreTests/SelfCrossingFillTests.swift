// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 周が自分と交わる形・穴が外周を跨ぐ形が、**回り数が 0 でない所** (nonzero) として
/// 塗られるかの検査。GPU を要する ([#1538])。
///
/// **物差しは画素の中心で数えた回り数である** (`ContourFillTests` と同じ)。回り数が 0 で
/// ないことと塗られていることが食い違う画素を数える。縁から 1 画素以内の画素は、
/// ラスタライズの規則しだいでどちらにも転ぶので数えない。
///
/// 耳切りは単純な多角形の手順なので、交わった周をそのまま渡すと、どの規則でも外になる
/// 切れ込みまで塗っていた。
///
/// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
@Suite(
    "自分と交わる周の塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SelfCrossingFillTests {
    private let size = 160

    /// 起票の星。5 点を 1 つ飛ばしに結ぶ。
    private let star: [SIMD2<Float>] = [
        SIMD2(80, 10), SIMD2(121, 137), SIMD2(13, 58), SIMD2(147, 58), SIMD2(39, 137),
    ]

    /// 塗った絵。画素ごとの線形の赤を、上の行から並べる。
    private struct Picture {
        var red: [Float]
        let size: Int

        func value(_ x: Int, _ y: Int) -> Float { red[y * size + x] }
        func isPainted(_ x: Int, _ y: Int) -> Bool { value(x, y) > 0.5 }
    }

    /// 回り数との食い違い。
    private struct Tally {
        /// 回り数 0 なのに塗られた画素。
        var spilled = 0
        /// 回り数が 0 でないのに塗られていない画素。
        var missing = 0
        /// 回り数が ±2 以上の画素と、そのうち塗られた画素。
        var deep = 0
        var deepPainted = 0

        var mismatched: Int { spilled + missing }
    }

    private func picture(_ draw: (Canvas) -> Void) throws -> Picture {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            draw(canvas)
        }
        let pixels = try canvas.target.readPixels()
        var red: [Float] = []
        red.reserveCapacity(size * size)
        for index in 0..<(size * size) { red.append(Float(pixels.components[index * 4])) }
        return Picture(red: red, size: size)
    }

    /// 最初の周を外周、残りを `beginContour` の穴として、平面の `vertex(x, y)` で並べる。
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

    private func tally(_ picture: Picture, _ rings: [[SIMD2<Float>]]) -> Tally {
        var result = Tally()
        for y in 0..<size {
            for x in 0..<size {
                let center = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                if isNearAnEdge(center, rings) { continue }
                let turns = winding(center, rings)
                let painted = picture.isPainted(x, y)
                if turns == 0, painted { result.spilled += 1 }
                if turns != 0, !painted { result.missing += 1 }
                if abs(turns) >= 2 {
                    result.deep += 1
                    if painted { result.deepPainted += 1 }
                }
            }
        }
        return result
    }

    private func tally(_ rings: [[SIMD2<Float>]]) throws -> Tally {
        try tally(picture { placeFlat($0, rings) }, rings)
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
                let length = length_squared(b - a)
                guard length > 0 else {
                    if distance(point, a) <= 1 { return true }
                    continue
                }
                let t = simd_clamp(dot(point - a, b - a) / length, 0, 1)
                if distance(point, a + t * (b - a)) <= 1 { return true }
            }
        }
        return false
    }

    /// 2 辺が端以外で交わる点。端が辺に載るだけなら交わりに数えない。
    private static func crossing(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> SIMD2<Float>? {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let d1 = cross(b - a, c - a)
        let d2 = cross(b - a, d - a)
        let d3 = cross(d - c, a - c)
        let d4 = cross(d - c, b - c)
        guard (d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0),
            (d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)
        else { return nil }
        return a + (d3 / (d3 - d4)) * (b - a)
    }

    /// 周が自分と交わるか (全部の辺の組を見る)。
    private static func crossesItself(_ ring: [SIMD2<Float>]) -> Bool {
        let count = ring.count
        for i in 0..<count {
            for j in (i + 1)..<count {
                let a = ring[i]
                let b = ring[(i + 1) % count]
                let c = ring[j]
                let d = ring[(j + 1) % count]
                if crossing(a, b, c, d) != nil { return true }
            }
        }
        return false
    }

    /// 中心 (80, 80) の {sides/step} の星形。
    private func starPolygon(sides: Int, step: Int, radius: Float) -> [SIMD2<Float>] {
        (0..<sides).map { index in
            let angle = -Float.pi / 2 + Float(index * step) / Float(sides) * 2 * .pi
            return SIMD2<Float>(80, 80) + radius * SIMD2(cos(angle), sin(angle))
        }
    }

    // MARK: - 条件 1・2: 自分と交わる周

    @Test("起票の再現: 5 点の星は、切れ込みを塗らず中の五角形まで塗る")
    func theReportedStarIsFilledAsAStar() throws {
        let drawn = try picture { placeFlat($0, [star]) }
        #expect(!drawn.isPainted(80, 120))  // 下の 2 本の腕の間の切れ込み (回り数 0)
        #expect(drawn.isPainted(80, 80))  // 中の五角形 (回り数 2)

        let result = tally(drawn, [star])
        #expect(result.spilled == 0)
        #expect(result.missing == 0)
        #expect(result.deep == 1560)
        #expect(result.deepPainted == 1560)

        // 5 つの交点で描き直した、交わらない 10 点の凹んだ周と同じ絵になる
        var corners = star
        for i in 0..<5 {
            for j in (i + 1)..<5 {
                if let point = Self.crossing(
                    star[i], star[(i + 1) % 5], star[j], star[(j + 1) % 5])
                {
                    corners.append(point)
                }
            }
        }
        try #require(corners.count == 10)
        let center = SIMD2<Float>(80, 80)
        let outline = corners.sorted {
            atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
        }
        let redrawn = try picture { placeFlat($0, [outline]) }
        var differing = 0
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                if isNearAnEdge(point, [star]) { continue }
                if drawn.isPainted(x, y) != redrawn.isPainted(x, y) { differing += 1 }
            }
        }
        #expect(differing == 0)
    }

    @Test(
        "始点・向き・形を変えても、回り数が 0 でない所だけを塗る",
        arguments: ["3 つ目の点から", "逆向き", "7 点の星", "砂時計", "同じ向きに 2 周する輪"])
    func otherCrossingRingsFollowNonzero(_ name: String) throws {
        let ring: [SIMD2<Float>]
        switch name {
        case "3 つ目の点から": ring = Array(star[2...] + star[..<2])
        case "逆向き": ring = star.reversed()
        case "7 点の星": ring = starPolygon(sides: 7, step: 3, radius: 70)
        case "砂時計":
            ring = [SIMD2(20, 20), SIMD2(140, 20), SIMD2(20, 140), SIMD2(140, 140)]
        default:
            // 半径 60 と 40 の五角形を、同じ向きに続けて 1 つの周にする
            ring =
                starPolygon(sides: 5, step: 1, radius: 60)
                + starPolygon(sides: 5, step: 1, radius: 40)
        }
        let result = try tally([ring])
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
        if name == "同じ向きに 2 周する輪" {
            #expect(result.deep == 3705)
            #expect(result.deepPainted == 3705)
        }
    }

    // MARK: - 条件 3: 外周を跨ぐ穴

    private let square: [SIMD2<Float>] = [
        SIMD2(20, 20), SIMD2(140, 20), SIMD2(140, 140), SIMD2(20, 140),
    ]
    /// 外周と逆回りに並べた、右の辺を跨ぐ三角形。
    private let straddling: [SIMD2<Float>] = [SIMD2(100, 60), SIMD2(100, 100), SIMD2(155, 80)]

    @Test("外周を跨ぐ逆回りの穴は、外周の中で開き、外へ出た先は塗られる")
    func aHoleStraddlingTheOuterRingIsPunched() throws {
        let rings = [square, straddling]
        let drawn = try picture { placeFlat($0, rings) }
        #expect(!drawn.isPainted(110, 80))  // 穴の中 (回り数 0)
        #expect(drawn.isPainted(147, 80))  // 外へ出た先 (回り数 -1)
        let result = tally(drawn, rings)
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    @Test("外周を跨ぐ同じ向きの穴は、重なった所を塗り、外へはみ出さない")
    func aSameDirectionContourStraddlingTheOuterRingIsFilled() throws {
        let rings = [square, straddling.reversed()]
        let drawn = try picture { placeFlat($0, rings) }
        #expect(drawn.isPainted(110, 80))  // 回り数 2
        let result = tally(drawn, rings)
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 外周の外に置いた周と、穴の中に置いた周。交わりは無いが、外周の中に離れた穴が並ぶ
    /// 形ではないので、耳切りへそのまま渡すと形の外まで塗るか、塗る所を塗らない
    /// (既定の書体の `!` の点・`%` の丸を 1 つの形に入れると出る)。
    @Test(
        "外周の外や穴の中に置いた周も、回り数どおりに塗る",
        arguments: ["外周の外 (逆回り)", "外周の外 (同じ向き)", "穴の中", "外周を包む周"])
    func contoursOutsideTheOuterRingFollowNonzero(_ name: String) throws {
        func box(_ low: Float, _ high: Float) -> [SIMD2<Float>] {
            [SIMD2(low, low), SIMD2(high, low), SIMD2(high, high), SIMD2(low, high)]
        }
        let rings: [[SIMD2<Float>]]
        switch name {
        case "外周の外 (逆回り)": rings = [box(20, 70), box(90, 140).reversed()]
        case "外周の外 (同じ向き)": rings = [box(20, 70), box(90, 140)]
        case "穴の中": rings = [box(10, 150), box(40, 120).reversed(), box(60, 100)]
        default: rings = [box(50, 110), box(20, 140).reversed()]
        }
        let result = try tally(rings)
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// いまの手順のまま通る形 (外周の中の、外周と同じ向きの周)。回り数 2 の所として塗る。
    @Test("外周の中に同じ向きに並べた周は、穴にならずに塗られる")
    func aSameDirectionContourInsideIsFilled() throws {
        let outer: [SIMD2<Float>] = [
            SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150),
        ]
        let triangle: [SIMD2<Float>] = [SIMD2(50, 50), SIMD2(110, 60), SIMD2(70, 110)]
        let drawn = try picture { placeFlat($0, [outer, triangle]) }
        #expect(drawn.red.filter { $0 > 0.5 }.count == 19600)  // 矩形まるごと
        let result = tally(drawn, [outer, triangle])
        #expect(result.mismatched == 0)
    }

    // MARK: - 条件 4: 半透明

    @Test("半透明の星は、中の五角形も腕と同じ濃さで 1 度だけ塗る")
    func aTranslucentStarIsPaintedOnce() throws {
        let drawn = try picture { canvas in
            canvas.fill(255, 128)
            placeFlat(canvas, [star])
        }
        let arm = drawn.value(80, 30)
        #expect(arm > 0.4 && arm < 0.6)
        #expect(drawn.value(80, 120) == 0)  // 切れ込みは下地のまま
        #expect(abs(drawn.value(80, 80) - arm) < 0.001)  // 中の五角形は腕と同じ
        #expect(drawn.red.filter { $0 > arm + 0.02 }.count == 0)
    }

    // MARK: - 条件 5: 立体の経路と記録した形

    @Test("奥行きを持つ頂点で並べた星と、記録して置いた星も、平面の星と同じ絵になる")
    func theDepthAndRecordedPathsMatchTheFlatStar() throws {
        let flat = try picture { placeFlat($0, [star]) }
        let withDepth = try picture { canvas in
            canvas.beginShape()
            for point in star { canvas.vertex(point.x, point.y, 0) }
            canvas.endShape(.close)
        }
        let recorded = try picture { canvas in
            let shape = canvas.createShape { placeFlat(canvas, [star]) }
            canvas.shape(shape)
        }
        for (name, drawn) in [("奥行き", withDepth), ("記録", recorded)] {
            #expect(!drawn.isPainted(80, 120), "\(name)")
            #expect(drawn.isPainted(80, 80), "\(name)")
            let result = tally(drawn, [star])
            #expect(result.mismatched == 0, "\(name): はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
            var differing = 0
            for index in flat.red.indices where (flat.red[index] > 0.5) != (drawn.red[index] > 0.5) {
                differing += 1
            }
            #expect(differing == 0, "\(name)")
        }
    }

    // MARK: - 縮退した入力 (反証の指摘 1〜4)

    /// 同じ交わりを幾つもの辺が通る形と、頂点を通って向こう側へ抜ける形。組ごとに求めた
    /// 交点が 1〜2 ulp ずれて周が閉じず、前者は形が丸ごと消えていた。後者は交わりに
    /// 数えられず、耳切りがはみ出していた。
    @Test(
        "同じ交わりを幾つもの辺が通る形や、頂点を通る形も、消えずに nonzero で塗る",
        arguments: [
            "行って戻る棘", "同じ線を逆にたどる", "横の辺が頂点を通る", "斜めの辺に頂点が載る", "縦の辺に頂点が載る",
            "元の辺に交点が 3 つ並ぶ", "触れて戻る 7 点の周", "頂点で触れ合う 2 つの葉",
        ])
    func degenerateCrossingsFollowNonzero(_ name: String) throws {
        let ring: [SIMD2<Float>]
        switch name {
        case "行って戻る棘":
            ring = [SIMD2(80, 100), SIMD2(0, 60), SIMD2(80, 100), SIMD2(0, 40), SIMD2(20, 80)]
        case "同じ線を逆にたどる":
            ring = [SIMD2(20, 40), SIMD2(80, 40), SIMD2(0, 40), SIMD2(0, 60), SIMD2(80, 0)]
        case "横の辺が頂点を通る":
            ring = [SIMD2(40, 40), SIMD2(60, 20), SIMD2(0, 40), SIMD2(100, 40), SIMD2(60, 120)]
        case "斜めの辺に頂点が載る":
            ring = [SIMD2(40, 40), SIMD2(0, 120), SIMD2(120, 0), SIMD2(120, 80), SIMD2(20, 100)]
        case "元の辺に交点が 3 つ並ぶ":
            ring = [
                SIMD2(131, 144), SIMD2(106, 41), SIMD2(90, 78), SIMD2(22, 84), SIMD2(149, 116),
                SIMD2(26, 118), SIMD2(32, 20), SIMD2(132, 45),
            ]
        case "触れて戻る 7 点の周":
            ring = [
                SIMD2(110, 100), SIMD2(80, 120), SIMD2(120, 70), SIMD2(20, 60), SIMD2(80, 120),
                SIMD2(130, 120), SIMD2(150, 60),
            ]
        case "頂点で触れ合う 2 つの葉":
            ring = [
                SIMD2(90, 30), SIMD2(130, 30), SIMD2(130, 130), SIMD2(90, 30), SIMD2(70, 130),
                SIMD2(50, 130), SIMD2(30, 70),
            ]
        default:
            ring = [SIMD2(40, 80), SIMD2(40, 0), SIMD2(20, 80), SIMD2(40, 20), SIMD2(80, 40)]
        }
        let drawn = try picture { placeFlat($0, [ring]) }
        #expect(drawn.red.contains { $0 > 0.5 })
        let result = tally(drawn, [ring])
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 交わらずに触れる形 (#1886)。耳切りと `mergeHoles` が塗り違えていた。
    @Test(
        "交わらずに触れる形も、回り数どおりに塗る",
        arguments: ["穴 2 つ", "外周の角から始まる穴"])
    func touchingShapesFollowNonzero(_ name: String) throws {
        let rings: [[SIMD2<Float>]]
        switch name {
        case "穴 2 つ":
            rings = [
                [
                    SIMD2(70, 83.333336), SIMD2(70, 90), SIMD2(83.333336, 103.33333), SIMD2(80, 110),
                    SIMD2(70, 130), SIMD2(19.23077, 96.15385), SIMD2(10, 110), SIMD2(10, 90), SIMD2(10, 50),
                    SIMD2(23.333332, 50), SIMD2(30, 70), SIMD2(34.615383, 71.53846), SIMD2(26, 50),
                    SIMD2(30, 50), SIMD2(50, 50), SIMD2(42, 62), SIMD2(60, 80),
                ],
                [SIMD2(42, 74), SIMD2(38.571426, 67.14285), SIMD2(35.454544, 71.818184)],
                [SIMD2(23.333332, 90), SIMD2(42, 90), SIMD2(35, 72.5)],
            ]
        default:
            rings = [
                [
                    SIMD2(172.05147, 43.578476), SIMD2(124.36866, 153.69818),
                    SIMD2(14.248955, 106.01538), SIMD2(61.93176, -4.104332),
                ],
                [SIMD2(119.45063, 64.39078), SIMD2(80.28504, 3.842804), SIMD2(14.248955, 106.01538)],
            ]
        }
        let drawn = try picture { placeFlat($0, rings) }
        #expect(drawn.red.contains { $0 > 0.5 })
        let result = tally(drawn, rings)
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 奥行きの経路は、周をひと回りして積んだ向きで平面を決める。砂時計では逆に回る 2 つの
    /// 葉が打ち消し合い、向きが 0 になって何も塗られなかった。
    @Test("奥行きを持つ頂点で並べた砂時計も、平面の砂時計と同じ絵になる")
    func theDepthPathFillsAnHourglass() throws {
        let hourglass: [SIMD2<Float>] = [
            SIMD2(20, 20), SIMD2(140, 20), SIMD2(20, 140), SIMD2(140, 140),
        ]
        let flat = try picture { placeFlat($0, [hourglass]) }
        let withDepth = try picture { canvas in
            canvas.beginShape()
            for point in hourglass { canvas.vertex(point.x, point.y, 0) }
            canvas.endShape(.close)
        }
        let result = tally(withDepth, [hourglass])
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
        var differing = 0
        for index in flat.red.indices where (flat.red[index] > 0.5) != (withDepth.red[index] > 0.5) {
            differing += 1
        }
        #expect(differing == 0)
    }

    @Test("外周と同じ向きに並べた周は、半透明でも外周の中と同じ濃さで 1 度だけ塗る")
    func aTranslucentSameDirectionContourIsPaintedOnce() throws {
        let outer: [SIMD2<Float>] = [
            SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150),
        ]
        let triangle: [SIMD2<Float>] = [SIMD2(50, 50), SIMD2(110, 60), SIMD2(70, 110)]
        let drawn = try picture { canvas in
            canvas.fill(255, 128)
            placeFlat(canvas, [outer, triangle])
        }
        let body = drawn.value(20, 20)
        #expect(body > 0.4 && body < 0.6)
        #expect(abs(drawn.value(75, 70) - body) < 0.001)  // 三角形の中 (回り数 2)
        #expect(drawn.red.filter { $0 > body + 0.02 }.count == 0)
    }

    // MARK: - 条件 6: 字の輪郭

    /// 既定の書体で、自分と交わる周を 1 つずつ塗る。**どの字が交わるかは書体の版で
    /// 変わりうる**ので、字を決め打ちせず、交わる周を探して選ぶ。
    @Test("既定の書体の、自分と交わる字の周を塗っても欠けない")
    func selfCrossingGlyphContoursAreFilledWhole() throws {
        let probe = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        probe.textSize(150)
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789&%@$#?!"
        var checked = 0
        for character in characters {
            for contour in probe.textOutline(String(character), 0, 0)
            where Self.crossesItself(contour.points) {
                let ring = centered([contour.points])
                let result = try tally(ring)
                checked += 1
                #expect(
                    result.mismatched == 0,
                    "\(character): はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
            }
        }
        // 1 つも交わらない書体では、この検査は何も見ていない
        #expect(checked > 0)
    }

    @Test("既定の書体の字を 1 つの形 (外周 + 残りを穴) で塗っても、重なりが抜けない", arguments: ["A", "B"])
    func glyphPartsInOneShapeFollowNonzero(_ character: String) throws {
        let probe = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        probe.textSize(120)
        let rings = centered(probe.textOutline(character, 0, 0).map(\.points))
        try #require(rings.count >= 2)
        let result = try tally(rings)
        #expect(result.mismatched == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 周の組を、囲みの箱の中心が面の中心に来るようにずらす。
    private func centered(_ rings: [[SIMD2<Float>]]) -> [[SIMD2<Float>]] {
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for ring in rings {
            for point in ring {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
        }
        let offset = SIMD2<Float>(Float(size) / 2, Float(size) / 2) - (low + high) / 2
        return rings.map { ring in ring.map { $0 + offset } }
    }
}
