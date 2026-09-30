// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 並べている途中の頂点 1 つぶん。
///
/// **平面と立体で同じものを溜める。** 立体で増えるのは頂点の中身 (奥行き・面の向き)
/// であって、形の種類ごとの対応表ではない ([ADR-0021] 決定 5)。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
struct BuildingVertex {
    /// 形自身の座標。変換は描くときに 1 度だけ掛かる。
    var position: SIMD3<Float>
    /// 面の向き。`nil` は**書かれていない**という意味で、形から求める。
    var normal: SIMD3<Float>?
    /// 断片へ届ける読み取り位置。貼る絵があれば絵の中の 0…1、無ければ書いた値そのまま
    /// (``Canvas/textureUV(_:_:)``)。`nil` は**書かれていない**という意味で、
    /// 形の囲みの箱から求める。
    var uv: SIMD2<Float>?
    /// 置いた時点の塗り。
    var fill: LinearRGBA
    /// 曲線が作った刻みの点か。**利用者が置いた点 (`vertex`・曲線の終点・通過点) ではない**
    /// ので、輪郭は継ぎ目に折れ目の形を置かない (``Canvas/strokeRing(count:isClosed:curveSteps:endSquare:band:disc:square:)``)。
    var isCurveStep = false
}

// 頂点を並べて形を作る。**道具は 1 つで、平面と立体に分かれない** ([ADR-0021] 決定 5)。
// 意味の説明は利用者が最初に触る層 (`Sketch`) が正本 ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // MARK: - 並べる

    // 頂点を並べ始める。
    public func beginShape(_ kind: VertexKind = .polygon) {
        // **形を開くのも置くことに含む** ([#1672])。区間の外で開いた形は、描き場所では境目が
        // 来ないので捨てられず、`vertex()` の点が際限なく溜まる (`setup()` で開き、`draw()` で
        // `beginDraw()` を書かずに点を足す書き方)
        //
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard canPlace else { return warnOutsideFrame(.placing) }
        // 閉じずに開き直した形は、描かずに捨てて 1 度だけ知らせる ([#1608])。境目で捨てる形
        // (``discardShapeLeftOpen()``) と同じく、点の有無によらず言う。片付けの並びは
        // ``discardOpenShape()`` の 1 か所に置く — 開き直す普段の場合もここを通る
        //
        // [#1608]: https://github.com/mokume-metal/mokume/issues/1608
        if isBuildingShape { warnShapeBegunWhileOpenOnce() }
        discardOpenShape()
        isBuildingShape = true
        shapeKind = kind
    }

    public func vertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        breakCurveSequence()
        appendVertex(SIMD3(x, y, 0), hasDepth: false)
    }

    // 奥行きを持つ頂点を 1 つ置く。
    public func vertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        breakCurveSequence()
        appendVertex(SIMD3(x, y, z), hasDepth: true)
    }

    // 貼る絵の読み取り位置つきで頂点を 1 つ置く。
    public func vertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ u: some ScalarConvertible, _ v: some ScalarConvertible) {
        let (x, y, u, v) = (x.asFloat, y.asFloat, u.asFloat, v.asFloat)
        breakCurveSequence()
        appendVertex(SIMD3(x, y, 0), hasDepth: false, uv: textureUV(u, v))
    }

    // 奥行きと読み取り位置を持つ頂点を 1 つ置く。
    public func vertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible, _ u: some ScalarConvertible, _ v: some ScalarConvertible) {
        let (x, y, z, u, v) = (x.asFloat, y.asFloat, z.asFloat, u.asFloat, v.asFloat)
        breakCurveSequence()
        appendVertex(SIMD3(x, y, z), hasDepth: true, uv: textureUV(u, v))
    }

    /// 書かれた読み取り位置を、断片の `Fragment.uv` へ届ける値にする。
    ///
    /// - **貼る絵を束ねていれば、受け取るのは画像の画素**である (手本の既定と、
    ///   ``image(_:_:_:_:_:_:_:_:_:)`` の切り出しに揃える)。絵の画素数で割って面の中の
    ///   0…1 へ写す
    /// - **束ねていなければ、書いた値を割らずにそのまま届ける** ([#1140])。割る先の
    ///   大きさが無いので 1×1 の絵と同じ扱いになり、利用者の断片は形自身の座標
    ///   (鼻から尾・左から右、など) を `in.uv` で読める。塗りは 1×1 の白い絵を読むので
    ///   (``Canvas/useWrittenUVTexture()``)、組み込みの断片の絵は変わらない
    ///
    /// 数でない値と、幅か高さが 0 の絵は、書かれていないことにする。
    ///
    /// [#1140]: https://github.com/mokume-metal/mokume/issues/1140
    private func textureUV(_ u: Float, _ v: Float) -> SIMD2<Float>? {
        guard u.isFinite, v.isFinite else { return nil }
        guard let picture = style.picture else { return SIMD2(u, v) }
        guard picture.width > 0, picture.height > 0 else { return nil }
        return SIMD2(u / Float(picture.width), v / Float(picture.height))
    }

    // これから置く頂点の面の向きを決める。
    public func normal(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        // 形の外で控えても、次の beginShape() が消すのでどの頂点にも効かない (#1520)
        guard admitsShapeCall("normal") else { return }
        let direction = SIMD3<Float>(x, y, z)
        // 長さを持たない向き・数でない向きは「書かれていない」に倒す。零ベクトルを
        // そのまま持たせると、光の計算で向きの定まらない面になる (#1528 で注意を足した)
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
            length_squared(direction) > 0
        else {
            currentNormal = nil
            warnBadNormalOnce()
            return
        }
        currentNormal = normalize(direction)
    }

    public func bezierVertex(
        _ cx1: some ScalarConvertible, _ cy1: some ScalarConvertible, _ cx2: some ScalarConvertible, _ cy2: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible
    ) {
        let (cx1, cy1, cx2, cy2, x, y) = (cx1.asFloat, cy1.asFloat, cx2.asFloat, cy2.asFloat, x.asFloat, y.asFloat)
        breakCurveSequence()
        guard admitsShapeCall("bezierVertex") else { return }
        guard let start = lastShapePoint else { return warnCurveWithoutStartOnce("bezierVertex") }
        let c1 = SIMD2(cx1, cy1)
        let c2 = SIMD2(cx2, cy2)
        let end = SIMD2(x, y)
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            // 最後の刻みは終点 — 利用者が置いた点なので、そこで折れれば角になる
            appendShapePoint(
                Self.cubicPoint(start, c1, c2, end, t), isCurveStep: step < currentCurveDetail)
        }
    }

    public func quadraticVertex(_ cx: some ScalarConvertible, _ cy: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (cx, cy, x, y) = (cx.asFloat, cy.asFloat, x.asFloat, y.asFloat)
        breakCurveSequence()
        guard admitsShapeCall("quadraticVertex") else { return }
        guard let start = lastShapePoint else { return warnCurveWithoutStartOnce("quadraticVertex") }
        // 2 次は 3 次の特別な形として通す — 曲線の道具を 1 本に保つ
        let control = SIMD2(cx, cy)
        let end = SIMD2(x, y)
        let c1 = start + (control - start) * (2.0 / 3.0)
        let c2 = end + (control - end) * (2.0 / 3.0)
        bezierVertex(c1.x, c1.y, c2.x, c2.y, end.x, end.y)
    }

    /// 通過点を結ぶ曲線の制御点を置く。
    ///
    /// **4 つ揃って初めて 1 区間が引ける** — 最初と最後の点は曲がり方を決めるためだけに
    /// 使われ、その間だけが実際に描かれる。
    ///
    /// **並びは `curveVertex` を続けて呼んでいる間だけ続く。** `vertex` / `bezierVertex` /
    /// `quadraticVertex` と穴の境目 (`beginContour` / `endContour`) で切れ、次の区間はまた
    /// 4 つ揃ってから引く。**並びの最初の区間は、その始点 (2 つ目に置いた点) も環に置く**
    /// — 環 (外周か穴) の最初でも、切れた後の並びでも同じで、穴の中の曲線は外周と独立に
    /// 始まる ([#1449])。直す前は環の最初でだけ置いていたので、切れた後の並びは手前の点から
    /// 刻みの 1 つ目へ直に繋がっていた ([#1537])。環の最後の点が始点と同じ位置なら置き
    /// 直さない — 始点を `vertex` で明示した書き方が、同じ点を 2 度持たない。規則の正本は
    /// ``Sketch/curveVertex(_:_:)`` の説明。
    ///
    /// [#1449]: https://github.com/mokume-metal/mokume/issues/1449
    /// [#1537]: https://github.com/mokume-metal/mokume/issues/1537
    public func curveVertex(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        guard admitsShapeCall("curveVertex") else { return }
        curveGuides.append(SIMD2(x, y))
        guard curveGuides.count >= 4 else { return }
        let count = curveGuides.count
        let p0 = curveGuides[count - 4]
        let p1 = curveGuides[count - 3]
        let p2 = curveGuides[count - 2]
        let p3 = curveGuides[count - 1]
        // 並びの最初の区間は始点も置く。環の最後の点が始点と同じ位置なら置き直さない (#1537)
        let last = (holePoints ?? shapePoints).last.map { SIMD2($0.position.x, $0.position.y) }
        if count == 4, last != p1 { appendShapePoint(p1, isCurveStep: false) }
        for step in 1...currentCurveDetail {
            let t = Float(step) / Float(currentCurveDetail)
            // 最後の刻みは通過点 — 張り具合 1 では折れ線の角になる
            appendShapePoint(
                Self.catmullRomPoint(p0, p1, p2, p3, t, tightness: currentCurveTightness),
                isCurveStep: step < currentCurveDetail)
        }
    }

    public func curveDetail(_ steps: Int) {
        // 1 より小さい刻みは 1 にして、1 度知らせる (#1698)
        guard steps >= 1 else {
            warnRounded(.badCurveDetail, "curveDetail", "the number of steps", takes: "1 or more", passed: steps, used: 1)
            currentCurveDetail = 1
            return
        }
        currentCurveDetail = steps
    }

    public func curveTightness(_ amount: some ScalarConvertible) {
        let amount = amount.asFloat
        currentCurveTightness = amount
    }

    public func beginContour() {
        guard admitsShapeCall("beginContour") else { return }
        // 開いたままの穴は、endShape() と同じ規則で畳んでから次を始める (#1528)
        closeOpenHole()
        holePoints = []
        breakCurveSequence()
    }

    public func endContour() {
        guard admitsShapeCall("endContour") else { return }
        guard holePoints != nil else { return warnContourNotBegunOnce() }
        closeOpenHole()
    }

    /// 開いている穴を畳む。**注意は言わない** — 閉じ忘れを畳むのは約束どおりの振る舞いで、
    /// 公開の ``endContour()`` とは道を分ける ([#1528])。
    ///
    /// 同じ道を通すと、穴を閉じた形・穴の無い形の ``endShape(_:)`` が「閉じる穴が無い」を
    /// 言ってしまう。穴を開いていなければ何もしない。点が 3 つに満たない穴は面にならない
    /// ので捨てる。
    ///
    /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
    private func closeOpenHole() {
        guard let hole = holePoints else { return }
        if hole.count >= 3 { shapeHoles.append(hole) }
        holePoints = nil
        breakCurveSequence()
    }

    public func endShape(_ end: ShapeEnd = .open) {
        defer { discardOpenShape() }
        // 区間の外では描かない。区間の中で開いた形を外で閉じても、形ごと捨てる ([#1672])。
        // 始まりの無い形の注意より先に見る — 外で開こうとした形は、開く口がもう断っている
        //
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard canPlace else { return warnOutsideFrame(.placing) }
        // 始まりの無い形の終わり — beginShape() の書き忘れか、二重呼び (#1520)
        guard isBuildingShape else { return warnShapeNotBegunOnce() }
        closeOpenHole()  // 閉じ忘れた穴も畳む
        drawBuiltShape(closed: end == .close)
    }

    /// 組み立て中の形を、描かずに捨てる。**注意は言わない。**
    ///
    /// ``endShape(_:)`` が描いた後に片付けるのと、フレームの境目が閉じ忘れた形を捨てる
    /// (``discardShapeLeftOpen()``) のと、``beginShape(_:)`` が開き直す前に空にする ([#1608])
    /// のが、同じここを通る ([#1591])。並びを 2 か所に書くと、組み立ての状態を 1 つ足した
    /// 日に片方だけが戻す — フレームの境目で戻す状態を境目の関数ごとに手で並べていたのが、
    /// #1591 の戻し落としの形そのものである。
    ///
    /// 開いたままの穴 (#1528) は畳まずに形ごと捨てる。畳むのは ``endShape(_:)`` が描く
    /// ときの約束で、描かない形の穴を畳む理由は無い。
    ///
    /// [#1591]: https://github.com/mokume-metal/mokume/issues/1591
    /// [#1608]: https://github.com/mokume-metal/mokume/issues/1608
    func discardOpenShape() {
        isBuildingShape = false
        // 読むのは組み立ての間だけ (`beginShape()` が書き直す) だが、既定へ戻しておく。
        // 境目の検査 (`CanvasTests.frameStateResetsAtEveryBoundary`) が、組み立ての状態を
        // 1 つの群として既定に戻ったかで見る
        shapeKind = .polygon
        shapePoints.removeAll(keepingCapacity: true)
        shapeIndices.removeAll(keepingCapacity: true)
        shapeHoles.removeAll(keepingCapacity: true)
        curveGuides.removeAll(keepingCapacity: true)
        holePoints = nil
        shapeHasDepth = false
        currentNormal = nil
    }

    /// 組み立て中の形ひとつぶん。形の組み立て (``createShape(_:)``) が、外で開いていた形を
    /// 記録の間だけ退かせるのに使う ([#1607])。
    ///
    /// **並びは ``discardOpenShape()`` と同じである。** 組み立ての状態を足したら 3 か所
    /// (ここ・``takeOpenShape()``・``restoreOpenShape(_:)``) と `discardOpenShape()` に足す。
    /// 落とすと、`CanvasTests.createShapeKeepsTheOuterOpenShape` が既定のままのものを名乗って赤になる。
    ///
    /// [#1607]: https://github.com/mokume-metal/mokume/issues/1607
    struct OpenShape {
        var isBuilding: Bool
        var kind: VertexKind
        var points: [BuildingVertex]
        var indices: [Int]
        var holes: [[BuildingVertex]]
        var holePoints: [BuildingVertex]?
        var hasDepth: Bool
        var normal: SIMD3<Float>?
        var curveGuides: [SIMD2<Float>]
    }

    /// 組み立て中の形を取り出し、組み立ての状態を既定へ戻す。**注意は言わない** —
    /// 取り出した形は ``restoreOpenShape(_:)`` で戻す ([#1607])。
    ///
    /// [#1607]: https://github.com/mokume-metal/mokume/issues/1607
    func takeOpenShape() -> OpenShape {
        let taken = OpenShape(
            isBuilding: isBuildingShape, kind: shapeKind, points: shapePoints,
            indices: shapeIndices, holes: shapeHoles, holePoints: holePoints,
            hasDepth: shapeHasDepth, normal: currentNormal, curveGuides: curveGuides)
        discardOpenShape()
        return taken
    }

    /// 取り出しておいた組み立て中の形へ戻す。
    func restoreOpenShape(_ shape: OpenShape) {
        isBuildingShape = shape.isBuilding
        shapeKind = shape.kind
        shapePoints = shape.points
        shapeIndices = shape.indices
        shapeHoles = shape.holes
        holePoints = shape.holePoints
        shapeHasDepth = shape.hasDepth
        currentNormal = shape.normal
        curveGuides = shape.curveGuides
    }

    /// フレームの境目で開いたままの形を、形ごと捨てて 1 度だけ知らせる ([#1591])。
    ///
    /// **組み立て中の形はフレームに属する** ([ADR-0021] 決定 4 の追補 (2026-09-27))。
    /// `beginShape()` と `endShape()` は対で開いて閉じる操作で、積み履歴 (#925) と同じく
    /// 1 つのフレームの中で釣り合う。持ち越すと、閉じ忘れた形へ次のフレームの `vertex()` が
    /// 点を積み続け、何も描かれないまま記憶だけが増える (60 fps で 1 時間に約 36 GB)。
    ///
    /// **フレームの頭と終わりの両方で呼ぶ。** 頭だけだと `draw()` で開いた形が止まっている
    /// 間のコールバックへ漏れ、終わりだけだと `setup()` で開いた形に 1 枚目の点が積まれる。
    /// 開いていなければ何もしない。形の組み立て (``createShape(_:)``) の出口も同じここを通る
    /// ([#1607])。
    ///
    /// [#1607]: https://github.com/mokume-metal/mokume/issues/1607
    /// [#1591]: https://github.com/mokume-metal/mokume/issues/1591
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    func discardShapeLeftOpen() {
        guard isBuildingShape else { return }
        warnShapeNotEndedOnce()
        discardOpenShape()
    }

    // 置いた頂点を 1 つ、番号で選ぶ。
    public func index(_ number: Int) {
        guard admitsShapeCall("index") else { return }
        shapeIndices.append(number)
    }

    // MARK: - 閉じる

    /// 並べ終えた頂点をどう読むか。
    ///
    /// 種類ごとに違う描き方をするのではなく、**どの種類も「原始形の一覧」へ畳んでから
    /// 同じ手順で出す**。塗りと線の出る順序が種類によって変わらない。
    private struct Primitive {
        /// 外周をなす頂点の番号。
        ///
        /// **形の全原始形で 1 本の並びを共有する切り出し**である ([#1781])。`.triangles`
        /// のように三角形 1 枚が原始形 1 つになる読み方で、原始形ごとに番号の配列を
        /// 確保しないため。添字は 0 から始まるとは限らないので、`startIndex` から数える。
        ///
        /// [#1781]: https://github.com/mokume-metal/mokume/issues/1781
        var ring: ArraySlice<Int>
        /// 穴をなす頂点の番号。
        var holes: [[Int]] = []
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 塗りを持つか (線と点は持たない)。
        var fills: Bool
    }

    /// 変換を掛けた頂点。立体だけが使う。
    private struct PlacedVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        /// 向きを形から求めたか。**求めた向きだけ両面として扱う** (``SolidVertex/normal``)。
        var isDerived: Bool
        var color: LinearRGBA
        /// 変換を掛ける**前**の面の向き。利用者の断片へ渡す (``SolidVertex/shapeNormal``)。
        var shapeNormal: SIMD3<Float>
    }

    /// 並べ終えた頂点を描く。
    private func drawBuiltShape(closed: Bool) {
        var points = shapePoints
        for hole in shapeHoles { points += hole }
        guard !points.isEmpty else { return }
        let primitives = builtPrimitives(closed: closed)

        // **塗る三角形を先に全部求める。** 面の向きは形の全体から求めるので、出す前に
        // 揃っている必要がある — 3 つずつ独立に処理すると、帯状・扇状に並べたときに
        // 後ろの頂点が書かれないまま残る
        //
        // 閉包を標準ライブラリの高階関数へ渡さずにループで回す。main actor の文脈で作った
        // 閉包は、要素ごとに隔離の実行時検査を払う (#1779)
        //
        // 三角形は形の全原始形で 1 本の並びへ積み、原始形ごとの区間で引く ([#1781])
        //
        // 交わった周を分けると、交点が `points` の後ろに足される ([#1538])。足した点は
        // 塗りの三角形だけが指し、輪郭 (`primitive.ring`) は指さない
        var allTriangles: [(Int, Int, Int)] = []
        var triangleRanges: [Range<Int>] = []
        triangleRanges.reserveCapacity(primitives.count)
        for primitive in primitives {
            let start = allTriangles.count
            fillTriangles(of: primitive, points: &points, into: &allTriangles)
            triangleRanges.append(start..<allTriangles.count)
        }
        let placed = shapeHasDepth ? placedVertices(points, triangles: allTriangles) : []
        // **形に 1 度だけ求める。** 囲みの箱は原始形によらず同じ (見るのは置いた点の
        // 全体) なので、原始形ごとに作り直すと置いた量の二乗で効く ([#915])
        let readsUV = readsUV(points)
        let fallback = readsUV ? uvFallback(points) : nil

        emit {
            for (primitive, range) in zip(primitives, triangleRanges) {
                // **原始形ごとに 塗り → 線。** 種類によらず同じ順序なので、線が
                // 隣の原始形の塗りに隠れることがない
                emitFill(
                    allTriangles[range], points: points, placed: placed,
                    readsUV: readsUV, fallback: fallback)
                if style.hasStroke, style.strokeWeight > 0 {
                    emitStroke(primitive, points: points, placed: placed)
                }
            }
        }
    }

    /// 立体なら立体の並びへ溜める区間を開き、平面ならそのまま実行する。
    ///
    /// **添字を書いた立体は、添字で読む列を開く。** 平面は添字を書いても列の作りが
    /// 変わらない — 三角形へ落とした時点で頂点が展開されるので、共有する先が無い。
    private func emit(_ body: () -> Void) {
        guard shapeHasDepth else { return body() }
        inSolidBatch(indexed: !shapeIndices.isEmpty, body)
    }

    /// 並べ終えた頂点を原始形の一覧へ畳む。
    ///
    /// **読む順は添字が決める。** 書かれていなければ置いた順 (`0, 1, 2, …`) で、これは
    /// 添字を「一巡りする並び」と書いたのと同じ意味になる。だから読み方 (``VertexKind``)
    /// の側は 1 つも分岐しない。
    ///
    /// **範囲外の番号は、それを含む原始形ごと落とす。** 1 つずつ落とすと `.triangles` の
    /// ような束ねて読む種類で 3 つ組の区切りがずれ、**それ以降の面が全部別の頂点を指す**。
    private func builtPrimitives(closed: Bool) -> [Primitive] {
        guard shapeIndices.isEmpty else {
            let range = shapePoints.indices
            let built = primitives(reading: shapeIndices, closed: closed)
            var kept: [Primitive] = []
            kept.reserveCapacity(built.count)
            for primitive in built {
                var inRange = true
                for index in primitive.ring where !range.contains(index) {
                    inRange = false
                    break
                }
                if inRange { kept.append(primitive) }
            }
            if kept.count != built.count { warnIndexOutOfRange() }
            return kept
        }
        return primitives(reading: Array(shapePoints.indices), closed: closed)
    }

    /// 読む順を、読み方に従って原始形の一覧へ畳む。
    private func primitives(reading outer: [Int], closed: Bool) -> [Primitive] {
        switch shapeKind {
        case .polygon:
            var holes: [[Int]] = []
            var next = shapePoints.count
            for hole in shapeHoles {
                holes.append(Array(next..<(next + hole.count)))
                next += hole.count
            }
            return [Primitive(ring: outer[...], holes: holes, isClosed: closed, fills: true)]

        case .triangles:
            // 読む順そのものの切り出しで足りる (並べ替えない)
            var built: [Primitive] = []
            built.reserveCapacity(outer.count / 3)
            for start in stride(from: 0, to: max(0, outer.count - 2), by: 3) {
                built.append(
                    Primitive(ring: outer[start..<(start + 3)], isClosed: true, fills: true))
            }
            return built

        case .triangleStrip:
            // **1 枚ずつ巻きを揃える** (帯の規約は OpenGL と同じ)。交互のまま出すと、
            // 隣り合う面の外積が打ち消し合って、書かれていない面の向きが求まらなくなる
            // (`placedVertices`)
            //
            // 並べ替えた番号は 1 本の並びへ**全部積んでから**切り出す。積む途中で切り出すと、
            // 切り出しが並びを参照している間の追記が並び全体の写しになる
            let count = max(0, outer.count - 2)
            var rings: [Int] = []
            rings.reserveCapacity(count * 3)
            for start in 0..<count {
                if start.isMultiple(of: 2) {
                    rings.append(outer[start])
                    rings.append(outer[start + 1])
                    rings.append(outer[start + 2])
                } else {
                    rings.append(outer[start + 1])
                    rings.append(outer[start])
                    rings.append(outer[start + 2])
                }
            }
            return Self.triples(of: rings)

        case .triangleFan:
            // 帯と同じく、積み終えてから切り出す
            var rings: [Int] = []
            rings.reserveCapacity(max(0, outer.count - 2) * 3)
            for step in 1..<max(1, outer.count - 1) {
                rings.append(outer[0])
                rings.append(outer[step])
                rings.append(outer[step + 1])
            }
            return Self.triples(of: rings)

        case .lines:
            var built: [Primitive] = []
            built.reserveCapacity(outer.count / 2)
            for start in stride(from: 0, to: max(0, outer.count - 1), by: 2) {
                built.append(
                    Primitive(ring: outer[start..<(start + 2)], isClosed: false, fills: false))
            }
            return built

        case .points:
            var built: [Primitive] = []
            built.reserveCapacity(outer.count)
            for index in outer.indices {
                built.append(Primitive(ring: outer[index..<(index + 1)], isClosed: false, fills: false))
            }
            return built
        }
    }

    /// 3 つずつ並んだ番号を、塗る三角形の原始形の一覧へ切り出す。
    private static func triples(of rings: [Int]) -> [Primitive] {
        var built: [Primitive] = []
        built.reserveCapacity(rings.count / 3)
        for start in stride(from: 0, to: rings.count, by: 3) {
            built.append(Primitive(ring: rings[start..<(start + 3)], isClosed: true, fills: true))
        }
        return built
    }

    /// 原始形を三角形へ分ける。返すのは頂点の番号の 3 つ組。
    ///
    /// **写すのは環の点だけ。** 平らな座標を点番号で引ける並びとして作ると、原始形ごとに
    /// 置いた点を全部舐めることになり、`.triangles` のように**三角形 1 枚が原始形 1 つ**に
    /// なる読み方では「1 度に渡した量」の二乗で効いた ([#915])。
    ///
    /// 全部を写すのは**穴があるときだけ**である。穴を持てるのは周をなす読み方だけで、
    /// その原始形は 1 つしかない。`Triangulation/mergeHoles(outer:holes:points:)` は点番号で
    /// 引く前提なので並びが要り、落とし方を渡す形にすると橋の判定が環の長さの二乗ぶん
    /// 引き直すことになって逆に遅くなる。
    ///
    /// [#915]: https://github.com/mokume-metal/mokume/issues/915
    private func fillTriangles(
        of primitive: Primitive, points: inout [BuildingVertex],
        into triangles: inout [(Int, Int, Int)]
    ) {
        guard primitive.fills, style.hasFill, primitive.ring.count >= 3 else { return }
        guard let basis = flatBasis(of: primitive, points: points) else { return }
        if primitive.holes.isEmpty {
            let ring = primitive.ring
            // **3 点なら分けるまでもない** ([#1781])。`Triangulation.triangulate` は 3 点に
            // `(0, 1, 2)` を返すので、平らな座標を写さずに同じ答えを積む。潰れた三角形を
            // 捨てる判定 (`flatBasis`) は上で済んでいる。`.triangles` などは三角形 1 枚が
            // 原始形 1 つなので、この近道が形 1 つにつき三角形の数だけ効く。3 点の周は
            // 交われないので、交わりも探さない ([#1538])
            if ring.count == 3 {
                pointScansThisFrame += 3
                let first = ring.startIndex
                triangles.append((ring[first], ring[first + 1], ring[first + 2]))
                return
            }
            pointScansThisFrame += ring.count
            var flattened: [SIMD2<Float>] = []
            flattened.reserveCapacity(ring.count)
            for index in ring { flattened.append(basis.flatten(points[index].position)) }
            let local = Array(flattened.indices)
            if let split = Triangulation.splitForNonzero(
                rings: [local], points: flattened, comparisons: &pointScansThisFrame)
            {
                fillSplit(split, flat: flattened, global: Array(ring), points: &points, into: &triangles)
                return
            }
            let first = ring.startIndex
            for (a, b, c) in Triangulation.triangulate(flattened, comparisons: &pointScansThisFrame) {
                triangles.append((ring[first + a], ring[first + b], ring[first + c]))
            }
            return
        }

        var all: [SIMD2<Float>] = []
        all.reserveCapacity(points.count)
        for point in points { all.append(basis.flatten(point.position)) }
        pointScansThisFrame += points.count
        if let split = Triangulation.splitForNonzero(
            rings: [Array(primitive.ring)] + primitive.holes, points: all,
            comparisons: &pointScansThisFrame)
        {
            fillSplit(split, flat: all, global: nil, points: &points, into: &triangles)
            return
        }
        let merged = Triangulation.mergeHoles(
            outer: Array(primitive.ring), holes: primitive.holes, points: all)
        pointScansThisFrame += merged.count
        var flattened: [SIMD2<Float>] = []
        flattened.reserveCapacity(merged.count)
        for index in merged { flattened.append(basis.flatten(points[index].position)) }
        for (a, b, c) in Triangulation.triangulate(flattened, comparisons: &pointScansThisFrame) {
            triangles.append((merged[a], merged[b], merged[c]))
        }
    }

    /// 交点で分けた周を三角形へ分ける ([#1538])。
    ///
    /// 交点は `points` の後ろに点として足す。分けた周の組は、交わらない形と同じ
    /// `mergeHoles` → `triangulate` へ 1 つずつ通す。
    ///
    /// - Parameters:
    ///   - flat: 分ける前の周が指す、平らな座標。
    ///   - global: `flat` の何番目が `points` の何番目か。`nil` なら同じ番号。
    private func fillSplit(
        _ split: Triangulation.Split, flat: [SIMD2<Float>], global: [Int]?,
        points: inout [BuildingVertex], into triangles: inout [(Int, Int, Int)]
    ) {
        let base = points.count
        func toGlobal(_ local: Int) -> Int {
            guard local < flat.count else { return base + local - flat.count }
            return global?[local] ?? local
        }
        var all = flat
        all.reserveCapacity(flat.count + split.crossings.count)
        // 片方の端だけに読み取り位置が書かれた辺では、書かれていない端を、耳切りの経路と
        // 同じ倒れ先 (``uvFallback(_:)`` が形の囲みの箱から求める値) で埋めてから補間する。
        // 倒れ先は交点を足す前の点で求める (交点は辺の上にあるので、囲みの箱は変わらない)
        var fallback: ((SIMD2<Float>) -> SIMD2<Float>)?
        for crossing in split.crossings where fallback == nil {
            for (from, to) in [
                (crossing.first.from, crossing.first.to), (crossing.second.from, crossing.second.to),
            ] where (points[toGlobal(from)].uv == nil) != (points[toGlobal(to)].uv == nil) {
                fallback = uvFallback(Array(points[..<base]))
                break
            }
        }
        for crossing in split.crossings {
            all.append(crossing.point)
            points.append(
                Self.crossingVertex(
                    points[toGlobal(crossing.first.from)], points[toGlobal(crossing.first.to)],
                    at: crossing.first.at,
                    points[toGlobal(crossing.second.from)], points[toGlobal(crossing.second.to)],
                    at: crossing.second.at, fallback: fallback))
        }
        for region in split.regions {
            let merged =
                region.holes.isEmpty
                ? region.outer
                : Triangulation.mergeHoles(
                    outer: region.outer, holes: region.holes, points: all, slack: split.slack)
            pointScansThisFrame += merged.count
            var flattened: [SIMD2<Float>] = []
            flattened.reserveCapacity(merged.count)
            for index in merged { flattened.append(all[index]) }
            for (a, b, c) in Triangulation.triangulate(
                flattened, comparisons: &pointScansThisFrame, slack: split.slack)
            {
                triangles.append((toGlobal(merged[a]), toGlobal(merged[b]), toGlobal(merged[c])))
            }
        }
    }

    /// 交点に足す点。**交わる 2 辺のそれぞれで線形に補間し、2 辺の値を平均する** ([#1538])。
    ///
    /// 奥行きを持つ形では、2 辺が同じ位置で交わるとは限らない (平らにした座標で交わっても、
    /// 奥行きが違う)。平均すると、交点は 2 辺の間に来る。色も同じく平均し、2 辺の色が
    /// 違えば交点はその中間になる。
    ///
    /// 読み取り位置と面の向きは**書かれている値からだけ取る**。両端に書かれている辺の値を
    /// 使い、2 辺とも書かれていれば平均する。どちらの辺にも無ければ書かれていないままにし、
    /// ほかの書かれていない点と同じく形から求める。
    ///
    /// ただし読み取り位置は、**片方の端だけに書かれた辺**なら、書かれていない端を
    /// `fallback` (書かれていない点が塗りで倒れる先と同じ値) で埋めて補間する。埋めずに
    /// その辺を捨てると、交点が形の囲みの箱の値へ倒れ、隣の書かれた点との間に継ぎ目が出る。
    static func crossingVertex(
        _ a: BuildingVertex, _ b: BuildingVertex, at t: Float,
        _ c: BuildingVertex, _ d: BuildingVertex, at u: Float,
        fallback: ((SIMD2<Float>) -> SIMD2<Float>)? = nil
    ) -> BuildingVertex {
        func mix(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ w: Float) -> SIMD3<Float> { x + w * (y - x) }
        func mix(_ x: SIMD2<Float>, _ y: SIMD2<Float>, _ w: Float) -> SIMD2<Float> { x + w * (y - x) }
        func mix(_ x: LinearRGBA, _ y: LinearRGBA, _ w: Float) -> SIMD4<Float> {
            let from = SIMD4(x.red, x.green, x.blue, x.alpha)
            return from + w * (SIMD4(y.red, y.green, y.blue, y.alpha) - from)
        }
        func average<Value: SIMD>(_ first: Value?, _ second: Value?) -> Value?
        where Value.Scalar == Float {
            guard let first else { return second }
            guard let second else { return first }
            return (first + second) * 0.5
        }

        var normalOnFirst: SIMD3<Float>?
        if let from = a.normal, let to = b.normal { normalOnFirst = mix(from, to, t) }
        var normalOnSecond: SIMD3<Float>?
        if let from = c.normal, let to = d.normal { normalOnSecond = mix(from, to, u) }
        func written(_ point: BuildingVertex, beside other: BuildingVertex) -> SIMD2<Float>? {
            if let uv = point.uv { return uv }
            guard other.uv != nil, let fallback else { return nil }
            return fallback(SIMD2(point.position.x, point.position.y))
        }
        var uvOnFirst: SIMD2<Float>?
        if let from = written(a, beside: b), let to = written(b, beside: a) {
            uvOnFirst = mix(from, to, t)
        }
        var uvOnSecond: SIMD2<Float>?
        if let from = written(c, beside: d), let to = written(d, beside: c) {
            uvOnSecond = mix(from, to, u)
        }

        let color = (mix(a.fill, b.fill, t) + mix(c.fill, d.fill, u)) * 0.5
        return BuildingVertex(
            position: (mix(a.position, b.position, t) + mix(c.position, d.position, u)) * 0.5,
            normal: average(normalOnFirst, normalOnSecond),
            uv: average(uvOnFirst, uvOnSecond),
            fill: LinearRGBA(
                premultipliedRed: color.x, green: color.y, blue: color.z, alpha: color.w),
            // 利用者が置いた点ではない。輪郭は元の周から引くので、この点を通らない
            isCurveStep: true)
    }

    /// 塗りが読み取り位置を持つか。**貼る絵を束ねているか、1 点でも書かれていれば持つ。**
    ///
    /// 絵が無くても、書いた位置は割らずに断片へ届く (``textureUV(_:_:)``)。どちらでも
    /// ないときだけ焼き場の白い区画を読み、読み取り位置が無かった頃と 1 ビットも
    /// 変わらない。
    private func readsUV(_ points: [BuildingVertex]) -> Bool {
        if style.picture != nil { return true }
        for point in points where point.uv != nil { return true }
        return false
    }

    /// 書かれていない読み取り位置の倒れ先。**形に 1 度だけ求める。**
    ///
    /// 全部の点に書かれていれば作らない — 囲みの箱は 1 度も引かれないので、求めるだけ
    /// 無駄である。**読み取り位置を持つか (``readsUV(_:)``) とは別**なので、呼ぶ側は
    /// 2 つを分けて持つ (``Canvas/emitFill(_:points:placed:readsUV:fallback:)``)。
    /// 読み取り位置を持たない形では呼ばない。
    ///
    /// 判定は**実際の読み取り位置の有無**で行う。「利用者が 4 引数の `vertex` を呼んだか」
    /// では代われない — ``textureUV(_:_:)`` は絵の幅か高さが 0 のときや数でない値が
    /// 渡されたときにも書かれていないことにするので、呼んだのに持たない点がある。
    private func uvFallback(_ points: [BuildingVertex]) -> ((SIMD2<Float>) -> SIMD2<Float>)? {
        var lacksUV = false
        for point in points where point.uv == nil {
            lacksUV = true
            break
        }
        guard lacksUV else { return nil }
        pointScansThisFrame += points.count
        var flat: [SIMD2<Float>] = []
        flat.reserveCapacity(points.count)
        for point in points { flat.append(SIMD2(point.position.x, point.position.y)) }
        return Canvas.boxUV(of: flat)
    }

    /// 三角形へ分けるための、平らな座標の取り方。
    ///
    /// **点番号で引ける並びを作らない。** 要る点だけを落とせるように、落とし方のほうを
    /// 持ち歩く (``Canvas/fillTriangles(of:points:into:)``)。
    private struct FlatBasis {
        /// `nil` なら平面 — xy をそのまま使う。
        ///
        /// **単位ベクトルとの内積へ畳まない。** `x * 1 + y * 0 + z * 0` にすると、`x` が
        /// `-0.0` の点で `+0.0` に変わる。絵は動かないはずだが、台帳を賭ける理由が無い。
        var across: SIMD3<Float>?
        var along: SIMD3<Float>?

        func flatten(_ position: SIMD3<Float>) -> SIMD2<Float> {
            guard let across, let along else { return SIMD2(position.x, position.y) }
            return SIMD2(dot(position, across), dot(position, along))
        }
    }

    /// 三角形へ分けるための、平らな座標の取り方を決める。
    ///
    /// 立体は**外周のなす平面へ落としてから**、平面と同じ三角形化の道具へ通す。穴も
    /// 同じ平面へ落とすので、穴が「一部の経路でだけ効く」ことにならない。
    /// 平面が決まらない (点が一直線に並ぶ・重なる) ときは `nil` を返して塗らない。
    private func flatBasis(of primitive: Primitive, points: [BuildingVertex]) -> FlatBasis? {
        guard shapeHasDepth else { return FlatBasis() }

        // 周をひと回りしながら面の向きを積む (Newell 法)。三角形 1 つから求めると、少しでも
        // 平らでない形で平面を取り違える
        var normal = SIMD3<Float>.zero
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        let ring = primitive.ring
        for offset in 0..<ring.count {
            let a = points[ring[ring.startIndex + offset]].position
            let b = points[ring[ring.startIndex + (offset + 1) % ring.count]].position
            normal += SIMD3(
                (a.y - b.y) * (a.z + b.z),
                (a.z - b.z) * (a.x + b.x),
                (a.x - b.x) * (a.y + b.y))
            low = simd_min(low, a)
            high = simd_max(high, a)
        }
        // **積んだ向きの長さは、周が囲む面積に比例する。** 自分と交わる周では、逆に回る
        // 葉どうしが打ち消し合い、砂時計では 0 になる ([#1538])。周の点がなす大きい三角形に
        // 比べて小さすぎるときは、その三角形から平面を決める。符号は積んだ向きに揃える。
        // 囲みの大きさに比べて小さいときだけ三角形を探すので、ふつうの形は手間も絵も
        // 変わらない
        let reach = length_squared(high - low)
        if length(normal) <= reach * 0x1p-10 {
            let widest = widestTriangleNormal(of: ring, points: points)
            if length(normal) <= length(widest) * 0x1p-10 {
                normal = dot(normal, widest) < 0 ? -widest : widest
            }
        }
        guard length_squared(normal) > 0 else { return nil }
        normal = normalize(normal)

        // 平面の上で直交する 2 本を選ぶ。どちらを選んでも分け方は変わらない
        let seed = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let across = normalize(cross(seed, normal))
        let along = cross(normal, across)
        return FlatBasis(across: across, along: along)
    }

    /// 周の点がなす大きい三角形の、面の向き (長さは三角形の面積の 2 倍)。
    ///
    /// 最初の点から最も遠い点を取り、その 2 点を結ぶ線から最も遠い点を足した三角形である。
    /// 周が平らなら、その平面の向きになる。点がすべて一直線に並ぶなら 0 を返す。
    private func widestTriangleNormal(of ring: ArraySlice<Int>, points: [BuildingVertex]) -> SIMD3<Float> {
        guard let first = ring.first else { return .zero }
        let origin = points[first].position
        var far = origin
        for index in ring {
            let point = points[index].position
            if length_squared(point - origin) > length_squared(far - origin) { far = point }
        }
        var widest = SIMD3<Float>.zero
        for index in ring {
            let candidate = cross(far - origin, points[index].position - origin)
            if length_squared(candidate) > length_squared(widest) { widest = candidate }
        }
        return widest
    }

    /// 変換を掛け、書かれていない面の向きを形から求める。
    private func placedVertices(_ points: [BuildingVertex], triangles: [(Int, Int, Int)])
        -> [PlacedVertex]
    {
        let matrix = transform.matrix
        let normalMatrix = transform.normalMatrix
        var needsDerivedNormals = false
        // **閉包へ渡さずにループで回す** — main actor の文脈で作った閉包を標準ライブラリの
        // 高階関数へ渡すと、要素ごとに隔離の実行時検査が入る (#1779)
        var placed: [PlacedVertex] = []
        placed.reserveCapacity(points.count)
        for point in points {
            let moved = matrix * SIMD4<Float>(point.position, 1)
            let normal: SIMD3<Float>
            if let written = point.normal {
                normal = normalize(normalMatrix * written)
            } else {
                normal = .zero
                needsDerivedNormals = true
            }
            placed.append(
                PlacedVertex(
                    position: SIMD3(moved.x, moved.y, moved.z),
                    normal: normal,
                    isDerived: point.normal == nil,
                    color: point.fill,
                    shapeNormal: point.normal ?? .zero))
        }

        // 全頂点に向きが書かれていれば、面から求めた向きは誰も使わない。
        // 未指定が1つでもあれば、変換前後の累積と加算順は従来通りに保つ。
        guard needsDerivedNormals else { return placed }

        // **書かれていない向きは、その頂点が属する三角形の向きを足し込んで求める。**
        // 三角形 3 つぶんずつ独立に処理すると、帯状・扇状に並べたときに後ろの頂点だけ
        // 書かれないまま残る
        //
        // **変換の前と後で 2 度足し込む。** 片方から他方を導けば 1 度で済むが、
        // 導いた値は既存の値と最下位ビットが揃わず、触っていない絵の台帳まで動く。
        // 光へ渡る向き (後) は 1 ビットも変えたくないので、断片へ渡す向き (前) を
        // 別に積む
        var accumulated = [SIMD3<Float>](repeating: .zero, count: points.count)
        var accumulatedInShape = [SIMD3<Float>](repeating: .zero, count: points.count)
        for triangle in triangles {
            let a = placed[triangle.0].position
            let b = placed[triangle.1].position
            let c = placed[triangle.2].position
            let face = cross(b - a, c - a)
            accumulated[triangle.0] += face
            accumulated[triangle.1] += face
            accumulated[triangle.2] += face

            let p = points[triangle.0].position
            let q = points[triangle.1].position
            let r = points[triangle.2].position
            let shapeFace = cross(q - p, r - p)
            accumulatedInShape[triangle.0] += shapeFace
            accumulatedInShape[triangle.1] += shapeFace
            accumulatedInShape[triangle.2] += shapeFace
        }
        for index in placed.indices where points[index].normal == nil {
            let sum = accumulated[index]
            placed[index].normal = length_squared(sum) > 0 ? normalize(sum) : .zero
            let shapeSum = accumulatedInShape[index]
            placed[index].shapeNormal = length_squared(shapeSum) > 0 ? normalize(shapeSum) : .zero
        }
        return placed
    }

    /// 塗りを出す。
    ///
    /// 貼る絵があるか、1 点でも読み取り位置が書かれていれば読み取り位置を付ける
    /// (``readsUV(_:)``)。**書かれていない頂点は形の囲みの箱 (xy) から作る** — 組み込みの
    /// 図形と同じ既定に倒すためで、書き忘れた形が絵の 1 画素だけで塗り潰される
    /// (手本がそうなる) のを避ける。絵が無い形でも同じ規則に倒す。
    ///
    /// 添字を書いた立体では、**同じ点を 2 度積まない** — 積むのは初めて参照されたときで、
    /// 2 度目からは番号だけを積む (``Canvas/appendSharedSolidVertex(slot:position:shapePosition:normal:shapeNormal:isDerived:uv:color:)``)。
    /// 共有の寿命が「形」ではなく「列」なのは、原始形が三角形 1 枚ずつに割れる読み方
    /// (`.triangles`) でも効かせるためである — 形の側で閉じると、原始形ごとに相異なる
    /// 点が 3 つしか無いので 1 つも減らない。
    ///
    /// **読み取り位置の有無と、倒れ先の有無は別のことである。** 一緒にすると、読み取り位置を
    /// 全部書いた形で倒れ先を省いた瞬間に「読み取り位置が無い」と読まれ、焼き場の白い区画が
    /// 選ばれて**貼った絵が消える**。しかも面の切り替えが列を閉じるので、形ごとに
    /// 列が割れて新しい二乗が生える。だから 2 つを別々に受け取る。
    private func emitFill(
        _ triangles: ArraySlice<(Int, Int, Int)>, points: [BuildingVertex], placed: [PlacedVertex],
        readsUV: Bool, fallback: ((SIMD2<Float>) -> SIMD2<Float>)?
    ) {
        func uv(_ index: Int) -> SIMD2<Float>? {
            guard readsUV else { return nil }
            if let written = points[index].uv { return written }
            // 倒れ先は「1 つでも書かれていない点がある」ときに作られるので、ここへ来た
            // 時点で必ず在る (`uvFallback`)
            return fallback?(
                SIMD2(points[index].position.x, points[index].position.y))
        }

        for triangle in triangles {
            if shapeHasDepth {
                for index in [triangle.0, triangle.1, triangle.2] {
                    let vertex = placed[index]
                    // **変換を焼き込む前の座標と向きも渡す。** 断片へ届くのはそちらで、
                    // 組み込みの立体と同じく「回しても模様が形に留まる」ようにする
                    if shapeIndices.isEmpty {
                        appendSolidVertex(
                            position: vertex.position, shapePosition: points[index].position,
                            normal: vertex.normal, shapeNormal: vertex.shapeNormal,
                            isDerived: vertex.isDerived, uv: uv(index), color: vertex.color)
                    } else {
                        appendSharedSolidVertex(
                            slot: index,
                            position: vertex.position, shapePosition: points[index].position,
                            normal: vertex.normal, shapeNormal: vertex.shapeNormal,
                            isDerived: vertex.isDerived, uv: uv(index), color: vertex.color)
                    }
                }
            } else {
                let (a, b, c) = triangle
                appendTriangle(
                    transform.apply(x: points[a].position.x, y: points[a].position.y),
                    transform.apply(x: points[b].position.x, y: points[b].position.y),
                    transform.apply(x: points[c].position.x, y: points[c].position.y),
                    colors: (points[a].fill, points[b].fill, points[c].fill),
                    uvs: readsUV ? (uv(a)!, uv(b)!, uv(c)!) : nil)
            }
        }
    }

    /// 線を出す。**穴の縁も輪郭を持つ。**
    private func emitStroke(
        _ primitive: Primitive, points: [BuildingVertex], placed: [PlacedVertex]
    ) {
        strokeRing(primitive.ring, closed: primitive.isClosed, points: points, placed: placed)
        for hole in primitive.holes {
            strokeRing(hole[...], closed: true, points: points, placed: placed)
        }
    }

    private func strokeRing(
        _ ring: ArraySlice<Int>, closed: Bool, points: [BuildingVertex], placed: [PlacedVertex]
    ) {
        guard !ring.isEmpty else { return }
        var curveSteps: [Bool] = []
        curveSteps.reserveCapacity(ring.count)
        for index in ring { curveSteps.append(points[index].isCurveStep) }
        if shapeHasDepth {
            var placedRing: [SIMD3<Float>] = []
            var shapeRing: [SIMD3<Float>] = []
            placedRing.reserveCapacity(ring.count)
            shapeRing.reserveCapacity(ring.count)
            for index in ring {
                placedRing.append(placed[index].position)
                shapeRing.append(points[index].position)
            }
            strokeSolidRing(
                placedRing, shapePoints: shapeRing, isClosed: closed, curveSteps: curveSteps)
        } else {
            // 平面の輪郭は変換の前の座標で組み立てる (`Outline` の説明を参照)
            var flatRing: [SIMD2<Float>] = []
            flatRing.reserveCapacity(ring.count)
            for index in ring { flatRing.append(SIMD2(points[index].position.x, points[index].position.y)) }
            strokeOutline(
                Outline(points: flatRing, isClosed: closed, fills: false, curveSteps: curveSteps))
        }
    }

    // MARK: - 溜める

    /// いま組んでいる環 (外周か穴) の最後の点。**空の穴は外周の点へ倒れない** — 穴の最初の
    /// ``bezierVertex(_:_:_:_:_:_:)`` / ``quadraticVertex(_:_:_:_:)`` は、形の中で手前に点が
    /// 無いときと同じく何もしない ([#1449])。
    ///
    /// [#1449]: https://github.com/mokume-metal/mokume/issues/1449
    private var lastShapePoint: SIMD2<Float>? {
        (holePoints ?? shapePoints).last.map { SIMD2($0.position.x, $0.position.y) }
    }

    /// 通過点の曲線の並び (``curveGuides``) を切る。**`curveVertex` 以外で点を置く呼び出し
    /// (`vertex` / `bezierVertex` / `quadraticVertex`) と、穴の境目で呼ぶ** — 次の区間は、
    /// また 4 つ揃ってから引かれる。
    ///
    /// ``appendVertex(_:hasDepth:uv:isCurveStep:)`` には入れない。`curveVertex` 自身が置く
    /// 刻みの点もそこを通るので、曲線が 1 区間で止まる。
    private func breakCurveSequence() {
        curveGuides.removeAll(keepingCapacity: true)
    }

    /// 曲線が作った点を置く。奥行きは直前の点から引き継ぐ。
    private func appendShapePoint(_ point: SIMD2<Float>, isCurveStep: Bool) {
        let depth = (holePoints?.last ?? shapePoints.last)?.position.z ?? 0
        appendVertex(SIMD3(point.x, point.y, depth), hasDepth: false, isCurveStep: isCurveStep)
    }

    private func appendVertex(
        _ position: SIMD3<Float>, hasDepth: Bool, uv: SIMD2<Float>? = nil,
        isCurveStep: Bool = false
    ) {
        // 形の外でここまで来るのは `vertex` の 4 つの形だけである。曲線の刻みの点
        // (`appendShapePoint`) は、呼んだ関数が自分の入口で形の外を受けてから来る
        guard admitsShapeCall("vertex") else { return }
        // 数でない座標は形を壊すだけなので置かない ([ADR-0020] 決定 5)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            return warnBadVertexOnce()
        }
        if hasDepth { shapeHasDepth = true }
        let vertex = BuildingVertex(
            position: position, normal: currentNormal, uv: uv, fill: style.fill,
            isCurveStep: isCurveStep)
        if holePoints != nil {
            holePoints?.append(vertex)
        } else {
            shapePoints.append(vertex)
        }
    }

    /// 3 次の曲線の上の点。
    nonisolated static func cubicPoint(
        _ p0: SIMD2<Float>, _ c1: SIMD2<Float>, _ c2: SIMD2<Float>, _ p1: SIMD2<Float>, _ t: Float
    ) -> SIMD2<Float> {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// 通過点を結ぶ曲線の上の点。`tightness` が 0 のとき、4 点のうち中の 2 点を滑らかに繋ぐ。
    nonisolated static func catmullRomPoint(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
        _ t: Float, tightness: Float
    ) -> SIMD2<Float> {
        let s = (1 - tightness) / 2
        let t2 = t * t
        let t3 = t2 * t
        let m1 = (p2 - p0) * s
        let m2 = (p3 - p1) * s
        return p1 * (2 * t3 - 3 * t2 + 1)
            + m1 * (t3 - 2 * t2 + t)
            + p2 * (-2 * t3 + 3 * t2)
            + m2 * (t3 - t2)
    }

    /// 頂点の仲間を受け付けるか。受け付けないなら、そのわけを 1 度だけ言う。
    ///
    /// **区間の外 (``Canvas/canPlace``) を、形の外より先に見る** ([#1672])。区間の外で開こうと
    /// した形は ``beginShape(_:)`` が断っているので、続く頂点に「`beginShape()` の間で呼べ」と
    /// 言っても直す先を指さない。区間の中で開いた形に、区間を出てから頂点を足すのも断る —
    /// 描き場所では境目が来ないので、足した点が捨てられないまま溜まる。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    private func admitsShapeCall(_ name: String) -> Bool {
        guard canPlace else {
            warnOutsideFrame(.placing)
            return false
        }
        guard isBuildingShape else {
            warnVertexOutsideShapeOnce(name)
            return false
        }
        return true
    }

    /// `beginShape()` の外で頂点の仲間を呼んだことを、初回だけ知らせる。
    ///
    /// **文面は呼んだ関数の名前を名乗る** ([#1498])。入口は `vertex` の 4 つの形・
    /// ``bezierVertex(_:_:_:_:_:_:)``・``quadraticVertex(_:_:_:_:)``・``curveVertex(_:_:)``・
    /// ``beginContour()``・``endContour()``・``normal(_:_:_:)``・``index(_:)`` で、事情は 1 つ
    /// なので鍵を共有し、文面には名前だけを入れる (``warnBadSize(_:)`` と同じ形)。直す前は
    /// どの入口も `vertex():` を名乗り、書き手は呼んでいない `vertex()` を探しに行くことに
    /// なっていた。`endContour()` と `normal(_:_:_:)` は [#1520] で加わった。
    ///
    /// [#1498]: https://github.com/mokume-metal/mokume/issues/1498
    /// [#1520]: https://github.com/mokume-metal/mokume/issues/1520
    private func warnVertexOutsideShapeOnce(_ name: String) {
        warnOnce(
            .vertexOutsideShape,
            "\(name)(): call this between beginShape() and endShape(). This call does nothing")
    }

    /// 形の中で手前に点が無いまま曲線を続けようとしたことを、初回だけ知らせる ([#1485])。
    ///
    /// **形の外の注意 (``warnVertexOutsideShapeOnce(_:)``) とは言うことが違う。** 呼んだ場所は
    /// 既に `beginShape()` と `endShape()` の間なので、間で呼べと言っても直す先を指さない。
    /// 穴の最初もこちらに当たる (穴は外周の点から始めない・``lastShapePoint``)。
    ///
    /// [#1485]: https://github.com/mokume-metal/mokume/issues/1485
    private func warnCurveWithoutStartOnce(_ name: String) {
        warnOnce(
            .curveWithoutStart,
            "\(name)(): a curve continues from the last point placed, and there is no point yet "
                + "in this shape or beginContour() hole, so this call does nothing. Place a "
                + "vertex() first")
    }

    /// 形の始まりが無いまま ``endShape(_:)`` を呼んだことを、初回だけ知らせる ([#1520])。
    ///
    /// 形の外の注意 (``warnVertexOutsideShapeOnce(_:)``) の文面は、`endShape()` には直す先を
    /// 指さない。対の始まりが無いことを言う。
    ///
    /// [#1520]: https://github.com/mokume-metal/mokume/issues/1520
    private func warnShapeNotBegunOnce() {
        warnOnce(
            .shapeNotBegun,
            "endShape(): no shape was begun with beginShape(), so there is nothing to end. This "
                + "call does nothing")
    }

    /// 開いたまま境目を越えた形を捨てたことを、初回だけ知らせる ([#1591])。
    ///
    /// **名乗るのは `beginShape()`** — 境目で呼ばれる関数は利用者が書いたものではなく、
    /// 直す先は開いた側 (対の終わりを、開いたのと同じ `draw()`・`setup()`・`createShape()` の
    /// 本体に置く) だからである。フレームの頭で捨てる形 (`setup()` で開いた) と終わりで捨てる
    /// 形 (`draw()` で開いた) の両方に当たるよう、どちらの境目かは言わない。形の外の注意
    /// (``warnVertexOutsideShapeOnce(_:)``) とは言うことが違うので鍵を分ける。捨てた後の
    /// フレームで閉じ忘れた形へ `vertex()` を足し続けると、あちらも言う。
    ///
    /// [#1591]: https://github.com/mokume-metal/mokume/issues/1591
    private func warnShapeNotEndedOnce() {
        warnOnce(
            .shapeNotEnded,
            "beginShape(): a shape was left open past the end of the draw(), setup() or "
                + "createShape() body that began it, so it was dropped without being drawn. End "
                + "each shape with endShape() in the same body")
    }

    /// 形を閉じないまま ``beginShape(_:)`` をもう一度呼び、前の形を捨てたことを、初回だけ
    /// 知らせる ([#1608])。
    ///
    /// 境目の注意 (``warnShapeNotEndedOnce()``) の文面は、開いた本体の終わりを越えたと
    /// 名乗る。重ね呼びは本体の終わりを越えていないので鍵を分け、直す先 (次の形を開く前に
    /// 閉じる) を言う。
    ///
    /// [#1608]: https://github.com/mokume-metal/mokume/issues/1608
    private func warnShapeBegunWhileOpenOnce() {
        warnOnce(
            .shapeBegunWhileOpen,
            "beginShape(): the previous shape was not ended with endShape() before beginShape() "
                + "was called again, so it was dropped without being drawn. End each shape with "
                + "endShape() before beginning the next")
    }

    /// 形の中で、穴を開かずに ``endContour()`` を呼んだことを、初回だけ知らせる ([#1528])。
    ///
    /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
    private func warnContourNotBegunOnce() {
        warnOnce(
            .contourNotBegun,
            "endContour(): no hole was begun with beginContour(), so there is nothing to end. "
                + "This call does nothing")
    }

    /// 形の中で、向きにならない値を ``normal(_:_:_:)`` に渡したことを、初回だけ知らせる
    /// ([#1528])。
    ///
    /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
    private func warnBadNormalOnce() {
        warnOnce(
            .badNormal,
            "normal(): got a direction that is not a number, or an infinite one, or one with no "
                + "length, so the vertices placed after this take their facing from the shape, "
                + "as if no normal() had been written")
    }

    private func warnBadVertexOnce() {
        warnOnce(
            .badVertex,
            "vertex(): got a coordinate that is not a number, or an infinite one, so that vertex "
                + "was not placed")
    }

    private func warnIndexOutOfRange() {
        warnOnce(
            .indexOutOfRange,
            "index(): got the number of a vertex that was never placed, so any face holding that "
                + "number was not drawn (numbers count from 0, and the points of a "
                + "beginContour() hole cannot be pointed at)")
    }
}
