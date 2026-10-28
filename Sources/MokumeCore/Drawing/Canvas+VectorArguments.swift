// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// `Vector2` / `Vector3` をそのまま座標や移動量として渡す口 (#3360)。
//
// どれも成分を取り出して、数で受ける同じ名前の口へ渡すだけで、描き方・変換・フレームの外での扱いは
// 数の口と同じである (別の道を持たない)。数を渡す口があるものにだけ足す — 3 次元の `circle` は
// 数の口が無いので、ここにも無い。

extension Canvas {
    /// 円。座標の読み方は ``ellipseMode(_:)`` が決める。``circle(_:_:_:)`` に `center.x`・`center.y` を渡すのと同じ。
    public func circle(_ center: Vector2, _ diameter: some ScalarConvertible) {
        circle(center.x, center.y, diameter)
    }

    /// 点。``point(_:_:)`` に `point.x`・`point.y` を渡すのと同じ。
    public func point(_ point: Vector2) {
        self.point(point.x, point.y)
    }

    /// 立体の空間の点。``point(_:_:_:)`` に 3 つの成分を渡すのと同じ。
    public func point(_ point: Vector3) {
        self.point(point.x, point.y, point.z)
    }

    /// 線。``line(_:_:_:_:)`` に 2 つの点の成分を渡すのと同じ。
    public func line(_ a: Vector2, _ b: Vector2) {
        line(a.x, a.y, b.x, b.y)
    }

    /// 立体の空間の線。``line(_:_:_:_:_:_:)`` に 2 つの点の成分を渡すのと同じ。
    public func line(_ a: Vector3, _ b: Vector3) {
        line(a.x, a.y, a.z, b.x, b.y, b.z)
    }

    /// 平行移動。``translate(_:_:)`` に `offset.x`・`offset.y` を渡すのと同じ。
    public func translate(_ offset: Vector2) {
        translate(offset.x, offset.y)
    }

    /// 奥行きを含む平行移動。``translate(_:_:_:)`` に 3 つの成分を渡すのと同じ。
    public func translate(_ offset: Vector3) {
        translate(offset.x, offset.y, offset.z)
    }

    /// 頂点を 1 つ置く。``vertex(_:_:)`` に `point.x`・`point.y` を渡すのと同じ。
    public func vertex(_ point: Vector2) {
        vertex(point.x, point.y)
    }

    /// 奥行きを持つ頂点を 1 つ置く。``vertex(_:_:_:)`` に 3 つの成分を渡すのと同じ。
    public func vertex(_ point: Vector3) {
        vertex(point.x, point.y, point.z)
    }
}
