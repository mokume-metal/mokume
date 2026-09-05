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
    struct Outline {
        /// 周を回る点。
        var points: [SIMD2<Float>]
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 扇で塗れる図形の中心。`nil` なら最初の点から扇状に分ける。
        var fanCenter: SIMD2<Float>?
        /// 塗りを持つか。線と点は持たない。
        var fills: Bool

        init(
            points: [SIMD2<Float>], isClosed: Bool, fanCenter: SIMD2<Float>? = nil,
            fills: Bool = true
        ) {
            self.points = points
            self.isClosed = isClosed
            self.fanCenter = fanCenter
            self.fills = fills
        }

        /// 形自身の座標で作った周を、置き場所ぶんずらす。**畳まないときの経路。**
        func moved(by offset: SIMD2<Float>) -> Outline {
            Outline(
                points: points.map { $0 + offset }, isClosed: isClosed,
                fanCenter: fanCenter.map { $0 + offset }, fills: fills)
        }
    }

    /// 周から、塗りと輪郭を出す。
    func draw(_ outline: Outline) {
        outlinesAssembledThisFrame += 1
        if outline.fills, hasFill { fillInterior(outline) }
        if hasStroke, currentStrokeWeight > 0 { strokeOutline(outline) }
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
        let key = FlatKey(
            form: form,
            hasFill: hasFill,
            hasStroke: hasStroke && currentStrokeWeight > 0,
            strokeWeight: currentStrokeWeight,
            strokeCap: currentStrokeCap,
            strokeJoin: currentStrokeJoin,
            textured: currentPicture != nil)
        guard key.hasFill || key.hasStroke else { return }

        // **貼る絵と輪郭が同居する図形は畳まない。** 塗りは絵の面を、輪郭は字形の面を
        // 読むので、1 つの図形の途中で列が割れる (`useTexture`)。1 つの雛形に収まらない
        //
        // 保持する形を記録している最中も畳まない (`recordingShape`)
        guard !(key.textured && key.hasFill && key.hasStroke), !recordingShape else {
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
        if key.textured, key.hasFill { useFillTexture() } else { useGlyphTexture() }

        // **雛形の頂点は白で、変換を掛けずに積む。** 色も変換も置き場所が持つので、
        // ここで焼き込むと二重に掛かる。組み立て自体は畳まないときとまったく同じ経路
        let savedTransform = transform
        let savedFill = currentFill
        let savedStroke = currentStroke
        transform = .identity
        currentFill = Self.unchangedTint
        currentStroke = Self.unchangedTint
        buildingFlatTemplate = true
        outlinesAssembledThisFrame += 1
        if key.hasFill { fillInterior(outline) }
        let strokeStart = vertices.count
        if key.hasStroke { strokeOutline(outline) }
        buildingFlatTemplate = false
        transform = savedTransform
        currentFill = savedFill
        currentStroke = savedStroke

        openFlat = OpenFlat(
            key: key, strokeStart: strokeStart, instanceStart: flatInstances.count)
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
            fill: currentFill, stroke: currentStroke)
    }

    /// 周の内側を塗る。
    ///
    /// 貼る絵があれば、**周の囲みの箱**を 0…1 に写した読み取り位置を付ける。組み込みの
    /// 図形はどれも周だけで表されているので、ここ 1 箇所で全部に効く。
    private func fillInterior(_ outline: Outline) {
        let points = outline.points
        guard points.count >= 3 else { return }
        let pivot = outline.fanCenter ?? points[0]
        let center = transform.apply(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return }

        // 箱は**周そのもの**から作る。扇の中心は周の内側にあるので、含めても広がらない
        let uvOf = currentPicture == nil ? nil : Self.boxUV(of: points)

        func place(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ bSource: SIMD2<Float>,
            _ c: SIMD2<Float>, _ cSource: SIMD2<Float>)
        {
            appendTriangle(
                a, b, c, colors: (currentFill, currentFill, currentFill),
                uvs: uvOf.map { ($0(pivot), $0(bSource), $0(cSource)) })
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
        let full = segmentCount(forRadius: max(radiusX, radiusY))
        let segments = max(1, Int((Float(full) * sweep / (2 * .pi)).rounded(.up)))
        let step = sweep / Float(segments)
        // 一周は最後の点が最初と重なるので落とす
        let count = sweep >= 2 * .pi ? segments : segments + 1
        return (0..<count).map { index in
            let angle = start + step * Float(index)
            return SIMD2(
                center.x + radiusX * cos(angle), center.y + radiusY * sin(angle))
        }
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
            "arc(): 終わりの角度は始まりより大きくしてください。この呼び出しは何も描きません")
    }

}
