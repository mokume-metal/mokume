// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 下地を、素の数値で塗る。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// ```
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func background(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255
    ) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.background(red, green, blue, alpha)
    }

    /// 下地を灰色で塗る。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// ```swift
    /// background(24)
    /// ```
    public func background(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.background(gray, alpha)
    }

    /// これから描く図形の塗りを、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**塗りを止めていたら、呼んだ時点で
    /// 再び塗るようになる。**
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
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
    /// - Note: `Int` の変数もそのまま渡せる (`fill(i, 0, 0)`)。
    ///   0–1 で書きたいときは ``LinearRGBA/display(red:green:blue:alpha:)`` を渡す。
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func fill(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.fill(red, green, blue, alpha)
    }

    /// 塗りを灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// fill(230)
    /// circle(200, 150, 180)
    /// ```
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    public func fill(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.fill(gray, alpha)
    }

    /// 塗りを、色の値と不透明度で決める。**不透明度の目盛りは 0–255**。
    ///
    /// 色を変数に持ったまま、その色を薄めて塗りたいときに使う。**塗りを止めていたら、
    /// 呼んだ時点で再び塗るようになる。**
    ///
    /// ```swift
    /// let ink = color(28, 28, 30)
    /// background(240)
    /// noStroke()
    /// fill(ink)
    /// rect(40, 60, 140, 140)
    /// fill(ink, 90)
    /// rect(220, 60, 140, 140)
    /// ```
    ///
    /// **不透明度は置き換えずに、色が元から持つ不透明度に掛ける** (手本の Processing と同じ)。
    /// `fill(c, 255)` は `c` のまま塗り、半透明の色を不透明にはしない — 不透明に塗りたいときは
    /// 不透明な色を渡す。`fill(color(230, 120, 40, 128), 128)` の不透明度は 64 あまりになる。
    ///
    /// **0–1 ではない。** `fill(c, 0.5)` はほぼ透明になる。0–1 の率で薄めたいときは
    /// `fill(c, rate * 255)` と書く。
    ///
    /// **範囲の外は締める。色の成分は締めない** — 不透明度の 400 は 255 と、-100 は 0 と同じに
    /// なる (掛ける率を 0–1 に締める)。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。数でない値・無限は受けず、塗りは直前のまま残る。
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func fill(_ color: LinearRGBA, _ alpha: some ScalarConvertible) {
        canvas.fill(color, alpha.asFloat)
    }

    /// これから引く線の色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**線を止めていたら、呼んだ時点で
    /// 再び引くようになる。**
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
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
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func stroke(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.stroke(red, green, blue, alpha)
    }

    /// 線の色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// strokeWeight(4)
    /// stroke(200)
    /// line(60, 90, 340, 210)
    /// ```
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func stroke(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.stroke(gray, alpha)
    }

    /// 線の色を、色の値と不透明度で決める。**不透明度の目盛りは 0–255**。
    ///
    /// 色を変数に持ったまま、その色を薄めて引きたいときに使う。**線を止めていたら、
    /// 呼んだ時点で再び引くようになる。**
    ///
    /// ```swift
    /// let ink = color(28, 28, 30)
    /// background(240)
    /// strokeWeight(8)
    /// stroke(ink)
    /// line(40, 100, 360, 100)
    /// stroke(ink, 90)
    /// line(40, 200, 360, 200)
    /// ```
    ///
    /// **不透明度は置き換えずに、色が元から持つ不透明度に掛ける** (手本の Processing と同じ)。
    /// `stroke(c, 255)` は `c` のまま引き、半透明の色を不透明にはしない — 不透明に引きたいときは
    /// 不透明な色を渡す。
    ///
    /// **0–1 ではない。** `stroke(c, 0.5)` はほぼ透明になる。0–1 の率で薄めたいときは
    /// `stroke(c, rate * 255)` と書く。
    ///
    /// **範囲の外は締める。色の成分は締めない** — 不透明度の 400 は 255 と、-100 は 0 と同じに
    /// なる (掛ける率を 0–1 に締める)。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。数でない値・無限は受けず、線の色は直前のまま残る。
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func stroke(_ color: LinearRGBA, _ alpha: some ScalarConvertible) {
        canvas.stroke(color, alpha.asFloat)
    }

    /// これから描く画像に掛ける色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 4 つ目の不透明度を下げると、画像そのものが薄くなる。
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// ```swift
    /// tint(255, 204, 0)
    /// ```
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func tint(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.tint(red, green, blue, alpha)
    }

    /// 画像に掛ける色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// ```swift
    /// tint(255, 128)
    /// ```
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func tint(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.tint(gray, alpha)
    }
}
