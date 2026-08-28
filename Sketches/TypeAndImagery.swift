// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
            fill(.display(red: 0.45, green: 0.85, blue: 0.5))
            stroke(.display(red: 0.12, green: 0.35, blue: 0.22))
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
        background(.display(red: 0.07, green: 0.08, blue: 0.11))
        textFont("Helvetica")

        // 見出しと、揃え方
        noStroke()
        fill(.display(red: 0.95, green: 0.92, blue: 0.85))
        textSize(46)
        text("mokume", 48, 90)
        textSize(18)
        fill(.display(red: 0.6, green: 0.65, blue: 0.75))
        textAlign(.left)
        text("左に揃える", 48, 130)
        textAlign(.center)
        text("中央に揃える", 300, 130)
        textAlign(.right)
        text("右に揃える", 560, 130)
        textAlign(.left)

        // 矩形へ流し込む
        stroke(.display(red: 0.25, green: 0.3, blue: 0.4))
        strokeWeight(1)
        noFill()
        rect(48, 160, 380, 150)
        noStroke()
        fill(.display(red: 0.85, green: 0.88, blue: 0.95))
        textSize(17)
        textLeading(26)
        _ = text(
            "文字は矩形へ流し込める。折り返しは幅を測ってから決まり、"
                + "入り切らなかったぶんは返ってくるので、続きを別の場所へ置ける。",
            56, 170, 364, 130)

        // 字の輪郭を図形として扱う
        push()
        translate(48, 380)
        stroke(.display(red: 0.95, green: 0.6, blue: 0.3))
        strokeWeight(2)
        noFill()
        textSize(72)
        for contour in textOutline("outline", 0, 60) {
            beginShape()
            for point in contour.points { vertex(point.x, point.y) }
            endShape(.close)
        }
        pop()

        // 絵を置く — 等倍・引き伸ばし・色掛け
        if let swatch {
            image(swatch, 480, 170)
            image(swatch, 560, 170, 128, 128)
            tint(.display(red: 1, green: 0.55, blue: 0.2))
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
