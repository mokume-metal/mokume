// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import simd

/// 並べている途中の頂点 1 つぶん。
///
/// **平面と立体で同じものを溜める。** 立体で増えるのは頂点の中身 (奥行き・面の向き)
/// であって、形の種類ごとの対応表ではない ([ADR-0021] 決定 5)。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
struct BuildingVertex {
    /// 形自身の座標。変換は描くときに 1 度だけ掛かる。
    var position: SIMD3<Float>
    /// 面の向き。`nil` は**書かれていない**という意味で、形から求める。
    var normal: SIMD3<Float>?
    /// 貼る絵のどこを読むか (0…1)。`nil` は**書かれていない**という意味で、
    /// 形の囲みの箱から求める。
    var uv: SIMD2<Float>?
    /// 置いた時点の塗り。
    var fill: LinearRGBA
}

// 頂点を並べて形を作る。**道具は 1 つで、平面と立体に分かれない** ([ADR-0021] 決定 5)。
// 意味の説明は利用者が最初に触る層 (`Sketch`) が正本 ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // MARK: - 並べる

    // 頂点を並べ始める。
    public func beginShape(_ kind: VertexKind = .polygon) {
        isBuildingShape = true
        shapeKind = kind
        shapeHasDepth = false
        currentNormal = nil
        shapePoints.removeAll(keepingCapacity: true)
        shapeHoles.removeAll(keepingCapacity: true)
        curveGuides.removeAll(keepingCapacity: true)
        holePoints = nil
    }

    public func vertex(_ x: Float, _ y: Float) {
        appendVertex(SIMD3(x, y, 0), hasDepth: false)
    }

    // 奥行きを持つ頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float, _ z: Float) {
        appendVertex(SIMD3(x, y, z), hasDepth: true)
    }

    // 貼る絵の読み取り位置つきで頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float, _ u: Float, _ v: Float) {
        appendVertex(SIMD3(x, y, 0), hasDepth: false, uv: textureUV(u, v))
    }

    // 奥行きと読み取り位置を持つ頂点を 1 つ置く。
    public func vertex(_ x: Float, _ y: Float, _ z: Float, _ u: Float, _ v: Float) {
        appendVertex(SIMD3(x, y, z), hasDepth: true, uv: textureUV(u, v))
    }

    /// 書かれた読み取り位置を、面の中の 0…1 へ写す。
    ///
    /// **受け取るのは画像の画素**である (手本の既定と、``image(_:_:_:_:_:_:_:_:_:)`` の
    /// 切り出しに揃える)。貼る絵を束ねていなければ写す先が無いので、書かれていない
    /// ことにする — そのときの頂点は焼き場の白い区画を読み、絵は変わらない。
    private func textureUV(_ u: Float, _ v: Float) -> SIMD2<Float>? {
        guard let picture = currentPicture, picture.width > 0, picture.height > 0,
            u.isFinite, v.isFinite
        else { return nil }
        return SIMD2(u / Float(picture.width), v / Float(picture.height))
    }

    // これから置く頂点の面の向きを決める。
    public func normal(_ x: Float, _ y: Float, _ z: Float) {
        let direction = SIMD3<Float>(x, y, z)
        // 長さを持たない向き・数でない向きは「書かれていない」に倒す。零ベクトルを
        // そのまま持たせると、光の計算で向きの定まらない面になる
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
            length_squared(direction) > 0
        else {
            currentNormal = nil
            return
        }
        currentNormal = normalize(direction)
    }

    public func bezierVertex(
        _ cx1: Float, _ cy1: Float, _ cx2: Float, _ cy2: Float, _ x: Float, _ y: Float
    ) {
        guard isBuildingShape, let start = lastShapePoint else {
            warnVertexOutsideShapeOnce()
            return
        }
        let c1 = SIMD2(cx1, cy1)
        let c2 = SIMD2(cx2, cy2)
        let end = SIMD2(x, y)
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            appendShapePoint(Self.cubicPoint(start, c1, c2, end, t))
        }
    }

    public func quadraticVertex(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        guard isBuildingShape, let start = lastShapePoint else {
            warnVertexOutsideShapeOnce()
            return
        }
        // 2 次は 3 次の特別な形として通す — 曲線の道具を 1 本に保つ
        let control = SIMD2(cx, cy)
        let end = SIMD2(x, y)
        let c1 = start + (control - start) * (2.0 / 3.0)
        let c2 = end + (control - end) * (2.0 / 3.0)
        bezierVertex(c1.x, c1.y, c2.x, c2.y, end.x, end.y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける** — 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが実際に描かれる。
    public func curveVertex(_ x: Float, _ y: Float) {
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce()
            return
        }
        curveGuides.append(SIMD2(x, y))
        guard curveGuides.count >= 4 else { return }
        let count = curveGuides.count
        let p0 = curveGuides[count - 4]
        let p1 = curveGuides[count - 3]
        let p2 = curveGuides[count - 2]
        let p3 = curveGuides[count - 1]
        if shapePoints.isEmpty { appendShapePoint(p1) }
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            appendShapePoint(
                Self.catmullRomPoint(p0, p1, p2, p3, t, tightness: currentCurveTightness))
        }
    }

    public func curveDetail(_ steps: Int) { currentCurveDetail = max(1, steps) }

    public func curveTightness(_ amount: Float) { currentCurveTightness = amount }

    public func beginContour() {
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce()
            return
        }
        holePoints = []
    }

    public func endContour() {
        guard let hole = holePoints else { return }
        if hole.count >= 3 { shapeHoles.append(hole) }
        holePoints = nil
    }

    public func endShape(_ end: ShapeEnd = .open) {
        defer {
            isBuildingShape = false
            shapePoints.removeAll(keepingCapacity: true)
            shapeHoles.removeAll(keepingCapacity: true)
            curveGuides.removeAll(keepingCapacity: true)
            holePoints = nil
            shapeHasDepth = false
            currentNormal = nil
        }
        guard isBuildingShape else { return }
        endContour()  // 閉じ忘れた穴も畳む
        drawBuiltShape(closed: end == .close)
    }

    // MARK: - 閉じる

    /// 並べ終えた頂点をどう読むか。
    ///
    /// 種類ごとに違う描き方をするのではなく、**どの種類も「原始形の一覧」へ畳んでから
    /// 同じ手順で出す**。塗りと線の出る順序が種類によって変わらない。
    private struct Primitive {
        /// 外周をなす頂点の番号。
        var ring: [Int]
        /// 穴をなす頂点の番号。
        var holes: [[Int]] = []
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 塗りを持つか (線と点は持たない)。
        var fills: Bool
    }

    /// 変換を掛けた頂点。立体だけが使う。
    private struct PlacedVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        /// 向きを形から求めたか。**求めた向きだけ両面として扱う** (``SolidVertex/normal``)。
        var isDerived: Bool
        var color: LinearRGBA
        /// 変換を掛ける**前**の面の向き。利用者の断片へ渡す (``SolidVertex/shapeNormal``)。
        var shapeNormal: SIMD3<Float>
    }

    /// 並べ終えた頂点を描く。
    private func drawBuiltShape(closed: Bool) {
        let points = shapePoints + shapeHoles.flatMap { $0 }
        guard !points.isEmpty else { return }
        let primitives = builtPrimitives(closed: closed)

        // **塗る三角形を先に全部求める。** 面の向きは形の全体から求めるので、出す前に
        // 揃っている必要がある — 3 つずつ独立に処理すると、帯状・扇状に並べたときに
        // 後ろの頂点が書かれないまま残る
        let triangles = primitives.map { fillTriangles(of: $0, points: points) }
        let placed = shapeHasDepth
            ? placedVertices(points, triangles: triangles.flatMap { $0 })
            : []

        emit {
            for (primitive, triangles) in zip(primitives, triangles) {
                // **原始形ごとに 塗り → 線。** 種類によらず同じ順序なので、線が
                // 隣の原始形の塗りに隠れることがない
                emitFill(triangles, points: points, placed: placed)
                if hasStroke, currentStrokeWeight > 0 {
                    emitStroke(primitive, points: points, placed: placed)
                }
            }
        }
    }

    /// 立体なら立体の並びへ溜める区間を開き、平面ならそのまま実行する。
    private func emit(_ body: () -> Void) {
        guard shapeHasDepth else { return body() }
        inSolidBatch(body)
    }

    /// 並べ終えた頂点を原始形の一覧へ畳む。
    private func builtPrimitives(closed: Bool) -> [Primitive] {
        let outer = Array(shapePoints.indices)
        switch shapeKind {
        case .polygon:
            var holes: [[Int]] = []
            var next = shapePoints.count
            for hole in shapeHoles {
                holes.append(Array(next..<(next + hole.count)))
                next += hole.count
            }
            return [Primitive(ring: outer, holes: holes, isClosed: closed, fills: true)]

        case .triangles:
            return stride(from: 0, to: max(0, outer.count - 2), by: 3).map {
                Primitive(ring: Array(outer[$0..<($0 + 3)]), isClosed: true, fills: true)
            }

        case .lines:
            return stride(from: 0, to: max(0, outer.count - 1), by: 2).map {
                Primitive(ring: Array(outer[$0..<($0 + 2)]), isClosed: false, fills: false)
            }

        case .points:
            return outer.map { Primitive(ring: [$0], isClosed: false, fills: false) }
        }
    }

    /// 原始形を三角形へ分ける。返すのは頂点の番号の 3 つ組。
    private func fillTriangles(of primitive: Primitive, points: [BuildingVertex])
        -> [(Int, Int, Int)]
    {
        guard primitive.fills, hasFill, primitive.ring.count >= 3 else { return [] }
        guard let flattened = flattened(primitive, points: points) else { return [] }
        let merged =
            primitive.holes.isEmpty
            ? primitive.ring
            : Triangulation.mergeHoles(
                outer: primitive.ring, holes: primitive.holes, points: flattened)
        return Triangulation.triangulate(merged.map { flattened[$0] })
            .map { (merged[$0.0], merged[$0.1], merged[$0.2]) }
    }

    /// 三角形へ分けるための、平らな座標。
    ///
    /// 立体は**外周のなす平面へ落としてから**、平面と同じ三角形化の道具へ通す。穴も
    /// 同じ平面へ落とすので、穴が「一部の経路でだけ効く」ことにならない。
    /// 平面が決まらない (点が一直線に並ぶ・重なる) ときは `nil` を返して塗らない。
    private func flattened(_ primitive: Primitive, points: [BuildingVertex]) -> [SIMD2<Float>]? {
        guard shapeHasDepth else {
            return points.map { SIMD2($0.position.x, $0.position.y) }
        }

        // 周をひと回りしながら面の向きを積む。三角形 1 つから求めると、少しでも
        // 平らでない形で平面を取り違える
        var normal = SIMD3<Float>.zero
        let ring = primitive.ring
        for index in ring.indices {
            let a = points[ring[index]].position
            let b = points[ring[(index + 1) % ring.count]].position
            normal += SIMD3(
                (a.y - b.y) * (a.z + b.z),
                (a.z - b.z) * (a.x + b.x),
                (a.x - b.x) * (a.y + b.y))
        }
        guard length_squared(normal) > 0 else { return nil }
        normal = normalize(normal)

        // 平面の上で直交する 2 本を選ぶ。どちらを選んでも分け方は変わらない
        let seed = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let across = normalize(cross(seed, normal))
        let along = cross(normal, across)
        return points.map { SIMD2(dot($0.position, across), dot($0.position, along)) }
    }

    /// 変換を掛け、書かれていない面の向きを形から求める。
    private func placedVertices(_ points: [BuildingVertex], triangles: [(Int, Int, Int)])
        -> [PlacedVertex]
    {
        let matrix = transform.matrix
        let normalMatrix = transform.normalMatrix
        var placed = points.map { point -> PlacedVertex in
            let moved = matrix * SIMD4<Float>(point.position, 1)
            return PlacedVertex(
                position: SIMD3(moved.x, moved.y, moved.z),
                normal: point.normal.map { normalize(normalMatrix * $0) } ?? .zero,
                isDerived: point.normal == nil,
                color: point.fill,
                shapeNormal: point.normal ?? .zero)
        }

        // **書かれていない向きは、その頂点が属する三角形の向きを足し込んで求める。**
        // 三角形 3 つぶんずつ独立に処理すると、帯状・扇状に並べたときに後ろの頂点だけ
        // 書かれないまま残る
        //
        // **変換の前と後で 2 度足し込む。** 片方から他方を導けば 1 度で済むが、
        // 導いた値は既存の値と最下位ビットが揃わず、触っていない絵の台帳まで動く。
        // 光へ渡る向き (後) は 1 ビットも変えたくないので、断片へ渡す向き (前) を
        // 別に積む
        var accumulated = [SIMD3<Float>](repeating: .zero, count: points.count)
        var accumulatedInShape = [SIMD3<Float>](repeating: .zero, count: points.count)
        for triangle in triangles {
            let a = placed[triangle.0].position
            let b = placed[triangle.1].position
            let c = placed[triangle.2].position
            let face = cross(b - a, c - a)
            accumulated[triangle.0] += face
            accumulated[triangle.1] += face
            accumulated[triangle.2] += face

            let p = points[triangle.0].position
            let q = points[triangle.1].position
            let r = points[triangle.2].position
            let shapeFace = cross(q - p, r - p)
            accumulatedInShape[triangle.0] += shapeFace
            accumulatedInShape[triangle.1] += shapeFace
            accumulatedInShape[triangle.2] += shapeFace
        }
        for index in placed.indices where points[index].normal == nil {
            let sum = accumulated[index]
            placed[index].normal = length_squared(sum) > 0 ? normalize(sum) : .zero
            let shapeSum = accumulatedInShape[index]
            placed[index].shapeNormal = length_squared(shapeSum) > 0 ? normalize(shapeSum) : .zero
        }
        return placed
    }

    /// 塗りを出す。
    ///
    /// 貼る絵があれば読み取り位置を付ける。**書かれていない頂点は形の囲みの箱 (xy) から
    /// 作る** — 組み込みの図形と同じ既定に倒すためで、書き忘れた形が絵の 1 画素だけで
    /// 塗り潰される (手本がそうなる) のを避ける。
    private func emitFill(
        _ triangles: [(Int, Int, Int)], points: [BuildingVertex], placed: [PlacedVertex]
    ) {
        let fallback = currentPicture == nil
            ? nil : Canvas.boxUV(of: points.map { SIMD2($0.position.x, $0.position.y) })
        func uv(_ index: Int) -> SIMD2<Float>? {
            guard let fallback else { return nil }
            return points[index].uv ?? fallback(
                SIMD2(points[index].position.x, points[index].position.y))
        }

        for triangle in triangles {
            let indices = [triangle.0, triangle.1, triangle.2]
            if shapeHasDepth {
                for index in indices {
                    let vertex = placed[index]
                    // **変換を焼き込む前の座標と向きも渡す。** 断片へ届くのはそちらで、
                    // 組み込みの立体と同じく「回しても模様が形に留まる」ようにする
                    appendSolidVertex(
                        position: vertex.position, shapePosition: points[index].position,
                        normal: vertex.normal, shapeNormal: vertex.shapeNormal,
                        isDerived: vertex.isDerived, uv: uv(index), color: vertex.color)
                }
            } else {
                let flat = indices.map {
                    transform.apply(x: points[$0].position.x, y: points[$0].position.y)
                }
                appendTriangle(
                    flat[0], flat[1], flat[2],
                    colors: (points[indices[0]].fill, points[indices[1]].fill,
                        points[indices[2]].fill),
                    uvs: fallback == nil
                        ? nil
                        : (uv(indices[0])!, uv(indices[1])!, uv(indices[2])!))
            }
        }
    }

    /// 線を出す。**穴の縁も輪郭を持つ。**
    private func emitStroke(
        _ primitive: Primitive, points: [BuildingVertex], placed: [PlacedVertex]
    ) {
        strokeRing(primitive.ring, closed: primitive.isClosed, points: points, placed: placed)
        for hole in primitive.holes {
            strokeRing(hole, closed: true, points: points, placed: placed)
        }
    }

    private func strokeRing(
        _ ring: [Int], closed: Bool, points: [BuildingVertex], placed: [PlacedVertex]
    ) {
        guard !ring.isEmpty else { return }
        if shapeHasDepth {
            strokeSolidRing(
                ring.map { placed[$0].position }, shapePoints: ring.map { points[$0].position },
                isClosed: closed)
        } else {
            // 平面の輪郭は変換の前の座標で組み立てる (`Outline` の説明を参照)
            strokeOutline(
                Outline(
                    points: ring.map { SIMD2(points[$0].position.x, points[$0].position.y) },
                    isClosed: closed, fills: false))
        }
    }

    // MARK: - 溜める

    private var lastShapePoint: SIMD2<Float>? {
        (holePoints?.last ?? shapePoints.last).map { SIMD2($0.position.x, $0.position.y) }
    }

    /// 曲線が作った点を置く。奥行きは直前の点から引き継ぐ。
    private func appendShapePoint(_ point: SIMD2<Float>) {
        let depth = (holePoints?.last ?? shapePoints.last)?.position.z ?? 0
        appendVertex(SIMD3(point.x, point.y, depth), hasDepth: false)
    }

    private func appendVertex(
        _ position: SIMD3<Float>, hasDepth: Bool, uv: SIMD2<Float>? = nil
    ) {
        guard isBuildingShape else { return warnVertexOutsideShapeOnce() }
        // 数でない座標は形を壊すだけなので置かない ([ADR-0020] 決定 5)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            return warnBadVertexOnce()
        }
        if hasDepth { shapeHasDepth = true }
        let vertex = BuildingVertex(
            position: position, normal: currentNormal, uv: uv, fill: currentFill)
        if holePoints != nil {
            holePoints?.append(vertex)
        } else {
            shapePoints.append(vertex)
        }
    }

    /// 3 次の曲線の上の点。
    static func cubicPoint(
        _ p0: SIMD2<Float>, _ c1: SIMD2<Float>, _ c2: SIMD2<Float>, _ p1: SIMD2<Float>, _ t: Float
    ) -> SIMD2<Float> {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// 通過点を結ぶ曲線の上の点。`tightness` が 0 のとき、4 点のうち中の 2 点を滑らかに繋ぐ。
    static func catmullRomPoint(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
        _ t: Float, tightness: Float
    ) -> SIMD2<Float> {
        let s = (1 - tightness) / 2
        let t2 = t * t
        let t3 = t2 * t
        let m1 = (p2 - p0) * s
        let m2 = (p3 - p1) * s
        return p1 * (2 * t3 - 3 * t2 + 1)
            + m1 * (t3 - 2 * t2 + t)
            + p2 * (-2 * t3 + 3 * t2)
            + m2 * (t3 - t2)
    }

    private func warnVertexOutsideShapeOnce() {
        guard !warnedVertexOutsideShape else { return }
        warnedVertexOutsideShape = true
        Diagnostics.warn(
            "vertex(): beginShape() と endShape() の間で呼んでください。この呼び出しは何もしません")
    }

    private func warnBadVertexOnce() {
        guard !warnedBadVertex else { return }
        warnedBadVertex = true
        Diagnostics.warn(
            "vertex(): 数でない座標・無限の座標が渡されたので、その頂点は置きませんでした")
    }
}
