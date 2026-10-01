// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 立体の線の、**画面で重なる点**に置く形の決め方 ([#1903] の決定)。
//
// 丸めない折れ目 (`miter` / `bevel`) の形は、そこで出会う帯の画面での向きと太さだけで決まり、
// 画面の軸によらない ([#1644])。#1644 が範囲の外に置いた 2 つの点 — 辺が 3 本以上集まる点
// ([#1889]) と、辺が画面でちょうど潰れる点 ([#1893]) — も同じ規則に入れる。どちらも以前は
// 画面の軸に沿った正方形へ倒れていたので、場面を画面の中心の周りに回すと正方形だけが回らず、
// 帯に対する形が変わった。
//
// 決め方は 1 つで、CPU のその場の線 (`strokeNet` / `strokeSolidRing`)・保持した形の組み直し
// (``SolidStrokePiece``)・GPU の骨 (`Shapes.metal` の `solidStrokeCorner`) が同じ手順を踏む。
//
// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
// [#1889]: https://github.com/mokume-metal/mokume/issues/1889
// [#1893]: https://github.com/mokume-metal/mokume/issues/1893
// [#1903]: https://github.com/mokume-metal/mokume/issues/1903
extension Canvas {

    /// 画面で重なる点に置く形。
    nonisolated enum ScreenCorner: Equatable {
        /// 何も置かない (帯だけで隙間が無い・線の長さちょうどで切る端)。
        case nothing
        /// 円板 (丸い端・丸い角)。
        case disc
        /// 画面の軸に沿った正方形 (向きの無い点の四角い端)。
        case square
        /// 添字の腕の帯の向きに沿った正方形 (出っ張らせる端)。
        case endSquare(Int)
        /// 添字の 2 本の腕の折れ目の形 (``joinRim(toward:_:half:join:)``)。
        case rim(Int, Int)
    }

    /// 画面で重なる点に置く形を決める ([#1903] の決定)。
    ///
    /// 点は、画面で潰れた (長さがちょうど 0 の) 辺で結ばれた点の群である。群に集まる腕は、群の
    /// 外へ出る辺の画面での向き (長さ 1) で、潰れた辺は向きを持たないので数えない。
    ///
    /// **同じ向きの腕は 1 本と数える。ただし別の点から出た腕どうしに限る。** 1 つの点が自分の
    /// 2 本の腕を同じ向きへ折り返す角 (`vertex(A); vertex(B); vertex(A)`) は #1644 のまま、帯を
    /// 延ばした形になる。同じ向きかは**値が等しいか**で見る。許容差は置かない — 画面で潰れたかを
    /// 長さがちょうど 0 かで見ること (`screenNormal`)、同じ位置の点を飛ばすときに位置が等しいかで
    /// 見ること (`strokeSolidRing` の `samePlace`)、2D の三角形分割で折り返す角を外積がちょうど 0
    /// かで見ること (`Triangulation.dropFlatCorners`) に揃える。値で比べるので、外積の積和の縮約
    /// (GPU の fast-math) にも左右されない。
    ///
    /// 数えた向きの数で、置く形が決まる:
    ///
    /// | 向きの数 | 形 |
    /// | --- | --- |
    /// | 0 | 向きの無い点。線の端を含む群は端の形、そうでなければ正方形 (`round` は円板) |
    /// | 1 | その帯の端 (`strokeCap`: `.square` は何も置かない・`.project` は帯の向きの正方形・`.round` は円板) |
    /// | 2 | 2 本の折れ目 (#1644) |
    /// | 3 以上 | 角度の順で 180° を越える間を挟む 2 本の折れ目。越える間が無ければ何も置かない (#1889) |
    ///
    /// 180° を越える間は、多くても 1 つである。180° 以下の間は両側の帯が角のそばを覆うので、
    /// 何も置かなくても隙間は空かない。ちょうど 180° の間も覆われるので置かない。
    ///
    /// `round` の折れ目は、いまどおり円板である。向きの数が 0 か 1 で群が線の端を含むときだけ、
    /// 端の形に従う。
    ///
    /// **3 本以上のときの 2 本の選び方は、角度を求めずに外積の符号で決める** — GPU と CPU が同じ
    /// 2 本を選ぶため (三角関数は GPU と CPU で丸めが違う)。いちばん時計回りの腕を前から順に
    /// 探し、残りがすべてその腕から反時計回りに 180° 未満 (か同じ向き) に収まるかを確かめ、
    /// 収まればいちばん反時計回りの腕を同じく前から探す。同じ向きの腕が並ぶときは前の腕を取る。
    ///
    /// - Parameters:
    ///   - arms: 腕の画面での向き (長さ 1)。群の点の順、その中は辺の順に並べる
    ///   - origins: 腕ごとに、出た点の番号 (同じ点なら同じ値)
    ///   - isEnd: 群が線の端 (辺が 1 本だけ来る点) を含むか
    ///
    /// [#1903]: https://github.com/mokume-metal/mokume/issues/1903
    nonisolated static func screenCorner(
        arms: [SIMD2<Float>], origins: [Int], isEnd: Bool, join: StrokeJoin, cap: StrokeCap
    ) -> ScreenCorner {
        // 別の点から出た同じ向きの腕は 1 本と数える。前の腕を残す
        var kept: [Int] = []
        kept.reserveCapacity(arms.count)
        for index in arms.indices
        where !kept.contains(where: { origins[$0] != origins[index] && arms[$0] == arms[index] }) {
            kept.append(index)
        }
        func end(_ arm: Int?) -> ScreenCorner {
            switch (cap, arm) {
            case (.round, _): .disc
            case (.square, .some): .nothing
            case (.project, .some(let arm)): .endSquare(arm)
            case (.square, .none), (.project, .none): .square
            }
        }
        if join == .round {
            guard kept.count <= 1, isEnd else { return .disc }
            return end(kept.first)
        }
        switch kept.count {
        case 0:
            return isEnd ? end(nil) : .square
        case 1:
            return end(kept[0])
        case 2:
            return .rim(kept[0], kept[1])
        default:
            return widestGap(arms, kept).map { .rim($0.0, $0.1) } ?? .nothing
        }
    }

    /// 腕を角度の順に並べたとき、180° を越える間を挟む 2 本 (時計回りの端・反時計回りの端)。
    /// 越える間が無ければ `nil`。
    private nonisolated static func widestGap(
        _ arms: [SIMD2<Float>], _ kept: [Int]
    ) -> (Int, Int)? {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        var first = kept[0]
        for index in kept.dropFirst() where arms[index] != arms[first] && cross(arms[first], arms[index]) < 0 {
            first = index
        }
        // 残りがすべて、時計回りの端から反時計回りに 180° 未満 (か同じ向き) に収まるか。等しい
        // 向きは外積を見ずに通す — GPU は積和を縮約するので、等しい 2 本の外積が 0 にならない
        for index in kept where index != first && arms[index] != arms[first] {
            let turn = cross(arms[first], arms[index])
            guard turn > 0 || (turn == 0 && dot(arms[first], arms[index]) > 0) else { return nil }
        }
        var last = first
        for index in kept where arms[index] != arms[last] && cross(arms[last], arms[index]) > 0 {
            last = index
        }
        return (first, last)
    }

    /// 4 点 `a`・`b`・`c`・`d` が同じ平面に載り、`b`→`a` と `c`→`d` が同じ側へ向かうか。
    ///
    /// 辺 `b`–`c` が画面で潰れたとき、`b` から `a` へ・`c` から `d` へ出る 2 本の帯が画面で同じ
    /// 向きになりうるのは (別の点から出た同じ向きの腕として 1 本と数え、端の形を置く)、この 4 点が
    /// 同じ平面に載るときだけである — 潰れた辺に沿って見たとき 2 本の腕の向きが等しいなら、
    /// 2 本の腕と潰れた辺の張る体積は 0 になる。そこで、端の円板 (48 頂点) を置く容量は、この
    /// 判定が真の点にだけ割り当てる (保持した形の部品・GPU の骨)。
    ///
    /// 許容差は稜線の「同じ平面」(``SolidEdges/coplanarAngle``) を使う。画面で値が等しくなるほど
    /// 揃った腕は、この許容差より何桁も平らなので、容量を割り当て損なわない。
    nonisolated static func mayMeetAsOneBand(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>
    ) -> Bool {
        let (first, along, second) = (a - b, c - b, d - c)
        let scale = length(first) * length(along) * length(second)
        guard scale > 0, scale.isFinite, dot(first, second) > 0 else { return false }
        let volume = abs(dot(cross(first, along), second))
        return volume <= Float(sin(SolidEdges.coplanarAngle)) * scale
    }
}

/// 立体の稜線の網を、**点ごとに**組み直すための元 (保持した形の部品・#1889・#1893)。
///
/// 網の点の形は、画面で潰れた辺の先の点まで見ないと決まらない (潰れた辺の両端は画面で重なり、
/// 1 点として形を置く)。どの辺が潰れるかは置く先の視点で決まるので、記録の間は視点によらず
/// 点ごとに部品を 1 つ積み、置くときに決める (`Canvas.strokeSolidEdges`)。部品は網そのものを
/// 共有し、点の番号だけを持つ。
final class SolidStrokeNet {
    /// 稜線の点 (形自身の座標)。
    let points: [SIMD3<Float>]
    /// 点ごとの隣の点の並び (辺の順)。`neighbors[starts[i]..<starts[i + 1]]` が点 i の隣。
    let starts: [Int]
    let neighbors: [Int]

    init(points: [SIMD3<Float>], edges: [(Int, Int)]) {
        self.points = points
        var degrees = [Int](repeating: 0, count: points.count)
        for (a, b) in edges {
            degrees[a] += 1
            degrees[b] += 1
        }
        var starts = [Int](repeating: 0, count: points.count + 1)
        for index in points.indices { starts[index + 1] = starts[index] + degrees[index] }
        var cursor = Array(starts.dropLast())
        var neighbors = [Int](repeating: 0, count: starts[points.count])
        for (a, b) in edges {
            neighbors[cursor[a]] = b
            cursor[a] += 1
            neighbors[cursor[b]] = a
            cursor[b] += 1
        }
        self.starts = starts
        self.neighbors = neighbors
    }

    /// 点 `index` の隣の点の番号。
    func neighbors(of index: Int) -> ArraySlice<Int> { neighbors[starts[index]..<starts[index + 1]] }

    /// 点 `index` の辺の数。
    func degree(of index: Int) -> Int { starts[index + 1] - starts[index] }

    /// 点 `index` が、画面で潰れた辺の先の点と 1 本と数える帯を作りうるか
    /// (``Canvas/mayMeetAsOneBand(_:_:_:_:)``)。辺が 2 本の点どうしの組だけを見る。辺が 1 本の
    /// 点 (線の端) を含む組は端の形になりうるので、真を返す。
    func mayEndAsOneBand(_ index: Int) -> Bool {
        let own = neighbors(of: index)
        guard own.count <= 2 else { return false }
        for partner in own {
            let theirs = neighbors(of: partner)
            if own.count == 1 || theirs.count == 1 { return true }
            guard theirs.count == 2, let mine = own.first(where: { $0 != partner }),
                let other = theirs.first(where: { $0 != index })
            else { continue }
            if Canvas.mayMeetAsOneBand(points[mine], points[index], points[partner], points[other]) {
                return true
            }
        }
        return false
    }
}
