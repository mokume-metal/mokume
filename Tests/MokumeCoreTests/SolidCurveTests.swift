// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 奥行き `z` を持つ曲線 (`bezierVertex` の 9 つの数・`quadraticVertex` の 6 つの数・`curveVertex(x, y, z)`・
/// 12 の数の `bezier()`・`curve()` と、`Vector3` のラベル付きの形) の絵 ([#3712])。GPU を要する。
///
/// 立体の曲線は、刻んだ点を `vertex(x, y, z)` で並べたのと同じ道を通る約束 (ADR-0021 決定 5) なので、
/// **同じ曲線を `curveDetail` の刻みで式から求めた点を `vertex(x, y, z)` で並べた絵と画素で比べる**。
/// 曲線の刻みの点は折れ目の形によらず円板で繋がる (``BuildingVertex/isCurveStep``) ので、比べる側は
/// 折れ目を丸 (`strokeJoin(.round)`) にする。比べる絵が背景だけなら何も見ていないので、背景と違うことも見る。
///
/// [#3712]: https://github.com/mokume-metal/mokume/issues/3712
@Suite(
    "奥行きを持つ曲線",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidCurveTests {
    private static let size = 200

    /// 面の中心の上手前から斜めに見下ろす視点 (``SolidLineAndGuideTests`` と同じ視点を、
    /// 完了条件 1 の曲線 (x が 100…250) が収まるよう右へずらしたもの)。
    private static func lookDown(_ canvas: Canvas) {
        canvas.camera(230, -80, 300, 175, 100, -40, 0, 1, 0)
    }

    private static let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 見下ろす視点で、背景を塗ってから `scene` を描いた絵。
    private func picture(_ scene: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(Self.black)
            Self.lookDown(canvas)
            canvas.noFill()
            canvas.stroke(.display(red: 1, green: 0.7, blue: 0.35))
            canvas.strokeWeight(4)
            canvas.strokeJoin(.round)
            scene(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func blank() throws -> DisplayImage { try picture { _ in } }

    /// 3 次の曲線の上の点 (手本の式)。
    private static func cubic(_ p0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ p1: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// 通過点を結ぶ曲線の上の点 (一様 Catmull-Rom に張りを掛けた式)。
    private static func catmullRom(
        _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float, tightness: Float = 0
    ) -> SIMD3<Float> {
        let s = (1 - tightness) / 2
        let t2 = t * t
        let t3 = t2 * t
        let m1 = (p2 - p0) * s
        let m2 = (p3 - p1) * s
        return p1 * (2 * t3 - 3 * t2 + 1) + m1 * (t3 - 2 * t2 + t) + p2 * (-2 * t3 + 3 * t2) + m2 * (t3 - t2)
    }

    /// 刻んだ点を `vertex(x, y, z)` で並べる。
    private static func polyline(_ canvas: Canvas, _ points: [SIMD3<Float>]) {
        canvas.beginShape()
        for point in points { canvas.vertex(point.x, point.y, point.z) }
        canvas.endShape()
    }

    private static func steps(_ detail: Int, _ point: (Float) -> SIMD3<Float>) -> [SIMD3<Float>] {
        (1...detail).map { point(Float($0) / Float(detail)) }
    }

    // 完了条件 1 の曲線
    private static let start = SIMD3<Float>(100, 100, 0)
    private static let control1 = SIMD3<Float>(150, 100, -80)
    private static let control2 = SIMD3<Float>(200, 100, -80)
    private static let end = SIMD3<Float>(250, 100, 0)

    private static var bezierPoints: [SIMD3<Float>] {
        [start] + steps(20) { cubic(start, control1, control2, end, $0) }
    }

    // MARK: - 完了条件 1

    @Test("9 つの数の bezierVertex は、刻んだ点を vertex(x, y, z) で並べた絵と画素が一致する")
    func bezierVertexMatchesVertices() throws {
        let curve = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.bezierVertex(150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.endShape()
        }
        let vertices = try picture { Self.polyline($0, Self.bezierPoints) }
        #expect(curve != (try blank()), "9 つの数の bezierVertex が何も描いていない")
        #expect(curve == vertices)
    }

    /// 奥行きに従って動くこと: 同じ x・y で奥行きの無い平面の曲線とは、見下ろすと違う絵になる。
    @Test("見下ろすと、奥行きを持つ曲線は同じ x・y の平面の曲線と違う絵になる")
    func bezierVertexFollowsDepth() throws {
        let solid = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.bezierVertex(150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.endShape()
        }
        let flat = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.bezierVertex(150, 100, 0, 200, 100, 0, 250, 100, 0)
            canvas.endShape()
        }
        #expect(solid != flat, "奥行きが絵に出ていない")
    }

    /// 刻みが効いていること (上の一致が、刻みを無視したまま一致しているのでないこと)。
    @Test("curveDetail の刻みが、9 つの数の bezierVertex にも効く")
    func curveDetailTakesEffect() throws {
        let coarse = try picture { canvas in
            canvas.curveDetail(3)
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.bezierVertex(150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.endShape()
        }
        let vertices = try picture { canvas in
            Self.polyline(canvas, [Self.start] + Self.steps(3) { Self.cubic(Self.start, Self.control1, Self.control2, Self.end, $0) })
        }
        let fine = try picture { Self.polyline($0, Self.bezierPoints) }
        #expect(coarse == vertices)
        #expect(coarse != fine)
    }

    // MARK: - 完了条件 2

    @Test("6 つの数の quadraticVertex は、同じ 2 次の曲線を刻んだ点と画素が一致する")
    func quadraticVertexMatchesVertices() throws {
        let control = SIMD3<Float>(175, 60, -120)
        let curve = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.quadraticVertex(175, 60, -120, 250, 100, 0)
            canvas.endShape()
        }
        // 2 次は 3 次の制御点へ直して刻む (平面の形と同じ)
        let c1 = Self.start + (control - Self.start) * (2.0 / 3.0)
        let c2 = Self.end + (control - Self.end) * (2.0 / 3.0)
        let vertices = try picture { Self.polyline($0, [Self.start] + Self.steps(20) { Self.cubic(Self.start, c1, c2, Self.end, $0) }) }
        #expect(curve != (try blank()), "6 つの数の quadraticVertex が何も描いていない")
        #expect(curve == vertices)
    }

    private static let guides: [SIMD3<Float>] = [
        SIMD3(60, 160, 40), SIMD3(110, 100, 0), SIMD3(220, 120, -100), SIMD3(260, 40, -40),
    ]

    private static var catmullRomPoints: [SIMD3<Float>] {
        [guides[1]] + steps(20) { catmullRom(guides[0], guides[1], guides[2], guides[3], $0) }
    }

    @Test("curveVertex(x, y, z) を 4 つ置くと、間の 1 区間を刻んだ点と画素が一致する")
    func curveVertexMatchesVertices() throws {
        let curve = try picture { canvas in
            canvas.beginShape()
            for guide in Self.guides { canvas.curveVertex(guide.x, guide.y, guide.z) }
            canvas.endShape()
        }
        let vertices = try picture { Self.polyline($0, Self.catmullRomPoints) }
        #expect(curve != (try blank()), "curveVertex(x, y, z) が何も描いていない")
        #expect(curve == vertices)
    }

    @Test("curveTightness の張りが、curveVertex(x, y, z) にも効く")
    func curveTightnessTakesEffect() throws {
        let tight = try picture { canvas in
            canvas.curveTightness(0.6)
            canvas.beginShape()
            for guide in Self.guides { canvas.curveVertex(guide.x, guide.y, guide.z) }
            canvas.endShape()
        }
        let g = Self.guides
        let vertices = try picture { canvas in
            Self.polyline(canvas, [g[1]] + Self.steps(20) { Self.catmullRom(g[0], g[1], g[2], g[3], $0, tightness: 0.6) })
        }
        let loose = try picture { Self.polyline($0, Self.catmullRomPoints) }
        #expect(tight == vertices)
        #expect(tight != loose)
    }

    @Test("12 の数の bezier は、beginShape・vertex(x, y, z)・9 つの数の bezierVertex・endShape と画素が一致する")
    func bezierMatchesSpelledShape() throws {
        let single = try picture { $0.bezier(100, 100, 0, 150, 100, -80, 200, 100, -80, 250, 100, 0) }
        let vertices = try picture { Self.polyline($0, Self.bezierPoints) }
        #expect(single != (try blank()), "12 の数の bezier が何も描いていない")
        #expect(single == vertices)
    }

    /// 完了条件への追加 (2026-11-10): 12 の数の `curve()` は、同じ 4 点を `curveVertex(x, y, z)` で 4 回置いた絵。
    @Test("12 の数の curve は、同じ 4 点を curveVertex(x, y, z) で 4 回置いた絵と画素が一致する")
    func curveMatchesCurveVertices() throws {
        let g = Self.guides
        let single = try picture { $0.curve(g[0].x, g[0].y, g[0].z, g[1].x, g[1].y, g[1].z, g[2].x, g[2].y, g[2].z, g[3].x, g[3].y, g[3].z) }
        let spelled = try picture { canvas in
            canvas.beginShape()
            for guide in g { canvas.curveVertex(guide.x, guide.y, guide.z) }
            canvas.endShape()
        }
        #expect(single != (try blank()), "12 の数の curve が何も描いていない")
        #expect(single == spelled)
    }

    // MARK: - Vector3 のラベル付きの形 (完了条件への追加)

    @Test("Vector3 のラベル付きの形は、数の形に同じ値を渡した絵と画素が一致する")
    func labelledFormsMatchNumbers() throws {
        let (a, c1, c2, b) = (Vector3(Self.start), Vector3(Self.control1), Vector3(Self.control2), Vector3(Self.end))
        #expect(
            try picture { $0.bezier(from: a, control1: c1, control2: c2, to: b) }
                == picture { $0.bezier(100, 100, 0, 150, 100, -80, 200, 100, -80, 250, 100, 0) })
        #expect(
            try picture { canvas in
                canvas.beginShape()
                canvas.vertex(100, 100, 0)
                canvas.bezierVertex(control1: c1, control2: c2, to: b)
                canvas.endShape()
            }
                == picture { canvas in
                    canvas.beginShape()
                    canvas.vertex(100, 100, 0)
                    canvas.bezierVertex(150, 100, -80, 200, 100, -80, 250, 100, 0)
                    canvas.endShape()
                })
        #expect(
            try picture { canvas in
                canvas.beginShape()
                canvas.vertex(100, 100, 0)
                canvas.quadraticVertex(control: Vector3(175, 60, -120), to: b)
                canvas.endShape()
            }
                == picture { canvas in
                    canvas.beginShape()
                    canvas.vertex(100, 100, 0)
                    canvas.quadraticVertex(175, 60, -120, 250, 100, 0)
                    canvas.endShape()
                })
        // curve(from:control1:control2:to:) は描く区間の両端を from・to に取る (平面の形と同じ並び)
        let g = Self.guides.map(Vector3.init)
        let labelled = try picture { $0.curve(from: g[1], control1: g[0], control2: g[3], to: g[2]) }
        #expect(labelled != (try blank()), "ラベル付きの curve が何も描いていない")
        #expect(
            labelled
                == (try picture {
                    $0.curve(g[0].x, g[0].y, g[0].z, g[1].x, g[1].y, g[1].z, g[2].x, g[2].y, g[2].z, g[3].x, g[3].y, g[3].z)
                }))
    }

    // MARK: - 完了条件 3・4: 平面の形と、平面の点との混ぜ方

    /// 奥行きが 0 の曲線は、x・y を平面の形と同じ式で刻む (刻んだ点が平面の形と同じ位置に並ぶ)。
    @Test("奥行きが 0 の曲線の刻みの点は、平面の形の刻みの点と x・y が同じで、奥行きを持つ")
    func zeroDepthPlacesTheFlatPoints() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        func built(_ body: () -> Void) throws -> (points: [SIMD3<Float>], hasDepth: Bool) {
            var result: (points: [SIMD3<Float>], hasDepth: Bool) = ([], false)
            try canvas.draw {
                canvas.beginShape()
                body()
                result = (canvas.shapePoints.map(\.position), canvas.shapeHasDepth)
                canvas.endShape()
            }
            return result
        }
        let pairs: [(String, () -> Void, () -> Void)] = [
            ("bezierVertex", {
                canvas.vertex(4, 50)
                canvas.bezierVertex(10, 4, 50, 8, 60, 58)
            }, {
                canvas.vertex(4, 50)
                canvas.bezierVertex(10, 4, 0, 50, 8, 0, 60, 58, 0)
            }),
            ("quadraticVertex", {
                canvas.vertex(4, 50)
                canvas.quadraticVertex(30, 2, 60, 58)
            }, {
                canvas.vertex(4, 50)
                canvas.quadraticVertex(30, 2, 0, 60, 58, 0)
            }),
            ("curveVertex", {
                canvas.curveVertex(2, 60)
                canvas.curveVertex(10, 10)
                canvas.curveVertex(50, 40)
                canvas.curveVertex(62, 4)
            }, {
                canvas.curveVertex(2, 60, 0)
                canvas.curveVertex(10, 10, 0)
                canvas.curveVertex(50, 40, 0)
                canvas.curveVertex(62, 4, 0)
            }),
        ]
        for (name, flat, solid) in pairs {
            let flatShape = try built(flat)
            let solidShape = try built(solid)
            #expect(!flatShape.hasDepth, "\(name): 平面の形が立体になった")
            #expect(solidShape.hasDepth, "\(name): 奥行きを持つ形が立体にならない")
            #expect(flatShape.points.count > 4, "\(name): 刻まれていない")
            #expect(flatShape.points == solidShape.points, "\(name): 刻みの点の位置が違う")
        }
    }

    /// `vertex(x, y)` の後の 9 つの数の `bezierVertex` は、`vertex(x, y)` と `vertex(x, y, z)` を混ぜたのと同じ —
    /// 平面の点は `z` = 0 の始点になり、形は立体になる。
    @Test("平面の点から始めた 9 つの数の bezierVertex は、vertex(x, y) と vertex(x, y, z) を混ぜた絵と一致する")
    func mixesWithFlatVertexLikeVertex() throws {
        let mixed = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100)
            canvas.bezierVertex(150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.endShape()
        }
        let vertices = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(100, 100)
            for point in Self.bezierPoints.dropFirst() { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        #expect(mixed == vertices)
    }

    /// 平面の `curveVertex(x, y)` と奥行きを持つ `curveVertex(x, y, z)` を 1 つの並びに混ぜると、平面の点を
    /// `z` = 0 の点として刻む (`vertex(x, y)` と同じ読み方)。
    @Test("curveVertex の平面の点と奥行きを持つ点を混ぜると、平面の点を z = 0 として刻む")
    func mixedCurveGuidesReadFlatPointsAtZeroDepth() throws {
        let g = Self.guides
        let mixed = try picture { canvas in
            canvas.beginShape()
            canvas.curveVertex(g[0].x, g[0].y)
            canvas.curveVertex(g[1].x, g[1].y)
            canvas.curveVertex(g[2].x, g[2].y, g[2].z)
            canvas.curveVertex(g[3].x, g[3].y, g[3].z)
            canvas.endShape()
        }
        let (p0, p1) = (SIMD3(g[0].x, g[0].y, 0), SIMD3(g[1].x, g[1].y, 0))
        let vertices = try picture { canvas in
            Self.polyline(canvas, [p1] + Self.steps(20) { Self.catmullRom(p0, p1, g[2], g[3], $0) })
        }
        #expect(mixed == vertices)
    }

    /// 上の検査は手前に点が無いので、平面の通過点を「手前の点の奥行き」として読んでも 0 になり、見分けられない。
    /// 手前に奥行きを持つ点 (`z` = 50) を置き、混ぜた並びの平面の通過点が手前の奥行きでなく `z` = 0 として
    /// 刻まれることを、置かれた点の位置で見る。
    @Test("奥行きを持つ点の後でも、混ぜた curveVertex の平面の点は手前の奥行きでなく z = 0 として刻む")
    func mixedCurveGuidesIgnoreTheDepthOfThePointBefore() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        let g = Self.guides
        var placed: [SIMD3<Float>] = []
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(20, 20, 50)
            canvas.curveVertex(g[0].x, g[0].y)
            canvas.curveVertex(g[1].x, g[1].y)
            canvas.curveVertex(g[2].x, g[2].y, g[2].z)
            canvas.curveVertex(g[3].x, g[3].y, g[3].z)
            placed = canvas.shapePoints.map(\.position)
            canvas.endShape()
        }
        let (p0, p1) = (SIMD3(g[0].x, g[0].y, 0), SIMD3(g[1].x, g[1].y, 0))
        let expected = [SIMD3<Float>(20, 20, 50), p1] + Self.steps(20) { Self.catmullRom(p0, p1, g[2], g[3], $0) }
        #expect(placed.count == expected.count)
        let worst = zip(placed, expected).map { simd_length($0.0 - $0.1) }.max() ?? .infinity
        #expect(worst < 1e-3, "刻みの点が z = 0 の平面の点から求めた位置と \(worst) ずれている")
    }

    /// 形を組んだ後の外周と穴の点の位置 (描かずに読む)。
    private struct BuiltPoints: Equatable {
        var outer: [SIMD3<Float>]
        var holes: [[SIMD3<Float>]]
    }

    private static func built(_ canvas: Canvas, _ body: () -> Void) throws -> BuiltPoints {
        var result = BuiltPoints(outer: [], holes: [])
        try canvas.draw {
            canvas.beginShape()
            body()
            result = BuiltPoints(
                outer: canvas.shapePoints.map(\.position), holes: canvas.shapeHoles.map { $0.map(\.position) })
            canvas.endShape()
        }
        return result
    }

    /// 案 a の規則 (#3712 の 2026-11-14 の決定とその補足): **平面の曲線の API は、奥行きを持つ曲線の API に
    /// z = 0 を渡したのと同じ絵になる** (`vertex(x, y)` ≡ `vertex(x, y, 0)` と同じ形)。奥行きを持つ形の中で、
    /// 平面の API で置いた並びと、同じ並びを z = 0 つきの奥行きを持つ API で置いた並びが、点の位置と数まで一致する。
    @Test("奥行きを持つ形の中の平面の曲線は、奥行きを持つ曲線の API に z = 0 を渡したのと同じ点を置く")
    func flatCurveEqualsSolidCurveAtZeroDepth() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        let cases: [(String, () -> Void, () -> Void)] = [
            ("bezierVertex・始点が奥行きを持つ", {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(10, 4, 50, 8, 60, 58)
            }, {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(10, 4, 0, 50, 8, 0, 60, 58, 0)
            }),
            ("quadraticVertex・始点が奥行きを持つ", {
                canvas.vertex(4, 50, -30)
                canvas.quadraticVertex(30, 2, 60, 58)
            }, {
                canvas.vertex(4, 50, -30)
                canvas.quadraticVertex(30, 2, 0, 60, 58, 0)
            }),
            ("ラベル付きの形・始点が奥行きを持つ", {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(control1: Vector2(10, 4), control2: Vector2(50, 8), to: Vector2(60, 58))
                canvas.vertex(20, 20, 40)
                canvas.quadraticVertex(control: Vector2(30, 2), to: Vector2(60, 58))
            }, {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(control1: Vector3(10, 4, 0), control2: Vector3(50, 8, 0), to: Vector3(60, 58, 0))
                canvas.vertex(20, 20, 40)
                canvas.quadraticVertex(control: Vector3(30, 2, 0), to: Vector3(60, 58, 0))
            }),
            ("bezierVertex・始点が平面の点で、形は奥行きを持つ", {
                canvas.vertex(30, 30, 20)
                canvas.vertex(4, 50)
                canvas.bezierVertex(10, 4, 50, 8, 60, 58)
                canvas.quadraticVertex(30, 2, 4, 50)
            }, {
                canvas.vertex(30, 30, 20)
                canvas.vertex(4, 50)
                canvas.bezierVertex(10, 4, 0, 50, 8, 0, 60, 58, 0)
                canvas.quadraticVertex(30, 2, 0, 4, 50, 0)
            }),
            ("曲線を続ける (2 つ目の始点は 1 つ目の終点)", {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(10, 4, 50, 8, 60, 58)
                canvas.quadraticVertex(30, 2, 4, 50)
            }, {
                canvas.vertex(4, 50, -30)
                canvas.bezierVertex(10, 4, 0, 50, 8, 0, 60, 58, 0)
                canvas.quadraticVertex(30, 2, 0, 4, 50, 0)
            }),
            ("curveVertex・4 点とも平面", {
                canvas.vertex(4, 50, -30)
                canvas.curveVertex(2, 60)
                canvas.curveVertex(10, 10)
                canvas.curveVertex(50, 40)
                canvas.curveVertex(62, 4)
            }, {
                canvas.vertex(4, 50, -30)
                canvas.curveVertex(2, 60, 0)
                canvas.curveVertex(10, 10, 0)
                canvas.curveVertex(50, 40, 0)
                canvas.curveVertex(62, 4, 0)
            }),
            // 反証役の例: 1 本目の区間は 4 点とも平面、2 本目は奥行きを持つ点をまたぐ
            ("curveVertex・窓が平面の点と奥行きを持つ点をまたぐ", {
                canvas.vertex(0, 0, 50)
                canvas.curveVertex(4, 40)
                canvas.curveVertex(16, 20)
                canvas.curveVertex(36, 44)
                canvas.curveVertex(52, 12)
                canvas.curveVertex(60, 50, -10)
            }, {
                canvas.vertex(0, 0, 50)
                canvas.curveVertex(4, 40, 0)
                canvas.curveVertex(16, 20, 0)
                canvas.curveVertex(36, 44, 0)
                canvas.curveVertex(52, 12, 0)
                canvas.curveVertex(60, 50, -10)
            }),
            ("curveVertex・始点の x・y が手前の点と同じで z だけ違う", {
                canvas.vertex(10, 10, -30)
                canvas.curveVertex(2, 60)
                canvas.curveVertex(10, 10)
                canvas.curveVertex(50, 40)
                canvas.curveVertex(62, 4)
            }, {
                canvas.vertex(10, 10, -30)
                canvas.curveVertex(2, 60, 0)
                canvas.curveVertex(10, 10, 0)
                canvas.curveVertex(50, 40, 0)
                canvas.curveVertex(62, 4, 0)
            }),
            ("穴 (beginContour) の中", {
                for (x, y) in [(0, 0), (64, 0), (64, 64), (0, 64)] as [(Float, Float)] { canvas.vertex(x, y, 10) }
                canvas.beginContour()
                canvas.vertex(20, 20, 10)
                canvas.bezierVertex(30, 10, 44, 30, 44, 44)
                canvas.quadraticVertex(30, 50, 20, 44)
                canvas.endContour()
            }, {
                for (x, y) in [(0, 0), (64, 0), (64, 64), (0, 64)] as [(Float, Float)] { canvas.vertex(x, y, 10) }
                canvas.beginContour()
                canvas.vertex(20, 20, 10)
                canvas.bezierVertex(30, 10, 0, 44, 30, 0, 44, 44, 0)
                canvas.quadraticVertex(30, 50, 0, 20, 44, 0)
                canvas.endContour()
            }),
        ]
        for (name, flat, solid) in cases {
            let flatShape = try Self.built(canvas, flat)
            let solidShape = try Self.built(canvas, solid)
            #expect(flatShape.outer.count + flatShape.holes.joined().count > 10, "\(name): 刻まれていない")
            #expect(flatShape == solidShape, "\(name): 平面の API と z = 0 を渡した奥行きを持つ API で点が違う")
        }
    }

    /// 上の同値の中身: 奥行きを持つ点の後の平面の `bezierVertex` は、その点から z = 0 の制御点・終点へ向かって
    /// 滑らかに下りる 1 本の曲線になる。期待は検査の側の式 (``cubic(_:_:_:_:_:)``) で求める。
    @Test("奥行きを持つ点の後の平面の bezierVertex は、手前の点から z = 0 へ滑らかに下りる")
    func flatBezierAfterSolidPointDescendsToZeroDepth() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        let points = try Self.built(canvas) {
            canvas.vertex(4, 50, -30)
            canvas.bezierVertex(10, 4, 50, 8, 60, 58)
        }.outer
        let start = SIMD3<Float>(4, 50, -30)
        let expected = [start] + Self.steps(20) { Self.cubic(start, SIMD3(10, 4, 0), SIMD3(50, 8, 0), SIMD3(60, 58, 0), $0) }
        #expect(points.count == expected.count)
        let worst = zip(points, expected).map { simd_length($0.0 - $0.1) }.max() ?? .infinity
        #expect(worst < 1e-3, "刻みの点が、手前の点から始まる z = 0 の制御点の曲線と \(worst) ずれている")
        // 最初の刻みはまだ奥にあり (z = 0 へ跳ばない)、奥行きは終点の 0 まで単調に戻る
        #expect(points[1].z < -20, "最初の刻みで奥行きが跳んだ: \(points[1].z)")
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.0.z <= $0.1.z }, "奥行きが単調に戻らない: \(points.map(\.z))")
        #expect(points.last?.z == 0)
    }

    /// 並びの最初の区間の始点 (2 つ目の通過点) は、環の最後の点と**奥行きまで**同じときだけ置き直さない (#1537)。
    /// x・y が同じで z だけ違う手前の点の後では、始点を置く — 4 点とも平面の区間でも、奥行きを持つ点を含む区間でも。
    @Test("通過点の始点が手前の点と x・y だけ同じなら、始点を置き直す (奥行きまで同じなら置き直さない)")
    func curveStartIsComparedWithDepth() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        let cases: [(String, before: SIMD3<Float>, guides: [SIMD3<Float>], hasDepth: Bool, placesStart: Bool)] = [
            ("平面の区間・z だけ違う", SIMD3(10, 10, -30), [SIMD3(2, 60, 0), SIMD3(10, 10, 0), SIMD3(50, 40, 0), SIMD3(62, 4, 0)], false, true),
            ("奥行きを持つ区間・z だけ違う", SIMD3(10, 10, -30), [SIMD3(2, 60, 0), SIMD3(10, 10, 0), SIMD3(50, 40, 5), SIMD3(62, 4, 5)], true, true),
            ("奥行きを持つ区間・奥行きまで同じ", SIMD3(10, 10, 5), [SIMD3(2, 60, 0), SIMD3(10, 10, 5), SIMD3(50, 40, 5), SIMD3(62, 4, 5)], true, false),
        ]
        for (name, before, guides, hasDepth, placesStart) in cases {
            let points = try Self.built(canvas) {
                canvas.vertex(before.x, before.y, before.z)
                for guide in guides {
                    if hasDepth { canvas.curveVertex(guide.x, guide.y, guide.z) } else { canvas.curveVertex(guide.x, guide.y) }
                }
            }.outer
            #expect(points.count == 1 + (placesStart ? 1 : 0) + 20, "\(name): 点の数が違う: \(points.count)")
            if placesStart, points.count > 1 { #expect(points[1] == guides[1], "\(name): 始点の位置が違う: \(points[1])") }
        }
    }

    /// 反証役の例: 奥行きを持つ点の後に平面の通過点を 4 つ、続けて奥行きを持つ通過点を 1 つ置く。1 本目の区間
    /// (4 点とも平面) と 2 本目の区間 (奥行きを持つ点が入る) が、共有する通過点を同じ奥行きで読む — 線が跳ばない。
    @Test("平面の通過点の後に奥行きを持つ通過点を足しても、共有する通過点の奥行きは 2 つの区間で同じ (線が跳ばない)")
    func sharedGuideKeepsOneDepthAcrossSegments() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        let flat: [SIMD2<Float>] = [SIMD2(4, 40), SIMD2(16, 20), SIMD2(36, 44), SIMD2(52, 12)]
        let solid = SIMD3<Float>(60, 50, -10)
        var placed: [SIMD3<Float>] = []
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(0, 0, 50)
            for point in flat { canvas.curveVertex(point.x, point.y) }
            canvas.curveVertex(solid.x, solid.y, solid.z)
            placed = canvas.shapePoints.map(\.position)
            canvas.endShape()
        }
        let g = flat.map { SIMD3($0.x, $0.y, 0) }
        let first = Self.steps(20) { Self.catmullRom(g[0], g[1], g[2], g[3], $0) }
        let second = Self.steps(20) { Self.catmullRom(g[1], g[2], g[3], solid, $0) }
        let expected = [SIMD3<Float>(0, 0, 50), g[1]] + first + second
        #expect(placed.count == expected.count)
        let worst = zip(placed, expected).map { simd_length($0.0 - $0.1) }.max() ?? .infinity
        #expect(worst < 1e-3, "置かれた点が z = 0 の通過点から求めた位置と \(worst) ずれている")
        // 1 本目の終わり (通過点 g[2]) と、2 本目の最初の刻みの間で奥行きが跳ばない
        let joint = 2 + first.count - 1
        #expect(placed[joint].z == 0, "1 本目の区間が通過点に着く奥行きが 0 でない: \(placed[joint].z)")
        #expect(abs(placed[joint + 1].z - placed[joint].z) < 1, "2 本目の区間の最初の刻みで奥行きが跳んだ")
    }

    /// 「奥行きを持つ形の中」の判定は、点を置く順に依らない。平面の曲線を先に置き、後から奥行きを持つ点が
    /// 来て初めて形が立体になる並びでも、先に置いた平面の曲線の点は `z` = 0 のまま (始点も渡した点も z = 0)。
    /// 奥行きを持つ点の後の平面の曲線は、z = 0 を渡した奥行きを持つ API と同じ点になる。
    @Test("平面の曲線を先に置き、後から奥行きを持つ点を置いても、先の平面の曲線の点は z = 0 のまま")
    func flatCurveBeforeSolidPointStaysAtZeroDepth() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        var hasDepth = false
        let points = try Self.built(canvas) {
            canvas.vertex(4, 50)
            canvas.bezierVertex(10, 4, 50, 8, 60, 58)
            canvas.vertex(30, 30, 20)
            canvas.bezierVertex(40, 10, 50, 20, 60, 40)
            hasDepth = canvas.shapeHasDepth
        }.outer
        let solid = try Self.built(canvas) {
            canvas.vertex(4, 50)
            canvas.bezierVertex(10, 4, 50, 8, 60, 58)
            canvas.vertex(30, 30, 20)
            canvas.bezierVertex(40, 10, 0, 50, 20, 0, 60, 40, 0)
        }.outer
        #expect(hasDepth)
        #expect(points.count == 42)
        #expect(points[..<21].allSatisfy { $0.z == 0 }, "先の平面の曲線の点が z = 0 でない: \(points.map(\.z))")
        #expect(points[21] == SIMD3(30, 30, 20))
        #expect(points == solid)
    }

    /// 記録した形 (`createShape`) を置いても (`shape(_:)`・`shape(_:at:)`)、同じ規則の絵になる (`endShape(.close)` で
    /// 閉じても)。比べる先は、手前の奥行きを持つ点から z = 0 の制御点・終点へ向かう曲線を、検査の側の式で刻んで
    /// `vertex(x, y, z)` で明示して並べた絵。
    @Test("記録した形でも、閉じた形でも、奥行きを持つ点の後の平面の曲線は z = 0 を渡した曲線の点を並べた絵と同じ")
    func recordedShapeFollowsTheSameRule() throws {
        let start = SIMD3<Float>(100, 100, 40)
        let (c1, c2, end) = (SIMD3<Float>(150, 60, 0), SIMD3<Float>(200, 140, 0), SIMD3<Float>(250, 100, 0))
        for close in [ShapeEnd.open, .close] {
            func mixed(_ canvas: Canvas) {
                canvas.beginShape()
                canvas.vertex(start.x, start.y, start.z)
                canvas.bezierVertex(c1.x, c1.y, c2.x, c2.y, end.x, end.y)
                canvas.endShape(close)
            }
            let explicit = try picture { canvas in
                canvas.beginShape()
                canvas.vertex(start.x, start.y, start.z)
                for p in Self.steps(20, { Self.cubic(start, c1, c2, end, $0) }) { canvas.vertex(p.x, p.y, p.z) }
                canvas.endShape(close)
            }
            let direct = try picture(mixed)
            let recorded = try picture { canvas in canvas.shape(canvas.createShape { mixed(canvas) }) }
            let placed = try picture { canvas in
                canvas.shape(canvas.createShape { mixed(canvas) }, at: [Placement(x: 0, y: 0)])
            }
            #expect(direct != (try blank()), "混ぜた形が何も描いていない")
            #expect(direct == explicit, "\(close)")
            #expect(recorded == explicit, "\(close)")
            #expect(placed == explicit, "\(close)")
        }
    }

    // MARK: - 形の外・始点の無いとき

    @Test("手前に点の無い 9 つの数の bezierVertex は何もせず、平面の形と同じ注意を 1 度だけ言う")
    func withoutStartDoesNothing() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        try canvas.draw {
            canvas.beginShape()
            canvas.bezierVertex(1, 2, 3, 4, 5, 6, 7, 8, 9)
            canvas.quadraticVertex(1, 2, 3, 4, 5, 6)
            #expect(canvas.shapePoints.isEmpty)
            canvas.endShape()
        }
        #expect(canvas.warnings.hasWarned(.curveWithoutStart))
    }

    @Test("フレームの外の 12 の数の bezier・curve は、何も描かず 1 度だけ注意する")
    func outsideAFrameDoesNothing() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: 64, height: 64)
        canvas.beginDraw()
        canvas.endDraw()
        canvas.bezier(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
        canvas.curve(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
        #expect(canvas.batches.isEmpty)
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    /// 12 の数の `bezier`・`curve` は、組み立て中の形に点を足さず、別の 1 本として引く (平面の形と同じ)。
    @Test("組み立て中の形の途中で呼んでも、その形は残る")
    func leavesTheOpenShapeAlone() throws {
        let g = Self.guides
        let inside = try picture { canvas in
            canvas.beginShape()
            canvas.vertex(20, 20, 0)
            canvas.vertex(180, 20, 0)
            canvas.bezier(100, 100, 0, 150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.curve(g[0].x, g[0].y, g[0].z, g[1].x, g[1].y, g[1].z, g[2].x, g[2].y, g[2].z, g[3].x, g[3].y, g[3].z)
            canvas.vertex(180, 60, 0)
            canvas.endShape()
        }
        let apart = try picture { canvas in
            canvas.bezier(100, 100, 0, 150, 100, -80, 200, 100, -80, 250, 100, 0)
            canvas.curve(g[0].x, g[0].y, g[0].z, g[1].x, g[1].y, g[1].z, g[2].x, g[2].y, g[2].z, g[3].x, g[3].y, g[3].z)
            canvas.beginShape()
            canvas.vertex(20, 20, 0)
            canvas.vertex(180, 20, 0)
            canvas.vertex(180, 60, 0)
            canvas.endShape()
        }
        #expect(inside == apart)
    }
}
