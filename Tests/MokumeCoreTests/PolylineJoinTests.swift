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

    /// 記録したときは腕が画面に写り、置く先では画面で点に潰れる (平行投影で視線に沿う辺)。
    /// 折れ目の頂点の数が枝で違うと、組み直しで部品が 1 点へ畳まれて、その場で描いた絵と
    /// 食い違う。
    ///
    /// **見るのは、保持した形がその場で描いた絵と一致することだけである。** 潰れた角は
    /// いま画面の軸に沿った正方形へ倒れるが、その形が正しいとは言っていない。潰れた角の
    /// 形は #1893 で決める。
    @Test("置く先でだけ腕が画面で潰れる角も、その場で描いたのと同じに埋まる", arguments: [StrokeJoin.miter, .bevel])
    func retainedJoinsSurviveAnArmCollapsingWhenPlaced(_ join: StrokeJoin) throws {
        func draw(_ canvas: Canvas) {
            canvas.stroke(255, 250)
            canvas.strokeJoin(join)
            canvas.beginShape()
            canvas.vertex(-40, 0, 0)
            canvas.vertex(0, 0, 0)
            canvas.vertex(0, 0, -60)
            canvas.endShape()
        }
        let placed = try render { canvas in
            let shape = canvas.createShape { draw(canvas) }
            canvas.ortho()
            canvas.translate(80, 80, 0)
            canvas.shape(shape)
        }
        let direct = try render { canvas in
            canvas.ortho()
            canvas.translate(80, 80, 0)
            draw(canvas)
        }
        #expect(direct.count > 0)
        #expect(placed.differing(from: direct) <= 2, "違う画素 \(placed.differing(from: direct))")
    }
}
