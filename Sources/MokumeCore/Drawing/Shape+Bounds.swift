// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 保持した形の外接矩形 (#2426 の A)。
//
// 意味の説明は利用者が最初に触る層の ``Shape/bounds`` が正本で、ここは求め方である。
// **焼くときに 1 度だけ求めて持つ** (`createShape` の出口と `Shape.group`)。問うたびに
// 走査すると、円の多い形で問うたびに費用がかかる。
//
// 外接は**幾何**のもので、線の太さを含まない。焼いた頂点には輪郭の帯が混ざっていて、
// 頂点を全部見ると太さぶん広がるので、見るものを 3 つに分ける。
//
//   1. 塗りの頂点: ``Shape/vertices`` のうち輪郭の区間 (``Shape/strokeRanges``) の外
//   2. 輪郭: 区間が持つ周の点 (``ThinStrokeRecipe``) を、記録のときの変換で置いたもの。
//      周を持たない区間 (一部だけを置き直したもの) は帯の頂点で代える (太さを含みうる)
//   3. 基本図形: 置き場所 (``FormInstance``) の中心・半幅・2x2 から、描く幾何で求める
//
// 立体の頂点は見ない。

/// 平面の軸に沿った外接の箱。**線の太さを含まない**。
struct PlaneBox: Equatable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float

    init(_ point: SIMD2<Float>) {
        minX = point.x
        maxX = point.x
        minY = point.y
        maxY = point.y
    }

    /// 点を含める。数でない・無限の点は含めない (描かれないので)。
    mutating func add(_ point: SIMD2<Float>) {
        guard point.x.isFinite, point.y.isFinite else { return }
        minX = min(minX, point.x)
        maxX = max(maxX, point.x)
        minY = min(minY, point.y)
        maxY = max(maxY, point.y)
    }

    /// 2 つの箱の和。どちらかが無ければ、ある側。
    static func union(_ a: PlaneBox?, _ b: PlaneBox?) -> PlaneBox? {
        guard var result = a else { return b }
        guard let b else { return result }
        result.add(SIMD2(b.minX, b.minY))
        result.add(SIMD2(b.maxX, b.maxY))
        return result
    }

    var rect: Rect { Rect(left: minX, top: minY, width: maxX - minX, height: maxY - minY) }
}

extension Optional where Wrapped == PlaneBox {
    /// 点を含める。数でない・無限の点は含めない (描かれないので)。まだ箱が無ければ、その点が最初の箱になる。
    mutating func include(_ point: SIMD2<Float>) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if self == nil { self = PlaneBox(point) } else { self?.add(point) }
    }
}

extension Shape {
    /// 焼いた並びから、平面の部分の幾何の外接を求める。
    static func measureBounds(
        vertices: [ShapeVertex], strokeRanges: [StrokeRange], forms: [FormInstance]
    ) -> PlaneBox? {
        var box: PlaneBox?

        // 1・2. 頂点。輪郭の区間は、周を持つなら周の点で、持たないなら帯の頂点で見る
        var covered: [Range<Int>] = []
        for stroke in strokeRanges where !stroke.range.isEmpty {
            if let thin = stroke.thin {
                for point in thin.outline.points { box.include(thin.transform.placed(x: point.x, y: point.y)) }
                covered.append(stroke.range)
            }
        }
        // 区間は記録の順に並ぶが、置き直しで入れ替わらない保証は無いので下限で並べる
        covered.sort { $0.lowerBound < $1.lowerBound }
        var next = 0
        var index = 0
        let count = vertices.count
        while index < count {
            while next < covered.count, covered[next].upperBound <= index { next += 1 }
            if next < covered.count, covered[next].lowerBound <= index {
                index = covered[next].upperBound
                continue
            }
            box.include(vertices[index].position)
            index += 1
        }

        // 3. 基本図形
        for form in forms { form.addGeometry(to: &box) }
        return box
    }
}

extension FormInstance {
    /// この図形が描く幾何の点を箱へ入れる。**線の太さは入れない。**
    ///
    /// 形自身の座標の点 `(u, v)` は、`offset.xy + linear.xy * u + linear.zw * v` へ移る
    /// (``linear`` は形自身の横軸・縦軸が移る先)。矩形は 4 つの角 (角を丸めても同じ箱)、線と
    /// 点は 2 つの端 (点は 2 つが重なる)、楕円は 2x2 を掛けた外接、扇は中心と弧の両端と、
    /// 弧の上で各軸が極値になる点である。
    func addGeometry(to box: inout PlaneBox?) {
        let origin = SIMD2(offset.x, offset.y)
        let columnU = SIMD2(linear.x, linear.y)
        let columnV = SIMD2(linear.z, linear.w)
        let halfU = size.x
        let halfV = size.y
        func place(_ u: Float, _ v: Float) -> SIMD2<Float> { origin + columnU * u + columnV * v }

        switch meta.x {
        case Kind.rect.rawValue:
            box.include(place(-halfU, -halfV))
            box.include(place(halfU, -halfV))
            box.include(place(halfU, halfV))
            box.include(place(-halfU, halfV))
        case Kind.line.rawValue:
            box.include(place(-halfU, 0))
            box.include(place(halfU, 0))
        case Kind.ellipse.rawValue:
            // 楕円の点 (halfU cos t, halfV sin t) の各軸の最大は、2 つの係数の 2 乗和の平方根
            let reach = SIMD2(
                (columnU.x * halfU * columnU.x * halfU + columnV.x * halfV * columnV.x * halfV).squareRoot(),
                (columnU.y * halfU * columnU.y * halfU + columnV.y * halfV * columnV.y * halfV).squareRoot())
            box.include(origin - reach)
            box.include(origin + reach)
        case Kind.arc.rawValue:
            box.include(origin)
            let start = offset.z
            let sweep = offset.w
            box.include(place(halfU * RuntimeMath.cos(start), halfV * RuntimeMath.sin(start)))
            box.include(place(halfU * RuntimeMath.cos(start + sweep), halfV * RuntimeMath.sin(start + sweep)))
            // 弧の上で各軸が極値になる媒介変数の角。軸ごとに `a cos t + b sin t` の極値は
            // `t = atan2(b, a)` とその反対側にある
            for axis in 0..<2 {
                let a = (axis == 0 ? columnU.x : columnU.y) * halfU
                let b = (axis == 0 ? columnV.x : columnV.y) * halfV
                guard a != 0 || b != 0 else { continue }
                let peak = RuntimeMath.atan2(b, a)
                for angle in [peak, peak + .pi] where Self.angle(angle, liesWithin: start, sweep: sweep) {
                    box.include(place(halfU * RuntimeMath.cos(angle), halfV * RuntimeMath.sin(angle)))
                }
            }
        default:
            break
        }
    }

    /// 角 `angle` が、`start` から `sweep` だけ進む弧の中にあるか (1 周を越える差は畳む)。
    private static func angle(_ angle: Float, liesWithin start: Float, sweep: Float) -> Bool {
        guard sweep < 2 * .pi else { return true }
        var delta = (angle - start).truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        return delta <= sweep
    }
}
