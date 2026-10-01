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
    /// 座標そのものを骨へ渡せない。骨が決めるのは「どの添字を、帯・円板・正方形・折れ目の
    /// 形のどれにするか」だけで、点を形に変えるのは呼び出し側の閉包である。
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
    /// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
    ///
    /// - Parameters:
    ///   - count: 点の数
    ///   - isClosed: 周が閉じているか (閉じていれば最後の点から最初の点へも帯が要る)
    ///   - curveSteps: 点ごとに、折れ目の形によらず円板で埋めるか (曲線の刻みの点と扇の角)。
    ///     空ならどの点も角
    ///   - samePlace: 添字 2 つの点が同じ位置か。折れ目と端の向きを取る隣は、同じ位置の点を
    ///     飛ばして探す (長さ 0 の帯は向きを持たない)
    ///   - endSquare: 1 つ目の添字の点に、2 つ目の添字の点から離れる向き (線の向き) に
    ///     沿った正方形を置く (出っ張らせる端 — #1535)
    ///   - band: 添字 2 つを結ぶ帯を置く
    ///   - disc: 添字の点に円板を置く (丸い端点と丸い角・曲線の刻みの継ぎ目)
    ///   - square: 添字の点に正方形を置く (向きの無い点の四角い端点)
    ///   - corner: 1 つ目の添字の点に、2 つ目の添字の点から来て 3 つ目の添字の点へ出る
    ///     折れ目の形を置く (丸めない角・``joinRim(toward:_:half:join:)``)。矩形の削いだ角は、
    ///     平面の呼び出し側がここで削いだ形に差し替える (`strokeOutline`)
    func strokeRing(
        count: Int, isClosed: Bool, curveSteps: [Bool] = [],
        samePlace: (Int, Int) -> Bool = { _, _ in false },
        endSquare: (Int, Int) -> Void,
        band: (Int, Int) -> Void, disc: (Int) -> Void, square: (Int) -> Void,
        corner: (Int, Int, Int) -> Void
    ) {
        /// `index` から `step` (±1) の向きへたどって、`index` と同じ位置でない最初の点。
        /// 開いた周で端を越えるか、1 周しても見つからなければ `nil`。
        func distinct(from index: Int, step: Int) -> Int? {
            var probe = index
            for _ in 1..<max(count, 2) {
                probe += step
                if isClosed {
                    probe = (probe + count) % count
                } else if probe < 0 || probe >= count {
                    return nil
                }
                if !samePlace(probe, index) { return probe }
            }
            return nil
        }
        func join(at index: Int) {
            if index < curveSteps.count, curveSteps[index] { return disc(index) }
            // **向きは、同じ位置の点を飛ばした両隣から取る** ([#1644])。曲線で閉じる周の
            // 最後の点のように、隣が同じ位置だと帯の向きが決まらない。飛ばさないと、
            // 折れ目の形が軸に沿った正方形へ倒れて帯の外へ出る
            guard let previous = distinct(from: index, step: -1),
                let next = distinct(from: index, step: 1)
            else {
                // 開いた周の端と同じ位置の点は、端の形が埋める。閉じた周で全部の点が
                // 重なるときだけ、これまでどおり隣の点で置く
                guard isClosed else { return }
                return strokeJoinShape(
                    at: index, from: (index + count - 1) % count, to: (index + 1) % count,
                    disc: disc, corner: corner)
            }
            strokeJoinShape(at: index, from: previous, to: next, disc: disc, corner: corner)
        }
        func cap(at index: Int, awayFrom neighbor: Int?) {
            // 端の向きも、同じ位置の点を飛ばした隣から取る (出っ張らせる端の正方形・#1535)。
            // 全部の点が重なるときは、これまでどおり隣の点を渡す
            let away = neighbor.map { distinct(from: index, step: $0 > index ? 1 : -1) ?? $0 }
            strokeCapShape(
                at: index, awayFrom: away, disc: disc, square: square, endSquare: endSquare)
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
    ///   - square: 添字の点に画面の軸に沿った正方形を置く (向きの無い点の四角い端点と、
    ///     辺が 3 本以上集まる丸めない角)
    ///   - corner: 1 つ目の添字の点に、2 つ目と 3 つ目の添字の点へ向かう 2 本の辺が出会う
    ///     折れ目の形を置く (辺が 2 本だけ集まる丸めない角)
    func strokeNet(
        count: Int, edges: [(Int, Int)],
        endSquare: (Int, Int) -> Void,
        band: (Int, Int) -> Void, disc: (Int) -> Void, square: (Int) -> Void,
        corner: (Int, Int, Int) -> Void
    ) {
        var degrees = [Int](repeating: 0, count: count)
        // 点ごとの、辺の向こうの点 (最初の 2 本)。端はその 1 本、折れ目は 2 本の帯の向きを決める
        var neighbors = [Int](repeating: 0, count: count)
        var others = [Int](repeating: 0, count: count)
        for (a, b) in edges {
            band(a, b)
            if degrees[a] == 0 { neighbors[a] = b } else if degrees[a] == 1 { others[a] = b }
            if degrees[b] == 0 { neighbors[b] = a } else if degrees[b] == 1 { others[b] = a }
            degrees[a] += 1
            degrees[b] += 1
        }
        for (index, degree) in degrees.enumerated() {
            switch degree {
            case 0: continue  // どの稜線にも属さない点 (面の中の継ぎ目) は線を持たない
            case 1:
                strokeCapShape(
                    at: index, awayFrom: neighbors[index], disc: disc, square: square,
                    endSquare: endSquare)
            case 2:
                strokeJoinShape(
                    at: index, from: neighbors[index], to: others[index], disc: disc, corner: corner)
            default:
                // 3 本以上の辺が集まる点 (箱の角など) は、2 本の帯で形が決まらない。
                // 画面の軸に沿った正方形のまま埋める (#1644 の範囲の外。形は #1889 で決める)
                if style.strokeJoin == .round { disc(index) } else { square(index) }
            }
        }
    }

    /// 折れ目を埋める。
    ///
    /// 帯は線分ごとに独立して置くので、曲がったところに楔形の隙間が空く。そこを
    /// 埋める形が角の形である。丸める角は円板で、丸めない角 (`miter` / `bevel`) は
    /// **そこで出会う 2 本の帯の向きと太さだけで決まる形** (``joinRim(toward:_:half:join:)``)
    /// で埋める ([#1644])。形自身の座標軸にも画面の軸にも依らないので、回して描いても
    /// 形が変わらず、一直線に並べた点では何も置かない。かつては軸に沿った正方形で埋めて
    /// いて、斜めに一直線に並べた点で角が帯の外へ出ていた。
    ///
    /// 矩形の直角の角は、`bevel` なら呼び出し側 (`strokeOutline`) が同じ形の削いだ角に
    /// 差し替える (#1506)。重なる所は平面の呼び出し側が引いて積む (`strokeOutline`・#1536)
    /// ので、半透明の線でも角だけ濃くはならない。
    ///
    /// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
    private func strokeJoinShape(
        at index: Int, from previous: Int, to next: Int, disc: (Int) -> Void,
        corner: (Int, Int, Int) -> Void
    ) {
        switch style.strokeJoin {
        case .round:
            disc(index)
        case .bevel, .miter:
            corner(index, previous, next)
        }
    }

    /// 丸めない折れ目の形の周。**角からのずれ**を、角のすぐ内側の点・1 本目の帯の外側の縁の
    /// 角・(尖りか 2 つの切り口)・2 本目の帯の外側の縁の角の順に並べる ([#1644])。凸多角形で、
    /// 角は周の内にある。
    ///
    /// 形は、2 本の帯の外側の縁を延ばして交わる点 (尖り) までの凧形を、角から
    /// k × 太さの半分の所で**二等分線に垂直に切った**ものである。`bevel` は k = 1、
    /// `miter` は k = √2 で、どちらも鋭い角で伸びすぎない。k = √2 は直角の尖りの長さで、
    /// 直角の `miter` は切られずに尖り、矩形の尖った角と一致する。`bevel` は矩形の削いだ角
    /// (#1506・`kFormJoinBevel`) と同じ削ぎ方を、任意の角度へ延ばしたものである。
    ///
    /// - 尖りが切る線より角の側にあるときは、切らずに尖りを置く (周は 3 点)。尖りは
    ///   `(外 1 + 外 2) × half / (1 + cos)` で求める。`miter` なら曲がる角が 90° 以下で
    ///   そうなる。直角では cos がちょうど 0 なので、軸に沿った矩形の角は、以前の正方形の
    ///   角と同じ値になる
    /// - そうでなければ、2 本の外側の縁を切る線に届く所まで延ばした 2 点を置く (周は 4 点)
    /// - 一直線 (2 つの向きが真反対) なら隙間は無いので、空を返す
    /// - **同じ向きへ折り返す角 (180°・`vertex(A); vertex(B); vertex(A)`) は、帯の先に
    ///   k × 太さの半分だけ延ばした長方形になる。** 尖りは無限に遠いので、両方の外側の縁
    ///   (帯の両側) を切る線まで延ばした形で、折り返しに近づく角の形の極限と一致する
    ///   (どちら回りに近づいても同じ)。出っ張りを出さない形を選ぶと、179° と 180° で形が
    ///   飛ぶ。向きの丸め方で出っ張りが出たり消えたりしないよう、cos は −1…1 に締める
    ///   (ADR-0039 決定 1・回しても形が変わらない)
    ///
    /// 外側の縁の角 (周の 2 つ目と最後) は、帯の縁の角と同じ値になる。帯と同じく
    /// `(-向き.y, 向き.x) × half` の形で求めるので、平面では帯の角と 1 ビットも違わない。
    ///
    /// - Parameters:
    ///   - first: 角から 1 本目の帯の向こうの点へ向かう、長さ 1 の向き
    ///   - second: 角から 2 本目の帯の向こうの点へ向かう、長さ 1 の向き
    ///   - half: 太さの半分
    nonisolated static func joinRim(
        toward first: SIMD2<Float>, _ second: SIMD2<Float>, half: Float, join: StrokeJoin
    ) -> [SIMD2<Float>] {
        let inward = first + second
        guard inward != .zero else { return [] }
        // 外側の縁の法線は、二等分線の外向き (−inward) の側を向く。同じ向きへ折り返す
        // (法線が inward と直交する) ときは、1 本目が左・2 本目が右へ分かれる
        var outer1 = SIMD2(-first.y, first.x)
        if dot(outer1, inward) > 0 { outer1 = -outer1 }
        var outer2 = SIMD2(second.y, -second.x)
        if dot(outer2, inward) > 0 { outer2 = -outer2 }
        // 長さ 1 の向きどうしでも、丸めで 1 を僅かに越えうる。越えたまま使うと、同じ向きへ
        // 折り返す角 (cos = −1) で平方根が数でなくなる
        let cosine = min(max(dot(outer1, outer2), -1), 1)
        let edge1 = outer1 * half
        let edge2 = outer2 * half
        // 切る線は角から k × half。尖りまでの距離は half × √(2 / (1 + cos)) なので、尖りが
        // 切る線より手前なのは cos ≥ 2 / k² − 1 のとき (`miter` で 0・`bevel` で 1)
        let reach: Float = join == .bevel ? 1 : Float(2).squareRoot()
        let sharpest: Float = join == .bevel ? 1 : 0
        // 角のすぐ内側の点。角そのものを周に入れると、角の点は帯の端と折れ目の形の境に
        // しか乗らず、角がちょうど画素の中心に来たとき、どの三角形にも入らないことがある
        // (帯の端の辺の途中に乗る T 字の継ぎ目になる)。内へ half / 64 だけ引いた点を
        // 周に入れれば角は形の内に入る。引いた所は両側の帯の重なりの中なので、塗る所は変わらない
        let inner = inward * (half / 64 / (inward.x * inward.x + inward.y * inward.y).squareRoot())
        if cosine >= sharpest {
            let tip = (outer1 + outer2) * (half / (1 + cosine))
            return [inner, edge1, tip, edge2]
        }
        let halfCosine = ((1 + cosine) / 2).squareRoot()
        let halfSine = ((1 - cosine) / 2).squareRoot()
        let extent = half * (reach - halfCosine) / halfSine
        return [inner, edge1, edge1 - first * extent, edge2 - second * extent, edge2]
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

// 平面の輪郭。骨に差し込むのは「点 → 帯の 4 隅」「点 → 円板の周」「点 → 正方形の 4 隅」
// 「角と両隣 → 折れ目の形の周」だけで、太さは形自身の座標のまま足して、変換は置くときに
// 1 度だけ掛ける。
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
    /// **保持する形の記録の間は、重ねて積んだ線に、引く素材 (``CarvedStroke``) を添える**
    /// ([#1829]・[#1920]・``StrokeRange``)。保持した形は置くときに半透明の色を掛けられ、
    /// そのとき重ねて積んだ片は角と継ぎ目で濃くなるからである。**引くのは、半透明の色を
    /// 掛けて置くとき最初の 1 度だけ** — 記録のときは素材を組んだところで止める。掛けない形は、
    /// 今までどおり重ねて積んだ頂点を置き、引く費用を払わない。
    ///
    /// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
    /// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
    /// [#1829]: https://github.com/mokume-metal/mokume/issues/1829
    /// [#1920]: https://github.com/mokume-metal/mokume/issues/1920
    func strokeOutline(_ outline: Outline) {
        let half = style.strokeWeight / 2
        let points = outline.points
        let chamfers = style.strokeJoin == .bevel ? outline.cornerDiagonals : []
        let start = vertices.count
        let overlaps = strokeOverlapsShow
        if overlaps {
            strokeCarved(outline, half: half, chamfers: chamfers)
        } else {
            strokeRing(
                count: points.count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
                samePlace: { points[$0] == points[$1] },
                endSquare: { appendSquare(at: points[$0], awayFrom: points[$1], half: half) },
                band: { appendBand(points[$0], points[$1], half: half) },
                disc: { appendDisc(at: points[$0], half: half) },
                square: { appendSquare(at: points[$0], half: half) },
                corner: { index, previous, next in
                    guard index < chamfers.count else {
                        return appendJoin(
                            at: points[index], from: points[previous], to: points[next], half: half)
                    }
                    appendChamferedCorner(at: points[index], outward: chamfers[index], half: half)
                })
        }
        // 記録の間は寄せられないので、積んだ区間を覚える (`recordedStrokeRanges`)
        if recordingShape, vertices.count > start {
            // 引かずに積んだ線のうち、`replace` は下地を読まないので、重ねても半透明のまま
            // 同じ色になる。残りの `blend` / `lightest` / `darkest` は、半透明の色を掛けて
            // 置かれると 2 回目で寄っていくので、引く素材を持っておく。点 1 つの輪郭は
            // 端の形が 1 枚だけで、重なる相手が無いので持たない
            let carved: CarvedStroke? =
                !overlaps && style.blendMode != .replace && points.count > 1
                ? carveLater(outline, half: half, chamfers: chamfers) : nil
            recordedStrokeRanges.append(StrokeRange(start..<vertices.count, carved: carved))
        }
    }

    /// 引く素材だけを組んで持つ。**引くのは、半透明の色を掛けて置くとき最初の 1 度**
    /// (``CarvedStroke/vertices``)。
    private func carveLater(
        _ outline: Outline, half: Float, chamfers: [SIMD2<Float>]
    ) -> CarvedStroke {
        let (carving, offset) = makeCarving(outline, half: half, chamfers: chamfers)
        return CarvedStroke(
            recipe: CarveRecipe(
                carving: carving, offset: offset, transform: transform, color: style.stroke,
                uv: whiteUV))
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
    /// 保持する形の記録は、**積み方を記録したときの色で決める**。記録の間も引いて積むと、
    /// 不透明のまま置く (いちばんよくある) 形の縁が動く。置くときに半透明の色を掛ける
    /// (``Placement/fill``) 形のために、不透明の線は引く素材も持ち、置くときに引く
    /// (``StrokeRange``・``strokeOutline(_:)``・#1829)。
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
        let (carving, offset) = makeCarving(outline, half: half, chamfers: chamfers)
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

    /// 片を集める。引くのは ``StrokeCarving/carved(_:)`` が行い、集めた値は Canvas の状態を
    /// 読まないので、直ちに引いても (``strokeCarved(_:half:chamfers:)``) 後で引いても
    /// (``CarveRecipe``) 結果は同じである。
    private func makeCarving(
        _ outline: Outline, half: Float, chamfers: [SIMD2<Float>]
    ) -> (carving: StrokeCarving, offset: SIMD2<Float>) {
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
        let join = style.strokeJoin
        strokeRing(
            count: points.count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
            samePlace: { points[$0] == points[$1] },
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
                carving.addPoint(index) { Self.appendSquare(at: points[index], half: half, to: &$0) }
            },
            corner: { index, previous, next in
                carving.addPoint(index) { polygon in
                    guard index < chamfers.count else {
                        return Self.appendJoin(
                            at: points[index], from: points[previous], to: points[next],
                            half: half, join: join, to: &polygon)
                    }
                    Self.appendChamferedCorner(
                        at: points[index], outward: chamfers[index], half: half, to: &polygon)
                }
            })
        return (carving, offset)
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

    /// 折れ目の形の周 (``joinRim(toward:_:half:join:)``)。一直線なら何も積まない。帯の向きが
    /// 決まらない (隣が同じ位置) ときは、軸に沿った正方形へ倒す。
    private static func appendJoin(
        at corner: SIMD2<Float>, from previous: SIMD2<Float>, to next: SIMD2<Float>,
        half: Float, join: StrokeJoin, to polygon: inout [SIMD2<Float>]
    ) {
        guard let rim = joinOffsets(at: corner, from: previous, to: next, half: half, join: join)
        else { return appendSquare(at: corner, half: half, to: &polygon) }
        for offset in rim { polygon.append(corner + offset) }
    }

    /// 角から両隣への向きを求めて、折れ目の形の周のずれを返す。向きが決まらなければ `nil`。
    ///
    /// 向きは帯 (`appendBand`) と同じく、差を長さで割って求める。帯の法線は
    /// `(-差.y / 長さ × half, 差.x / 長さ × half)` で、ここから出る外側の縁の角は、その
    /// 符号を変えたものか、そのものになる。
    fileprivate static func joinOffsets(
        at corner: SIMD2<Float>, from previous: SIMD2<Float>, to next: SIMD2<Float>,
        half: Float, join: StrokeJoin
    ) -> [SIMD2<Float>]? {
        let back = previous - corner
        let ahead = next - corner
        let backLength = (back.x * back.x + back.y * back.y).squareRoot()
        let aheadLength = (ahead.x * ahead.x + ahead.y * ahead.y).squareRoot()
        guard backLength > 0, aheadLength > 0, backLength.isFinite, aheadLength.isFinite else {
            return nil
        }
        return joinRim(
            toward: SIMD2(back.x / backLength, back.y / backLength),
            SIMD2(ahead.x / aheadLength, ahead.y / aheadLength), half: half, join: join)
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
    /// 揃う。向きの無い点の四角い端は、形の座標の軸に沿った `appendSquare(at:half:)` の
    /// ままである。丸めない折れ目は、2 本の帯の向きから決まる `appendJoin` で埋める (#1644)。
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

    /// 丸めない折れ目の形を置く (``joinRim(toward:_:half:join:)``・#1644)。周の最初の点
    /// (角のすぐ内側) を要にした扇に割る。一直線なら何も置かない。帯の向きが決まらない (隣が同じ位置) ときは、
    /// 軸に沿った正方形へ倒す。
    private func appendJoin(
        at corner: SIMD2<Float>, from previous: SIMD2<Float>, to next: SIMD2<Float>, half: Float
    ) {
        guard
            let rim = Self.joinOffsets(
                at: corner, from: previous, to: next, half: half, join: style.strokeJoin)
        else { return appendSquare(at: corner, half: half) }
        guard rim.count >= 3 else { return }
        let hub = strokePoint(x: corner.x + rim[0].x, y: corner.y + rim[0].y)
        var previousPoint = strokePoint(x: corner.x + rim[1].x, y: corner.y + rim[1].y)
        for offset in rim.dropFirst(2) {
            let current = strokePoint(x: corner.x + offset.x, y: corner.y + offset.y)
            appendTriangle(hub, previousPoint, current, color: style.stroke)
            previousPoint = current
        }
    }

    /// 正方形を置く (向きの無い点の四角い端点)。
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
