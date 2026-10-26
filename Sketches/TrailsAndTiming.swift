// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 上は同じ点を消去/描き足し/半透明の黒い矩形で薄める比較。半透明backgroundは前の絵と
/// 混ぜず置き換えるので、薄める側はfillとrectを使う。
/// 下は同じ初期絵を繰り返しfilter/毎回effectsでぼかす。前者はぼけが蓄積、後者は元の絵へ
/// 毎回同じぼかし。緑の印はfilterの後なので鋭く、effectsの指定後でも描き終わりの効果には入る。
/// `--render /tmp/trails --frames 150` を60 fpsで見る。180枚ごとに初期化し、入力や実時間を使わない。
final class TrailsAndTiming: Sketch {
    private var pads: [Canvas] = []
    var settings: SketchSettings { SketchSettings(width: 780, height: 540, title: "trails and timing") }
    func setup() throws { pads = try (0..<5).map { _ in try createGraphics(240, 180) } }

    func draw() {
        background(18)
        let phase = (frameCount - 1) % 180
        for index in 0..<5 {
            let pad = pads[index]
            draw(into: pad) {
                noStroke()
                if phase == 0 {
                    background(0)
                    if index >= 3 {
                        fill(255)
                        rect(36, 30, 18, 115)
                        circle(150, 70, 40)
                    }
                }
                if index < 3 {
                    if index == 0 { background(0) }
                    if index == 2 {
                        fill(0, 32)
                        rect(0, 0, width, height)
                    }
                    fill(255, 170, 50)
                    circle(120 + 80 * cos(time * 3), 90 + 55 * sin(time * 3), 12)
                } else {
                    if index == 3 { filter([.blur(radius: 2)]) }
                    else { effects([.blur(radius: 2)]) }
                    // 同じ位置へ同じ不透明な印。filterはここまで来る前、effectsは描き終わり。
                    fill(60, 240, 130)
                    rect(178, 135, 34, 10)
                }
            }
            let x = 10 + (index < 3 ? index : index - 3) * 260
            let y = index < 3 ? 30 : 300
            image(pad, x, y)
            fill(235)
            textSize(16)
            text(["clear each frame", "retain", "fade with rect", "filter: accumulates", "effects: from source"][index], x, y + 205)
        }
        fill(200)
        text("reset every 180 frames", 530, 325)
        text("Green marker is drawn", 530, 355)
        text("after filter / effects call.", 530, 380)
    }
}
