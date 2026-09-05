// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 下地を、素の数値で塗る。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// ```
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func background(
        _ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255
    ) {
        canvas.background(red, green, blue, alpha)
    }

    /// 下地を灰色で塗る。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// ```swift
    /// background(24)
    /// ```
    public func background(_ gray: Float, _ alpha: Float = 255) {
        canvas.background(gray, alpha)
    }

    /// これから描く図形の塗りを、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**塗りを止めていたら、呼んだ時点で
    /// 再び塗るようになる。**
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// noStroke()
    /// fill(255, 204, 0)
    /// circle(150, 150, 160)
    /// fill(89, 191, 242, 153)
    /// circle(250, 150, 160)
    /// ```
    ///
    /// - Note: 引数は `Float` なので `Int` の変数はそのまま渡せない (`fill(Float(i), 0, 0)`)。
    ///   0–1 で書きたいときは ``LinearRGBA/display(red:green:blue:alpha:)`` を渡す。
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    public func fill(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        canvas.fill(red, green, blue, alpha)
    }

    /// 塗りを灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// fill(230)
    /// circle(200, 150, 180)
    /// ```
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    public func fill(_ gray: Float, _ alpha: Float = 255) {
        canvas.fill(gray, alpha)
    }

    /// これから引く線の色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**線を止めていたら、呼んだ時点で
    /// 再び引くようになる。**
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// noFill()
    /// strokeWeight(6)
    /// stroke(255, 204, 0)
    /// circle(200, 150, 180)
    /// ```
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func stroke(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        canvas.stroke(red, green, blue, alpha)
    }

    /// 線の色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// strokeWeight(4)
    /// stroke(200)
    /// line(60, 90, 340, 210)
    /// ```
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func stroke(_ gray: Float, _ alpha: Float = 255) {
        canvas.stroke(gray, alpha)
    }

    /// これから描く画像に掛ける色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 4 つ目の不透明度を下げると、画像そのものが薄くなる。
    ///
    /// ```swift
    /// tint(255, 204, 0)
    /// ```
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func tint(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        canvas.tint(red, green, blue, alpha)
    }

    /// 画像に掛ける色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// ```swift
    /// tint(255, 128)
    /// ```
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func tint(_ gray: Float, _ alpha: Float = 255) {
        canvas.tint(gray, alpha)
    }
}
