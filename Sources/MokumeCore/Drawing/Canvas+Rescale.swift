// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 保持した形の円板と周を、置いた後の大きさで刻み直す仕組み (#1645)。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

/// ``Shape/vertices`` のうち**楕円・弧の周の塗りの 1 区間**と、置くときに刻み直す素材 ([#1645])。
///
/// 保持した形は、記録のときの変換で周の点まで組む。**置くときに拡大して置くと、記録した多角形が
/// そのまま拡大され、保証 (画面の上で 0.25 画素以内) が外れる**。そこで、周の元
/// (``Canvas/Outline/Ring``) を持ち、置いた後の大きさで要る分割数が記録のときより増えるなら、
/// 区間を刻み直した頂点で差し替える (``Canvas/rescaledFillVertices(_:placedBy:cache:fill:)``)。
///
/// 輪郭の側は ``StrokeRange/thin`` が同じ役を持つ。塗りは輪郭と違って画面で半画素寄せないので、
/// 別の並びで持つ ([ADR-0039] 決定 2)。
///
/// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
struct RingFillRange {
    /// ``Shape/vertices`` の中での区間。
    var range: Range<Int>
    /// 区間を刻み直す素材。
    var recipe: RingFillRecipe

    init(_ range: Range<Int>, recipe: RingFillRecipe) {
        self.range = range
        self.recipe = recipe
    }

    /// 区間だけを `offset` ずらした写し。
    func shifted(by offset: Int) -> RingFillRange {
        RingFillRange((range.lowerBound + offset)..<(range.upperBound + offset), recipe: recipe)
    }
}

/// 楕円・弧の周の塗りを、刻み直して頂点にする素材。**値だけで自己完結する。**
///
/// 周の点の並びは図形が組んだものを共有する (記録のたびに箱を作らない)。
struct RingFillRecipe {
    /// 形自身の座標の周 (記録のときの変換を掛ける前)。**周の元を持つ** (``Canvas/Outline/ring``)。
    let outline: Canvas.Outline
    /// 記録のときの塗りの色。
    let color: LinearRGBA
    /// 貼る絵があったか。あれば、読み取り位置は周の囲みの箱から決める。
    let hasPicture: Bool
    /// 記録のときの変換 (入れ子なら外側の置き場所の行列も合成したもの)。
    let transform: Transform
    /// 貼る絵が無いときの読み取り位置 (焼き場の白い区画)。
    let uv: SIMD2<Float>

    /// 別の保持した形の中で置かれた塗り。行列と色を合成する (刻み直すのは外側を置くとき)。
    func moved(by matrix: simd_float4x4, tint: LinearRGBA?) -> RingFillRecipe {
        var color = self.color
        if let tint {
            color = LinearRGBA(
                premultipliedRed: color.red * tint.red, green: color.green * tint.green,
                blue: color.blue * tint.blue, alpha: color.alpha * tint.alpha)
        }
        return RingFillRecipe(
            outline: outline, color: color, hasPicture: hasPicture,
            transform: Transform(matrix: matrix * transform.matrix), uv: uv)
    }

    /// 置いた後の拡大 `scale` で要る周の分割数。記録のときより増えなければ `nil`。
    func segments(atScale scale: Float) -> Int? {
        guard let ring = outline.ring else { return nil }
        let needed = Canvas.segmentCount(
            forRadius: max(ring.radiusX, ring.radiusY), scale: scale)
        return needed > ring.segments ? needed : nil
    }
}

extension Canvas.Outline {
    /// 周をなぞるとき、円板を置く点があるか (丸い端・丸い折れ目・曲線の刻み)。
    ///
    /// 円板の分割数が絵に出るかの判定で、骨 (`strokeRing`) が円板を置く点の規則と同じである。
    func placesDiscs(cap: StrokeCap, join: StrokeJoin) -> Bool {
        if curveSteps.contains(true) { return true }
        // 点が 1 つだけなら、端の形そのものを置く
        if points.count == 1 { return cap == .round }
        if isClosed { return join == .round && points.count >= 2 }
        // 開いた周は、両端の形と、途中の点の折れ目
        return cap == .round || (join == .round && points.count >= 3)
    }
}

extension ThinStrokeRecipe {
    /// 置いた後の拡大 `scale` で要る分割数 (周・円板)。**どちらも記録のときより増えなければ `nil`**
    /// で、記録した頂点をそのまま置く。
    ///
    /// 分割数は半径の単調な関数なので、拡大が記録のときより大きくなければ、増えることはない。
    func splits(atScale scale: Float) -> (ring: Int, disc: Int)? {
        var ringCount = 0
        var discCount = 0
        var grows = false
        if let ring = outline.ring {
            ringCount = Canvas.segmentCount(
                forRadius: max(ring.radiusX, ring.radiusY), scale: scale)
            grows = ringCount > ring.segments
        }
        if discSegments > 0 {
            discCount = Canvas.segmentCount(forRadius: weight / 2, scale: scale)
            grows = grows || discCount > discSegments
        }
        return grows ? (ringCount, discCount) : nil
    }
}

extension ThinStrokeRecipe {
    /// 置いた後の拡大 `scale` で刻み直した周の輪郭。周の元が無いか、刻みが増えなければ記録した輪郭の
    /// まま。細い線の組み直し (``Canvas/thinVertices(_:placedBy:cache:stroke:)``) が使う。
    func outline(atScale scale: Float) -> Canvas.Outline {
        guard let ring = outline.ring else { return outline }
        let needed = Canvas.segmentCount(forRadius: max(ring.radiusX, ring.radiusY), scale: scale)
        return Canvas.regenerated(outline, ringSegments: max(needed, ring.segments))
    }
}

extension Canvas {
    /// 周の元を持つ輪郭を、一周を `ringSegments` 個に刻み直した輪郭にする。周の元が無ければ、
    /// そのまま返す。置き場所のずれ (``Outline/unmoved``) は引き継ぐ。
    static func regenerated(_ outline: Outline, ringSegments: Int) -> Outline {
        guard var ring = outline.ring, ring.segments != ringSegments else { return outline }
        ring.segments = ringSegments
        let base = ringOutline(ring)
        guard let unmoved = outline.unmoved else { return base }
        return base.moved(by: unmoved.offset)
    }

    /// 保持した形の輪郭を、置いた後の大きさで刻み直した頂点 (記録した頂点と同じ座標・色)。
    /// **周も円板も記録のときより増えなければ `nil`** で、呼ぶ側は記録した頂点をそのまま置く。
    ///
    /// 片は引いて積む (``CarveRecipe``)。重ねたまま積んだ記録と、塗る領域は同じで、半透明の色を
    /// 掛けて置いても重なった所が濃くならない。**刻み直しは分割数の組ごとに 1 度だけ** — 同じ
    /// 大きさで置き続ける形は、控えた頂点を移すだけで済む (``ThinStrokeCache``)。
    func rescaledVertices(
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache,
        stroke: Int
    ) -> [ShapeVertex]? {
        let combined = matrix * recipe.transform.matrix
        guard let splits = recipe.splits(atScale: Self.splitScale(of: combined)) else { return nil }
        let key = ThinStrokeCache.scaledKey(ring: splits.ring, disc: splits.disc)
        if let cached = cache.rescaledStroke(stroke, key) { return cached }
        let outline = Self.regenerated(recipe.outline, ringSegments: splits.ring)
        // 端と折れ目の形は、いまの設定から読む。記録のときの形へ入れ替えて、戻す
        let saved = (style.strokeCap, style.strokeJoin)
        style.strokeCap = recipe.cap
        style.strokeJoin = recipe.join
        let carved = carveRecipe(
            outline, half: recipe.weight / 2, transform: recipe.transform, color: recipe.color,
            uv: recipe.uv, discSegments: splits.disc > 0 ? splits.disc : nil)
        (style.strokeCap, style.strokeJoin) = saved
        let vertices = carved.vertices()
        cache.rememberRescaledStroke(vertices, stroke, key)
        return vertices
    }

    /// 保持した形の楕円・弧の塗りを、置いた後の大きさで刻み直した頂点。増えなければ `nil`。
    func rescaledFillVertices(
        _ recipe: RingFillRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache, fill: Int
    ) -> [ShapeVertex]? {
        let combined = matrix * recipe.transform.matrix
        guard let segments = recipe.segments(atScale: Self.splitScale(of: combined)) else {
            return nil
        }
        if let cached = cache.rescaledFill(fill, segments) { return cached }
        let vertices = Self.ringFillVertices(
            Self.regenerated(recipe.outline, ringSegments: segments), recipe: recipe)
        cache.rememberRescaledFill(vertices, fill, segments)
        return vertices
    }

    /// 周の元を持つ輪郭の塗りの頂点。扇で塗り (``fillInterior(_:)`` と同じ割り方・同じ式)、記録した
    /// 頂点と同じ座標 (記録のときの変換を掛けた後・半画素寄せはしない) で返す。
    static func ringFillVertices(_ outline: Outline, recipe: RingFillRecipe) -> [ShapeVertex] {
        let points = outline.points
        guard points.count >= 3 else { return [] }
        let pivot = outline.fanCenter ?? points[0]
        let center = recipe.transform.apply(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return [] }
        let uvOf = recipe.hasPicture ? Self.boxUV(of: points) : nil
        var vertices: [ShapeVertex] = []
        vertices.reserveCapacity(ring.count * 3)

        func emit(
            _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ bSource: SIMD2<Float>, _ c: SIMD2<Float>,
            _ cSource: SIMD2<Float>
        ) {
            var uvs = (recipe.uv, recipe.uv, recipe.uv)
            if let uvOf { uvs = (uvOf(pivot), uvOf(bSource), uvOf(cSource)) }
            vertices.append(ShapeVertex(position: a, uv: uvs.0, color: recipe.color))
            vertices.append(ShapeVertex(position: b, uv: uvs.1, color: recipe.color))
            vertices.append(ShapeVertex(position: c, uv: uvs.2, color: recipe.color))
        }

        var previous = recipe.transform.apply(x: ring[0].x, y: ring[0].y)
        var previousSource = ring[0]
        for point in ring.dropFirst() {
            let current = recipe.transform.apply(x: point.x, y: point.y)
            emit(center, previous, previousSource, current, point)
            previous = current
            previousSource = point
        }
        if outline.fanCenter != nil, outline.isClosed {
            let first = recipe.transform.apply(x: ring[0].x, y: ring[0].y)
            emit(center, previous, previousSource, first, ring[0])
        }
        return vertices
    }
}
