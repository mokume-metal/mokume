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
    public func rect(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
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
        draw(folding: .rect(width: w, height: h), at: SIMD2(box.x, box.y)) {
            Outline(
                points: [
                    SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h),
                ], isClosed: true)
        }
    }

    /// 正方形。座標の読み方は ``rectMode(_:)`` が決める。
    public func square(_ a: Float, _ b: Float, _ extent: Float) {
        rect(a, b, extent, extent)
    }

    /// 円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func circle(_ a: Float, _ b: Float, _ diameter: Float) {
        ellipse(a, b, diameter, diameter)
    }

    /// 楕円。座標の読み方は ``ellipseMode(_:)`` が決める。
    public func ellipse(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        let box = Self.resolveBox(a, b, c, d, mode: currentEllipseMode)
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
            Outline(
                points: Self.arcPoints(
                    center: SIMD2(0, 0), radiusX: radiusX, radiusY: radiusY,
                    from: 0, sweep: 2 * .pi),
                isClosed: true, fanCenter: SIMD2(0, 0))
        }
    }

    /// 円弧。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// 塗りは中心を含む扇形で、輪郭も扇の周 (2 本の半径と弧) を回る。
    public func arc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float
    ) {
        let box = Self.resolveBox(a, b, c, d, mode: currentEllipseMode)
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
            return Outline(
                points: isFullTurn ? arcPoints : [SIMD2(0, 0)] + arcPoints,
                isClosed: true, fanCenter: SIMD2(0, 0))
        }
    }

    /// 三角形。
    public func triangle(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float
    ) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3)], isClosed: true))
    }

    /// 四角形。頂点は与えた順に結ばれる。
    public func quad(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
        _ x3: Float, _ y3: Float, _ x4: Float, _ y4: Float
    ) {
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2), SIMD2(x3, y3), SIMD2(x4, y4)],
                isClosed: true))
    }

    // 線。塗りは持たない。
    public func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        if formAllowed(fills: false) {
            return appendLineForm(SIMD2(x1, y1), SIMD2(x2, y2))
        }
        draw(
            Outline(
                points: [SIMD2(x1, y1), SIMD2(x2, y2)], isClosed: false, fills: false))
    }

    /// 点。大きさは線の太さ、形は端点の形 (``strokeCap(_:)``) が決める。
    public func point(_ x: Float, _ y: Float) {
        if formAllowed(fills: false) {
            return appendPointForm(SIMD2(x, y))
        }
        draw(Outline(points: [SIMD2(x, y)], isClosed: false, fills: false))
    }

}
