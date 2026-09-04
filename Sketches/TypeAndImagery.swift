// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 文字・画像・保持した形。
final class TypeAndImagery: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "type and imagery")

    /// 毎フレーム組み立て直さない葉。色は形の中で決まる。
    private var leaf = Shape.empty
    /// 組にした一房。置くのは 1 回で済む。
    private var cluster = Shape.empty
    /// 自分で描いた絵。
    private var swatch: Image?

    func setup() {
        leaf = createShape {
            fill(115, 217, 128)
            stroke(31, 89, 56)
            strokeWeight(2)
            beginShape()
            vertex(0, -22)
            bezierVertex(16, -14, 16, 14, 0, 22)
            bezierVertex(-16, 14, -16, -14, 0, -22)
            endShape(.close)
        }
        cluster = Shape.group(
            (0..<9).map { index in
                createShape {
                    push()
                    translate(Float(index % 3) * 46, Float(index / 3) * 46)
                    rotate(Float(index) * 0.4)
                    shape(leaf)
                    pop()
                }
            })

        // 絵を自分で組み立てる。画素へ直に書ける
        let image = try? createImage(64, 64)
        for y in 0..<64 {
            for x in 0..<64 {
                let wave = 0.5 + 0.5 * sin(Float(x) * 0.2) * cos(Float(y) * 0.2)
                image?.set(x, y, .display(red: wave, green: 0.35, blue: 1 - wave))
            }
        }
        swatch = image
    }

    func draw() {
        background(18, 20, 28)
        textFont("Helvetica")

        // 見出しと、揃え方
        noStroke()
        fill(242, 235, 217)
        textSize(46)
        text("mokume", 48, 90)
        textSize(18)
        fill(153, 166, 191)
        textAlign(.left)
        text("左に揃える", 48, 130)
        textAlign(.center)
        text("中央に揃える", 300, 130)
        textAlign(.right)
        text("右に揃える", 560, 130)
        textAlign(.left)

        // 矩形へ流し込む
        stroke(64, 76, 102)
        strokeWeight(1)
        noFill()
        rect(48, 160, 380, 150)
        noStroke()
        fill(217, 224, 242)
        textSize(17)
        textLeading(26)
        _ = text(
            "文字は矩形へ流し込める。折り返しは幅を測ってから決まり、"
                + "入り切らなかったぶんは返ってくるので、続きを別の場所へ置ける。",
            56, 170, 364, 130)

        // 字の輪郭を図形として扱う
        push()
        translate(48, 380)
        stroke(242, 153, 76)
        strokeWeight(2)
        noFill()
        textSize(72)
        for contour in textOutline("outline", 0, 60) {
            beginShape()
            for point in contour.points { vertex(point.x, point.y) }
            endShape(.close)
        }
        pop()

        // 自分の色を持つ字形。**塗りの色は掛からない** ので、同じ 1 行の中で
        // 単色の字は塗りの色で出て、絵文字だけが自分の色で出る
        textSize(30)
        fill(153, 166, 191)
        text("色を持つ字形 🔴 🙂 🌿", 48, 500)

        // 絵を置く — 等倍・引き伸ばし・色掛け
        if let swatch {
            image(swatch, 480, 170)
            image(swatch, 560, 170, 128, 128)
            tint(255, 140, 51)
            image(swatch, 704, 170, 128, 128)
            noTint()
        }

        // 保持した形 — 1 枚ずつと、組にしたもの
        push()
        translate(560, 360)
        for index in 0..<4 {
            shape(leaf, Float(index) * 52, 0)
        }
        pop()
        shape(cluster, 790, 340)
    }
}
