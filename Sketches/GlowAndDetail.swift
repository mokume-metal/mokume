// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 描く細かさを半分にして拡大し、描き終えた絵に効果を重ねる。
///
/// **見どころは、コードに拡大が 1 行も出てこないこと。** `pixelDensity` を 0.5 にしても
/// 座標は出す細かさのままなので、下の `draw()` は等倍のときと 1 文字も違わない。
/// 実際に刻んでいるのは 480×270 で、画面に出ているのは 960×540 である。
///
/// **効果は並べた順にかかる。** にじみ → 色ずれ → 周辺減光 の 3 段で、にじみの強さだけを
/// 時刻で振ってある。強さが変わっていることは**動いて初めて読める** — 止まった 1 枚では
/// 「そういう絵」と見分けが付かない。
///
/// 細い線と小さな点を多く置いてあるのは、**低い細かさでいちばん崩れるもの**を並べないと
/// 拡大が何をしているか読めないからである。
final class GlowAndDetail: Sketch {
    // 描く細かさは半分。**出す細かさは変えない**ので、座標も窓の大きさもそのまま
    var settings = SketchSettings(
        width: 960, height: 540, title: "glow and detail", pixelDensity: 0.5)

    /// 輻の本数。細い線を放射状に置く。
    private let spokes = 72

    func draw() {
        background(5, 8, 13)

        let centre = (x: width / 2, y: height / 2)
        let turn = time * 0.35

        // 細い輻。**内側と外側で回る向きを変える**ので、交差が動き続ける
        noFill()
        strokeWeight(1)
        for index in 0..<spokes {
            let ratio = Float(index) / Float(spokes)
            let angle = ratio * 2 * Float.pi + turn
            let inner = 70 + sin(angle * 3 + time) * 18
            let outer = 210 + sin(angle * 5 - time * 1.4) * 30
            stroke(
                .display(
                    red: 0.35 + ratio * 0.65, green: 0.55 + ratio * 0.3, blue: 1 - ratio * 0.55,
                    alpha: 0.9))
            line(
                centre.x + cos(angle) * inner, centre.y + sin(angle) * inner,
                centre.x + cos(angle) * outer, centre.y + sin(angle) * outer)
        }

        // 明るい点。**にじみの種**になるので、この点だけが周りへ光を漏らす
        noStroke()
        for index in 0..<24 {
            let angle = Float(index) / 24 * 2 * Float.pi - turn * 2.2
            let radius = 250 + sin(angle * 4 + time * 0.8) * 30
            fill(255, 235, 178)
            circle(centre.x + cos(angle) * radius, centre.y + sin(angle) * radius, 7)
        }

        // 細い同心円。**低い細かさでいちばん崩れる**のは細い曲線なので、
        // 拡大が何を埋めているかはここに出る
        noFill()
        strokeWeight(1)
        for index in 0..<16 {
            let radius = 96 + Float(index) * 9
            let fade = 0.5 - Float(index) / 40
            stroke(.display(red: 0.3, green: 0.55, blue: 0.9, alpha: fade))
            circle(centre.x, centre.y, radius * 2)
        }

        // 真ん中の芯。**にじみがいちばん強く出る場所**を絵の中心に置く
        noStroke()
        fill(255, 242, 204)
        circle(centre.x, centre.y, 34 + 6 * sin(time * 1.7))

        // にじみの強さだけを振る。**並べた順にかかる**ので、色ずれは
        // にじんだ後の絵に効く
        effects([
            .bloom(amount: 0.45 + 0.35 * (0.5 + 0.5 * sin(time * 1.1)), threshold: 0.4, radius: 14),
            .fringe(amount: 0.55),
            .vignette(amount: 0.6),
        ])
    }
}
