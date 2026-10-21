// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 基本図形を置く口 (`rect` / `circle` / `arc` など)。`Canvas.swift` の MARK「図形」から、
// 図形を置く 9 本をここへ移した ([#943](https://github.com/mokume-metal/mokume/issues/943))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

extension Canvas {
    /// 矩形。座標の読み方は ``rectMode(_:)`` が決める。
    public func rect(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        placeRect(a, b, c, d, cornerRadius: 0)
    }

    /// 4 つの角を同じ半径で丸めた矩形。座標の読み方は ``rectMode(_:)`` が決める。
    public func rect(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ r: some ScalarConvertible
    ) {
        let (a, b, c, d, r) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, r.asFloat)
        // 負の半径・数でない値は 0 にして (角を丸めない)、1 度知らせる (ADR-0020 決定 5・#2757)。
        // `>=` は NaN も弾く。**+∞ は弾かない** — 「できるだけ丸く」と読めて、`placeRect` が
        // 短い辺の半分へ締める (`1e9` と同じ扱い)
        guard r >= 0 else {
            warnRounded(
                .badCornerRadius, "rect", "the corner radius", takes: "0 or more",
                passed: r, used: 0)
            return placeRect(a, b, c, d, cornerRadius: 0)
        }
        placeRect(a, b, c, d, cornerRadius: r)
    }

    /// 矩形を置く。4 引数と 5 引数の口がここへ集まる。
    ///
    /// `cornerRadius` は検め済み (0 以上・数でないものは無い) で、**ここで短い辺の半分に
    /// 締める** (Processing 4 の `PGraphics.rect` の `maxRounding` と同じ)。0 のときは角を丸めない
    /// 矩形の経路をそのまま通るので、4 引数の絵は変わらない (#2757)。
    private func placeRect(_ a: Float, _ b: Float, _ c: Float, _ d: Float, cornerRadius: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: style.rectMode)
        guard box.width > 0, box.height > 0 else { return }
        let w = box.width
        let h = box.height
        let radius = min(cornerRadius, w / 2, h / 2)
        // 距離関数で描ける間は頂点を組み立てない (`Canvas+Form.swift`)
        if formAllowed(fills: true) {
            return appendForm(
                .rect, center: SIMD2(box.x + w / 2, box.y + h / 2), half: SIMD2(w / 2, h / 2),
                fills: true, cornerRadius: radius)
        }
        // 角を丸めた矩形は、貼る絵 (`texture()`) か利用者の断片 (`shader()`) が効いている間だけ
        // ここへ来る。距離関数の経路に入れないので、角を円弧の刻みで繋いだ周で描く。畳まない
        if radius > 0 {
            let segments = Self.segmentCount(
                forRadius: radius, scale: Self.splitScale(of: transform.matrix))
            return draw(
                Self.roundedRectOutline(width: w, height: h, radius: radius, segments: segments)
                    .moved(by: SIMD2(box.x, box.y)))
        }
        // 周は**形自身の座標**で作り、左上の角を置き場所として渡す。畳まないときは
        // 角を足し戻すだけなので、絵は 1 ビットも変わらない (足す順が入れ替わるだけ)
        //
        // 4 つの角は直角なので、外向きの対角を添える。`bevel` の角を距離関数の経路と
        // 同じ線で削ぐのに使う (#1506)
        draw(folding: .rect(width: w, height: h), at: SIMD2(box.x, box.y)) { _ in
            Outline(
                points: [
                    SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h),
                ], isClosed: true,
                cornerDiagonals: [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)],
                strokesAsOneRegion: true,
                namedFill: Outline.NamedFill(
                    isEllipse: false, center: SIMD2(w / 2, h / 2), half: SIMD2(w / 2, h / 2)))
        }
    }

    /// 角を半径 `radius` の円弧で丸めた矩形の周 (形自身の座標・左上が原点)。
    ///
    /// `radius` は幅・高さの半分以下で、0 より大きい。**4 つの角を、`segments` を一周の分割数として
    /// 刻む** (円と同じ数え方・``segmentCount(forRadius:scale:)``)。弧は辺に接して繋がるので
    /// 折れ目は無く、点はどれも刻みとして円板で繋ぐ (`curveSteps`)。半径が辺の半分ちょうどで
    /// 重なる点は 1 つに畳む (長さ 0 の辺を作らない)。
    static func roundedRectOutline(
        width w: Float, height h: Float, radius r: Float, segments: Int
    ) -> Outline {
        // 辺に接する点は、三角関数の丸めを通さず座標そのものを置く
        let corners: [(center: SIMD2<Float>, start: Float)] = [
            (SIMD2(w - r, r), -.pi / 2), (SIMD2(w - r, h - r), 0),
            (SIMD2(r, h - r), .pi / 2), (SIMD2(r, r), .pi),
        ]
        let ends: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(w - r, 0), SIMD2(w, r)), (SIMD2(w, h - r), SIMD2(w - r, h)),
            (SIMD2(r, h), SIMD2(0, h - r)), (SIMD2(0, r), SIMD2(r, 0)),
        ]
        var points: [SIMD2<Float>] = []
        for (index, corner) in corners.enumerated() {
            var arc = arcOffsets(
                radiusX: r, radiusY: r, from: corner.start, sweep: .pi / 2, fullTurn: segments)
            for offset in arc.indices { arc[offset] += corner.center }
            arc[0] = ends[index].0
            arc[arc.count - 1] = ends[index].1
            for point in arc where point != points.last { points.append(point) }
        }
        if points.count > 1, points.last == points.first { points.removeLast() }
        return Outline(
            points: points, isClosed: true, fanCenter: SIMD2(w / 2, h / 2),
            curveSteps: Array(repeating: true, count: points.count), strokesAsOneRegion: true,
            namedFill: Outline.NamedFill(
                isEllipse: false, center: SIMD2(w / 2, h / 2), half: SIMD2(w / 2, h / 2)))
    }

    /// 正方形。座標の読み方は ``rectMode(_:)`` が決める。
    public func square(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ extent: some ScalarConvertible) {
        let (a, b, extent) = (a.asFloat, b.asFloat, extent.asFloat)
        rect(a, b, extent, extent)
    }

    /// 円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func circle(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ diameter: some ScalarConvertible) {
        let (a, b, diameter) = (a.asFloat, b.asFloat, diameter.asFloat)
        ellipse(a, b, diameter, diameter)
    }

    /// 楕円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func ellipse(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        let box = Self.resolveBox(a, b, c, d, mode: style.ellipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return }
        let center = SIMD2(box.x + radiusX, box.y + radiusY)
        if formAllowed(fills: true) {
            return appendForm(.ellipse, center: center, half: SIMD2(radiusX, radiusY), fills: true)
        }
        // 周は**形自身の座標**で作り、中心を置き場所として渡す。**周を作るのは畳めない
        // と分かってから** — 畳めるときは置き場所を 1 つ足すだけで、周は要らない
        draw(folding: .ellipse(radiusX: radiusX, radiusY: radiusY), at: center) { segments in
            // 周の点はどれも刻みで、角は 1 つも無い (#1423)。一周を何個に刻むかは、画面に出る
            // 半径で決まる (#1645)。鍵が持つ数で刻む
            Self.ringOutline(
                Outline.Ring(
                    radiusX: radiusX, radiusY: radiusY, start: 0, sweep: 2 * .pi,
                    segments: segments))
        }
    }

    /// 円弧。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// 塗りは中心を含む扇形で、輪郭も扇の周 (2 本の半径と弧) を回る。
    public func arc(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible
    ) {
        let (a, b, c, d, start, stop) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, start.asFloat, stop.asFloat)
        let box = Self.resolveBox(a, b, c, d, mode: style.ellipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return }
        guard stop > start else {
            warnReversedArcOnce()
            return
        }
        let sweep = min(stop - start, 2 * .pi)
        // 一周ぶんなら中心は周に含めない (楕円と同じ形になる)
        let isFullTurn = sweep >= 2 * .pi
        let center = SIMD2(box.x + radiusX, box.y + radiusY)
        if formAllowed(fills: true) {
            return isFullTurn
                ? appendForm(.ellipse, center: center, half: SIMD2(radiusX, radiusY), fills: true)
                : appendForm(
                    .arc, center: center, half: SIMD2(radiusX, radiusY),
                    arc: SIMD2(start, sweep), fills: true)
        }
        draw(
            folding: .arc(radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep),
            at: center
        ) { segments in
            // 周の点はどれも円板で埋める。弧の点は刻みで、**扇の 3 つの角 (中心と弧の両端)
            // も折れ目の形によらず丸く繋ぐ** — 距離関数の経路は 3 つの角を真の距離で丸く出し、
            // `StrokeJoin.miter` の注記もそう約束している。#1423 は 3 つの角だけを折れ目の形に
            // 従わせていたが、`texture()` / `shader()` を足しただけで角の形が変わっていた (#1486)。
            // 一周を何個に刻むかは、画面に出る半径で決まる (#1645)
            Self.ringOutline(
                Outline.Ring(
                    radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep,
                    segments: segments))
        }
    }

    /// 三角形。
    public func triangle(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ x3: some ScalarConvertible, _ y3: some ScalarConvertible
    ) {
        let (x1, y1, x2, y2, x3, y3) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat)
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3)], isClosed: true))
    }

    /// 四角形。頂点は与えた順に結ばれる。
    public func quad(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ x4: some ScalarConvertible, _ y4: some ScalarConvertible
    ) {
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
        let points = [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3), SIMD2(x4, y4)]
        // 辺が交差しない四角形は、線全体を 1 回だけ混ぜる。凹んだ形では向かい合う辺が線に沿って
        // 太さより離れたまま重なりうる (#1536 の反証)。交差する形 (砂時計) は、任意多角形の
        // 自己交差と同じく交点で 2 回混ぜる
        draw(
            Outline(
                points: points, isClosed: true, fillTriangles: Self.quadTriangles(points),
                strokesAsOneRegion: !Self.quadCrosses(points)))
    }

    /// 凸でない四角形の塗りを割る三角形。凸なら `nil` (最初の点からの扇で塗る)。
    ///
    /// 4 つの頂点は利用者が並べるので、凸とは限らない ([#1534])。4 点で閉じた計算なので、
    /// 耳切り (`Triangulation`) へは通さない — 耳切りは自己交差した周を砂時計に割れない。
    ///
    /// - **辺が交差する**: 交わる点を頂点にした三角形 2 枚 (砂時計)。回り数はどちらの
    ///   三角形も ±1 なので、nonzero でも even-odd でも同じ形になる
    /// - **凹んでいる**: 凹んだ点を要にした扇。凹んだ点からの対角線は必ず形の中を通る
    /// - **凸**: `nil`。凸の四角形の割り方は変えない
    ///
    /// [#1534]: https://github.com/mokume-metal/mokume/issues/1534
    static func quadTriangles(_ p: [SIMD2<Float>])
        -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]?
    {
        switch quadShape(p[0], p[1], p[2], p[3]) {
        case .crossing(pair: 0, point: let x):
            return [(p[1], p[2], x), (p[3], p[0], x)]
        case .crossing(pair: _, point: let x):
            return [(p[0], p[1], x), (p[2], p[3], x)]
        case .concave(let dent):
            let (a, b, c, d) = (p[dent], p[(dent + 1) % 4], p[(dent + 2) % 4], p[(dent + 3) % 4])
            return [(a, b, c), (a, c, d)]
        case .convex:
            return nil
        }
    }

    /// 4 つの頂点がなす形。**`quad()` と `beginShape(.quads)` が、割り方をこの判定で決める**
    /// (``quadShape(_:_:_:_:)``)。
    enum QuadShape: Equatable {
        /// 凸 (辺が交差せず、凹んだ角も無い)。
        case convex
        /// 凹んでいる。`dent` が凹んだ点の番号で、そこからの対角線は必ず形の中を通る。
        case concave(dent: Int)
        /// 向かい合う辺が交わる (砂時計)。`pair` が 0 なら辺 0–1 と辺 2–3、1 なら辺 1–2 と
        /// 辺 3–0 が交わり、`point` がその交点。
        case crossing(pair: Int, point: SIMD2<Float>)
    }

    /// 4 点がなす形を判定する。番号でなく 4 つの点を受けるのは、`beginShape(.quads)` が
    /// 四角 1 枚ごとに呼ぶので、配列を作らずに済ませるため。
    static func quadShape(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>
    ) -> QuadShape {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

        if let x = segmentCrossing(p0, p1, p2, p3) { return .crossing(pair: 0, point: x) }
        if let x = segmentCrossing(p1, p2, p3, p0) { return .crossing(pair: 1, point: x) }
        // 回る向きと逆に曲がる角が、凹んだ点である。交差しない四角形では高々 1 つ
        let area = cross(p2 - p0, p3 - p1)
        let turns = SIMD4<Float>(
            cross(p0 - p3, p1 - p0), cross(p1 - p0, p2 - p1),
            cross(p2 - p1, p3 - p2), cross(p3 - p2, p0 - p3))
        for index in 0..<4 where turns[index] * area < 0 { return .concave(dent: index) }
        return .convex
    }

    /// 線分 ab と cd が、端点以外の 1 点で交わるなら、その点。
    private static func segmentCrossing(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> SIMD2<Float>? {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let dc = cross(b - a, c - a)
        let dd = cross(b - a, d - a)
        let da = cross(d - c, a - c)
        let db = cross(d - c, b - c)
        guard dc * dd < 0, da * db < 0 else { return nil }
        return a + (b - a) * (da / (da - db))
    }

    /// 四角形の向かい合う辺が交わるか (砂時計の形か)。``quadTriangles(_:)`` と同じ判定。
    static func quadCrosses(_ p: [SIMD2<Float>]) -> Bool {
        segmentCrossing(p[0], p[1], p[2], p[3]) != nil || segmentCrossing(p[1], p[2], p[3], p[0]) != nil
    }

    // 線。塗りは持たない。
    public func line(_ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible) {
        let (x1, y1, x2, y2) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat)
        if formAllowed(fills: false) {
            if let dash = style.strokeDash {
                return appendDashedLineForms(SIMD2(x1, y1), SIMD2(x2, y2), by: dash)
            }
            return appendLineForm(SIMD2(x1, y1), SIMD2(x2, y2))
        }
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2)], isClosed: false, fills: false))
    }

    /// 点。大きさは線の太さ、形は端点の形 (``strokeCap(_:)``) が決める。
    public func point(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        if formAllowed(fills: false) {
            return appendPointForm(SIMD2(x, y))
        }
        draw(Outline(points: [SIMD2(x, y)], isClosed: false, fills: false))
    }

    // 立体の空間に線を引く。視点と奥行きを通る。
    public func line(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ z1: some ScalarConvertible,
        _ x2: some ScalarConvertible, _ y2: some ScalarConvertible, _ z2: some ScalarConvertible
    ) {
        let (x1, y1, z1, x2, y2, z2) = (x1.asFloat, y1.asFloat, z1.asFloat, x2.asFloat, y2.asFloat, z2.asFloat)
        placeSolidVertices(.lines, [SIMD3(x1, y1, z1), SIMD3(x2, y2, z2)])
    }

    // 立体の空間に点を打つ。視点と奥行きを通る。
    public func point(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        placeSolidVertices(.points, [SIMD3(x, y, z)])
    }

    /// 奥行きを持つ頂点を並べた形を 1 つ置く。**`beginShape(kind)`・`vertex(x, y, z)`・`endShape()`
    /// と同じ道を通る** — 3 次元の `line`・`point` に別の描き方を持たせない ([ADR-0021] 決定 5)。
    ///
    /// 組み立て中の形 (`beginShape()` を開いたまま) があれば、退かせて置き、戻す
    /// (``takeOpenShape()``・``restoreOpenShape(_:)``)。2 次元の `line`・`point` が開いた形に
    /// 触らないのと揃える。退かせずに開くと、`beginShape()` が開いた形を描かずに捨てる。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    func placeSolidVertices(_ kind: VertexKind, _ points: [SIMD3<Float>]) {
        // 置けない区間なら、開く前に 1 度だけ断る。開く口に断らせると、続く `vertex()` が
        // 「開いていない形への頂点」の注意まで言う
        guard canPlace else { return warnOutsideFrame(.placing) }
        let open = takeOpenShape()
        defer { restoreOpenShape(open) }
        beginShape(kind)
        for point in points { vertex(point.x, point.y, point.z) }
        endShape()
    }

}
