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
            // 破線の輪郭は、塗りだけを距離関数で置き、輪郭は破線の片で引く (#2835)
            if dashedStroke != nil {
                let outline =
                    radius > 0
                    ? Self.roundedRectOutline(
                        width: w, height: h, radius: radius,
                        segments: Self.segmentCount(
                            forRadius: radius, scale: Self.splitScale(of: transform.matrix))
                    ).moved(by: SIMD2(box.x, box.y))
                    : Outline(
                        points: [
                            SIMD2(box.x, box.y), SIMD2(box.x + w, box.y), SIMD2(box.x + w, box.y + h),
                            SIMD2(box.x, box.y + h),
                        ], isClosed: true)
                return appendDashedForm(
                    .rect, center: SIMD2(box.x + w / 2, box.y + h / 2), half: SIMD2(w / 2, h / 2),
                    cornerRadius: radius, outline: outline)
            }
            return appendForm(
                .rect, center: SIMD2(box.x + w / 2, box.y + h / 2), half: SIMD2(w / 2, h / 2),
                fills: true, cornerRadius: radius)
        }
        // 角を丸めた矩形は、貼る絵 (`texture()`) か利用者の断片 (`shader()`) が効いている間だけ
        // ここへ来る。距離関数の経路に入れないので、角を円弧の刻みで繋いだ周で描く。
        if radius > 0 {
            // **塗りだけのときは、角を丸めない矩形と同じく畳む** (#3170)。周は形自身の座標で作って左上の角を
            // 置き場所として渡し、角の弧の刻みは鍵が持つ数 (置き場所の拡大で決まる整数) で刻む。
            // **輪郭があれば畳まず、置き場所ごとに組む。** 畳んだ雛形は輪郭の頂点を「雛形の座標を置き場所の
            // 行列で移す」順で置き、畳まない道は「位置を足してから移す」順で置くので、縁の頂点が 1 ulp 違い、
            // 縁の画素が畳まない絵と変わりうる (16×10・半径 5・`strokeWeight(0.7)`・回転 0.29 で 3 成分)。
            // 絵を動かさない約束 (完了条件 2) を守るため、輪郭つきは今までの道に残す
            if !(style.hasStroke && style.strokeWeight > 0) {
                return draw(folding: .roundedRect(width: w, height: h, radius: radius), at: SIMD2(box.x, box.y)) {
                    segments in
                    Self.roundedRectOutline(width: w, height: h, radius: radius, segments: segments)
                }
            }
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
            if dashedStroke != nil {
                return appendDashedForm(
                    .ellipse, center: center, half: SIMD2(radiusX, radiusY),
                    outline: ringOutlineForDash(
                        radiusX: radiusX, radiusY: radiusY, start: 0, sweep: 2 * .pi,
                        piece: .sector, at: center))
            }
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
                    segments: segments, piece: .sector))
        }
    }

    /// 円弧。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// 塗りは中心を含む扇形で、輪郭は開いた弧 (中心へ半径を引かない)。閉じ方を選ぶなら
    /// ``arc(_:_:_:_:_:_:_:)`` を使う。
    public func arc(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible
    ) {
        placeArc(a.asFloat, b.asFloat, c.asFloat, d.asFloat, start.asFloat, stop.asFloat, mode: nil)
    }

    /// 円弧を、閉じ方 (``ArcMode``) を選んで描く。座標の読み方は ``ellipseMode(_:)`` が決める。
    ///
    /// `.pie` は塗りも輪郭も扇、`.chord` は弧の両端を弦で結んだ形、`.open` は輪郭を閉じない
    /// (塗りは弦で結んだ形)。
    public func arc(
        _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible,
        _ mode: ArcMode
    ) {
        placeArc(a.asFloat, b.asFloat, c.asFloat, d.asFloat, start.asFloat, stop.asFloat, mode: mode)
    }

    /// 円弧を置く。`mode` が `nil` なら、渡さなかったとき (塗りは扇・輪郭は開いた弧)。
    ///
    /// **距離関数の経路で描ける図形は、閉じ方によらず 1 つの置き場所・1 つの断片で描く** (``FormInstance/ArcClosure``)。
    /// 塗りが扇か弦で結んだ形か、輪郭が扇の周・弦で結んだ形の周・開いた弧の帯のどれかは、断片が閉じ方から決める。
    /// だから既定の `arc` も縁を滑らかにして出し、塗りと輪郭を 1 つの断片で重ねる約束 (ADR-0039 決定 5) も、
    /// 閉じ方の違う `arc` が同じ列に並ぶ性質も、`.pie` と変わらない。
    ///
    /// 距離関数の経路を使えないとき — `texture()` か `shader()` を効かせた塗りは三角形の経路へ — は、輪郭の周
    /// (``Outline``) を部分ごとに組んで描く (``placeArcInParts(mode:center:radiusX:radiusY:start:sweep:)``)。
    /// 破線の輪郭 (#2835) は、塗りを距離関数のまま置き、輪郭だけを周の片で引く。
    ///
    /// **一周は、どの閉じ方でも楕円と同じ** (終わりが始まりの 2π 以上先なら、閉じ方に差が出る端が無い)。
    private func placeArc(
        _ a: Float, _ b: Float, _ c: Float, _ d: Float, _ start: Float, _ stop: Float, mode: ArcMode?
    ) {
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
        let closure = mode.map(\.closure) ?? .standard
        let drawsStroke = style.hasStroke && style.strokeWeight > 0
        // **外接は閉じ方の幾何で決まり、描く経路にも塗り・輪郭の有無にも依らない** (``Shape/bounds``・#2428)。
        // 距離関数の経路は置き場所が幾何を持つが、三角形の経路 (`texture()` / `shader()`) と塗りを止めた破線の
        // 輪郭は置き場所を足さない。その経路が頂点や周の点から外接を出すと、塗りを止めた既定の弧が扇の中心を落とすので、
        // 描かない置き場所で幾何を渡す。何も描かない (塗りも輪郭も無い) 弧は外接も持たない
        if !isFullTurn, recordingShape, canPlace, style.hasFill || drawsStroke,
            !(formAllowed(fills: true) && (dashedStroke == nil || style.hasFill))
        {
            noteGeometryForm(
                .arc, center: center, half: SIMD2(radiusX, radiusY), arc: SIMD2(start, sweep),
                arcClosure: closure)
        }
        if formAllowed(fills: true) {
            if dashedStroke != nil {
                return isFullTurn
                    ? appendDashedForm(
                        .ellipse, center: center, half: SIMD2(radiusX, radiusY),
                        outline: ringOutlineForDash(
                            radiusX: radiusX, radiusY: radiusY, start: 0, sweep: 2 * .pi,
                            piece: .sector, at: center))
                    : appendDashedForm(
                        .arc, center: center, half: SIMD2(radiusX, radiusY), arc: SIMD2(start, sweep),
                        arcClosure: closure,
                        outline: ringOutlineForDash(
                            radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep,
                            piece: closure.strokePiece, at: center))
            }
            return isFullTurn
                ? appendForm(.ellipse, center: center, half: SIMD2(radiusX, radiusY), fills: true)
                : appendForm(
                    .arc, center: center, half: SIMD2(radiusX, radiusY),
                    arc: SIMD2(start, sweep), arcClosure: closure, fills: true)
        }
        guard isFullTurn || mode == .pie || (mode == nil && !drawsStroke) else {
            return placeArcInParts(
                mode: mode, center: center, radiusX: radiusX, radiusY: radiusY, start: start,
                sweep: sweep)
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
                    segments: segments, piece: .sector))
        }
    }

    /// 距離関数の経路を使えない (貼る絵か断片が塗りに効いている) とき、弧の塗りと輪郭が 1 つの扇の形では出せない
    /// 閉じ方 (既定・`.chord`・`.open`) を、輪郭の周を部分ごとに組んで置く。
    ///
    /// - 既定: 塗りは扇、輪郭は開いた弧
    /// - `.chord`: 弦で結んだ形の塗りと、その周の輪郭
    /// - `.open`: 弦で結んだ形の塗りと、開いた弧の輪郭
    ///
    /// 塗りの後に輪郭を引くので、重なりの順は輪郭を実線で引くときと同じ (塗りの上に輪郭)。
    /// 破線の輪郭は、開いた弧の周を刻むので、ここでも ``strokeOutline(_:discSegments:)`` が引き受ける。
    /// **周は区間の中だと分かってから組む。**
    private func placeArcInParts(
        mode: ArcMode?, center: SIMD2<Float>, radiusX: Float, radiusY: Float, start: Float,
        sweep: Float
    ) {
        guard canPlace else { return warnOutsideFrame(.placing) }
        func outline(_ piece: Outline.Ring.Piece) -> Outline {
            ringOutlineForDash(
                radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep, piece: piece,
                at: center)
        }
        // 塗りの部分と輪郭の部分は別の口が控えるが、**弧は 1 つの図形**。書けないものは 1 度だけ数える (#3139)
        countingOneVectorFigure {
            switch mode {
            case nil:
                draw(outline(.sectorFill))
                draw(outline(.arcLine))
            case .chord:
                draw(outline(.chord))
            case .open:
                draw(outline(.chordFill))
                draw(outline(.arcLine))
            case .pie:
                // 呼ぶ側が扇を 1 つの形で出す。ここへは来ない
                preconditionFailure("a pie is placed as a single form")
            }
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

    // 3 次の曲線を 1 本引く。`beginShape()`・`vertex()`・`bezierVertex()`・`endShape()` と同じ道を通る。
    public func bezier(
        _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible,
        _ x3: some ScalarConvertible, _ y3: some ScalarConvertible, _ x4: some ScalarConvertible, _ y4: some ScalarConvertible
    ) {
        let (x1, y1, x2, y2, x3, y3, x4, y4) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat, x3.asFloat, y3.asFloat, x4.asFloat, y4.asFloat)
        // 区間の外では `beginShape()` が断るのと同じ注意を、先に言って何もしない
        guard canPlace else { return warnOutsideFrame(.placing) }
        // 組み立て中の形があっても、それは触らない。`beginShape()` で開き直すと外の形を
        // 捨ててしまうので、形の組み立て (`createShape`) と同じく取り出して、描いた後に戻す
        let outer = takeOpenShape()
        beginShape()
        vertex(x1, y1)
        bezierVertex(x2, y2, x3, y3, x4, y4)
        endShape()
        restoreOpenShape(outer)
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

extension ArcMode {
    /// 距離関数の経路の置き場所が持つ、同じ閉じ方 (``FormInstance/ArcClosure``)。
    fileprivate var closure: FormInstance.ArcClosure {
        switch self {
        case .open: .open
        case .chord: .chord
        case .pie: .pie
        }
    }
}

extension FormInstance.ArcClosure {
    /// 三角形の経路 (破線の輪郭) が輪郭として刻む周の部分。
    fileprivate var strokePiece: Canvas.Outline.Ring.Piece {
        switch self {
        case .pie: .sector
        case .chord: .chord
        case .standard, .open: .arcLine
        }
    }
}
