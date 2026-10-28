// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// `Vector2` / `Vector3` をそのまま座標や移動量として渡す口 (#3360)。
//
// どれも数で受ける同じ名前の口と同じ絵・同じ変換になる。`Canvas` の同じ口へ転送するだけで、
// フレームの外で呼んだときの扱いも数の口と同じ (注意して無視する)。数を渡す口があるものにだけ
// 足す — 3 次元の `circle` は数の口が無いので、ここにも無い。

extension SketchPart {
    /// 円を塗る。中心を `Vector2` で渡す。
    ///
    /// ``circle(_:_:_:)`` の `a`・`b` に `center.x`・`center.y` を渡すのと同じで、座標の読み方も
    /// ``ellipseMode(_:)`` が決める。位置を持ち歩いているときに、毎回 `.x`・`.y` へ開かずに書ける。
    ///
    /// ```swift
    /// let pos = Vector2(200, 150)
    /// circle(pos, 80)
    /// ```
    // shot: 参照 circle(_:_:_:)
    public func circle(_ center: Vector2, _ diameter: some ScalarConvertible) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.circle(center, diameter.asFloat)
    }

    /// 点を打つ。位置を `Vector2` で渡す。``point(_:_:)`` に `point.x`・`point.y` を渡すのと同じ。
    ///
    /// ```swift
    /// point(Vector2(200, 150))
    /// ```
    // shot: 参照 point(_:_:)
    public func point(_ point: Vector2) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.point(point)
    }

    /// 立体の空間に点を打つ。位置を `Vector3` で渡す。``point(_:_:_:)`` に 3 つの成分を渡すのと同じ。
    ///
    /// ```swift
    /// point(Vector3(200, 150, -40))
    /// ```
    // shot: 参照 point(_:_:_:)
    public func point(_ point: Vector3) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.point(point)
    }

    /// 2 つの点を結ぶ線を引く。点を `Vector2` で渡す。``line(_:_:_:_:)`` に 2 つの点の成分を渡すのと同じ。
    ///
    /// ```swift
    /// line(Vector2(40, 40), Vector2(360, 260))
    /// ```
    // shot: 参照 line(_:_:_:_:)
    public func line(_ a: Vector2, _ b: Vector2) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.line(a, b)
    }

    /// 立体の空間で 2 つの点を結ぶ線を引く。点を `Vector3` で渡す。
    /// ``line(_:_:_:_:_:_:)`` に 2 つの点の成分を渡すのと同じ。
    ///
    /// ```swift
    /// line(Vector3(40, 40, 0), Vector3(360, 260, -200))
    /// ```
    // shot: 参照 line(_:_:_:_:_:_:)
    public func line(_ a: Vector3, _ b: Vector3) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.line(a, b)
    }

    /// 原点をずらす。移動量を `Vector2` で渡す。``translate(_:_:)`` に `offset.x`・`offset.y` を渡すのと同じ。
    ///
    /// ```swift
    /// let pos = Vector2(200, 150)
    /// translate(pos)
    /// ```
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 参照 translate(_:_:)
    public func translate(_ offset: Vector2) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.translate(offset)
    }

    /// 原点を奥行きも含めてずらす。移動量を `Vector3` で渡す。
    /// ``translate(_:_:_:)`` に 3 つの成分を渡すのと同じ (奥行きは見ている側が正)。
    ///
    /// ```swift
    /// translate(Vector3(200, 150, -100))
    /// ```
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 参照 translate(_:_:_:)
    public func translate(_ offset: Vector3) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.translate(offset)
    }

    /// 頂点を 1 つ置く。位置を `Vector2` で渡す。``vertex(_:_:)`` に `point.x`・`point.y` を渡すのと同じ。
    ///
    /// ```swift
    /// let corners: [Vector2] = [[60, 60], [340, 90], [200, 250]]
    /// beginShape()
    /// for corner in corners { vertex(corner) }
    /// endShape(.close)
    /// ```
    // shot: 参照 vertex(_:_:)
    public func vertex(_ point: Vector2) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.vertex(point)
    }

    /// 奥行きを持つ頂点を 1 つ置く。位置を `Vector3` で渡す。``vertex(_:_:_:)`` に 3 つの成分を渡すのと同じ。
    ///
    /// ```swift
    /// beginShape(.lines)
    /// vertex(Vector3(60, 60, 0))
    /// vertex(Vector3(340, 240, -150))
    /// endShape()
    /// ```
    // shot: 参照 vertex(_:_:_:)
    public func vertex(_ point: Vector3) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.vertex(point)
    }
}
