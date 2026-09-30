// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 周を太さのある帯でなぞる。**骨は 1 本で、平面と立体が共有する** — 違うのは点を
// 帯や円板に変えるところだけである。骨が持つのは端と折れ目の規則、すなわち
// 「どこに帯を置き、どこを角として埋め、どこを端として仕上げるか」だけ。
//
// 骨が 2 本あったころは、`strokeCap` / `strokeJoin` の扱いを平面だけ直しても
// `vertex(x, y, z)` を並べた形には届かなかった。**利用者からは同じ設定に見えるのに
// 絵だけが食い違う**うえ、台帳もその食い違いを写さない (立体の輪郭を通るシーンが
// 端も折れ目も既定のままだったため。覆いを足したのが [#890]、畳んだのが [#891])。
//
// [#890]: https://github.com/mokume-metal/mokume/issues/890
// [#891]: https://github.com/mokume-metal/mokume/issues/891
extension Canvas {

    /// 点の並びを輪郭としてなぞる骨。
    ///
    /// **点は添字で受け取る。** 立体は世界の座標と形自身の座標を対で連れ回すので、
    /// 座標そのものを骨へ渡せない。骨が決めるのは「どの添字を、帯・円板・正方形の
    /// どれにするか」だけで、点を形に変えるのは呼び出し側の 3 つの閉包である。
    ///
    /// **曲線の刻みの継ぎ目は角ではない** ([#1409])。折れ目の形 (`strokeJoin`) を置かず、
    /// 形によらず円板で埋める。円板は両側の帯の縁に接するので、どれだけ急に曲がっても
    /// 隙間を残さず、帯の外へも出ない — 線は刻みの折れ線から太さの半分の内側を
    /// ちょうど塗る。角の形のほうの正方形は軸に沿っているので、斜めに走る曲線の継ぎ目に
    /// 置くと角が帯の外へ最大 (√2 − 1) × 太さ / 2 出て、縁が鋸の歯のように太っていた。
    /// 円板は正方形より三角形が多い (`strokeJoin(.round)` が払うのと同じ量) が、隣の刻みの
    /// 向きを要さないので、骨は点ごとの判断のまま保てる。
    ///
    /// 円板は両側の帯と重なり、刻みが太さの半分より細かければ 2 つ先の帯にも届く。骨は形を
    /// 重ねたまま渡し、平面の呼び出し側が、線に沿って太さ以内の先に置いた片との重なりを
    /// 引いて積む (`strokeOutline`・[#1536])。
    ///
    /// 利用者が置いた点 (`vertex`・曲線の終点・通過点) は刻みではなく、折れ目の形に従う。
    /// 扇の 3 つの角 (中心と弧の両端) は置いた点ではないので、刻みと同じく円板で埋める
    /// ([#1486] — 距離関数の経路が真の距離で丸く出すのに揃える)。
    ///
    /// [#1409]: https://github.com/mokume-metal/mokume/issues/1409
    /// [#1486]: https://github.com/mokume-metal/mokume/issues/1486
    /// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
    ///
    /// - Parameters:
    ///   - count: 点の数
    ///   - isClosed: 周が閉じているか (閉じていれば最後の点から最初の点へも帯が要る)
    ///   - curveSteps: 点ごとに、折れ目の形によらず円板で埋めるか (曲線の刻みの点と扇の角)。
    ///     空ならどの点も角
    ///   - endSquare: 1 つ目の添字の点に、2 つ目の添字の点から離れる向き (線の向き) に
    ///     沿った正方形を置く (出っ張らせる端 — #1535)
    ///   - band: 添字 2 つを結ぶ帯を置く
    ///   - disc: 添字の点に円板を置く (丸い端点と丸い角・曲線の刻みの継ぎ目)
    ///   - square: 添字の点に正方形を置く (四角い端点と、丸めない角)。矩形の削いだ角は、
    ///     平面の呼び出し側がここで削いだ形に差し替える (`strokeOutline`)
    func strokeRing(
        count: Int, isClosed: Bool, curveSteps: [Bool] = [],
        endSquare: (Int, Int) -> Void,
        band: (Int, Int) -> Void, disc: (Int) -> Void, square: (Int) -> Void
    ) {
        func join(at index: Int) {
            if index < curveSteps.count, curveSteps[index] { return disc(index) }
            strokeJoinShape(at: index, disc: disc, square: square)
        }
        func cap(at index: Int, awayFrom neighbor: Int?) {
            strokeCapShape(
                at: index, awayFrom: neighbor, disc: disc, square: square, endSquare: endSquare)
        }

        // 点が 1 つだけなら、端点の形そのものを置く
        if count == 1 {
            cap(at: 0, awayFrom: nil)
            return
        }
        guard count >= 2 else { return }

        let segmentCount = isClosed ? count : count - 1
        for index in 0..<segmentCount {
            band(index, (index + 1) % count)
        }

        if isClosed {
            for index in 0..<count {
                join(at: index)
            }
        } else {
            for index in 1..<(count - 1) {
                join(at: index)
            }
            cap(at: 0, awayFrom: 1)
            cap(at: count - 1, awayFrom: count - 2)
        }
    }

    /// 辺の網を輪郭としてなぞる骨。立体の稜線がこれを通る。
    ///
    /// 周と同じ規則を網へ広げただけである — **点に 2 本以上の辺が来ればそこは折れ目、
    /// 1 本しか来なければ端**。周は全ての点に 2 本が来る網 (閉じた周) か、両端だけ
    /// 1 本の網 (開いた周) にあたる。
    ///
    /// 辺ごとに端を 2 つずつ置かないのは、同じ点へ集まる辺の数だけ円板が重なるから
    /// である。球の極には一周ぶんの経線が集まるが、置く円板は 1 枚で済む。
    ///
    /// - Parameters:
    ///   - count: 点の数
    ///   - edges: 点の添字の対。同じ辺が 2 度現れないこと
    ///   - endSquare: 1 つ目の添字の点に、2 つ目の添字の点から離れる向きに沿った正方形を置く
    ///   - band: 添字 2 つを結ぶ帯を置く
    ///   - disc: 添字の点に円板を置く
    ///   - square: 添字の点に軸に沿った正方形を置く
    func strokeNet(
        count: Int, edges: [(Int, Int)],
        endSquare: (Int, Int) -> Void,
        band: (Int, Int) -> Void, disc: (Int) -> Void, square: (Int) -> Void
    ) {
        var degrees = [Int](repeating: 0, count: count)
        // 端 (辺が 1 本だけ来る点) の、その辺の向こうの点
        var neighbors = [Int](repeating: 0, count: count)
        for (a, b) in edges {
            band(a, b)
            degrees[a] += 1
            degrees[b] += 1
            neighbors[a] = b
            neighbors[b] = a
        }
        for (index, degree) in degrees.enumerated() {
            switch degree {
            case 0: continue  // どの稜線にも属さない点 (面の中の継ぎ目) は線を持たない
            case 1:
                strokeCapShape(
                    at: index, awayFrom: neighbors[index], disc: disc, square: square,
                    endSquare: endSquare)
            default: strokeJoinShape(at: index, disc: disc, square: square)
            }
        }
    }

    /// 折れ目を埋める。
    ///
    /// 帯は線分ごとに独立して置くので、曲がったところに楔形の隙間が空く。そこを
    /// 埋める形が角の形である。**隙間を埋める向きだけを見て、内側か外側かを判定
    /// しない** — 埋める図形は内側では帯に重なるが、重なる所は平面の呼び出し側が引いて
    /// 積む (`strokeOutline`・#1536) ので、半透明の線でも角だけ濃くはならない。
    private func strokeJoinShape(at index: Int, disc: (Int) -> Void, square: (Int) -> Void) {
        switch style.strokeJoin {
        case .round:
            disc(index)
        case .bevel, .miter:
            // 任意多角形の折れ目は、どちらも正方形で埋める。尖らせる形は鋭角で極端に
            // 伸びるため、限界を持たない実装では正方形へ倒す (限界の設計は輪郭が育ってから)。
            // 矩形の直角の角だけは、`bevel` なら呼び出し側 (`strokeOutline`) がこの正方形を
            // 45° で削いだ形に差し替える (#1506)
            square(index)
        }
    }

    /// 端を仕上げる。
    ///
    /// **出っ張らせる端の正方形は、線の向きに沿って置く** ([#1535])。帯と合わせて、線を
    /// 太さの半分だけ延ばした長方形になる — 距離関数の経路 (`line`) と同じ形である。
    /// 軸に沿って置いていた頃は、斜めの線で端が菱形に張り出していた。
    /// 向きの無い点 (`neighbor` が `nil`) の四角い端は、軸に沿った正方形のまま。
    ///
    /// [#1535]: https://github.com/mokume-metal/mokume/issues/1535
    ///
    /// - Parameter neighbor: 端の隣の点の添字。孤立した点なら `nil`
    private func strokeCapShape(
        at index: Int, awayFrom neighbor: Int?, disc: (Int) -> Void, square: (Int) -> Void,
        endSquare: (Int, Int) -> Void
    ) {
        switch (style.strokeCap, neighbor) {
        case (.square, .some):
            return  // 線の長さちょうどで切る
        case (.round, _):
            disc(index)
        case (.project, .some(let neighbor)):
            endSquare(index, neighbor)
        case (.square, .none), (.project, .none):
            square(index)
        }
    }
}

// 平面の輪郭。骨に差し込むのは「点 → 帯の 4 隅」「点 → 円板の周」「点 → 正方形の 4 隅」の
// 3 つだけで、太さは形自身の座標のまま足して、変換は置くときに 1 度だけ掛ける。
extension Canvas {

    /// 周を太さのある帯でなぞる。
    ///
    /// **矩形の直角の角は、`bevel` なら削いだ角で埋める** (#1506)。距離関数の経路と同じ
    /// 線で削ぐので、`shader()` や `texture()` を足して三角形の経路へ落ちても角の形が
    /// 変わらない。閉じた周の `square` は折れ目からしか呼ばれないので、端の形には及ばない。
    ///
    /// **片どうしの重なりは引いて積む** ([#1536]・[#1562])。帯・折れ目の形・端の形・刻みの
    /// 円板は互いに重なるので、そのまま積むと半透明の線や下地を読む混ぜ方で、重なった所
    /// だけが 2〜3 回混ざって濃くなる。先に置いた片との差を積めば、形も塗る領域も変えずに
    /// 1 回だけ混ぜられる (``StrokeCarving``)。重ねても絵が変わらない線
    /// (``strokeOverlapsShow`` が偽) は、引かずにこれまでどおり積む。
    ///
    /// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
    /// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
    func strokeOutline(_ outline: Outline) {
        let half = style.strokeWeight / 2
        let points = outline.points
        let chamfers = style.strokeJoin == .bevel ? outline.cornerDiagonals : []
        let start = vertices.count
        if strokeOverlapsShow {
            strokeCarved(outline, half: half, chamfers: chamfers)
        } else {
            strokeRing(
                count: points.count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
                endSquare: { appendSquare(at: points[$0], awayFrom: points[$1], half: half) },
                band: { appendBand(points[$0], points[$1], half: half) },
                disc: { appendDisc(at: points[$0], half: half) },
                square: { index in
                    guard index < chamfers.count else {
                        return appendSquare(at: points[index], half: half)
                    }
                    appendChamferedCorner(at: points[index], outward: chamfers[index], half: half)
                })
        }
        // 記録の間は寄せられないので、積んだ区間を覚える (`recordedStrokeRanges`)
        if recordingShape, vertices.count > start {
            recordedStrokeRanges.append(start..<vertices.count)
        }
    }

    /// 線の片の重なりが絵に出るか。**出ないのは、重ねて混ぜても同じ色になる線だけ** —
    /// 組み込みの断片で、不透明の色を `blend` / `lightest` / `darkest` で置くか、`replace` で
    /// 置き換える線である。
    ///
    /// 次のときは、いまの色によらず出るものとして扱う:
    ///
    /// - `shader()` が効いている。断片が出す不透明度は分からない
    /// - 畳みの雛形を積んでいる。雛形は白で積み、色は置き場所ごとに掛かる
    ///
    /// **引いて積むと、不透明の絵も縁の画素が動きうる。** 切り口の頂点は単精度で求めるので、
    /// 縁から 1/1000 画素ほどの所に中心が乗る画素は、塗られるかが入れ替わりうる。重ねても
    /// 絵が変わらない線は引かないので、この揺れは引いた線にしか出ない。
    ///
    /// 保持する形の記録は、記録したときの色で決める。置くときに半透明の色を掛けた
    /// (``Placement/fill``) 不透明の線は、引かずに積んだままになる (#1829)。記録の間も
    /// 引くと、不透明のまま置く (いちばんよくある) 形の縁が動く。
    var strokeOverlapsShow: Bool {
        if buildingFlatTemplate || currentShader != nil { return true }
        switch style.blendMode {
        case .replace: return false
        // 不透明なら、明るいほう・暗いほうを採る混ぜ方も 2 回目で値が変わらない
        // (`mokume_composite` の `max(s, d)` / `min(s, d)`)。半透明なら 2 回目で寄っていく
        case .blend, .lightest, .darkest: return style.stroke.alpha < 1
        case .add, .subtract, .difference, .exclusion, .multiply, .screen: return true
        }
    }

    /// 片を集め、先に置いた片との重なりを引いて積む (``StrokeCarving``)。
    ///
    /// 片の形は重ねて積むとき (`appendBand` ほか) と同じ式で組む。残りは扇に割る (要の選び方は
    /// ``StrokeCarving/carved(_:)``)。
    ///
    /// 置き場所ぶんずらした周は、ずらす前の周で引いてから置き場所を足す (``Outline/unmoved``)。
    /// 畳んだ雛形と同じ座標で引くので、畳むかどうかで頂点の数が変わらない。
    private func strokeCarved(_ outline: Outline, half: Float, chamfers: [SIMD2<Float>]) {
        let (points, offset) = outline.unmoved ?? (outline.points, SIMD2<Float>(0, 0))
        var carving = StrokeCarving(
            points: points, isClosed: outline.isClosed, weight: half * 2,
            wholeOutline: outline.strokesAsOneRegion)
        if discOffsets?.half != half {
            discOffsets = (
                half, Self.arcOffsets(radiusX: half, radiusY: half, from: 0, sweep: 2 * .pi)
            )
        }
        let rim = discOffsets?.offsets ?? []
        strokeRing(
            count: points.count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
            endSquare: { index, neighbor in
                carving.addPoint(index) {
                    Self.appendSquare(at: points[index], awayFrom: points[neighbor], half: half, to: &$0)
                }
            },
            band: { a, b in
                carving.addBand(segment: a) { Self.appendBand(points[a], points[b], half: half, to: &$0) }
            },
            disc: { index in
                let center = points[index]
                carving.addPoint(index) { polygon in
                    for offset in rim { polygon.append(center + offset) }
                }
            },
            square: { index in
                carving.addPoint(index) { polygon in
                    guard index < chamfers.count else {
                        return Self.appendSquare(at: points[index], half: half, to: &polygon)
                    }
                    Self.appendChamferedCorner(
                        at: points[index], outward: chamfers[index], half: half, to: &polygon)
                }
            })
        func place(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let moved = point + offset
            return strokePoint(x: moved.x, y: moved.y)
        }
        carving.carved { polygon, range, hub in
            guard let hub else {
                let first = place(polygon[range.lowerBound])
                var previous = place(polygon[range.lowerBound + 1])
                for index in (range.lowerBound + 2)..<range.upperBound {
                    let current = place(polygon[index])
                    appendTriangle(first, previous, current, color: style.stroke)
                    previous = current
                }
                return
            }
            let center = place(hub)
            let first = place(polygon[range.lowerBound])
            var previous = first
            for index in (range.lowerBound + 1)..<range.upperBound {
                let current = place(polygon[index])
                appendTriangle(center, previous, current, color: style.stroke)
                previous = current
            }
            appendTriangle(center, previous, first, color: style.stroke)
        }
    }

    // 片の周 (形自身の座標) を積む。式は重ねて積むとき (`appendBand` ほか) と 1 つずつ同じで、
    // ずらしていない周なら、引かれなかった頂点は変換の後も 1 ビットも変わらない

    /// 帯の 4 隅。長さ 0 の線分は帯を持たない。
    private static func appendBand(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, half: Float, to polygon: inout [SIMD2<Float>]
    ) {
        let delta = b - a
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return }
        let normal = SIMD2(-delta.y / length * half, delta.x / length * half)
        polygon.append(SIMD2(a.x + normal.x, a.y + normal.y))
        polygon.append(SIMD2(b.x + normal.x, b.y + normal.y))
        polygon.append(SIMD2(b.x - normal.x, b.y - normal.y))
        polygon.append(SIMD2(a.x - normal.x, a.y - normal.y))
    }

    /// 線の向きに沿った正方形の 4 隅。向きが決まらなければ軸に沿った正方形。
    private static func appendSquare(
        at center: SIMD2<Float>, awayFrom from: SIMD2<Float>, half: Float,
        to polygon: inout [SIMD2<Float>]
    ) {
        let delta = center - from
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return appendSquare(at: center, half: half, to: &polygon) }
        let along = delta / length * half
        let across = SIMD2(-along.y, along.x)
        polygon.append(SIMD2(center.x - along.x - across.x, center.y - along.y - across.y))
        polygon.append(SIMD2(center.x + along.x - across.x, center.y + along.y - across.y))
        polygon.append(SIMD2(center.x + along.x + across.x, center.y + along.y + across.y))
        polygon.append(SIMD2(center.x - along.x + across.x, center.y - along.y + across.y))
    }

    /// 軸に沿った正方形の 4 隅。
    private static func appendSquare(
        at center: SIMD2<Float>, half: Float, to polygon: inout [SIMD2<Float>]
    ) {
        polygon.append(SIMD2(center.x - half, center.y - half))
        polygon.append(SIMD2(center.x + half, center.y - half))
        polygon.append(SIMD2(center.x + half, center.y + half))
        polygon.append(SIMD2(center.x - half, center.y + half))
    }

    /// 削いだ角の五角形 (角と、外側の 4 分の 1 の縁)。
    private static func appendChamferedCorner(
        at corner: SIMD2<Float>, outward: SIMD2<Float>, half: Float, to polygon: inout [SIMD2<Float>]
    ) {
        let cut = (Float(2).squareRoot() - 1) * half
        polygon.append(corner)
        polygon.append(SIMD2(corner.x + outward.x * half, corner.y + 0))
        polygon.append(SIMD2(corner.x + outward.x * half, corner.y + outward.y * cut))
        polygon.append(SIMD2(corner.x + outward.x * cut, corner.y + outward.y * half))
        polygon.append(SIMD2(corner.x + 0, corner.y + outward.y * half))
    }

    /// 輪郭の頂点を描画先へ写す。**画面で (+0.5, +0.5) 画素寄せる** ([ADR-0039] 決定 2)。
    ///
    /// 塗りの縁は整数の座標で画素の境目に乗り、線の中心は画素の中心に乗る約束で、
    /// 寄せるのは「線である」ことだけを理由にする。寄せは**最後の変換が決まる場所で
    /// 1 回だけ**行う — ここで決まらない 2 つは寄せない:
    ///
    /// - 畳む雛形を積んでいる間 (`buildingFlatTemplate`): 置き場所ごとに変換が違うので、
    ///   頂点関数が置いた後に寄せる (`shapeVertexMain`)
    /// - 保持する形を記録している間 (`recordingShape`): 置くときに行列を掛けた直後に寄せる
    ///   (`Canvas.place(_:of:at:)`)
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    private func strokePoint(x: Float, y: Float) -> SIMD2<Float> {
        let placed = transform.apply(x: x, y: y)
        return buildingFlatTemplate || recordingShape ? placed : placed + 0.5
    }

    /// 線分 1 本を帯にする。
    private func appendBand(_ a: SIMD2<Float>, _ b: SIMD2<Float>, half: Float) {
        let delta = b - a
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return }
        let normal = SIMD2(-delta.y / length * half, delta.x / length * half)
        let p1 = strokePoint(x: a.x + normal.x, y: a.y + normal.y)
        let p2 = strokePoint(x: b.x + normal.x, y: b.y + normal.y)
        let p3 = strokePoint(x: b.x - normal.x, y: b.y - normal.y)
        let p4 = strokePoint(x: a.x - normal.x, y: a.y - normal.y)
        appendTriangle(p1, p2, p3, color: style.stroke)
        appendTriangle(p1, p3, p4, color: style.stroke)
    }

    /// 線の向きに沿った正方形を置く (出っ張らせる端 — #1535)。
    ///
    /// **正方形は 2 通りある。** 線の端 (`strokeCap(.project)`) はこちらで、線の向きに沿って
    /// 置く — 帯と合わせて線を太さの半分だけ延ばした形になり、距離関数の経路の `line` と
    /// 揃う。向きの無い点の四角い端と、丸めない折れ目は、形の座標の軸に沿った
    /// `appendSquare(at:half:)` のままである。
    ///
    /// 向きは形自身の座標で `from` から `center` へ向かう向きで、帯の向きと同じ座標で
    /// 取るので、変換を掛けた後も帯と揃う。長さ 0 (隣が同じ位置) で向きが決まらない
    /// ときは、軸に沿った正方形へ倒す。
    private func appendSquare(
        at center: SIMD2<Float>, awayFrom from: SIMD2<Float>, half: Float
    ) {
        let delta = center - from
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return appendSquare(at: center, half: half) }
        let along = delta / length * half
        let across = SIMD2(-along.y, along.x)
        let a = strokePoint(x: center.x - along.x - across.x, y: center.y - along.y - across.y)
        let b = strokePoint(x: center.x + along.x - across.x, y: center.y + along.y - across.y)
        let c = strokePoint(x: center.x + along.x + across.x, y: center.y + along.y + across.y)
        let d = strokePoint(x: center.x - along.x + across.x, y: center.y - along.y + across.y)
        appendTriangle(a, b, c, color: style.stroke)
        appendTriangle(a, c, d, color: style.stroke)
    }

    /// 円板を置く (丸い端点と丸い角)。周は半径に応じて分ける。
    ///
    /// **周のずれは太さごとに 1 度だけ求める** (#1785)。曲線 (`curveVertex` / `bezierVertex`)
    /// の点はどれも円板で継ぐので、1 区間で分割数ぶん置かれる。1 本の線を描く間は太さが
    /// 変わらないので、直前の太さの 1 件を控えておけば、`acos` と三角関数と配列の確保を
    /// 円板ごとに払わずに済む。点は中心にずれを足すだけなので、値は変わらない
    /// (``arcOffsets(radiusX:radiusY:from:sweep:)``)。
    private func appendDisc(at center: SIMD2<Float>, half: Float) {
        if discOffsets?.half != half {
            discOffsets = (
                half, Self.arcOffsets(radiusX: half, radiusY: half, from: 0, sweep: 2 * .pi)
            )
        }
        guard let offsets = discOffsets?.offsets, let start = offsets.first else { return }
        let hub = strokePoint(x: center.x, y: center.y)
        let firstPoint = center + start
        var previous = strokePoint(x: firstPoint.x, y: firstPoint.y)
        for offset in offsets.dropFirst() {
            let point = center + offset
            let current = strokePoint(x: point.x, y: point.y)
            appendTriangle(hub, previous, current, color: style.stroke)
            previous = current
        }
        let first = strokePoint(x: firstPoint.x, y: firstPoint.y)
        appendTriangle(hub, previous, first, color: style.stroke)
    }

    /// 正方形を置く (四角い端点と、任意多角形の折れ目・矩形の尖らせた角)。
    private func appendSquare(at center: SIMD2<Float>, half: Float) {
        let a = strokePoint(x: center.x - half, y: center.y - half)
        let b = strokePoint(x: center.x + half, y: center.y - half)
        let c = strokePoint(x: center.x + half, y: center.y + half)
        let d = strokePoint(x: center.x - half, y: center.y + half)
        appendTriangle(a, b, c, color: style.stroke)
        appendTriangle(a, c, d, color: style.stroke)
    }

    /// 矩形の直角の角を、45° で削いで埋める (#1506)。
    ///
    /// 削ぐ線は角から太さの半分だけ離れた所を通り、`outward · (p − corner) = √2 · half`
    /// で表せる。距離関数の経路 (`Shapes.metal` の `kFormJoinBevel`) と同じ線である。
    ///
    /// **埋めるのは角の外側の 4 分の 1 だけ** — 角から外向きに `half` の正方形を、削ぐ線で
    /// 落とした五角形。残りは両側の帯が覆うので、帯と合わせた和は距離関数の経路の
    /// 八角形にちょうど一致する。正方形全体を削ぐと、辺が太さの (2 − √2) / 2 倍より短い
    /// 矩形で、内側の半分が向かいの角の削ぐ線の外へはみ出す。
    ///
    /// - Parameter outward: 角の外向きの対角 (各成分 ±1)
    private func appendChamferedCorner(
        at corner: SIMD2<Float>, outward: SIMD2<Float>, half: Float
    ) {
        let cut = (Float(2).squareRoot() - 1) * half
        let hub = strokePoint(x: corner.x, y: corner.y)
        let offsets = [
            SIMD2(outward.x * half, 0),
            SIMD2(outward.x * half, outward.y * cut),
            SIMD2(outward.x * cut, outward.y * half),
            SIMD2(0, outward.y * half),
        ]
        var rim: [SIMD2<Float>] = []
        rim.reserveCapacity(offsets.count)
        for offset in offsets { rim.append(strokePoint(x: corner.x + offset.x, y: corner.y + offset.y)) }
        for index in 0..<(rim.count - 1) {
            appendTriangle(hub, rim[index], rim[index + 1], color: style.stroke)
        }
    }
}
