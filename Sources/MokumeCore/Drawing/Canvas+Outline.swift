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
    /// - Parameters:
    ///   - count: 点の数
    ///   - isClosed: 周が閉じているか (閉じていれば最後の点から最初の点へも帯が要る)
    ///   - band: 添字 2 つを結ぶ帯を置く
    ///   - disc: 添字の点に円板を置く (丸い端点と丸い角)
    ///   - square: 添字の点に正方形を置く (四角い端点と削いだ角)
    func strokeRing(
        count: Int, isClosed: Bool,
        band: (Int, Int) -> Void, disc: (Int) -> Void, square: (Int) -> Void
    ) {
        // 折れ目を埋める。
        //
        // 帯は線分ごとに独立して置くので、曲がったところに楔形の隙間が空く。そこを
        // 埋める形が角の形である。**隙間を埋める向きだけを見て、内側か外側かを判定
        // しない** — 埋める図形は内側でも帯に重なるだけで、絵は変わらない。
        func join(at index: Int) {
            switch currentStrokeJoin {
            case .round:
                disc(index)
            case .bevel, .miter:
                // 削ぐ形は正方形の一部で近似する。尖らせる形は鋭角で極端に伸びるため、
                // 限界を持たない実装では削ぐ形へ倒す (限界の設計は輪郭が育ってから)
                square(index)
            }
        }

        // 端を仕上げる。
        func cap(at index: Int, isolated: Bool) {
            switch currentStrokeCap {
            case .square where !isolated:
                return  // 線の長さちょうどで切る
            case .round:
                disc(index)
            case .square, .project:
                square(index)
            }
        }

        // 点が 1 つだけなら、端点の形そのものを置く
        if count == 1 {
            cap(at: 0, isolated: true)
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
            cap(at: 0, isolated: false)
            cap(at: count - 1, isolated: false)
        }
    }
}

// 平面の輪郭。骨に差し込むのは「点 → 帯の 4 隅」「点 → 円板の周」「点 → 正方形の 4 隅」の
// 3 つだけで、太さは形自身の座標のまま足して、変換は置くときに 1 度だけ掛ける。
extension Canvas {

    /// 周を太さのある帯でなぞる。
    func strokeOutline(_ outline: Outline) {
        let half = currentStrokeWeight / 2
        let points = outline.points
        strokeRing(
            count: points.count, isClosed: outline.isClosed,
            band: { appendBand(points[$0], points[$1], half: half) },
            disc: { appendDisc(at: points[$0], half: half) },
            square: { appendSquare(at: points[$0], half: half) })
    }

    /// 線分 1 本を帯にする。
    private func appendBand(_ a: SIMD2<Float>, _ b: SIMD2<Float>, half: Float) {
        let delta = b - a
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0 else { return }
        let normal = SIMD2(-delta.y / length * half, delta.x / length * half)
        let p1 = transform.apply(x: a.x + normal.x, y: a.y + normal.y)
        let p2 = transform.apply(x: b.x + normal.x, y: b.y + normal.y)
        let p3 = transform.apply(x: b.x - normal.x, y: b.y - normal.y)
        let p4 = transform.apply(x: a.x - normal.x, y: a.y - normal.y)
        appendTriangle(p1, p2, p3, color: currentStroke)
        appendTriangle(p1, p3, p4, color: currentStroke)
    }

    /// 円板を置く (丸い端点と丸い角)。周は半径に応じて分ける。
    private func appendDisc(at center: SIMD2<Float>, half: Float) {
        let points = Self.arcPoints(
            center: center, radiusX: half, radiusY: half, from: 0, sweep: 2 * .pi)
        let hub = transform.apply(x: center.x, y: center.y)
        var previous = transform.apply(x: points[0].x, y: points[0].y)
        for point in points.dropFirst() {
            let current = transform.apply(x: point.x, y: point.y)
            appendTriangle(hub, previous, current, color: currentStroke)
            previous = current
        }
        let first = transform.apply(x: points[0].x, y: points[0].y)
        appendTriangle(hub, previous, first, color: currentStroke)
    }

    /// 正方形を置く (四角い端点と削いだ角)。
    private func appendSquare(at center: SIMD2<Float>, half: Float) {
        let a = transform.apply(x: center.x - half, y: center.y - half)
        let b = transform.apply(x: center.x + half, y: center.y - half)
        let c = transform.apply(x: center.x + half, y: center.y + half)
        let d = transform.apply(x: center.x - half, y: center.y + half)
        appendTriangle(a, b, c, color: currentStroke)
        appendTriangle(a, c, d, color: currentStroke)
    }
}
