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
    /// - **補いが成り立たない `rect` は補わない** (#1934 の 2 回目の反証 1): 回した後に縦横で倍率の
    ///   違う拡大や剪断を掛けると、2 組の辺の隔たりがどちらも 1 を割ったまま、形は長い細い菱形に
    ///   なる。正方形にすると潰れ、帯にすると弦がもう一組の辺に縛られて暗くなり横へ伸びるので、
    ///   どの向きも細い `rect` は、描く画素での外接の箱が ``thinFillSmallReach`` 以内のときだけ
    ///   小さい形にする。帯も、弦の平らな所がある (端の辺の、列 (行) の向きの長さが長い辺より短い)
    ///   ときだけにする。それ以外は周から三角形に割る (直す前と同じ)
    /// - **長い向きが短い形** (列 (行) の向きの長さが ``thinFillShortSpan`` 未満): 上の 2 つでは、
    ///   長い向きの端が列の中心を跨ぐかどうかで、跨ぐ列の数が 1 つ振れる。長さ 1.5 の帯は 1 列か
    ///   2 列になり、光の量が倍まで振れる。そこで長い向きにも同じ手当てを当てる — 長さを整数の
    ///   列の数へ広げ、被覆で光の量を配る (矩形は 1 枚の片、楕円は列 1 つずつの片・``ShortProfile``)。
    ///   配る量は、距離関数の経路が長い向きを箱フィルタで数えた量を、置く位置についてならした値
    ///   である。`rect` ではちょうど面積になる。長い形は端の 1 列の振れが 1 / 長さ に収まるので、
    ///   上の 2 つのまま描く
    ///
    /// 細さは ``roundedDrawnWeight(_:)`` で丸めてから 1 と比べる (線と同じ幅)。変換が潰れている
    /// (行列式 0) と補わない — 三角形のときも面積が無くて何も出ない。**寸法・中心が数でない・無限
    /// なら補わない** — 周から三角形に割るこれまでの塗りへ戻す (距離関数の経路も、有限でない半径の
    /// 形は置かずに断る・`appendForm(_:center:half:axis:arc:fills:cap:)`)。
    ///
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    static func thinFillPieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite, isFinite(named) else { return nil }
        return named.isEllipse
            ? thinEllipsePieces(named, by: linear) : thinRectPieces(named, by: linear)
    }

    /// 長い向きが短いとみなす、列 (行) の向きの長さの上限 (描く画素)。これ以上長い形は、端の
    /// 列の振れ (1 列ぶん) が光の量の 1 / 長さ に収まる (#1934 の反証 2)。
    static let thinFillShortSpan: Float = 10

    /// 寸法と中心がどれも有限か。
    private static func isFinite(_ named: Outline.NamedFill) -> Bool {
        named.half.x.isFinite && named.half.y.isFinite && named.center.x.isFinite
            && named.center.y.isFinite
    }

    /// 名指しの基本図形の塗りが、2x2 `linear` で置いて描く画素で 1 画素より細い向きを持つか
    /// (``thinFillPieces(_:by:)`` が片を返すのと同じ判定)。片を組まずに答える — 畳みの鍵は置き場所
    /// ごとに求める (``thinFillLinear(_:)``)。
    static func isThinFill(_ named: Outline.NamedFill, by linear: simd_float2x2) -> Bool {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite, isFinite(named) else { return false }
        if named.isEllipse {
            return roundedDrawnWeight(2 * principalAxes(ellipseLinear(named, linear)).short) < 1
        }
        return rectPlan(named, by: linear) != nil
    }

    /// どの向きも細い `rect` を小さい形 (描く画素 1 つの正方形) とみなす、描く画素での外接の箱の
    /// 大きさの上限。回した描く画素 1 つの正方形 (√2) が入る大きさで、これより長い形を正方形に
    /// 潰さない (#1934 の 2 回目の反証 1)。
    static let thinFillSmallReach: Float = 1.5

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

    /// 細い `rect` の補い方。
    private enum RectPlan {
        /// 小さい形: 描く画素 1 つの正方形。被覆は描く画素での面積。
        case square(coverage: Float)
        /// 帯: 1 組の辺の隔たり `span` だけが細い。`edge` は長い辺、`endAlong` は端の辺が列 (行) の
        /// 向きにどれだけ伸びるか (描く画素)。
        case band(widensHeight: Bool, span: Float, edge: SIMD2<Float>, endAlong: Float, area: Float)
    }

    /// 細い `rect` を、補いが成り立つ形のときだけどう補うか。細くないか、補いが成り立たない形
    /// (``thinFillPieces(_:by:)`` の「補いが成り立たない `rect`」) なら `nil`。
    ///
    /// 2 本の辺は実際に描く画素へ写して測る: 形自身の x の向きの辺 `across` と y の向きの辺 `down`。
    private static func rectPlan(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> RectPlan? {
        let span = drawnRectSpans(named, by: linear)
        guard span.height < 1 || span.width < 1 else { return nil }
        let across = linear.columns.0 * (2 * named.half.x)
        let down = linear.columns.1 * (2 * named.half.y)
        if span.height < 1, span.width < 1 {
            // どの向きも細い: 外接の箱が小さく、面積も描く画素 1 つに満たないときだけ正方形にする
            let box = abs(across) + abs(down)
            guard box.x <= thinFillSmallReach, box.y <= thinFillSmallReach, span.area < 1
            else { return nil }
            return .square(coverage: span.area)
        }
        // 1 組だけが細い: 上下の辺が細いなら形自身の x の向きの辺が長い辺
        let widensHeight = span.height < 1
        let edge = widensHeight ? across : down
        let end = widensHeight ? down : across
        let byRows = abs(edge.y) > abs(edge.x)
        let edgeAlong = byRows ? abs(edge.y) : abs(edge.x)
        let endAlong = byRows ? abs(end.y) : abs(end.x)
        // 弦の平らな所が無い (端の辺のほうが列の向きに長い) 形は、弦が端の辺に縛られる
        guard endAlong < edgeAlong else { return nil }
        return .band(
            widensHeight: widensHeight, span: widensHeight ? span.height : span.width, edge: edge,
            endAlong: endAlong, area: span.area)
    }

    private static func thinRectPieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        guard let plan = rectPlan(named, by: linear) else { return nil }
        let (widensHeight, thinSpan, edge, endAlong, area): (Bool, Float, SIMD2<Float>, Float, Float)
        switch plan {
        case .square(let coverage):
            return [unitSquare(around: named.center, inverse: linear.inverse, coverage: coverage)]
        case .band(let widens, let span, let longEdge, let along, let drawnArea):
            (widensHeight, thinSpan, edge, endAlong, area) = (widens, span, longEdge, along, drawnArea)
        }
        // 長い向きが短い形の手当ては、端の辺が 1 列に収まるときだけ (剪断で端が長く伸びた形は、
        // 長さを長い辺だけで数えると形が縮む)。収まらなければ帯のまま広げる
        if endAlong <= 1, let profile = ShortProfile(rectEdge: edge, area: area) {
            return shortPieces(profile, center: named.center, inverse: linear.inverse)
        }
        var half = named.half
        let band = widenedBand(thinSpan, along: simd_normalize(edge))
        let coverage = band.coverage
        if widensHeight {
            half.y *= band.widen
        } else {
            half.x *= band.widen
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

    /// 細長い楕円を長軸に沿って切る片の数の上限。片は長軸に沿ってほぼ 1 画素ずつだが、長い楕円は
    /// ここで止め、片を長くする。
    ///
    /// **片を長くしても、置く位置による振れは出ない** — どの列もちょうど 1 つの片に入り、跨ぐ中心は
    /// n 個のままである。変わるのは、片の中のいちばん太い弦を取るぶんの多め (片の数 K に対して
    /// 4 / (πK) ほど) と、被覆が片ごとの段になることだけで、64 なら多めは 2% に収まる。距離関数の
    /// 経路の細い楕円も、長さ L に対して 4 / (πL) ほど多めに出る。上限を 1024 にしていた頃は、
    /// 400×0.5 の楕円 1 つが 2,400 頂点になり、200 個の組み立てが周から割るときの 6.4 倍かかった
    /// (#1934 の反証 8)。64 なら 384 頂点 (周から割ると 189) である。
    static let thinEllipseSliceLimit = 64

    /// 単位円を描く画素の楕円へ写す 2x2 (形自身の座標の半径を掛けたもの)。
    private static func ellipseLinear(
        _ named: Outline.NamedFill, _ linear: simd_float2x2
    ) -> simd_float2x2 {
        simd_float2x2(linear.columns.0 * named.half.x, linear.columns.1 * named.half.y)
    }

    private static func thinEllipsePieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        let shape = ellipseLinear(named, linear)
        let axes = principalAxes(shape)
        // 半径が単精度で無限へあふれた楕円も補わない (片の数を整数へ直せない)
        guard axes.long.isFinite, axes.short.isFinite,
            roundedDrawnWeight(2 * axes.short) < 1
        else { return nil }
        let inverse = linear.inverse
        // 長軸も細い楕円 (1 画素より小さい円を含む) は、描く画素 1 つの正方形にする。被覆は描く
        // 画素での外接する箱の面積 (2 つの半径の積の 4 倍)
        if roundedDrawnWeight(2 * axes.long) < 1 {
            return [
                unitSquare(
                    around: named.center, inverse: inverse, coverage: 4 * axes.long * axes.short)
            ]
        }
        if let profile = ShortProfile(ellipse: shape, longAxis: axes.direction) {
            return shortPieces(profile, center: named.center, inverse: inverse)
        }
        let along = axes.direction
        let across = SIMD2(-along.y, along.x)
        let thin = 2 * axes.short
        let width = thin * widenedBand(thin, along: along).widen
        let long = axes.long
        // 片の数は、上限で切ってから整数へ直す (巨大な直径を `Int` へ直すと実行時に落ちる)
        let span = 2 * long
        guard span.isFinite else { return nil }
        let count =
            span >= Float(thinEllipseSliceLimit)
            ? thinEllipseSliceLimit : max(1, Int(span.rounded(.up)))
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

    // MARK: - 長い向きが短い形

    /// 長い向きが短い細い形の、列 (行) ごとの弦 (#1934 の反証 2・``thinFillPieces(_:by:)``)。
    ///
    /// 描く画素で形の中心を原点に、**長い向きの座標 `s`** で表す。帯が横寄りなら列が形を切り、
    /// `s` は描く画素の x で、弦は縦に測る。縦寄りなら行が切り、`s` は y で、弦は横に測る。
    /// 弦の中点は 1 本の直線に並ぶ (矩形は帯の中心線、楕円は縦 (横) の弦を二等分する直径)。
    struct ShortProfile {
        /// 行が形を切るか (偽なら列が切る)。
        var byRows: Bool
        /// 長い向きの長さの半分 (描く画素)。`s` は −half…half。
        var half: Float
        /// `s = 0` での弦の長さ (描く画素)。
        var peak: Float
        /// 楕円か。楕円なら弦は `peak × √(1 − (s / half)²)`、矩形なら一定。
        var isEllipse: Bool
        /// 弦の中点の並ぶ線の傾き。`s` が 1 進むと、中点が弦の向きに `slope` 動く。
        var slope: Float

        /// 矩形の長い辺 `edge` (描く画素) と描く画素での面積から。長い向きが短くなければ `nil`。
        init?(rectEdge edge: SIMD2<Float>, area: Float) {
            byRows = abs(edge.y) > abs(edge.x)
            let along = byRows ? edge.y : edge.x
            half = abs(along) / 2
            guard half > 0, 2 * half < Canvas.thinFillShortSpan else { return nil }
            peak = area / (2 * half)
            isEllipse = false
            slope = (byRows ? edge.x : edge.y) / along
        }

        /// 単位円を描く画素の楕円へ写す 2x2 `shape` と、その長軸の向きから。長い向きが短くなければ
        /// `nil`。楕円を `S = shape · shapeᵀ` で表すと、x の幅の半分は `√S_xx`、中心を通る縦の弦は
        /// `2 |det| / √S_xx`、縦の弦の中点は `y = (S_xy / S_xx) x` に並ぶ (行が切るなら x と y を入れ替える)。
        init?(ellipse shape: simd_float2x2, longAxis: SIMD2<Float>) {
            let c0 = SIMD2<Double>(Double(shape.columns.0.x), Double(shape.columns.0.y))
            let c1 = SIMD2<Double>(Double(shape.columns.1.x), Double(shape.columns.1.y))
            let sxx = c0.x * c0.x + c1.x * c1.x
            let sxy = c0.x * c0.y + c1.x * c1.y
            let syy = c0.y * c0.y + c1.y * c1.y
            let area = abs(c0.x * c1.y - c0.y * c1.x)
            byRows = abs(longAxis.y) > abs(longAxis.x)
            let along = byRows ? syy : sxx
            let extent = along.squareRoot()
            guard extent > 0, (2 * extent).isFinite, 2 * extent < Double(Canvas.thinFillShortSpan)
            else { return nil }
            half = Float(extent)
            peak = Float(2 * area / extent)
            isEllipse = true
            slope = Float(sxy / along)
        }

        /// 弦の、`s` から `t` までの積分 (どちらも −half…half)。
        func integral(_ s: Float, _ t: Float) -> Float {
            guard isEllipse else { return peak * (t - s) }
            return peak * (unitArea(t) - unitArea(s))
        }

        /// `∫₀^s √(1 − (v / half)²) dv`
        private func unitArea(_ s: Float) -> Float {
            let r = min(max(s / half, -1), 1)
            return half / 2 * (r * max(0, 1 - r * r).squareRoot() + asin(r))
        }

        /// 列の位置を一様に動かしてならした、**列ごとの「列の中でいちばん太い弦 × 列と形が重なる
        /// 長さ」の和**。距離関数の経路が、長い向きを箱フィルタで、細い向きを画素の中で中心に
        /// いちばん近い位置の弦で数えた量 (`mokume_thinEllipseCoverage`) の、置く位置についての平均で
        /// ある。矩形では弦が一定なので、ちょうど面積になる。
        ///
        /// 列 [u, u + 1] を動かして積分する。中心を含む列は弦が `peak` で、重なりの積分は
        /// `half ≥ 1` なら 1、そうでなければ `2 half − half²`。中心の片側にある列は、中心にいちばん
        /// 近い端 (中心から v) の弦を取り、重なりは `min(1, half − v)` なので、
        /// `∫₀^half f(v) · min(1, half − v) dv`。両側で 2 倍する。
        var averagedLight: Float {
            guard isEllipse else { return peak * 2 * half }
            let x = half
            let middle = peak * (x >= 1 ? 1 : 2 * x - x * x)
            let knee = max(0, x - 1)
            // v f(v) の原始関数: −peak (x² / 3) (1 − v² / x²)^(3/2)
            func moment(_ v: Float) -> Float {
                let r = v / x
                return -peak * x * x / 3 * pow(max(0, 1 - r * r), 1.5)
            }
            let side = integral(0, knee) + x * integral(knee, x) - (moment(x) - moment(knee))
            return middle + 2 * side
        }
    }

    /// 長い向きが短い形を、**長い向きに整数の列 (行) の数ぶんの片**にする (#1934 の反証 2)。
    ///
    /// 長さを切り上げた整数 m 列ぶんの幅を、形の中心のまわりに置く。片の端は列の境目と平行 (列が
    /// 切るなら縦) なので、置く位置によらず列の中心をちょうど m 個含む。弦の向きには、弦の中点の線の
    /// まわりにちょうど n 行 (1 か 2) の高さに広げる。光の量 (``ShortProfile/averagedLight``) を
    /// 列に配り、被覆を「列 1 つに配った量 / n」にする。どれも置く位置に依らないので、畳みの雛形と
    /// 保持した形の控えにも使える。
    ///
    /// **矩形は m 列を 1 枚の片にする** — 弦が一定なので、どの列にも同じ量を配ればよい。楕円は列
    /// 1 つずつの片に切り、片の中の弦の積分の割合で配る。
    private static func shortPieces(
        _ profile: ShortProfile, center: SIMD2<Float>, inverse: simd_float2x2
    ) -> [ThinFillPiece] {
        let count = max(1, Int((2 * profile.half).rounded(.up)))
        let light = profile.averagedLight
        let left = -Float(count) / 2
        // (片の始まり, 終わり, 列 1 つに配る量)
        var spans: [(from: Float, to: Float, share: Float)] = []
        if profile.isEllipse {
            let whole = profile.integral(-profile.half, profile.half)
            spans.reserveCapacity(count)
            for index in 0..<count {
                let from = left + Float(index)
                let low = max(from, -profile.half)
                let high = min(from + 1, profile.half)
                let share = high > low && whole > 0 ? light * profile.integral(low, high) / whole : 0
                if share > 0 { spans.append((from, from + 1, share)) }
            }
        } else {
            spans.append((left, -left, light / Float(count)))
        }
        var largest: Float = 0
        for span in spans { largest = max(largest, span.share) }
        let crossings: Float = largest <= 1 ? 1 : 2
        let axis: SIMD2<Float> = profile.byRows ? SIMD2(0, 1) : SIMD2(1, 0)
        let across: SIMD2<Float> = profile.byRows ? SIMD2(1, 0) : SIMD2(0, 1)
        func corner(_ s: Float, _ side: Float) -> SIMD2<Float> {
            center + inverse * (axis * s + across * (profile.slope * s + side))
        }
        var pieces: [ThinFillPiece] = []
        pieces.reserveCapacity(spans.count)
        for span in spans {
            pieces.append(
                ThinFillPiece(
                    corners: (
                        corner(span.from, -crossings / 2), corner(span.to, -crossings / 2),
                        corner(span.to, crossings / 2), corner(span.from, crossings / 2)
                    ), coverage: span.share / crossings))
        }
        return pieces
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
    ///
    /// 読み取り位置の箱は、周の点を持つ素材 (楕円) なら周から、持たない素材 (矩形・記録のときに
    /// 周を落とす) なら形の箱 (中心 ± 半幅・半高 = 矩形の周の囲みの箱) から作る。
    static func thinFillVertices(
        _ pieces: [ThinFillPiece], recipe: RingFillRecipe
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan]) {
        var box = recipe.outline.points
        if box.isEmpty, let named = recipe.outline.namedFill {
            box = [named.center - named.half, named.center + named.half]
        }
        let uvOf = recipe.hasPicture ? boxUV(of: box) : nil
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
