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
/// **名指しの基本図形 (`rect` と一周の楕円) の塗りも同じ素材で持つ** ([#1934])。置いた後に描く画素で
/// 1 画素より細くなるなら、広げた頂点で区間を差し替える
/// (``Canvas/thinFillVertices(_:placedBy:cache:fill:)``)。`rect` は周の元を持たないので、刻み直しは
/// しない (``RingFillRecipe/segments(atScale:)`` が `nil`)。
///
/// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
/// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
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
///
/// **矩形は周を持たず、細さを測る形 (``Canvas/Outline/namedFill``) だけを持つ** (#1934 の反証 7)。
/// `shader()` / `texture()` を付けて記録した矩形はどれもこの素材を持つので、周ごと持つと、絵を
/// 貼った矩形を何万も記録した形で、素材が頂点 (矩形 1 つに 192 バイト) より重くなる。周は値の
/// 中に箱で持つ (楕円・弧だけが箱を作る)。
struct RingFillRecipe {
    /// 周の持ち方。楕円・弧は刻み直すので周ごと (箱に入れる)、矩形は細さを測る形だけ。
    private enum Source {
        indirect case ring(Canvas.Outline)
        case named(Canvas.Outline.NamedFill?)
    }
    private let source: Source

    /// 形自身の座標の周 (記録のときの変換を掛ける前)。楕円・弧は**周の元を持つ** (``Canvas/Outline/ring``)。
    /// 矩形は周の点を持たず、細さを測る形 (``Canvas/Outline/namedFill``) だけを持つ周を返す。
    var outline: Canvas.Outline {
        switch source {
        case .ring(let outline): outline
        case .named(let named): Canvas.Outline(points: [], isClosed: true, namedFill: named)
        }
    }
    /// 記録のときの塗りの色。
    let color: LinearRGBA
    /// 貼る絵があったか。あれば、読み取り位置は周の囲みの箱から決める。
    let hasPicture: Bool
    /// 記録のときの変換 (入れ子なら外側の置き場所の行列も合成したもの)。
    let transform: Transform
    /// 貼る絵が無いときの読み取り位置 (焼き場の白い区画)。
    let uv: SIMD2<Float>

    init(
        outline: Canvas.Outline, color: LinearRGBA, hasPicture: Bool, transform: Transform,
        uv: SIMD2<Float>
    ) {
        source = outline.ring != nil ? .ring(outline) : .named(outline.namedFill)
        self.color = color
        self.hasPicture = hasPicture
        self.transform = transform
        self.uv = uv
    }

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

    /// 名指しの基本図形の塗りの、記録のときの変換を掛けた後のいちばん細い向きの幅 (入れ子の外側の
    /// 行列も含む・#1934)。形の中で最も細い塗りを見つけるのに使う。名指しの基本図形でなければ無限大。
    /// **丸めない** — 置くときの行列と掛け合わせた後で 1 度だけ丸める (``ThinStrokeRecipe/recordedWeight``
    /// と同じ)。矩形の辺の隔たりも楕円の短い直径も、最小の辺 (直径) × 最小の特異値を下回らない。
    var recordedFillSpan: Float {
        guard let named = outline.namedFill else { return .infinity }
        let columns = transform.matrix.columns
        let linear = simd_float2x2(
            SIMD2(columns.0.x, columns.0.y), SIMD2(columns.1.x, columns.1.y))
        return Float(
            Double(2 * min(named.half.x, named.half.y)) * Canvas.smallestSingularValue(of: linear))
    }

    /// 置いた後の拡大 `scale` で要る周の分割数。記録のときより増えなければ `nil`。
    func segments(atScale scale: Float) -> Int? {
        guard let ring = outline.ring else { return nil }
        let needed = Canvas.segmentCount(
            forRadius: max(ring.radiusX, ring.radiusY), scale: scale)
        return needed > ring.segments ? needed : nil
    }
}

extension Canvas {
    /// 輪郭が円板 (丸い端・丸い折れ目・曲線の刻み) を置く点を持つか。**円板を置くかの規則は、ここ 1 つ。**
    ///
    /// 畳みの鍵 (``FlatForm/placesDiscs(cap:join:)``) と、保持した形の組み直しの素材
    /// (``Outline/placesDiscs(cap:join:)``) が、周の形だけを変えてこれを呼ぶ。円板の分割数は、置く
    /// 輪郭にしか絵に出ないので、鍵と素材は置かない輪郭の分割数を 0 にして、拡大の違いで雛形を
    /// 割らず、刻み直しを払わない。**規則が骨 (`strokeRing`) とずれると、円板が黙って消える** —
    /// ずれは `ScaledDiscTests` が、骨に数えさせて突き合わせる。
    ///
    /// 骨の規則: 点が 1 つなら端の形そのもの。閉じた周は全部の点が折れ目で、開いた周は両端が端、
    /// 途中の点が折れ目。曲線の刻みの点は、折れ目の位置 (閉じた周の全部・開いた周の途中) にあるときだけ
    /// 円板で継ぐ。端の形が円板なのは、丸い端だけ。
    ///
    /// - Parameter hasJoinCurveSteps: 折れ目の位置に曲線の刻みの点があるか。
    static func strokePlacesDiscs(
        pointCount: Int, isClosed: Bool, hasJoinCurveSteps: Bool, cap: StrokeCap, join: StrokeJoin
    ) -> Bool {
        if pointCount == 1 { return cap == .round }
        if isClosed { return hasJoinCurveSteps || (join == .round && pointCount >= 2) }
        return hasJoinCurveSteps || cap == .round || (join == .round && pointCount >= 3)
    }
}

extension Canvas.Outline {
    /// 周をなぞるとき、円板を置く点があるか (``Canvas/strokePlacesDiscs(pointCount:isClosed:hasJoinCurveSteps:cap:join:)``)。
    func placesDiscs(cap: StrokeCap, join: StrokeJoin) -> Bool {
        // 折れ目の位置: 閉じた周は全部の点、開いた周は両端を除く途中の点
        var hasJoinCurveSteps = false
        let joins = isClosed ? curveSteps.indices : (curveSteps.count > 2 ? 1..<(curveSteps.count - 1) : 0..<0)
        for index in joins where index < points.count && curveSteps[index] {
            hasJoinCurveSteps = true
            break
        }
        return Canvas.strokePlacesDiscs(
            pointCount: points.count, isClosed: isClosed, hasJoinCurveSteps: hasJoinCurveSteps,
            cap: cap, join: join)
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
    /// **積み方は、記録のときに合わせる。** 不透明の線は片を重ねたまま積み、引くと縁から 1/1000 画素
    /// ほどの所に中心が乗る画素が入れ替わりうるので (``strokeOverlapsShow``)、刻み直しも重ねたまま
    /// 積む (``stackedVertices(_:recipe:discSegments:)``)。引いて積むのは、記録した頂点がもう引いて
    /// あるとき (``ThinStrokeRecipe/recordedCarved``) と、半透明の色を掛けて置くとき
    /// (`translucent`・``ThinStrokeRecipe/carvesWhenTinted``) で、置いた頂点が重なった所だけ濃くならない
    /// ようにする (``CarveRecipe``)。**刻み直しは分割数と積み方の組ごとに 1 度だけ** — 同じ大きさで
    /// 置き続ける形は、控えた頂点を移すだけで済む (``ThinStrokeCache``)。
    func rescaledVertices(
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4, translucent: Bool,
        cache: ThinStrokeCache, stroke: Int
    ) -> [ShapeVertex]? {
        let combined = matrix * recipe.transform.matrix
        guard let splits = recipe.splits(atScale: Self.splitScale(of: combined)) else { return nil }
        let carves = recipe.recordedCarved || (translucent && recipe.carvesWhenTinted)
        let key = ThinStrokeCache.scaledKey(ring: splits.ring, disc: splits.disc, carved: carves)
        if let cached = cache.rescaledStroke(stroke, key) { return cached }
        let outline = Self.regenerated(recipe.outline, ringSegments: splits.ring)
        let vertices: [ShapeVertex]
        if carves {
            // 端と折れ目の形は、いまの設定から読む。記録のときの形へ入れ替えて、戻す
            let saved = (style.strokeCap, style.strokeJoin)
            style.strokeCap = recipe.cap
            style.strokeJoin = recipe.join
            let carved = carveRecipe(
                outline, half: recipe.weight / 2, thin: nil, transform: recipe.transform,
                color: recipe.color, uv: recipe.uv, discSegments: splits.disc)
            (style.strokeCap, style.strokeJoin) = saved
            vertices = carved.vertices()
        } else {
            vertices = stackedVertices(outline, recipe: recipe, discSegments: splits.disc)
        }
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

    /// 周の元を持つ輪郭の塗りの頂点。扇で塗り (``fillInterior(_:thinFillMatrix:)`` が細さを補わない
    /// ときと同じ割り方・同じ式)、記録した
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
