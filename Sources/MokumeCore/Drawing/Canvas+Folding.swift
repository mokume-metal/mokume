// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 周を 1 本の道具としてなぞる仕組み。`Canvas.swift` の MARK「周をひとつの道具に
// する」を、区画ごとここへ移した ([#943](https://github.com/mokume-metal/mokume/issues/943))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

extension Canvas {

    /// 図形の周。**塗りと輪郭はここから出る**ので、図形ごとに輪郭を書かずに済む。
    ///
    /// 点は変換をかける前の座標で持つ — 変換は最後に 1 度だけ掛ける。輪郭の太さは
    /// 画面の画素で測るので、変換の前に帯を作ると拡大で太さが変わってしまう。
    nonisolated struct Outline {
        /// 周を回る点。
        var points: [SIMD2<Float>]
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 扇で塗れる図形の中心。`nil` なら最初の点から扇状に分ける。
        ///
        /// **最初の点からの扇は、凸な周でしか正しくない。** 凸でない周は ``fillTriangles``
        /// で割り方を渡す (凸でない `quad`)。
        var fanCenter: SIMD2<Float>?
        /// 塗りを割る三角形。`nil` なら扇で割る (``fanCenter``)。
        ///
        /// 周は与えた順のまま輪郭に使い、**塗りだけを別に割る**ときに持つ。凸でない `quad` が
        /// そうで、最初の点から扇に割ると、凹んだ形はへこみまで塗り、辺の交差した形は
        /// 砂時計にならない ([#1534])。
        ///
        /// [#1534]: https://github.com/mokume-metal/mokume/issues/1534
        var fillTriangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]?
        /// 塗りを持つか。線と点は持たない。
        var fills: Bool
        /// 点ごとに、折れ目の形によらず円板で埋めるか。曲線の刻みの点
        /// (``BuildingVertex/isCurveStep``) と、扇の 3 つの角 (中心と弧の両端・#1486) がそう。
        /// 空ならどの点も角。
        var curveSteps: [Bool]
        /// 点ごとに、矩形の直角の角としての外向きの対角 (各成分 ±1)。`strokeJoin(.bevel)` で
        /// 角を距離関数の経路と同じ 45° の線で削ぐのに使う (#1506)。空なら矩形の角ではない
        /// (任意多角形の折れ目で、2 本の帯の向きから決まる形で埋める・#1644。直角の `bevel`
        /// では、ここで削いだ角と同じ形になる)。
        var cornerDiagonals: [SIMD2<Float>]
        /// 線を 1 つの領域として 1 回だけ混ぜるか。基本図形 (`rect` / `ellipse` / `arc`) と、辺の交差しない
        /// `quad` が立てる。
        ///
        /// 立てると、線の片は線に沿った隔たりによらず先に置いた片を全部引いて積む
        /// (``StrokeCarving``・[#1562])。距離関数の経路と同じ塗り方で、細長い楕円の上下の弧の
        /// ように線に沿って離れた部分が重なっても濃くならない。基本図形は自己交差しない
        /// ので、交差を 2 回混ぜる任意多角形の約束 (#1536) とは食い違わない。
        ///
        /// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
        var strokesAsOneRegion: Bool
        /// 置き場所ぶんずらす前の周と、ずらした量 (``moved(by:)``)。ずらしていなければ `nil`。
        ///
        /// 線の片の重なりを引くときは、ずらす前の周で引いてから足す (``StrokeCarving``)。
        /// 引き算の切り口は単精度の丸めを含むので、ずらした座標で引くと、畳んだ雛形
        /// (ずらす前の座標で組む) と頂点の数まで食い違う。
        var unmoved: (points: [SIMD2<Float>], offset: SIMD2<Float>)?

        init(
            points: [SIMD2<Float>], isClosed: Bool, fanCenter: SIMD2<Float>? = nil,
            fillTriangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]? = nil,
            fills: Bool = true, curveSteps: [Bool] = [], cornerDiagonals: [SIMD2<Float>] = [],
            strokesAsOneRegion: Bool = false
        ) {
            self.points = points
            self.isClosed = isClosed
            self.fanCenter = fanCenter
            self.fillTriangles = fillTriangles
            self.fills = fills
            self.curveSteps = curveSteps
            self.cornerDiagonals = cornerDiagonals
            self.strokesAsOneRegion = strokesAsOneRegion
        }

        /// 形自身の座標で作った周を、置き場所ぶんずらす。**畳まないときの経路。**
        func moved(by offset: SIMD2<Float>) -> Outline {
            var moved = Outline(
                points: points.map { $0 + offset }, isClosed: isClosed,
                fanCenter: fanCenter.map { $0 + offset },
                fillTriangles: fillTriangles?.map { ($0.0 + offset, $0.1 + offset, $0.2 + offset) },
                fills: fills, curveSteps: curveSteps, cornerDiagonals: cornerDiagonals,
                strokesAsOneRegion: strokesAsOneRegion)
            moved.unmoved = unmoved.map { ($0.points, $0.offset + offset) } ?? (points, offset)
            return moved
        }
    }

    /// 周から、塗りと輪郭を出す。
    func draw(_ outline: Outline) {
        // 区間の外では置かず、組み立てた数も数えない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        outlinesAssembledThisFrame += 1
        if outline.fills, style.hasFill { fillInterior(outline) }
        if style.hasStroke, style.strokeWeight > 0 { strokeOutline(outline) }
    }

    /// 形自身の座標で作った周を、置き場所へ置く。**同じ形が続く間は畳む。**
    ///
    /// 畳めるときは頂点を 1 組も積まず、置き場所を 1 つ足すだけで済む。畳めないときは
    /// 周を置き場所ぶんずらして今までどおり積む — 足す順が入れ替わるだけなので、
    /// **絵は 1 ビットも変わらない**。
    ///
    /// **周は閉包で受け取る。** 開いている雛形と同じ形なら置き場所を 1 つ足すだけで、
    /// 周は 1 度も作らない (#752 — 畳めても無条件に周を組んでいたのを直した)。
    func draw(
        folding form: FlatForm, at anchor: SIMD2<Float>, outline makeOutline: () -> Outline
    ) {
        // 区間の外では、畳む相手の控えも雛形も動かさない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        let key = FlatKey(
            form: form,
            hasFill: style.hasFill,
            hasStroke: style.hasStroke && style.strokeWeight > 0,
            strokeWeight: style.strokeWeight,
            strokeCap: style.strokeCap,
            strokeJoin: style.strokeJoin,
            strokeLinear: thinStrokeLinear(),
            texture: style.hasFill ? style.picture?.held : nil)
        guard key.hasFill || key.hasStroke else { return }

        // **貼る絵と輪郭が同居する図形は畳まない。** 塗りは絵の面を、輪郭は字形の面を
        // 読むので、1 つの図形の途中で列が割れる (`useTexture`)。1 つの雛形に収まらない
        //
        // 保持する形を記録している最中も畳まない (`recordingShape`)
        guard !(key.texture != nil && key.hasStroke), !recordingShape else {
            return draw(makeOutline().moved(by: anchor))
        }

        // 開いている雛形と同じ形なら、置き場所を足すだけで済む
        if openFlat?.key == key {
            appendFolded(placement(at: anchor), key: key, outline: makeOutline)
            return
        }
        let outline = makeOutline()

        // **2 つ目が来てから畳む。** 1 つ目で雛形を開くと、矩形と円を交互に置いた絵で
        // 図形の数だけ列が分かれる — 平面は元から 1 つの列にまとまるので、それは
        // 畳む前より遅い ([#424](https://github.com/mokume-metal/mokume/issues/424))
        if let waiting = pendingFlat, waiting.key == key,
            waiting.vertexEnd == vertices.count, waiting.batchCount == batches.count
        {
            // 1 つ目の頂点を溜め場から抜き、雛形として積み直す。抜けるのは**まだ列が
            // 閉じていない末尾**にいるときだけで、上の 2 つの条件がそれを見ている
            vertices.removeLast(vertices.count - waiting.vertexStart)
            trimCoverage(to: waiting.vertexStart)
            pendingFlat = nil
            openFlatTemplate(key: key, outline: outline)
            flatInstances.append(waiting.placement)
            appendFolded(placement(at: anchor), key: key, outline: { outline })
            return
        }

        // 畳む相手がまだいない。**今までどおり置いて**、次に同じ形が来るのを待つ
        closeFlatTemplate()
        let batchesBefore = batches.count
        let vertexStart = vertices.count
        draw(outline.moved(by: anchor))
        guard batches.count == batchesBefore, vertices.count > vertexStart else {
            pendingFlat = nil
            return
        }
        pendingFlat = PendingFlat(
            key: key, outline: outline, placement: placement(at: anchor),
            vertexStart: vertexStart, vertexEnd: vertices.count, batchCount: batches.count)
    }

    /// 畳んだ置き場所を 1 つ足す。**上限に達していたら、同じ形のまま雛形を開き直す。**
    ///
    /// 開き直すのは、畳まない経路へ落とすと**上限をまたいだ図形だけ組み立て方が
    /// 変わってしまう**ためである。周は上限に達したときしか要らないので閉包で受け取る。
    private func appendFolded(
        _ placement: FlatInstance, key: FlatKey, outline makeOutline: () -> Outline
    ) {
        // **畳んだ置き場所は ``beginFlat()`` も ``useTexture(_:)`` も通らない**ので、描き場所を
        // 置いた記録はここで取る (#1683 の反証)。取らないと、描いている最中の描き場所を読んで
        // 置いた図形が、注意なしに前の絵になる
        if let graphics = (key.texture?.owner as? RenderTarget)?.drawer { note(placing: graphics) }
        notePaintPlacement()
        if let open = openFlat, isBatchFull(flatInstances.count, since: open.instanceStart) {
            openFlatTemplate(key: key, outline: makeOutline())
        }
        flatInstances.append(placement)
    }

    /// 雛形を 1 つ積んで開く。**開いていた列は閉じる。**
    private func openFlatTemplate(key: FlatKey, outline: Outline) {
        beginFlat()
        closeBatch()
        // 読む面は雛形を積み始める前に決める。積んでいる途中で変わると、雛形が
        // 2 つの列に割れる
        //
        // **面は鍵から引く。** いまの貼る絵から引き直すと、鍵が別の面で開いた雛形を
        // 指しているときに食い違う (`useFillTexture()` と同じ手順を鍵の側から踏む)
        if let texture = key.texture {
            texture.prepare()
            useTexture(texture)
        } else {
            useGlyphTexture()
        }

        // **雛形の頂点は白で、変換を掛けずに積む。** 色も変換も置き場所が持つので、
        // ここで焼き込むと二重に掛かる。組み立て自体は畳まないときとまったく同じ経路
        let savedTransform = transform
        let savedFill = style.fill
        let savedStroke = style.stroke
        transform = .identity
        style.fill = Self.unchangedTint
        style.stroke = Self.unchangedTint
        buildingFlatTemplate = true
        // 細い線の雛形は、鍵の変換で細さを測って広げる (#1637・``thinStrokeMatrix``)
        templateStrokeMatrix = key.strokeLinear.map(\.linear).map { linear in
            simd_float4x4(
                SIMD4(linear.x, linear.y, 0, 0), SIMD4(linear.z, linear.w, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        }
        outlinesAssembledThisFrame += 1
        if key.hasFill { fillInterior(outline) }
        let strokeStart = vertices.count
        if key.hasStroke { strokeOutline(outline) }
        buildingFlatTemplate = false
        templateStrokeMatrix = nil
        transform = savedTransform
        style.fill = savedFill
        style.stroke = savedStroke

        openFlat = OpenFlat(
            key: key, strokeStart: strokeStart, instanceStart: flatInstances.count)
    }

    /// いまの変換で、線が描く画素 1 画素より細くなる向きがあるなら、その変換の 2x2 (#1637)。
    /// 畳みの鍵 (``FlatKey/strokeLinear``) に入る。線を持たない図形と、どの向きでも細く
    /// ならない線は `nil` で、これまでどおり変換の違う置き場所も同じ雛形に畳む。
    private func thinStrokeLinear() -> ThinFold? {
        guard style.hasStroke, style.strokeWeight > 0 else { return nil }
        let matrix = transform.matrix
        let drawn = drawnLinear(matrix)
        guard Self.thinnestDrawnWeight(style.strokeWeight, by: drawn) < 1 else { return nil }
        return ThinFold(
            key: Self.rotationFreeKey(drawn),
            linear: SIMD4(
                matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y))
    }

    /// 掛けても値の変わらない色。雛形の頂点はこれで積む。
    private static let unchangedTint = LinearRGBA(
        premultipliedRed: 1, green: 1, blue: 1, alpha: 1)

    /// いまの変換と塗りから、置き場所を 1 つ作る。
    private func placement(at anchor: SIMD2<Float>) -> FlatInstance {
        let columns = transform.matrix.columns
        return FlatInstance(
            linear: SIMD4(columns.0.x, columns.0.y, columns.1.x, columns.1.y),
            offset: transform.apply(x: anchor.x, y: anchor.y),
            fill: style.fill, stroke: style.stroke)
    }

    /// 周の内側を塗る。
    ///
    /// 貼る絵があれば、**周の囲みの箱**を 0…1 に写した読み取り位置を付ける。組み込みの
    /// 図形はどれも周だけで表されているので、ここ 1 箇所で全部に効く。
    private func fillInterior(_ outline: Outline) {
        let points = outline.points
        guard points.count >= 3 else { return }
        if let triangles = outline.fillTriangles {
            let uvOf = style.picture == nil ? nil : Self.boxUV(of: points)
            for (a, b, c) in triangles {
                // `Optional.map` に閉包を渡さない — 三角形ごとに隔離の実行時検査を払う (#1779)
                var uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
                if let uvOf { uvs = (uvOf(a), uvOf(b), uvOf(c)) }
                appendTriangle(
                    transform.apply(x: a.x, y: a.y), transform.apply(x: b.x, y: b.y),
                    transform.apply(x: c.x, y: c.y),
                    colors: (style.fill, style.fill, style.fill), uvs: uvs)
            }
            return
        }
        let pivot = outline.fanCenter ?? points[0]
        let center = transform.apply(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return }

        // 箱は**周そのもの**から作る。扇の中心は周の内側にあるので、含めても広がらない
        let uvOf = style.picture == nil ? nil : Self.boxUV(of: points)

        func place(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ bSource: SIMD2<Float>,
            _ c: SIMD2<Float>, _ cSource: SIMD2<Float>)
        {
            var uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            if let uvOf { uvs = (uvOf(pivot), uvOf(bSource), uvOf(cSource)) }
            appendTriangle(a, b, c, colors: (style.fill, style.fill, style.fill), uvs: uvs)
        }

        var previous = transform.apply(x: ring[0].x, y: ring[0].y)
        var previousSource = ring[0]
        for point in ring.dropFirst() {
            let current = transform.apply(x: point.x, y: point.y)
            place(center, previous, previousSource, current, point)
            previous = current
            previousSource = point
        }
        if outline.fanCenter != nil, outline.isClosed {
            let first = transform.apply(x: ring[0].x, y: ring[0].y)
            place(center, previous, previousSource, first, ring[0])
        }
    }

    /// 弧の上の点を返す。円と楕円は「一周ぶんの弧」であり、別の道具にはしない。
    static func arcPoints(
        center: SIMD2<Float>, radiusX: Float, radiusY: Float, from start: Float, sweep: Float
    ) -> [SIMD2<Float>] {
        var points = arcOffsets(radiusX: radiusX, radiusY: radiusY, from: start, sweep: sweep)
        for index in points.indices { points[index] = center + points[index] }
        return points
    }

    /// 弧の上の点の、中心からのずれ。**中心を足せば ``arcPoints(center:radiusX:radiusY:from:sweep:)``
    /// と 1 ビットも違わない** — 点は `center.x + radiusX * cos(angle)` で、掛け算を先に済ませて
    /// から中心を足す式なので、ずれを控えて後から足しても同じ値になる (#1785)。
    static func arcOffsets(
        radiusX: Float, radiusY: Float, from start: Float, sweep: Float
    ) -> [SIMD2<Float>] {
        let full = segmentCount(forRadius: max(radiusX, radiusY))
        let segments = max(1, Int((Float(full) * sweep / (2 * .pi)).rounded(.up)))
        let step = sweep / Float(segments)
        // 一周は最後の点が最初と重なるので落とす
        let count = sweep >= 2 * .pi ? segments : segments + 1
        // 閉包を標準ライブラリへ渡さずにループで回す。main actor の文脈の閉包は、点ごとに
        // 隔離の実行時検査を払う (#1779)
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let angle = start + step * Float(index)
            points.append(SIMD2(radiusX * cos(angle), radiusY * sin(angle)))
        }
        return points
    }

    /// 4 つの数を、左上の角と大きさへ読み替える。
    static func resolveBox(_ a: Float, _ b: Float, _ c: Float, _ d: Float, mode: ShapeMode)
        -> (x: Float, y: Float, width: Float, height: Float)
    {
        switch mode {
        case .corner: return (a, b, c, d)
        case .corners: return (min(a, c), min(b, d), abs(c - a), abs(d - b))
        case .center: return (a - c / 2, b - d / 2, c, d)
        case .radius: return (a - c, b - d, c * 2, d * 2)
        }
    }

    /// 円を近似する多角形の辺の数。
    ///
    /// 多角形と真円の隔たりがいちばん大きいのは辺の中央で、その差は
    /// `r(1 − cos(π/n))`。これを 0.25 画素以下に収める `n` を選ぶ。
    ///
    /// **式が返す値をそのまま使う。** 下限 3 は多角形が成立する最小の辺数であって、
    /// 精度の判断ではない — 精度は式が持っている。かつては下限 32 を掛けていたが、
    /// 根拠がどこにも無く、直径 12 の円 (式は 11 を返す) に 3 倍の頂点を組み立てて
    /// いた。10,000 個置くと 40fps まで落ちる ([#423])。
    ///
    /// **上限 1024 は品質の判断ではなく、暴走の歯止めである。** 式は大きな半径で
    /// `n ≈ π√(2r)` に漸近するので、半径 10⁹ のような値が紛れ込むと 1 個の円に
    /// 14 万辺を割いてしまう。上限 `n` に対して保証が届く半径は `r = n²/(2π²)` で、
    /// 1024 なら約 53,000 — 面より桁違いに大きい円まで保証の内側に居る。
    ///
    /// かつての上限 128 は「大きすぎる円に 128 辺を超えて割いても見た目は変わらない」
    /// を根拠にしていたが、実際には変わっていた。半径 20000 の円は、画面に映る
    /// 800 列のうち 677 列で 1 画素以上・最大 6 画素ずれる ([#429] で実測)。
    ///
    /// 拡大縮小の変換は考えない。拡大した円が粗くなるのは受け入れる。
    ///
    /// [#423]: https://github.com/mokume-metal/mokume/issues/423
    /// [#429]: https://github.com/mokume-metal/mokume/issues/429
    static func segmentCount(forRadius radius: Float) -> Int {
        let tolerance = 0.25
        let cap = 1024
        // 隔たりが許容誤差に届かない円は、いちばん粗い多角形で足りる
        guard radius.isFinite, Double(radius) > tolerance else { return 3 }
        // **倍精度で解く。** 半径が大きいほど `1 − tolerance/r` は 1 に貼り付き、
        // 単精度では引き算で桁が落ちる — 半径 20000 で 629 ではなく 628 を返し、
        // 上限とは別に保証を 0.2% 外していた ([#429])
        let radians = acos(max(-1, 1 - tolerance / Double(radius)))
        // 角度が潰れるのは半径が大きすぎるとき。いちばん**細かい**側へ倒す
        // (かつては 3 を返し、半径 10⁷ の円が三角形になっていた)
        guard radians > 0 else { return cap }
        return min(cap, max(3, Int((Double.pi / radians).rounded(.up))))
    }

    /// 角度が逆向きの円弧を、初回だけ知らせる。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    func warnReversedArcOnce() {
        warnOnce(
            .reversedArc,
            "arc(): the ending angle has to be larger than the starting one. This call draws nothing")
    }

}
