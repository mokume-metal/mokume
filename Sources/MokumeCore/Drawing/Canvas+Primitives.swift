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
        let box = Self.resolveBox(a, b, c, d, mode: style.rectMode)
        guard box.width > 0, box.height > 0 else { return }
        let w = box.width
        let h = box.height
        // 距離関数で描ける間は頂点を組み立てない (`Canvas+Form.swift`)
        if formAllowed(fills: true) {
            return appendForm(
                .rect, center: SIMD2(box.x + w / 2, box.y + h / 2), half: SIMD2(w / 2, h / 2),
                fills: true)
        }
        // 周は**形自身の座標**で作り、左上の角を置き場所として渡す。畳まないときは
        // 角を足し戻すだけなので、絵は 1 ビットも変わらない (足す順が入れ替わるだけ)
        //
        // 4 つの角は直角なので、外向きの対角を添える。`bevel` の角を距離関数の経路と
        // 同じ線で削ぐのに使う (#1506)
        draw(folding: .rect(width: w, height: h), at: SIMD2(box.x, box.y)) {
            Outline(
                points: [
                    SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h),
                ], isClosed: true,
                cornerDiagonals: [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)])
        }
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
        draw(folding: .ellipse(radiusX: radiusX, radiusY: radiusY), at: center) {
            let points = Self.arcPoints(
                center: SIMD2(0, 0), radiusX: radiusX, radiusY: radiusY,
                from: 0, sweep: 2 * .pi)
            // 周の点はどれも刻みで、角は 1 つも無い (#1423)
            return Outline(
                points: points, isClosed: true, fanCenter: SIMD2(0, 0),
                curveSteps: Array(repeating: true, count: points.count))
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
        ) {
            let arcPoints = Self.arcPoints(
                center: SIMD2(0, 0), radiusX: radiusX, radiusY: radiusY,
                from: start, sweep: sweep)
            // 周の点はどれも円板で埋める。弧の点は刻みで、**扇の 3 つの角 (中心と弧の両端)
            // も折れ目の形によらず丸く繋ぐ** — 距離関数の経路は 3 つの角を真の距離で丸く出し、
            // `StrokeJoin.miter` の注記もそう約束している。#1423 は 3 つの角だけを折れ目の形に
            // 従わせていたが、`texture()` / `shader()` を足しただけで角の形が変わっていた (#1486)
            let points = isFullTurn ? arcPoints : [SIMD2(0, 0)] + arcPoints
            return Outline(
                points: points, isClosed: true, fanCenter: SIMD2(0, 0),
                curveSteps: Array(repeating: true, count: points.count))
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
        draw(Outline(points: points, isClosed: true, fillTriangles: Self.quadTriangles(points)))
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
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        /// 線分 ab と cd が、端点以外の 1 点で交わるなら、その点。
        func crossing(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>)
            -> SIMD2<Float>?
        {
            let dc = cross(b - a, c - a)
            let dd = cross(b - a, d - a)
            let da = cross(d - c, a - c)
            let db = cross(d - c, b - c)
            guard dc * dd < 0, da * db < 0 else { return nil }
            return a + (b - a) * (da / (da - db))
        }

        if let x = crossing(p[0], p[1], p[2], p[3]) {
            return [(p[1], p[2], x), (p[3], p[0], x)]
        }
        if let x = crossing(p[1], p[2], p[3], p[0]) {
            return [(p[0], p[1], x), (p[2], p[3], x)]
        }
        // 回る向きと逆に曲がる角が、凹んだ点である。交差しない四角形では高々 1 つ
        let area = cross(p[2] - p[0], p[3] - p[1])
        let dent = (0..<4).first { index in
            let turn = cross(p[index] - p[(index + 3) % 4], p[(index + 1) % 4] - p[index])
            return turn * area < 0
        }
        guard let dent else { return nil }
        let (a, b, c, d) = (p[dent], p[(dent + 1) % 4], p[(dent + 2) % 4], p[(dent + 3) % 4])
        return [(a, b, c), (a, c, d)]
    }

    // 線。塗りは持たない。
    public func line(_ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible) {
        let (x1, y1, x2, y2) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat)
        if formAllowed(fills: false) {
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

}
