// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 三角形の経路で、描く画素で 1 画素より細い名指しの基本図形の塗りを補う仕組み (#1934)。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

extension Canvas {

    /// 描く画素で 1 画素より細い塗りを補う片 1 つ ([#1934])。
    ///
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    struct ThinFillPiece {
        /// 4 つの角 (形自身の座標)。凸の四角形で、最初の角からの扇 (三角形 2 枚) に割る。
        var corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
        /// 断片の後で掛ける被覆 (`ShapeFragmentIn.coverage`・#1637 と同じ口)。
        var coverage: Float
    }

    /// 名指しの基本図形の塗りを、形自身の座標を描く画素へ写す 2x2 `linear` で置いたとき、描く画素で
    /// 1 画素より細い向きを持つなら、補う片 ([#1934])。**細くなければ `nil`** で、塗りはこれまで
    /// どおり周から三角形に割る。
    ///
    /// 三角形の経路の縁には AA が無い (ADR-0039 決定 3) ので、描く画素で 1 画素より細い帯は、
    /// 画素の中心を跨ぐかどうかで消えるか満濃度の 1 行になる。`fill(_:)` の説明 (「`rect` や
    /// `circle` で 1 画素より細く描いた塗りは、置く位置によらず面積に比例した濃さで出る」) は
    /// 経路を限らないので、距離関数の経路 (#1477) と同じ約束をここで守る。線の補い
    /// (``ThinStroke``・#1637) と同じく、**帯を広げ、細さの割合を被覆として断片の後で掛ける。**
    ///
    /// - **帯** (`rect` の片方の向きだけが細い): 細い向きを、**描く画素の軸に沿って列 (行) が
    ///   帯を切る長さ**がちょうど整数 n になるまで広げ、被覆を「元の切る長さ / n」にする。列ごとに
    ///   跨ぐ画素の中心がちょうど n 個になるので、光の量は帯の断面に比例する。線の補いのように
    ///   **線に垂直な太さ**を 1 にすると、45° の帯は列が切る長さが √2 になり、跨ぐ中心が 1 つか
    ///   2 つかを位相が決める — 向きが 45° ちょうどなら全部の列が揃い、置く位置で光の量が 1/√2 倍か
    ///   √2 倍に振れる (線の側は #2172)。垂直な太さが 1 未満なら切る長さは √2 未満なので、n は 1 か 2
    /// - **細長い楕円** (短軸だけが細い): 短軸を広げるだけでは、先端の弦が 1 より短いまま残る。
    ///   描く画素で長軸に沿って約 1 画素ごとの片に切り、片ごとに帯と同じ幅へ広げ、被覆を片の中で
    ///   いちばん太い弦から取る。距離関数の経路 (`mokume_thinEllipseCoverage`) が画素の中で中心に
    ///   いちばん近い位置の弦を取るのと同じ取り方で、長軸が短くなると下の正方形へ連続してつながる
    /// - **小さい形** (どの向きも細い `rect`・長軸も細い楕円): 描く画素の軸に沿った描く画素 1 つの
    ///   正方形にし、被覆を描く画素での外接する箱の面積にする (円は直径の 2 乗・#1477 の判断 1 A。
    ///   線の点の補いと同じ形)
    ///
    /// 細さは ``roundedDrawnWeight(_:)`` で丸めてから 1 と比べる (線と同じ幅)。変換が潰れている
    /// (行列式 0) と補わない — 三角形のときも面積が無くて何も出ない。
    ///
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    static func thinFillPieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite else { return nil }
        return named.isEllipse
            ? thinEllipsePieces(named, by: linear) : thinRectPieces(named, by: linear)
    }

    /// 名指しの基本図形の塗りが、2x2 `linear` で置いて描く画素で 1 画素より細い向きを持つか
    /// (``thinFillPieces(_:by:)`` が片を返すのと同じ判定)。片を組まずに答える — 畳みの鍵は置き場所
    /// ごとに求める (``thinFillLinear(_:)``)。
    static func isThinFill(_ named: Outline.NamedFill, by linear: simd_float2x2) -> Bool {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite else { return false }
        if named.isEllipse {
            return roundedDrawnWeight(2 * principalAxes(ellipseLinear(named, linear)).short) < 1
        }
        let span = drawnRectSpans(named, by: linear)
        return span.height < 1 || span.width < 1
    }

    // MARK: - 矩形

    /// 矩形の、描く画素での 2 組の辺の隔たり (辺に垂直に測る・丸めた値) と、描く画素での面積。
    ///
    /// 上下の辺 (形自身の x の向き) の隔たりは、面積を辺の長さで割った `高さ × |det| / |D·x|`
    /// (線の ``drawnWeight(_:along:by:)`` と同じ量)。
    private static func drawnRectSpans(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> (height: Float, width: Float, area: Float) {
        let area = abs(simd_determinant(linear))
        let height = roundedDrawnWeight(2 * named.half.y * area / simd_length(linear.columns.0))
        let width = roundedDrawnWeight(2 * named.half.x * area / simd_length(linear.columns.1))
        return (height, width, 4 * named.half.x * named.half.y * area)
    }

    private static func thinRectPieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        let span = drawnRectSpans(named, by: linear)
        guard span.height < 1 || span.width < 1 else { return nil }
        // どの向きも細く、面積も描く画素 1 つに満たない形は、描く画素 1 つの正方形にする。強く
        // 剪断した形はどの向きも細いまま面積が 1 を越えうるので、細いほうの向きだけを広げる
        if span.height < 1, span.width < 1, span.area < 1 {
            return [unitSquare(around: named.center, inverse: linear.inverse, coverage: span.area)]
        }
        var half = named.half
        let coverage: Float
        if span.height < 1, span.width >= 1 || span.height <= span.width {
            let band = widenedBand(span.height, along: simd_normalize(linear.columns.0))
            half.y *= band.widen
            coverage = band.coverage
        } else {
            let band = widenedBand(span.width, along: simd_normalize(linear.columns.1))
            half.x *= band.widen
            coverage = band.coverage
        }
        let center = named.center
        return [
            ThinFillPiece(
                corners: (
                    center + SIMD2(-half.x, -half.y), center + SIMD2(half.x, -half.y),
                    center + SIMD2(half.x, half.y), center + SIMD2(-half.x, half.y)
                ), coverage: coverage)
        ]
    }

    /// 辺に垂直な隔たり `span` (描く画素・1 未満) の帯を、向き `direction` (描く画素・長さ 1) に
    /// 沿って広げる倍率と被覆。**列 (行) が帯を切る長さを整数 n にする** (``thinFillPieces(_:by:)``)。
    ///
    /// 帯が横寄り (|x| ≥ |y|) なら列が、縦寄りなら行が帯を切る。切る長さは `span` を、帯の向きの
    /// 大きいほうの成分で割ったものになる。
    private static func widenedBand(
        _ span: Float, along direction: SIMD2<Float>
    ) -> (widen: Float, coverage: Float) {
        let axis = max(abs(direction.x), abs(direction.y))
        let crossings: Float = span / axis <= 1 ? 1 : 2
        let target = crossings * axis
        return (target / span, span / target)
    }

    /// 描く画素での中心 `center` のまわりの、描く画素の軸に沿った描く画素 1 つの正方形。
    private static func unitSquare(
        around center: SIMD2<Float>, inverse: simd_float2x2, coverage: Float
    ) -> ThinFillPiece {
        func corner(_ x: Float, _ y: Float) -> SIMD2<Float> { center + inverse * SIMD2(x, y) }
        return ThinFillPiece(
            corners: (corner(-0.5, -0.5), corner(0.5, -0.5), corner(0.5, 0.5), corner(-0.5, 0.5)),
            coverage: coverage)
    }

    // MARK: - 楕円

    /// 細長い楕円を長軸に沿って切る片の数の上限。**暴走の歯止めで、品質の判断ではない** — 片を
    /// 長くしても光の量の総和は変わらず、片の中のいちばん太い弦を取るぶんの多め (片の数 K に対して
    /// 4 / (πK) ほど) が上限で 0.1% に収まる。
    static let thinEllipseSliceLimit = 1024

    /// 単位円を描く画素の楕円へ写す 2x2 (形自身の座標の半径を掛けたもの)。
    private static func ellipseLinear(
        _ named: Outline.NamedFill, _ linear: simd_float2x2
    ) -> simd_float2x2 {
        simd_float2x2(linear.columns.0 * named.half.x, linear.columns.1 * named.half.y)
    }

    private static func thinEllipsePieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        let axes = principalAxes(ellipseLinear(named, linear))
        guard roundedDrawnWeight(2 * axes.short) < 1 else { return nil }
        let inverse = linear.inverse
        // 長軸も細い楕円 (1 画素より小さい円を含む) は、描く画素 1 つの正方形にする。被覆は描く
        // 画素での外接する箱の面積 (2 つの半径の積の 4 倍)
        if roundedDrawnWeight(2 * axes.long) < 1 {
            return [
                unitSquare(
                    around: named.center, inverse: inverse, coverage: 4 * axes.long * axes.short)
            ]
        }
        let along = axes.direction
        let across = SIMD2(-along.y, along.x)
        let thin = 2 * axes.short
        let width = thin * widenedBand(thin, along: along).widen
        let long = axes.long
        let count = min(Int((2 * long).rounded(.up)), thinEllipseSliceLimit)
        var pieces: [ThinFillPiece] = []
        pieces.reserveCapacity(count)
        func corner(_ distance: Float, _ side: Float) -> SIMD2<Float> {
            named.center + inverse * (along * distance + across * side)
        }
        for index in 0..<count {
            let from = -long + 2 * long * Float(index) / Float(count)
            let to = -long + 2 * long * Float(index + 1) / Float(count)
            // 片の中で、中心にいちばん近い位置の弦 (片の中でいちばん太い)
            let nearest = from <= 0 && to >= 0 ? 0 : min(abs(from), abs(to))
            let ratio = min(nearest / long, 1)
            let chord = thin * max(0, 1 - ratio * ratio).squareRoot()
            guard chord > 0 else { continue }
            pieces.append(
                ThinFillPiece(
                    corners: (
                        corner(from, -width / 2), corner(to, -width / 2), corner(to, width / 2),
                        corner(from, width / 2)
                    ), coverage: chord / width))
        }
        return pieces
    }

    /// 2x2 `m` が単位円を写した楕円の、長い半径・短い半径と、長軸の向き (長さ 1)。
    ///
    /// 半径は特異値で、``smallestSingularValue(of:)`` と同じく倍精度で、2 乗の差を引かない形で
    /// 解く。向きは `m mᵀ` の大きいほうの固有値の固有ベクトル。円に近くて向きが決まらないときは
    /// 描く画素の x の向きにする (細長い楕円の片にだけ使い、円は正方形の側へ行くので効かない)。
    private static func principalAxes(
        _ m: simd_float2x2
    ) -> (long: Float, short: Float, direction: SIMD2<Float>) {
        let a = Double(m.columns.0.x)
        let b = Double(m.columns.0.y)
        let c = Double(m.columns.1.x)
        let d = Double(m.columns.1.y)
        let trace = a * a + b * b + c * c + d * d
        let area = abs(a * d - b * c)
        let largest = ((trace + 2 * area).squareRoot() + max(trace - 2 * area, 0).squareRoot()) / 2
        let smallest = largest > 0 ? area / largest : 0
        // m mᵀ = [[p, q], [q, r]] の固有値 largest² の固有ベクトル
        let p = a * a + c * c
        let q = a * b + c * d
        let r = b * b + d * d
        let lambda = largest * largest
        let first = SIMD2(q, lambda - p)
        let second = SIMD2(lambda - r, q)
        let chosen = simd_length_squared(first) >= simd_length_squared(second) ? first : second
        let length = simd_length(chosen)
        let direction =
            length > 0 && length.isFinite
            ? SIMD2<Float>(Float(chosen.x / length), Float(chosen.y / length)) : SIMD2<Float>(1, 0)
        return (Float(largest), Float(smallest), direction)
    }

    // MARK: - 積む

    /// 細い塗りの片を積み、片ごとの被覆を付ける (``noteCoverage(_:in:)``)。色と変換はいまのもので、
    /// 塗りを周から積むとき (``fillInterior(_:thinFillMatrix:)``) と同じ。
    ///
    /// **貼る絵の読み取り位置は、元の周の囲みの箱から取り、箱の外へ広げた角は箱の縁へ寄せる**
    /// (``clampedUV(_:)``)。広げた帯にも絵の全体が載り、帯の中ほどの画素は元の帯と同じ所を読む。
    func fillThin(_ pieces: [ThinFillPiece], outline: Outline) {
        let uvOf = style.picture == nil ? nil : Self.boxUV(of: outline.points)
        let colors = (style.fill, style.fill, style.fill)
        for piece in pieces {
            let start = vertices.count
            let (a, b, c, d) = piece.corners
            let placedA = transform.apply(x: a.x, y: a.y)
            let placedB = transform.apply(x: b.x, y: b.y)
            let placedC = transform.apply(x: c.x, y: c.y)
            let placedD = transform.apply(x: d.x, y: d.y)
            var first: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            var second: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            if let uvOf {
                let (uvA, uvB, uvC, uvD) = (
                    Self.clampedUV(uvOf(a)), Self.clampedUV(uvOf(b)), Self.clampedUV(uvOf(c)),
                    Self.clampedUV(uvOf(d))
                )
                first = (uvA, uvB, uvC)
                second = (uvA, uvC, uvD)
            }
            appendTriangle(placedA, placedB, placedC, colors: colors, uvs: first)
            appendTriangle(placedA, placedC, placedD, colors: colors, uvs: second)
            noteCoverage(piece.coverage, in: start..<vertices.count)
        }
    }

    /// 読み取り位置を 0…1 の箱に収める。
    static func clampedUV(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        simd_clamp(uv, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1))
    }

    // MARK: - 畳み

    /// いまの変換で、名指しの基本図形 `form` の塗りが描く画素 1 画素より細くなるなら、その変換の
    /// 2x2 (#1934)。畳みの鍵 (``FlatKey/fillLinear``) に入る。**鍵は 2x2 そのもの** — 広げ方が帯の
    /// 向きで決まるので、線 (``rotationFreeKey(_:)``) と違って回転だけが違う置き場所も別の雛形になる。
    /// 塗りを持たない図形・扇・細くならない塗りは `nil` で、これまでどおり変換の違う置き場所も
    /// 同じ雛形に畳む。
    func thinFillLinear(_ form: FlatForm) -> ThinFold? {
        guard style.hasFill, let named = form.namedFill else { return nil }
        let matrix = transform.matrix
        guard Self.isThinFill(named, by: drawnLinear(matrix)) else { return nil }
        let linear = SIMD4(
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y)
        return ThinFold(key: linear, linear: linear)
    }

    // MARK: - 保持した形

    /// 保持した形の名指しの基本図形の塗りを、置いた後に細ければ広げて組み直した頂点と被覆の区間
    /// (#1934)。**細くならなければ `nil`** で、呼ぶ側は記録した頂点 (か、刻み直した頂点) を置く。
    ///
    /// 頂点は記録した頂点と同じ座標 (形自身の座標に記録のときの変換を掛けたもの) で返すので、呼ぶ側は
    /// 記録した頂点と同じく置き場所の行列と色を掛ける。**組み直しは描く画素へ写す 2x2 ごとに 1 度
    /// だけ** — 同じ大きさ・同じ向きで置き続ける形は、控えた頂点を移すだけで済む (``ThinStrokeCache``)。
    func thinFillVertices(
        _ recipe: RingFillRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache, fill: Int
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        guard let named = recipe.outline.namedFill else { return nil }
        let linear = drawnLinear(matrix * recipe.transform.matrix)
        let key = SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
        if let cached = cache.thinFill(fill, key) { return cached }
        var built: (vertices: [ShapeVertex], coverage: [CoverageSpan])?
        if let pieces = Self.thinFillPieces(named, by: linear) {
            built = Self.thinFillVertices(pieces, recipe: recipe)
        }
        cache.rememberThinFill(built, fill, key)
        return built
    }

    /// 片を、記録した頂点と同じ座標・色・読み取り位置の頂点にする (``fillThin(_:outline:)`` と
    /// 同じ割り方)。
    static func thinFillVertices(
        _ pieces: [ThinFillPiece], recipe: RingFillRecipe
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan]) {
        let uvOf = recipe.hasPicture ? boxUV(of: recipe.outline.points) : nil
        var vertices: [ShapeVertex] = []
        vertices.reserveCapacity(pieces.count * 6)
        var spans: [CoverageSpan] = []
        for piece in pieces {
            let start = vertices.count
            let (a, b, c, d) = piece.corners
            for corner in [a, b, c, a, c, d] {
                var uv = recipe.uv
                if let uvOf { uv = clampedUV(uvOf(corner)) }
                vertices.append(
                    ShapeVertex(
                        position: recipe.transform.apply(x: corner.x, y: corner.y), uv: uv,
                        color: recipe.color))
            }
            CoverageSpan.note(piece.coverage, in: start..<vertices.count, to: &spans)
        }
        return (vertices, spans)
    }
}

extension Canvas.FlatForm {
    /// `fill(_:)` の説明が名指す基本図形なら、その塗りの形。**周の閉包が作る周
    /// (``Canvas/Outline/namedFill``) と同じ値** — 畳みの鍵はこちらで細さを測り、雛形は周の側で
    /// 広げる。扇 (一周でない弧) は `nil`。
    var namedFill: Canvas.Outline.NamedFill? {
        switch self {
        case .rect(let width, let height):
            Canvas.Outline.NamedFill(
                isEllipse: false, center: SIMD2(width / 2, height / 2),
                half: SIMD2(width / 2, height / 2))
        case .ellipse(let radiusX, let radiusY):
            Canvas.Outline.NamedFill(
                isEllipse: true, center: SIMD2(0, 0), half: SIMD2(radiusX, radiusY))
        case .arc(let radiusX, let radiusY, _, let sweep):
            sweep >= 2 * .pi
                ? Canvas.Outline.NamedFill(
                    isEllipse: true, center: SIMD2(0, 0), half: SIMD2(radiusX, radiusY))
                : nil
        }
    }
}
