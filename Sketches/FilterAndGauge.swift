// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 呼んだ時点の絵に効果を掛ける (`filter`) と、絵ごとに掛けて新しい絵を返す (`Image.filtered`)。
///
/// **左は `filter` の前に描いたものにだけ掛かる。** 回る光の玉は、ぼかしとにじみで溶ける。その後に描いた
/// 計器 (灰色の円環と橙の針、下の目盛りの棒) は、同じ面の上でくっきりしたまま — `effects()` で書くと、計器も
/// ぼける。
///
/// **右は `Image.filtered`。** 上は年輪の縞を焼いた絵のまま、下は同じ絵に `.threshold(level: 0.5)` を掛けた
/// 新しい絵で、明るい縞だけが白になって影絵になる。元の絵は変わらないので、上は縞のまま残っている。
final class FilterAndGauge: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "filter and gauge")
    }

    /// 焼いた縞。**初期化で 1 度だけ作る。** 影絵は絵ごとに新しい絵を返すので、毎フレーム呼ばず 1 度だけ作って持つ
    private var stripes: Image?
    private var silhouette: Image?

    func setup() {
        let image = try? createImage(220, 200)
        for y in 0..<200 {
            for x in 0..<220 {
                let warp = sin(Float(y) * 0.06) * 14
                let ring = 0.5 + 0.5 * sin((Float(x) + warp) * 0.16)
                image?.set(x, y, .display(red: ring, green: ring * 0.8, blue: ring * 0.5))
            }
        }
        stripes = image
        silhouette = image?.filtered([.threshold(level: 0.5)])
    }

    func draw() {
        background(14, 16, 24)

        // 左: 光の玉。ここまでの絵にだけ、ぼかしとにじみを掛ける
        noStroke()
        for index in 0..<6 {
            let angle = Float(index) / 6 * 2 * Float.pi + time * 0.8
            fill(
                .display(
                    red: 0.9 + 0.1 * cos(angle), green: 0.45 + 0.35 * sin(angle), blue: 0.2 + 0.3 * cos(angle * 2)))
            circle(260 + cos(angle) * 120, 230 + sin(angle) * 90, 70)
        }
        filter([.blur(radius: 5), .bloom(amount: 0.7, threshold: 0.4)])

        // その後に描いたものには掛からない。灰色の円環・橙の針・下の目盛り
        noFill()
        stroke(190, 196, 208)
        strokeWeight(6)
        circle(260, 230, 280)
        stroke(242, 115, 64)
        strokeWeight(5)
        let needle = time * 1.2
        line(260, 230, 260 + cos(needle) * 130, 230 + sin(needle) * 130)
        noStroke()
        fill(190, 196, 208)
        for step in 0..<10 {
            rect(120 + Float(step) * 28, 420, 18, 24)
        }

        // 右: 焼いた縞と、同じ縞に threshold を掛けた新しい絵
        guard let stripes, let silhouette else { return }
        image(stripes, 640, 60)
        image(silhouette, 640, 290)
    }
}
