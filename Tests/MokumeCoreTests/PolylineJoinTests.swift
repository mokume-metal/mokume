// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 任意多角形の折れ目 (`strokeJoin(.miter)` / `.bevel`) の形 ([#1644])。GPU を要する。
///
/// **折れ目の形は、そこで出会う 2 本の帯の向きと太さだけで決まる。** かつては形自身の
/// 座標軸 (立体では画面の軸) に沿った正方形で埋めていたので、斜めに一直線に並べた点で
/// 正方形の角が帯の外へ出て、回して描くと形が変わった。
///
/// 期待値は保存した画像ではなく、次の 2 つから導く ([ADR-0019] 決定 4):
///
/// - **同じ図形になるはずの 2 経路を描いて比べる** (一直線の折れ線と 2 点の線・回して
///   描いた折れ線と回した座標の折れ線・4 点の矩形と `rect`)
/// - **形は CPU で式から出した「帯 + 折れ目の形」と比べる。** 折れ目の形は、2 本の外側の
///   縁の交点 (尖り) を頂点とする凧形を、角から k × 太さ / 2 の所で二等分線に垂直に切った
///   ものである (`bevel` は k = 1、`miter` は k = √2)。実装の写しではない
///
/// 線の頂点は画面で半画素寄せられる ([ADR-0039] 決定 2) ので、画素 (x, y) の中心は形の
/// 座標の (x, y) に当たる。三角形の経路は縁の AA を持たない ([ADR-0039] 決定 3)。
///
/// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
@Suite(
    "任意多角形の折れ目",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PolylineJoinTests {
    private let size = 160
    private let weight: Float = 20

    /// 塗られた画素。縁を 50% の被覆で白黒にする。
    private struct Coverage {
        var inked: [Bool]
        let size: Int

        subscript(x: Int, y: Int) -> Bool { inked[y * size + x] }

        func differing(from other: Coverage) -> Int {
            zip(inked, other.inked).filter { $0 != $1 }.count
        }
        var count: Int { inked.filter { $0 }.count }
    }

    private func render(_ body: (Canvas) -> Void) throws -> Coverage {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(weight)
            body(canvas)
        }
        let pixels = try canvas.target.readPixels()
        var inked: [Bool] = []
        inked.reserveCapacity(size * size)
        for index in 0..<(size * size) { inked.append(Float(pixels.components[index * 4]) >= 0.5) }
        return Coverage(inked: inked, size: size)
    }

    private func polyline(_ canvas: Canvas, _ points: [SIMD2<Float>], closed: Bool = false) {
        canvas.beginShape()
        for point in points { canvas.vertex(point.x, point.y) }
        closed ? canvas.endShape(.close) : canvas.endShape()
    }

    private func solidPolyline(_ canvas: Canvas, _ points: [SIMD2<Float>]) {
        canvas.beginShape()
        for point in points { canvas.vertex(point.x, point.y, 0) }
        canvas.endShape()
    }

    private static func rotated(_ point: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        SIMD2(point.x * cos(angle) - point.y * sin(angle), point.x * sin(angle) + point.y * cos(angle))
    }

    // MARK: - 式 (CPU)

    /// 凸多角形 (どちら回りでもよい) の中に、縁から `margin` 以上入っているか。`margin` が
    /// 負なら、縁の外 `-margin` までを中に数える。
    private static func contains(
        _ polygon: [SIMD2<Float>], _ point: SIMD2<Float>, margin: Float
    ) -> Bool {
        var area: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        guard area != 0 else { return false }
        let sign: Float = area > 0 ? 1 : -1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let edge = b - a
            let length = simd_length(edge)
            guard length > 0 else { continue }
            let inward = sign * (edge.x * (point.y - a.y) - edge.y * (point.x - a.x)) / length
            if inward < margin { return false }
        }
        return true
    }

    /// 線分の帯 (端は線の長さちょうどで切る)。
    private static func band(_ a: SIMD2<Float>, _ b: SIMD2<Float>, half: Float) -> [SIMD2<Float>] {
        let along = simd_normalize(b - a)
        let normal = SIMD2(-along.y, along.x) * half
        return [a + normal, b + normal, b - normal, a - normal]
    }

    /// 角 `corner` で、`from` から来て `to` へ出る折れ目の形。2 本の外側の縁の交点を
    /// 頂点とする凧形と、角から `reach` の所で二等分線に垂直に切る半平面の組で返す。
    private static func joinShape(
        from: SIMD2<Float>, corner: SIMD2<Float>, to: SIMD2<Float>, half: Float, reach: Float
    ) -> (kite: [SIMD2<Float>], bisector: SIMD2<Float>, reach: Float) {
        let incoming = simd_normalize(corner - from)
        let outgoing = simd_normalize(to - corner)
        // 左へ曲がるなら、外側は右
        let turn = incoming.x * outgoing.y - incoming.y * outgoing.x
        let side: Float = turn > 0 ? -1 : 1
        let outer1 = SIMD2(-incoming.y, incoming.x) * side
        let outer2 = SIMD2(-outgoing.y, outgoing.x) * side
        let edge1 = corner + outer1 * half
        let edge2 = corner + outer2 * half
        // 2 本の外側の縁 (edge1 + s · incoming と edge2 − t · outgoing) の交点
        let denominator = incoming.x * outgoing.y - incoming.y * outgoing.x
        let delta = edge2 - edge1
        let s = (delta.x * outgoing.y - delta.y * outgoing.x) / denominator
        let tip = edge1 + incoming * s
        let bisector = simd_normalize(outer1 + outer2)
        return ([corner, edge1, tip, edge2], bisector, reach)
    }

    /// 3 点の折れ線 (端は線の長さちょうどで切る) の、式から出した形と描いた絵の食い違い。
    /// 縁から 1 画素以内の画素は数えない。
    private func mismatches(
        _ drawn: Coverage, points: [SIMD2<Float>], reachFactor: Float
    ) -> (spilled: Int, missing: Int) {
        let half = weight / 2
        let bands = [
            Self.band(points[0], points[1], half: half), Self.band(points[1], points[2], half: half),
        ]
        let join = Self.joinShape(
            from: points[0], corner: points[1], to: points[2], half: half,
            reach: reachFactor * half)
        func inJoin(_ point: SIMD2<Float>, margin: Float) -> Bool {
            Self.contains(join.kite, point, margin: margin)
                && simd_dot(point - points[1], join.bisector) <= join.reach - margin
        }
        var result = (spilled: 0, missing: 0)
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x), Float(y))
                let surelyIn =
                    bands.contains { Self.contains($0, point, margin: 1) } || inJoin(point, margin: 1)
                let maybeIn =
                    bands.contains { Self.contains($0, point, margin: -1) } || inJoin(point, margin: -1)
                if drawn[x, y], !maybeIn { result.spilled += 1 }
                if !drawn[x, y], surelyIn { result.missing += 1 }
            }
        }
        return result
    }

    // MARK: - 条件 1: 一直線の折れ線

    @Test("一直線に並べた 3 点の折れ線は、帯の外へ出ない", arguments: [StrokeJoin.miter, .bevel])
    func aStraightPolylineStaysInsideTheBand(_ join: StrokeJoin) throws {
        let three = try render { canvas in
            canvas.strokeJoin(join)
            polyline(canvas, [SIMD2(20, 20), SIMD2(80, 80), SIMD2(140, 140)])
        }
        let two = try render { canvas in
            canvas.strokeJoin(join)
            polyline(canvas, [SIMD2(20, 20), SIMD2(140, 140)])
        }
        #expect(two.count > 0)
        #expect(!three[88, 72])  // 直線から 11.3 離れた、太さ 20 の帯の外
        #expect(three.differing(from: two) == 0)
    }

    // MARK: - 条件 2: 回しても形が変わらない

    @Test(
        "回してから描いた折れ目と、回した座標で描いた折れ目が同じ形になる",
        arguments: [StrokeJoin.miter, .bevel], ["直角", "45°", "三角形"])
    func joinsDoNotDependOnTheAxes(_ join: StrokeJoin, _ name: String) throws {
        let angle = Float.pi / 4
        let center = SIMD2<Float>(80, 80)
        func pair(_ join: StrokeJoin) throws -> Int {
            let points: [SIMD2<Float>]
            switch name {
            case "直角": points = [SIMD2(-50, 20), SIMD2(0, -30), SIMD2(50, 20)]
            case "45°": points = [SIMD2(-50, 0), SIMD2(0, 0), SIMD2(40, 40)]
            default: points = [SIMD2(-40, 30), SIMD2(0, -40), SIMD2(40, 30)]
            }
            let closed = name == "三角形"
            let turned = try render { canvas in
                canvas.strokeJoin(join)
                canvas.translate(center.x, center.y)
                canvas.rotate(angle)
                if closed {
                    canvas.triangle(
                        points[0].x, points[0].y, points[1].x, points[1].y, points[2].x, points[2].y)
                } else {
                    polyline(canvas, points)
                }
            }
            let moved = points.map { Self.rotated($0, by: angle) + center }
            let direct = try render { canvas in
                canvas.strokeJoin(join)
                if closed {
                    canvas.triangle(
                        moved[0].x, moved[0].y, moved[1].x, moved[1].y, moved[2].x, moved[2].y)
                } else {
                    polyline(canvas, moved)
                }
            }
            #expect(turned.count > 0)
            return turned.differing(from: direct)
        }
        // 丸い折れ目は形が向きによらないので、違いは浮動小数の丸めだけ
        let control = try pair(.round)
        let differing = try pair(join)
        #expect(differing <= control, "違う画素 \(differing) / 丸い折れ目 \(control)")
    }

    // MARK: - 条件 3: 案 A の形

    @Test(
        "折れ目の形は、尖りを角から k × 太さ / 2 で二等分線に垂直に切った形になる",
        arguments: [StrokeJoin.miter, .bevel], Array(stride(from: 15, through: 165, by: 15)))
    func joinsCutTheMiterAcrossTheBisector(_ join: StrokeJoin, _ degrees: Int) throws {
        // 軸に沿わない向きから入り、中の点で `degrees` だけ曲がる
        let base = Float(20) * .pi / 180
        let turn = Float(degrees) * .pi / 180
        let corner = SIMD2<Float>(80, 80)
        let incoming = SIMD2(cos(base), sin(base))
        let outgoing = SIMD2(cos(base + turn), sin(base + turn))
        let points = [corner - incoming * 60, corner, corner + outgoing * 60]
        let drawn = try render { canvas in
            canvas.strokeJoin(join)
            canvas.strokeCap(.square)
            polyline(canvas, points)
        }
        let result = mismatches(
            drawn, points: points, reachFactor: join == .miter ? Float(2).squareRoot() : 1)
        #expect(result.spilled == 0 && result.missing == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    // MARK: - 条件 4: いま正しい絵

    @Test("4 点で閉じた矩形の bevel は、三角形の経路の rect の削いだ角と同じ絵になる")
    func aFourPointRectangleBevelMatchesTheRectangle() throws {
        let square: [SIMD2<Float>] = [SIMD2(40, 40), SIMD2(120, 40), SIMD2(120, 120), SIMD2(40, 120)]
        let drawn = try render { canvas in
            canvas.strokeJoin(.bevel)
            polyline(canvas, square, closed: true)
        }
        let rect = try render { canvas in
            canvas.strokeJoin(.bevel)
            canvas.shader(
                try! canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
            canvas.rect(40, 40, 80, 80)
        }
        #expect(rect.count > 0)
        #expect(drawn.differing(from: rect) == 0)
    }

    @Test("4 点で閉じた矩形の miter は、直角の尖った角のまま")
    func aFourPointRectangleMiterKeepsSharpCorners() throws {
        let square: [SIMD2<Float>] = [SIMD2(40, 40), SIMD2(120, 40), SIMD2(120, 120), SIMD2(40, 120)]
        let drawn = try render { canvas in
            canvas.strokeJoin(.miter)
            polyline(canvas, square, closed: true)
        }
        // 外の正方形 [30, 130] と内の正方形 [50, 110] の間。縁の上の画素は数えない
        var mismatched = 0
        for y in 0..<size {
            for x in 0..<size {
                let (px, py) = (Float(x), Float(y))
                let outer = max(abs(px - 80), abs(py - 80))
                if outer == 50 || outer == 30 { continue }
                let inside = outer < 50 && outer > 30
                if drawn[x, y] != inside { mismatched += 1 }
            }
        }
        #expect(mismatched == 0)
    }

    // MARK: - 条件 5: 立体

    @Test("奥行きを持つ頂点で一直線に並べた折れ線も、帯の外へ出ない", arguments: [StrokeJoin.miter, .bevel])
    func aStraightSolidPolylineStaysInsideTheBand(_ join: StrokeJoin) throws {
        let three = try render { canvas in
            canvas.strokeJoin(join)
            solidPolyline(canvas, [SIMD2(20, 20), SIMD2(80, 80), SIMD2(140, 140)])
        }
        let two = try render { canvas in
            canvas.strokeJoin(join)
            solidPolyline(canvas, [SIMD2(20, 20), SIMD2(140, 140)])
        }
        #expect(two.count > 0)
        #expect(!three[88, 72])
        #expect(three.differing(from: two) == 0)
    }

    /// 組み込みの立体の、不透明な `miter` の稜線は GPU で組む (#1741)。`plane` の角は辺が
    /// 2 本だけ集まる点で、直角の `miter` の尖りは、回した外の正方形の角に一致する。
    /// 半透明の線は CPU の骨 (`strokeNet`) で組むので、同じ形を CPU の経路でも見る。
    @Test("回した plane の稜線は、GPU で組んでも CPU で組んでも、角が尖りのまま外へ出ない", arguments: ["GPU", "記録して置く", "CPU"])
    func aTurnedPlaneKeepsItsMiterCorners(_ route: String) throws {
        let angle = Float.pi / 6
        let drawn = try render { canvas in
            canvas.strokeJoin(.miter)
            if route == "CPU" { canvas.stroke(255, 250) }
            if route == "記録して置く" {
                let shape = canvas.createShape { canvas.plane(80, 80) }
                canvas.translate(80, 80, 0)
                canvas.rotateZ(angle)
                canvas.shape(shape)
            } else {
                canvas.translate(80, 80, 0)
                canvas.rotateZ(angle)
                canvas.plane(80, 80)
            }
        }
        var mismatched = 0
        for y in 0..<size {
            for x in 0..<size {
                let local = Self.rotated(SIMD2(Float(x) - 80, Float(y) - 80), by: -angle)
                let reach = max(abs(local.x), abs(local.y))
                if abs(reach - 50) <= 1 || abs(reach - 30) <= 1 { continue }
                if drawn[x, y] != (reach < 50 && reach > 30) { mismatched += 1 }
            }
        }
        #expect(drawn.count > 0)
        #expect(mismatched == 0)
    }

    // MARK: - 透視で奥へ引っ込む辺 (反証の 2 回目の指摘 2-1)

    /// 床のように倒した `plane` を透視で見る。手前の角から奥へ引っ込む辺は、世界での差の
    /// 横成分と画面での動きが逆を向く。腕の向きを世界での差から取っていた頃は、外側の楔が
    /// 埋まらずに欠けた。
    ///
    /// 物差しは画面に写した四隅から式で出した「帯 + 尖りを √2 × 太さ / 2 で切った折れ目」で
    /// ある。帯は画面での太さを保つので、画面に写した四隅の間の、太さ 20 の長方形になる。
    @Test("透視で奥へ引っ込む辺の角も、画面に写した帯の向きで埋まる", arguments: ["GPU", "CPU"])
    func recedingEdgesUseTheirScreenDirection(_ route: String) throws {
        var corners: [SIMD2<Float>] = []
        let drawn = try render { canvas in
            canvas.strokeJoin(.miter)
            if route == "CPU" { canvas.stroke(255, 250) }
            canvas.translate(80, 140, 0)
            canvas.rotateX(Float(100) * .pi / 180)
            let camera = canvas.currentCamera
            let matrix = canvas.transform.matrix
            let scale = Float(size) / 2 / tan(Camera.defaultFieldOfView / 2)
            for local in [SIMD2<Float>(-40, -40), SIMD2(40, -40), SIMD2(40, 40), SIMD2(-40, 40)] {
                let world = matrix * SIMD4(local.x, local.y, 0, 1)
                let offset = SIMD3(world.x, world.y, world.z) - camera.eye
                let depth = simd_dot(offset, camera.forward)
                corners.append(
                    SIMD2(Float(size) / 2, Float(size) / 2)
                        + SIMD2(simd_dot(offset, camera.right), simd_dot(offset, camera.down))
                        * (scale / depth))
            }
            canvas.plane(80, 80)
        }
        let result = mismatches(drawn, ring: corners, reachFactor: Float(2).squareRoot())
        #expect(drawn.count > 0)
        #expect(result.spilled == 0 && result.missing == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 閉じた周 (画面の座標) の、式から出した形と描いた絵の食い違い。縁から 1 画素以内は数えない。
    private func mismatches(
        _ drawn: Coverage, ring: [SIMD2<Float>], reachFactor: Float
    ) -> (spilled: Int, missing: Int) {
        let half = weight / 2
        let count = ring.count
        var bands: [[SIMD2<Float>]] = []
        var joins: [(kite: [SIMD2<Float>], bisector: SIMD2<Float>, reach: Float, corner: SIMD2<Float>)] = []
        for index in 0..<count {
            let previous = ring[(index + count - 1) % count]
            let corner = ring[index]
            let next = ring[(index + 1) % count]
            bands.append(Self.band(corner, next, half: half))
            let join = Self.joinShape(
                from: previous, corner: corner, to: next, half: half, reach: reachFactor * half)
            joins.append((join.kite, join.bisector, join.reach, corner))
        }
        func inside(_ point: SIMD2<Float>, margin: Float) -> Bool {
            bands.contains { Self.contains($0, point, margin: margin) }
                || joins.contains {
                    Self.contains($0.kite, point, margin: margin)
                        && simd_dot(point - $0.corner, $0.bisector) <= $0.reach - margin
                }
        }
        var result = (spilled: 0, missing: 0)
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x), Float(y))
                if drawn[x, y], !inside(point, margin: -1) { result.spilled += 1 }
                if !drawn[x, y], inside(point, margin: 1) { result.missing += 1 }
            }
        }
        return result
    }

    // MARK: - 同じ向きへ折り返す角 (反証の 2 回目の指摘 2-2)

    /// `vertex(A); vertex(B); vertex(A)` の B は 180° の折り返しで、尖りは無限に遠い。形は
    /// 帯を k × 太さ / 2 だけ延ばした長方形で、折り返しに近づく角の形の極限と一致する。
    /// 向きによって丸めで出っ張りが出たり消えたりしないことを、軸に沿った向きと斜めの
    /// 向きで見る。
    @Test(
        "同じ向きへ折り返す角は、向きによらず帯を延ばした長方形になる",
        arguments: [StrokeJoin.miter, .bevel], [SIMD2<Float>(1, 0), SIMD2(1, 4), SIMD2(3, -7), SIMD2(-5, 2)])
    func foldsExtendTheBandInEveryDirection(_ join: StrokeJoin, _ direction: SIMD2<Float>) throws {
        let along = simd_normalize(direction)
        let tip = SIMD2<Float>(80, 80)
        let start = tip - along * 50
        let drawn = try render { canvas in
            canvas.strokeJoin(join)
            canvas.strokeCap(.square)
            polyline(canvas, [start, tip, start])
        }
        let half = weight / 2
        let reach = (join == .miter ? Float(2).squareRoot() : 1) * half
        let across = SIMD2(-along.y, along.x)
        let shape = [
            start + across * half, tip + along * reach + across * half,
            tip + along * reach - across * half, start - across * half,
        ]
        var spilled = 0
        var missing = 0
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x), Float(y))
                if drawn[x, y], !Self.contains(shape, point, margin: -1) { spilled += 1 }
                if !drawn[x, y], Self.contains(shape, point, margin: 1) { missing += 1 }
            }
        }
        #expect(drawn.count > 0)
        #expect(spilled == 0 && missing == 0, "はみ出し \(spilled)・塗り漏れ \(missing)")
    }

    // MARK: - 同じ位置の隣 (反証の指摘 3・4)

    /// 隣が同じ位置の点 (長さ 0 の帯) は向きを持たない。向きは同じ位置の点を飛ばした両隣から
    /// 取る。飛ばさないと、軸に沿った正方形へ倒れて帯の外へ出ていた。
    @Test("同じ位置の点が続く一直線の折れ線も、帯の外へ出ない", arguments: [StrokeJoin.miter, .bevel], [false, true])
    func repeatedPointsDoNotLeaveTheBand(_ join: StrokeJoin, _ depth: Bool) throws {
        func draw(_ points: [SIMD2<Float>]) throws -> Coverage {
            try render { canvas in
                canvas.strokeJoin(join)
                depth ? solidPolyline(canvas, points) : polyline(canvas, points)
            }
        }
        let repeated = try draw([SIMD2(20, 20), SIMD2(80, 80), SIMD2(80, 80), SIMD2(140, 140)])
        let two = try draw([SIMD2(20, 20), SIMD2(140, 140)])
        #expect(two.count > 0)
        #expect(!repeated[88, 72])
        #expect(repeated.differing(from: two) == 0)
    }

    @Test("端に同じ位置の点が続いても、出っ張らせる端は線の向きに沿う", arguments: [false, true])
    func repeatedEndPointsKeepTheProjectingCapAligned(_ depth: Bool) throws {
        func draw(_ points: [SIMD2<Float>]) throws -> Coverage {
            try render { canvas in
                canvas.strokeCap(.project)
                depth ? solidPolyline(canvas, points) : polyline(canvas, points)
            }
        }
        let repeated = try draw([SIMD2(30, 30), SIMD2(30, 30), SIMD2(130, 130), SIMD2(130, 130)])
        let two = try draw([SIMD2(30, 30), SIMD2(130, 130)])
        #expect(two.count > 0)
        #expect(repeated.differing(from: two) == 0)
    }

    /// 曲線で閉じる周 (字形の `o`) は、最後の点が最初の点と重なる。
    @Test("最後の点が最初の点と重なる字形の周も、重なりを除いた周と同じ輪郭になる", arguments: [StrokeJoin.miter, .bevel])
    func closedCurveGlyphsIgnoreTheRepeatedPoint(_ join: StrokeJoin) throws {
        let probe = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        probe.textFont("Helvetica")
        probe.textSize(120)
        let contours = probe.textOutline("o", 30, 120)
        let glyph = try #require(contours.first { $0.points.count > 3 }?.points)
        try #require(glyph.first == glyph.last)
        // 周の始まりは字の上端 (接線が横) にあり、軸に沿った正方形でも帯に収まってしまう。
        // 45° 回して、始まりの接線を斜めにする
        let center = SIMD2<Float>(80, 80)
        let middle = glyph.reduce(SIMD2<Float>(0, 0), +) / Float(glyph.count)
        let ring = glyph.map { Self.rotated($0 - middle, by: Float.pi / 4) + center }
        func draw(_ points: [SIMD2<Float>]) throws -> Coverage {
            try render { canvas in
                canvas.strokeWeight(8)
                canvas.strokeJoin(join)
                polyline(canvas, points, closed: true)
            }
        }
        let repeated = try draw(ring)
        let trimmed = try draw(Array(ring.dropLast()))
        #expect(trimmed.count > 0)
        #expect(repeated.differing(from: trimmed) == 0)
    }

    // MARK: - 保持した形 (反証の指摘 1・2)

    /// 保持した形の輪郭の形は、形の中で決まる。置くときの `strokeJoin` は効かない。
    /// 半透明の線は CPU で組み、置く先の視点で組み直す (``SolidStrokePiece``)。
    @Test(
        "保持した立体の折れ目は、記録したときの形で組み直される",
        arguments: [(StrokeJoin.bevel, StrokeJoin.miter), (.miter, .bevel)], ["plane", "折れ線"])
    func retainedSolidJoinsKeepTheRecordedJoin(_ joins: (StrokeJoin, StrokeJoin), _ name: String) throws {
        let (recorded, placing) = joins
        func draw(_ canvas: Canvas) {
            canvas.stroke(255, 250)
            if name == "plane" {
                canvas.plane(80, 80)
            } else {
                solidPolyline(canvas, [SIMD2(-50, 30), SIMD2(0, -40), SIMD2(50, 30)])
            }
        }
        let placed = try render { canvas in
            canvas.strokeJoin(recorded)
            let shape = canvas.createShape { draw(canvas) }
            canvas.strokeJoin(placing)
            canvas.translate(80, 80, 0)
            canvas.rotateZ(Float.pi / 6)
            canvas.shape(shape)
        }
        let direct = try render { canvas in
            canvas.strokeJoin(recorded)
            canvas.translate(80, 80, 0)
            canvas.rotateZ(Float.pi / 6)
            draw(canvas)
        }
        let other = try render { canvas in
            canvas.strokeJoin(placing)
            canvas.translate(80, 80, 0)
            canvas.rotateZ(Float.pi / 6)
            draw(canvas)
        }
        #expect(direct.differing(from: other) > 0, "2 つの形が見分けられない")
        #expect(placed.differing(from: direct) == 0)
    }

    /// 記録したときと置く先とで、腕が画面で潰れるかが変わる角 (#1893)。平行投影では視線に
    /// 沿う辺が画面で点に潰れ、潰れた辺の両端は画面で重なる点になる。
    ///
    /// **潰れた腕の角は、見えている帯の端になる** (#1903 の決定・案 R)。物差しは条件 1 と同じで、
    /// 同じ視点で 2 点 A→B だけを描いた絵と一致する。4 点の形は同じ平面に載る折り返し
    /// (A・B・C・D で B–C が視線に沿い、C→D が A へ戻る) で、B と C から出る帯が同じ向きなので
    /// 1 本と数え、端の円板を置く。記録した線は置くときに、点と繋がりからその場の線と同じ手順で
    /// 組み直すので (``SolidStrokePiece``)、記録したときと置く先とで積む三角形の数が違ってよい。
    ///
    /// 逆の組 (記録したときに潰れ、置く先では潰れない) は、その場で同じ視点で描いた 3 点 / 4 点の
    /// 絵と一致する。
    @Test(
        "記録したときと置く先とで腕が画面で潰れるかが変わる角も、その場で描いたのと同じ形になる",
        arguments: [StrokeJoin.miter, .bevel],
        ["置く先で潰れる・3 点", "置く先で潰れる・4 点", "記録したときに潰れる・3 点", "記録したときに潰れる・4 点"])
    func retainedJoinsSurviveAnArmCollapsingWhenPlaced(_ join: StrokeJoin, _ name: String) throws {
        let path: [SIMD3<Float>] =
            name.hasSuffix("3 点")
            ? [SIMD3(-40, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -60)]
            : [SIMD3(-40, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -60), SIMD3(-40, 0, -60)]
        func draw(_ canvas: Canvas, _ points: [SIMD3<Float>]) {
            canvas.stroke(255, 250)
            canvas.strokeJoin(join)
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        let collapsedWhenPlaced = name.hasPrefix("置く先で潰れる")
        let placed = try render { canvas in
            if !collapsedWhenPlaced { canvas.ortho() }
            let shape = canvas.createShape { draw(canvas, path) }
            collapsedWhenPlaced ? canvas.ortho() : canvas.perspective()
            canvas.translate(80, 80, 0)
            canvas.shape(shape)
        }
        let direct = try render { canvas in
            if collapsedWhenPlaced { canvas.ortho() }
            canvas.translate(80, 80, 0)
            // 置く先で潰れるなら、物差しは 2 点 A→B。潰れないなら、同じ点をその場で描いた絵
            draw(canvas, collapsedWhenPlaced ? Array(path.prefix(2)) : path)
        }
        #expect(direct.count > 0)
        #expect(placed.differing(from: direct) == 0, "違う画素 \(placed.differing(from: direct))")
    }

    // MARK: - 画面で潰れる腕 (#1893)

    /// 起票時の再現。平行投影で、2 本目の辺 B → C は視線に沿って画面で点に潰れる。
    private static let collapsingPath: [SIMD3<Float>] = [
        SIMD3(-60, -40, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -60),
    ]

    private func solidPath(
        _ canvas: Canvas, _ points: [SIMD3<Float>], join: StrokeJoin, cap: StrokeCap, turn: Float = 0
    ) {
        canvas.stroke(255, 250)
        canvas.ortho()
        canvas.strokeJoin(join)
        canvas.strokeCap(cap)
        canvas.translate(80, 80, 0)
        if turn != 0 { canvas.rotateZ(turn) }
        canvas.beginShape()
        for point in points { canvas.vertex(point.x, point.y, point.z) }
        canvas.endShape()
    }

    /// 画面で潰れた腕の角は、見えている帯の端になる。いまは画面の軸に沿った正方形へ倒れて、
    /// 帯の端の線より先へ出ていた (`.square` と `.project` で赤)。
    @Test(
        "画面で潰れた腕の角は、見えている帯の端になる",
        arguments: [StrokeJoin.miter, .bevel], [StrokeCap.square, .project, .round])
    func aCollapsedArmEndsTheVisibleBand(_ join: StrokeJoin, _ cap: StrokeCap) throws {
        let three = try render { solidPath($0, Self.collapsingPath, join: join, cap: cap) }
        let two = try render { solidPath($0, Array(Self.collapsingPath.prefix(2)), join: join, cap: cap) }
        #expect(two.count > 0)
        #expect(three.differing(from: two) == 0, "違う画素 \(three.differing(from: two))")
    }

    /// 途中の辺 B–C が潰れる折れ線は、画面で A → B (= C) → D の山形になる。重なる B と C を
    /// 1 点とみなすので、山の頂は 3 点 A・B・D の折れ目で埋まる (起票時の案 L では楔形の欠けが
    /// 空いた)。
    @Test("途中の辺が画面で潰れる折れ線は、潰れた辺を除いた折れ線の折れ目になる", arguments: [StrokeJoin.miter, .bevel])
    func aCollapsedMiddleEdgeKeepsTheJoin(_ join: StrokeJoin) throws {
        let d = SIMD3<Float>(60, -40, -60)
        let four = try render { solidPath($0, Self.collapsingPath + [d], join: join, cap: .square) }
        let three = try render {
            solidPath($0, [Self.collapsingPath[0], Self.collapsingPath[1], d], join: join, cap: .square)
        }
        #expect(three.count > 0)
        #expect(four.differing(from: three) == 0, "違う画素 \(four.differing(from: three))")
    }

    /// 視線に沿う辺は回しても潰れたまま。回した絵を画面の中心の周りに戻すと、回さない絵と
    /// 縁を除いて一致する。いまは正方形だけが回らずに、帯との位置が変わっていた。
    @Test(
        "画面で潰れた腕の角は、回しても形が変わらない",
        arguments: [StrokeJoin.miter, .bevel], [StrokeCap.square, .project, .round])
    func aCollapsedArmTurnsWithTheBand(_ join: StrokeJoin, _ cap: StrokeCap) throws {
        let angle = Float.pi / 6
        let still = try render { solidPath($0, Self.collapsingPath, join: join, cap: cap) }
        let turned = try render { solidPath($0, Self.collapsingPath, join: join, cap: cap, turn: angle) }
        #expect(still.count > 0)
        let differing = Self.differingAfterTurningBack(turned, by: angle, from: still)
        #expect(differing == 0, "違う画素 \(differing)")
    }

    /// 画面の 1 点に潰れた形の全体 (1 本の線を真正面から見たもの) は、向きの無い点のまま
    /// (#1893 の条件 4 の境界)。出っ張らせる端は、画面の軸に沿った正方形になる。
    @Test("画面の 1 点に潰れた線の出っ張らせる端は、画面の軸に沿った正方形のまま")
    func aWhollyCollapsedLineKeepsTheAxisSquare() throws {
        let drawn = try render {
            solidPath($0, [SIMD3(0, 0, 0), SIMD3(0, 0, -60)], join: .miter, cap: .project)
        }
        var mismatched = 0
        for y in 0..<size {
            for x in 0..<size {
                let reach = max(abs(Float(x) - 80), abs(Float(y) - 80))
                if abs(reach - 10) <= 1 { continue }
                if drawn[x, y] != (reach < 10) { mismatched += 1 }
            }
        }
        #expect(drawn.count > 0)
        #expect(mismatched == 0)
    }

    /// 組み込みの立体の、不透明な `miter` の稜線は GPU で組む。`plane` を真横から平行投影で
    /// 見ると (視線を辺にちょうど沿わせる)、奥へ向かう 2 本の辺が画面で点に潰れ、手前と奥の
    /// 辺が画面で重なる。重なる 2 本は別の点から同じ向きへ出るので 1 本と数え、角は帯の端に
    /// なる。絵は画面の縦の帯 (x = 80・y = 40…120) と両端の端の形である。
    ///
    /// `camera(280, 80, 0, 80, 80, 0, 0, 1, 0)` は視線が世界の −x にちょうど沿い、画面の横は
    /// 世界の −z・縦は +y になる (どちらも成分は 0 と ±1 だけ)。浮動小数の `rotateX(PI / 2)` では
    /// 長さがちょうど 0 にならない。
    @Test(
        "視線を辺に沿わせた plane は、GPU で組んでも CPU で組んでも、帯と両端の端の形になる",
        arguments: ["GPU", "CPU"], [StrokeCap.round, .square, .project])
    func aPlaneSeenAlongAnEdgeEndsWithTheCap(_ route: String, _ cap: StrokeCap) throws {
        let drawn = try render { canvas in
            canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
            canvas.ortho()
            canvas.strokeCap(cap)
            if route == "CPU" { canvas.stroke(255, 250) }
            canvas.translate(80, 80, 0)
            canvas.plane(80, 80)
        }
        let half = weight / 2
        let reach: Float = cap == .project ? half : 0
        func inside(_ point: SIMD2<Float>, margin: Float) -> Bool {
            let band = abs(point.x - 80) <= half - margin && point.y >= 40 - reach + margin
                && point.y <= 120 + reach - margin
            guard cap == .round else { return band }
            let caps = [SIMD2<Float>(80, 40), SIMD2(80, 120)].contains {
                simd_distance(point, $0) <= half - margin
            }
            return band || caps
        }
        var spilled = 0
        var missing = 0
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x), Float(y))
                if drawn[x, y], !inside(point, margin: -1) { spilled += 1 }
                if !drawn[x, y], inside(point, margin: 1) { missing += 1 }
            }
        }
        #expect(drawn.count > 0)
        #expect(spilled == 0 && missing == 0, "はみ出し \(spilled)・塗り漏れ \(missing)")
        if route == "GPU" {
            let cpu = try render { canvas in
                canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
                canvas.ortho()
                canvas.strokeCap(cap)
                canvas.stroke(255, 250)
                canvas.translate(80, 80, 0)
                canvas.plane(80, 80)
            }
            #expect(drawn.differing(from: cpu) == 0, "GPU と CPU で違う画素 \(drawn.differing(from: cpu))")
        }
    }

    // MARK: - 辺が 3 本以上集まる点 (#1889)

    /// 箱の 8 隅 (形自身の座標)。添字の 3 ビットが x・y・z の符号を表す。
    private static func boxCorners(half: Float) -> [SIMD3<Float>] {
        (0..<8).map { index in
            SIMD3(index & 1 == 0 ? -half : half, index & 2 == 0 ? -half : half, index & 4 == 0 ? -half : half)
        }
    }

    /// 箱の 12 辺。添字が 1 ビットだけ違う隅の対。
    private static let boxEdges: [(Int, Int)] = (0..<8).flatMap { a in
        [1, 2, 4].compactMap { bit in a & bit == 0 ? (a, a | bit) : nil }
    }

    /// いまの変換と既定の透視で、形自身の座標の点を画面の座標へ落とす (画素の中心が整数)。
    private func projected(_ local: SIMD3<Float>, _ canvas: Canvas) -> SIMD2<Float> {
        let camera = canvas.currentCamera
        let world = canvas.transform.matrix * SIMD4(local, 1)
        let offset = SIMD3(world.x, world.y, world.z) - camera.eye
        let scale = Float(size) / 2 / tan(Camera.defaultFieldOfView / 2)
        let depth = simd_dot(offset, camera.forward)
        return SIMD2(Float(size) / 2, Float(size) / 2)
            + SIMD2(simd_dot(offset, camera.right), simd_dot(offset, camera.down)) * (scale / depth)
    }

    /// 画面に写した網 (点と辺) の、式から出した「帯 + 案 A の折れ目」と描いた絵の食い違い。
    ///
    /// 点ごとに、そこから出る辺の画面での向きを角度の順に並べる。隣り合う 2 本の間が 180° を
    /// 越える所があれば、その 2 本で凧形を k × 太さ / 2 で切った折れ目を置き、無ければ何も
    /// 置かない (#1889 の案 A)。縁から 1 画素以内は数えない。
    private func mismatches(
        _ drawn: Coverage, net points: [SIMD2<Float>], edges: [(Int, Int)], half: Float, reachFactor: Float
    ) -> (spilled: Int, missing: Int) {
        let bands = edges.map { Self.band(points[$0.0], points[$0.1], half: half) }
        var joins: [(kite: [SIMD2<Float>], bisector: SIMD2<Float>, reach: Float, corner: SIMD2<Float>)] = []
        for index in points.indices {
            let corner = points[index]
            let far = edges.compactMap { $0.0 == index ? points[$0.1] : $0.1 == index ? points[$0.0] : nil }
            let sorted = far.sorted {
                atan2($0.y - corner.y, $0.x - corner.x) < atan2($1.y - corner.y, $1.x - corner.x)
            }
            let angles = sorted.map { atan2($0.y - corner.y, $0.x - corner.x) }
            for step in sorted.indices {
                let next = (step + 1) % sorted.count
                var gap = angles[next] - angles[step]
                if gap <= 0 { gap += 2 * .pi }
                guard gap > .pi else { continue }
                let join = Self.joinShape(
                    from: sorted[step], corner: corner, to: sorted[next], half: half,
                    reach: reachFactor * half)
                joins.append((join.kite, join.bisector, join.reach, corner))
            }
        }
        func inside(_ point: SIMD2<Float>, margin: Float) -> Bool {
            bands.contains { Self.contains($0, point, margin: margin) }
                || joins.contains {
                    Self.contains($0.kite, point, margin: margin)
                        && simd_dot(point - $0.corner, $0.bisector) <= $0.reach - margin
                }
        }
        var result = (spilled: 0, missing: 0)
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2<Float>(Float(x), Float(y))
                if drawn[x, y], !inside(point, margin: -1) { result.spilled += 1 }
                if !drawn[x, y], inside(point, margin: 1) { result.missing += 1 }
            }
        }
        return result
    }

    /// `turned` を画面の中心 (80, 80) の周りに −`angle` 回して戻したものと、`still` の違う画素。
    /// どちらかの絵で縁に接する画素 (8 近傍に違う値がある) は数えない。
    private static func differingAfterTurningBack(
        _ turned: Coverage, by angle: Float, from still: Coverage
    ) -> Int {
        let size = still.size
        func onEdge(_ coverage: Coverage, _ x: Int, _ y: Int) -> Bool {
            for dy in -1...1 {
                for dx in -1...1 {
                    let (nx, ny) = (x + dx, y + dy)
                    guard nx >= 0, ny >= 0, nx < size, ny < size else { return true }
                    if coverage[nx, ny] != coverage[x, y] { return true }
                }
            }
            return false
        }
        let center = SIMD2<Float>(80, 80)
        var differing = 0
        for y in 0..<size {
            for x in 0..<size where !onEdge(still, x, y) {
                let moved = rotated(SIMD2(Float(x), Float(y)) - center, by: angle) + center
                let (tx, ty) = (Int(moved.x.rounded()), Int(moved.y.rounded()))
                guard tx >= 0, ty >= 0, tx < size, ty < size, !onEdge(turned, tx, ty) else { continue }
                if turned[tx, ty] != still[x, y] { differing += 1 }
            }
        }
        return differing
    }

    /// 起票時の再現の箱。角は辺が 3 本集まる点で、画面に写した 3 本の帯の間に 180° を越える所が
    /// あれば、その間を挟む 2 本の折れ目になる。無ければ何も置かない (帯の和だけ)。いまは画面の
    /// 軸に沿った正方形で埋まり、角が帯の外へ出ていた。
    ///
    /// 経路は 4 通り: 不透明な `miter` (組み込みの立体は GPU で組む・`bevel` は CPU)、半透明
    /// (CPU の骨 `strokeNet`)、不透明のまま記録して置く (保持した形の GPU の線・#1756)、半透明で
    /// 記録して置く (部品を置く先の視点で組み直す)。
    @Test(
        "辺が 3 本集まる箱の角は、180° を越える間を挟む 2 本の折れ目になる",
        arguments: [StrokeJoin.miter, .bevel], ["不透明", "半透明", "記録して置く", "半透明で記録して置く"])
    func boxCornersFollowTheWidestGap(_ join: StrokeJoin, _ route: String) throws {
        var corners: [SIMD2<Float>] = []
        let drawn = try render { canvas in
            canvas.strokeWeight(16)
            canvas.strokeJoin(join)
            if route.hasPrefix("半透明") { canvas.stroke(255, 250) }
            let shape = route.hasSuffix("記録して置く") ? canvas.createShape { canvas.box(80) } : nil
            canvas.translate(80, 80, 0)
            canvas.rotateX(0.6)
            canvas.rotateY(0.7)
            corners = Self.boxCorners(half: 40).map { projected($0, canvas) }
            if let shape { canvas.shape(shape) } else { canvas.box(80) }
        }
        let result = mismatches(
            drawn, net: corners, edges: Self.boxEdges, half: 8,
            reachFactor: join == .miter ? Float(2).squareRoot() : 1)
        #expect(drawn.count > 0)
        #expect(result.spilled == 0 && result.missing == 0, "はみ出し \(result.spilled)・塗り漏れ \(result.missing)")
    }

    /// 同じ箱を画面の中心の周りに回して描き、戻すと回さない絵と縁を除いて一致する。いまは
    /// 正方形だけが回らずに、帯との位置が変わっていた。
    @Test(
        "回した箱の角も、回す前の角を回した形になる",
        arguments: [StrokeJoin.miter, .bevel], ["不透明", "半透明"])
    func boxCornersTurnWithTheBox(_ join: StrokeJoin, _ route: String) throws {
        let angle = Float.pi / 6
        func draw(_ turn: Float) throws -> Coverage {
            try render { canvas in
                canvas.strokeWeight(16)
                canvas.strokeJoin(join)
                if route == "半透明" { canvas.stroke(255, 250) }
                canvas.translate(80, 80, 0)
                if turn != 0 { canvas.rotateZ(turn) }
                canvas.rotateX(0.6)
                canvas.rotateY(0.7)
                canvas.box(80)
            }
        }
        let still = try draw(0)
        let turned = try draw(angle)
        #expect(still.count > 0)
        let differing = Self.differingAfterTurningBack(turned, by: angle, from: still)
        #expect(differing == 0, "違う画素 \(differing)")
    }

    /// 正面から平行投影で見た箱は、奥へ向かう 4 本の辺が画面で潰れ、手前と奥の面が重なる。
    /// 画面で長さを持つ帯だけを数え、別の点から同じ向きへ出る帯は 1 本と数えるので、角は
    /// 辺が 2 本の角 (#1644) になる。絵は回した外の正方形 (辺 80 + 太さ) と内の正方形
    /// (辺 80 − 太さ) の間。
    @Test("正面から平行投影で見た箱の角は、画面で長さを持つ帯だけで決まる", arguments: ["不透明", "半透明"])
    func aFrontalBoxCountsOnlyTheEdgesOnScreen(_ route: String) throws {
        let angle = Float.pi / 6
        let drawn = try render { canvas in
            canvas.strokeWeight(16)
            canvas.strokeJoin(.miter)
            if route == "半透明" { canvas.stroke(255, 250) }
            canvas.ortho()
            canvas.translate(80, 80, 0)
            canvas.rotateZ(angle)
            canvas.box(80)
        }
        var mismatched = 0
        for y in 0..<size {
            for x in 0..<size {
                let local = Self.rotated(SIMD2(Float(x) - 80, Float(y) - 80), by: -angle)
                let reach = max(abs(local.x), abs(local.y))
                if abs(reach - 48) <= 1 || abs(reach - 32) <= 1 { continue }
                if drawn[x, y] != (reach < 48 && reach > 32) { mismatched += 1 }
            }
        }
        #expect(drawn.count > 0)
        #expect(mismatched == 0)
    }

    // MARK: - 画面で重なる点の群 (#1893 の反証)

    /// 画面で重なる点は、何段続いても 1 つの群にまとめ、群に 1 度だけ形を置く。決まりは網の骨
    /// (`strokeNet`) の 1 か所にあり、周も網も、その場で描いても記録して置いても同じ骨を通る。
    /// 経路ごとに写して持っていた頃は、記録した形が潰れた辺の先を 1 段しか引けず、2 段以上
    /// 潰れると軸の正方形や欠けが出た。

    /// 平行投影で B・C・D が視線に沿って並ぶ折れ線 (端が 2 段潰れる)。記録したときは透視で
    /// 潰れず、置く先で潰れる。物差しは同じ視点で 2 点 A→B だけを描いた絵。
    @Test(
        "記録した折れ線の端が画面で 2 段潰れても、見えている帯の端になる",
        arguments: [StrokeCap.project, .square, .round])
    func aRetainedEndCollapsingTwiceEndsTheVisibleBand(_ cap: StrokeCap) throws {
        let path: [SIMD3<Float>] = [SIMD3(-60, -40, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -30), SIMD3(0, 0, -60)]
        func draw(_ canvas: Canvas, _ points: [SIMD3<Float>]) {
            canvas.stroke(255, 250)
            canvas.strokeCap(cap)
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        let placed = try render { canvas in
            let shape = canvas.createShape { draw(canvas, path) }
            canvas.ortho()
            canvas.translate(80, 80, 0)
            canvas.shape(shape)
        }
        let direct = try render { canvas in
            canvas.ortho()
            canvas.translate(80, 80, 0)
            draw(canvas, Array(path.prefix(2)))
        }
        #expect(direct.count > 0)
        #expect(placed.differing(from: direct) == 0, "違う画素 \(placed.differing(from: direct))")
    }

    /// 平行投影で B・C・D・E の 4 点が視線に沿って並ぶ折れ線 (途中が 3 段潰れる)。山の頂は
    /// 3 点 A・B・F の折れ目になる。記録して置いても同じ。
    @Test(
        "画面で重なる点が 4 つ続く折れ線も、潰れた辺を除いた折れ線の折れ目になる",
        arguments: [StrokeJoin.miter, .bevel], ["その場", "記録して置く"])
    func fourCoincidentPointsKeepTheJoin(_ join: StrokeJoin, _ route: String) throws {
        let path: [SIMD3<Float>] = [
            SIMD3(-60, -40, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -20), SIMD3(0, 0, -40), SIMD3(0, 0, -60),
            SIMD3(60, -40, -60),
        ]
        func draw(_ canvas: Canvas, _ points: [SIMD3<Float>]) {
            canvas.stroke(255, 250)
            canvas.strokeJoin(join)
            canvas.strokeCap(.square)
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        let drawn = try render { canvas in
            let shape = route == "記録して置く" ? canvas.createShape { draw(canvas, path) } : nil
            canvas.ortho()
            canvas.translate(80, 80, 0)
            if let shape { canvas.shape(shape) } else { draw(canvas, path) }
        }
        let three = try render { canvas in
            canvas.ortho()
            canvas.translate(80, 80, 0)
            draw(canvas, [path[0], path[1], path[5]])
        }
        #expect(three.count > 0)
        #expect(drawn.differing(from: three) == 0, "違う画素 \(drawn.differing(from: three))")
    }

    /// 稜線の 3 点が一直線に並ぶ形 (``ModelFixture/ridge``) を、視線をその直線に沿わせて見る。
    /// 3 点が画面の 1 点に重なり、1 つの群として折れ目を 1 つ置く。記録して置いた絵は、同じ視点で
    /// その場で描いた絵と一致する。真ん中の点は番号が最も小さく群の代表になるので、潰れた辺の先を
    /// 1 段しか引かない組み直しでは、誰も置かなかった。
    @Test("記録した稜線で 3 点が画面で重なっても、その場で描いたのと同じ形になる", arguments: [StrokeJoin.miter, .bevel])
    func aRetainedNetWithThreeCoincidentPoints(_ join: StrokeJoin) throws {
        func draw(_ canvas: Canvas, _ model: Model) {
            canvas.stroke(255, 250)
            canvas.strokeJoin(join)
            canvas.strokeCap(.square)
            canvas.model(model)
        }
        func view(_ canvas: Canvas) {
            canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
            canvas.ortho()
            canvas.translate(80, 80, 0)
            canvas.scale(40, 40, 40)
        }
        let placed = try render { canvas in
            let model = try! canvas.loadModel(ModelFixture.ridge, normalize: false)
            let shape = canvas.createShape { draw(canvas, model) }
            view(canvas)
            canvas.shape(shape)
        }
        let direct = try render { canvas in
            let model = try! canvas.loadModel(ModelFixture.ridge, normalize: false)
            view(canvas)
            draw(canvas, model)
        }
        #expect(direct.count > 0)
        #expect(placed.differing(from: direct) == 0, "違う画素 \(placed.differing(from: direct))")
    }

    /// 描いた立体の頂点の数 (描き切る前の溜め場)。線の三角形の数を見る。
    private func solidVertexCount(_ body: (Canvas) -> Void) throws -> Int {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        var count = 0
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.strokeWeight(weight)
            let start = canvas.solidVertices.count
            body(canvas)
            canvas.closeBatch()
            count = canvas.solidVertices.count - start
        }
        return count
    }

    /// 途中の辺 B–C が潰れる折れ線では、重なる B と C を 1 点とみなし、折れ目を 1 度だけ置く。
    /// 2 度置くと、半透明の線の折れ目だけが 2 回混ざって濃くなる (奥の折れ目を先に置いたとき、
    /// 手前の折れ目が奥行きで弾かれずに重なる)。
    ///
    /// 見るのは積んだ頂点の数である。その場で描いた 4 点の線は、潰れた辺を除いた 3 点 A・B・D の
    /// 線と同じ数を積み (帯 2 本と折れ目 1 つ)、記録して置いた線は、同じ視点でその場で描いた線と
    /// 同じ数を積む。並べる向きを逆にした組も見る。
    ///
    /// **数えるのは不透明の線である。** 半透明の線は片の重なりを画面で引いて積む (#1561) ので、
    /// 積む頂点の数が片の数を表さない (引いた残りの割り方は、潰れた辺の両端の世界の位置の丸めで
    /// 変わる)。骨 (`strokeNet`) は不透明の線と同じなので、折れ目を何度置くかは不透明の線で見える。
    @Test("画面で重なる点の折れ目は 1 度だけ置く", arguments: ["A から", "D から"])
    func coincidentPointsPlaceTheJoinOnce(_ order: String) throws {
        let forward: [SIMD3<Float>] = [SIMD3(-60, -40, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -60), SIMD3(60, -40, -60)]
        let path = order == "A から" ? forward : forward.reversed()
        func draw(_ canvas: Canvas, _ points: [SIMD3<Float>]) {
            canvas.stroke(255)
            canvas.strokeJoin(.miter)
            canvas.strokeCap(.square)
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        func view(_ canvas: Canvas) {
            canvas.ortho()
            canvas.translate(80, 80, 0)
        }
        let four = try solidVertexCount { canvas in
            view(canvas)
            draw(canvas, path)
        }
        let three = try solidVertexCount { canvas in
            view(canvas)
            draw(canvas, [forward[0], forward[1], forward[3]])
        }
        let placed = try solidVertexCount { canvas in
            let shape = canvas.createShape { draw(canvas, path) }
            view(canvas)
            canvas.shape(shape)
        }
        #expect(three > 0)
        #expect(four == three, "4 点 \(four)・3 点 \(three)")
        #expect(placed == four, "記録して置いた線 \(placed)・その場 \(four)")
    }

    // MARK: - 2 回目の反証

    /// 保持した形の細い線 (#1637) の「被覆が 1 未満」の印は、線の頂点を積んだ列に立つ。`.replace`
    /// の列はこの印で下地を読む組へ移る (`ShapePipeline`)。印を列を開く前に立てると、直前に開いて
    /// いた別種の列 (ここでは矩形) へ渡って下ろされた。
    @Test("細い線の記録した形を置くと、被覆の印が線の頂点の入る列に立つ")
    func retainedThinStrokesMarkTheirOwnBatch() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        var marked: Bool?
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(0.4)
            canvas.blendMode(.replace)
            let shape = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-30, -30, 0)
                canvas.vertex(30, -30, 0)
                canvas.vertex(30, 30, 0)
                canvas.endShape(.close)
            }
            canvas.fill(200)
            canvas.noStroke()
            canvas.rect(4, 4, 20, 20)
            canvas.translate(80, 80, 0)
            canvas.shape(shape)
            canvas.closeBatch()
            marked = canvas.batches.last { if case .solid = $0.source { true } else { false } }?.thinCoverage
        }
        #expect(marked == true)
    }

    /// 開いた周の全部の点が画面の 1 点に重なる線 (視線に沿う 1 本の線) の `.square` の端は、平面の
    /// 周と同じく線の長さちょうどで切り、何も置かない (#1893 の条件 4「いまのまま」)。記録した形は
    /// 何も積まないので、頂点を持たない。
    @Test("画面の 1 点に潰れた線の切る端は、何も置かない")
    func aWhollyCollapsedLineWithSquareCapsDrawsNothing() throws {
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 0, -60)]
        let drawn = try render { solidPath($0, path, join: .miter, cap: .square) }
        let flat = try render { canvas in
            canvas.strokeCap(.square)
            polyline(canvas, [SIMD2(80, 80), SIMD2(80, 80)])
        }
        #expect(drawn.count == 0, "塗られた画素 \(drawn.count)")
        #expect(drawn.differing(from: flat) == 0)
        var vertexCount = -1
        _ = try render { canvas in
            canvas.ortho()
            canvas.strokeCap(.square)
            let shape = canvas.createShape {
                canvas.beginShape()
                for point in path { canvas.vertex(point.x, point.y, point.z) }
                canvas.endShape()
            }
            vertexCount = shape.vertexCount
        }
        #expect(vertexCount == 0, "記録した頂点 \(vertexCount)")
    }

    /// 途中の辺 B–C が視線に沿う折り返し (B→A と C→D が画面で同じ向き) は、潰れた辺で繋がった別の
    /// 点から出た同じ向きの腕を 1 本と数え、帯の端になる (#1893 の案 R・条件 5 と同じ規則)。同じ点が
    /// 自分の 2 本の腕を折り返す角 (A・B・A) は #1644 のまま、帯を延ばした形になる。2 つは別の形で、
    /// 前者は 2 点 A→B の絵、後者は平面の A・B・A の絵と一致する。
    @Test("潰れた辺の先の点との折り返しは端、同じ点の折り返しは #1644 の形", arguments: [StrokeJoin.miter, .bevel])
    func foldsAcrossACollapsedEdgeEndTheBand(_ join: StrokeJoin) throws {
        let (a, b) = (SIMD3<Float>(-50, -30, 0), SIMD3<Float>(0, 0, 0))
        let acrossCollapse = try render {
            solidPath($0, [a, b, SIMD3(0, 0, -60), SIMD3(-50, -30, -60)], join: join, cap: .square)
        }
        let twoPoints = try render { solidPath($0, [a, b], join: join, cap: .square) }
        let samePoint = try render { solidPath($0, [a, b, a], join: join, cap: .square) }
        let flatFold = try render { canvas in
            canvas.strokeJoin(join)
            canvas.strokeCap(.square)
            polyline(canvas, [SIMD2(30, 50), SIMD2(80, 80), SIMD2(30, 50)])
        }
        #expect(acrossCollapse.differing(from: twoPoints) == 0)
        #expect(samePoint.differing(from: flatFold) == 0)
        #expect(samePoint.differing(from: twoPoints) > 0, "2 つの形が見分けられない")
    }

    /// GPU の骨の丸い端の容量は、画面で 1 本になりうる点 (同じ平面に載る 4 点) にある。3D では逆の
    /// 側へ傾いた腕 ((40, 0, −80) と (40, 0, 80)) も、潰れた辺 (z 軸) に沿って見れば画面で同じ向きに
    /// なる。以前は 3D の内積が正の組にしか容量が無く、GPU だけが円板の代わりに折り返しを置いた。
    /// 骨を直に組んで GPU で描いた絵と、同じ周を CPU で描いた絵が一致する。
    @Test("3D で逆の側へ傾いた腕を 1 本と数える端も、GPU と CPU で同じ円板になる")
    func gpuRoundEndsCoverArmsLeaningApart() throws {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, -40), SIMD3(40, 0, 40), SIMD3(40, 0, -80),
        ]
        func meshPoint(_ index: Int) -> SolidMesh.Point {
            SolidMesh.Point(position: points[index], normal: .zero, uv: .zero)
        }
        // 周 0 → 1 → 2 → 3 を、同じ平面 (y = 0) の同じ向きの 2 枚で張る (間の辺 0–2 は線にならない)
        let net = SolidEdges(SolidMesh(points: [0, 1, 2, 0, 3, 2].map(meshPoint)))
        let geometry = try #require(try SolidStrokeGeometry(net: net, gpu: RenderDevice()))
        #expect(SolidStrokeNet(points: net.points, edges: net.edges).mayEndAsOneBand(0))
        // 平行投影で視線は −z。辺 0–1 と 2–3 が画面で潰れ、周の全体が画面の横の線 (y = 80) になる
        func view(_ canvas: Canvas) {
            canvas.ortho()
            canvas.translate(60, 80, 0)
        }
        let gpu = try render { canvas in
            view(canvas)
            canvas.openGPUStroke(
                of: .mesh(.plane(width: 1, height: 1)), geometry: geometry, matrix: canvas.transform.matrix,
                weight: weight, cap: .round, color: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1),
                uv: canvas.whiteUV, geometryScale: 1)
        }
        let cpu = try render { canvas in
            view(canvas)
            canvas.beginShape()
            for point in points { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape(.close)
        }
        #expect(cpu.count > 0)
        #expect(gpu.differing(from: cpu) == 0, "GPU と CPU で違う画素 \(gpu.differing(from: cpu))")
    }

    /// GPU の頂点関数は、辺の両端がそれぞれ辺の潰れを判定する。引数の順を入れ替えると fast-math の
    /// 積和の縮約で判定が食い違いうるので、記録の位置が小さい点を先にした同じ式で判定する。原文の
    /// 構造で見る (透視で縮約の差を確かめて起こす配置は作れない)。
    @Test("GPU の頂点関数は、辺の潰れを両端で同じ式で判定する")
    func gpuCollapseIsJudgedTheSameAtBothEnds() throws {
        let source = try RenderDevice().shaders.bundledShaderSource(named: "Shapes")
        let start = try #require(source.range(of: "SolidStrokeCorner solidStrokeCornerShape("))
        let body = source[start.upperBound...]
        #expect(source.contains("recordP < recordQ ? !solidStrokeNormal(p, q, s, normal) : !solidStrokeNormal(q, p, s, normal)"))
        #expect(body.contains("solidStrokeEdgeCollapsed(center, record, solidStrokePlaced(entry.xyz, s), uint(entry.w), s)"))
    }

    /// 群の形はいちばん手前の点に置く。透視で目を通る辺 C–B (C が奥) を、番号の小さい奥の点 C から
    /// 並べ、間に不透明な面を置く。奥の点に置いていた頃は、出っ張らせる端が面に隠れた。
    @Test("画面で重なる点の形は、間の面に隠れない手前の点に置く", arguments: ["その場", "記録して置く"])
    func groupsPlaceAtTheNearestPointBehindAFace(_ route: String) throws {
        let path: [SIMD3<Float>] = [SIMD3(-60, -40, 0), SIMD3(0, 0, -60), SIMD3(0, 0, 0)]
        func draw(_ canvas: Canvas) {
            canvas.strokeCap(.project)
            canvas.beginShape()
            for point in path { canvas.vertex(point.x, point.y, point.z) }
            canvas.endShape()
        }
        let drawn = try render { canvas in
            canvas.translate(80, 80, 0)
            if route == "記録して置く" {
                let shape = canvas.createShape { draw(canvas) }
                canvas.shape(shape)
            } else {
                draw(canvas)
            }
            canvas.noStroke()
            canvas.fill(40)
            canvas.translate(0, 0, -30)
            canvas.plane(24, 24)
        }
        // 端の向こう (A から B へ進む向きに 5 画素) は、出っ張らせる端だけが塗る
        let along = simd_normalize(SIMD2<Float>(60, 40))
        let probe = SIMD2<Float>(80, 80) + along * 5
        #expect(drawn[Int(probe.x.rounded()), Int(probe.y.rounded())])
    }

    /// 組み込みの立体でも、群の形は手前の点に置く (GPU の骨も CPU の骨も同じ選び方)。箱の辺を目を
    /// 通る直線に載せ、手前と奥の角を画面で重ねる。角の尖りの先に、2 つの角の間の奥行きの面を置く。
    /// 奥の角に置くと尖りが面に隠れる。z を裏返した組も見る (どちらの角の番号が小さくても同じ)。
    @Test(
        "目を通る辺で重なる箱の角は、手前の角の尖りを置く",
        arguments: ["GPU", "CPU"], [false, true])
    func boxCornersOnTheEyeRayPlaceTheNearCorner(_ route: String, _ flipped: Bool) throws {
        let drawn = try render { canvas in
            canvas.strokeWeight(16)
            canvas.strokeJoin(.miter)
            if route == "CPU" { canvas.stroke(255, 250) }
            canvas.push()
            canvas.translate(40, 40, 0)
            if flipped { canvas.scale(1, 1, -1) }
            canvas.box(80)
            canvas.pop()
            canvas.noStroke()
            canvas.fill(40)
            canvas.translate(90, 90, 0)
            canvas.plane(20, 20)
        }
        #expect(drawn[85, 85])
    }
}
