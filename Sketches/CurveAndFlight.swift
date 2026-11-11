// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// ベジェ曲線に沿って、紙飛行機が向きを変えながら飛ぶ。**曲線の上の点と、そこでの進む向きを、
/// 3 次式を自分で展開せずに求める** 3 つの口 (`bezier`・`bezierPoint`・`bezierTangent`) を、
/// 作者が書く形のまま並べた参照スケッチ ([#2430])。
///
/// - `bezier(…)` — 始点・制御点 2 つ・終点を渡して、灰色の曲線を 1 行で引く
/// - `bezierPoint(a, b, c, d, t)` — `x` の 4 つ・`y` の 4 つで 2 回呼び、`t` の位置を得る
/// - `bezierTangent(a, b, c, d, t)` — 同じ並びで傾きを得て、`atan2(y, x)` を機首の向きにする
///
/// `t` は 0 から 1 を 6.7 秒で巡る。`t` は曲線の長さの割合ではないので、曲線が急に曲がる所では
/// 機体の速さが変わる。
///
/// **下の橙の機体は、通過点を結ぶ曲線の側の 3 つの口** (`curve`・`curvePoint`・`curveTangent`・[#3710])
/// で同じことをする。4 つの点のうち両端の 2 つ (灰色の丸) は通らず、間の 1 区間だけを飛ぶ。
/// こちらの 2 つの口は、いまの `curveTightness` を読む。
///
/// [#2430]: https://github.com/mokume-metal/mokume/issues/2430
/// [#3710]: https://github.com/mokume-metal/mokume/issues/3710
final class CurveAndFlight: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "curve and flight")
    }

    func draw() {
        background(18, 20, 26)

        // 曲線と、それを引っぱる制御点
        stroke(70, 76, 90)
        strokeWeight(1)
        line(60, 420, 260, 60)
        line(900, 160, 640, 600)
        noStroke()
        fill(70, 76, 90)
        circle(260, 60, 10)
        circle(640, 600, 10)
        noFill()
        stroke(120)
        strokeWeight(2)
        bezier(60, 420, 260, 60, 640, 600, 900, 160)

        // 曲線の上を飛ぶ機体。周期のある動きは phase(period:) で書く (何日走らせても刻みが粗くならない)
        let t = phase(period: 1 / 0.15)
        let x = bezierPoint(60, 260, 640, 900, t)
        let y = bezierPoint(420, 60, 600, 160, t)
        let angle = atan2(bezierTangent(420, 60, 600, 160, t), bezierTangent(60, 260, 640, 900, t))
        push {
            translate(x, y)
            rotate(angle)
            noStroke()
            fill(255)
            triangle(14, 0, -10, -8, -10, 8)
        }

        // 通過点を結ぶ曲線の 1 区間と、その上を飛ぶ橙の機体。両端の点は曲がり方を決めるだけで通らない
        noStroke()
        fill(70, 76, 90)
        circle(120, 380, 10)
        circle(880, 520, 10)
        noFill()
        stroke(120)
        strokeWeight(2)
        curve(120, 380, 300, 500, 700, 440, 880, 520)
        let cx = curvePoint(120, 300, 700, 880, t)
        let cy = curvePoint(380, 500, 440, 520, t)
        let heading = atan2(curveTangent(380, 500, 440, 520, t), curveTangent(120, 300, 700, 880, t))
        push {
            translate(cx, cy)
            rotate(heading)
            noStroke()
            fill(242, 115, 64)
            triangle(14, 0, -10, -8, -10, 8)
        }
    }
}
