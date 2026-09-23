// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 図形・基準モード・輪郭・変換・混ぜ方・頂点列。
///
/// 曲線と、頂点の並べ方 (`beginShape` に渡す種類) は `CurvesAndVertices` が持つ。
final class ShapesAndStyle: Sketch {
    var settings = SketchSettings(width: 960, height: 720, title: "shapes and style")

    func draw() {
        background(18, 20, 26)

        // 図形をひととおり
        noStroke()
        fill(242, 115, 64)
        rect(48, 48, 140, 90)
        rectMode(.center)
        fill(89, 191, 242)
        rect(280, 93, 120, 80)
        rectMode(.corner)
        fill(242, 217, 89)
        circle(430, 93, 90)
        fill(153, 128, 230)
        arc(560, 93, 100, 100, 0.4, 4.2)
        fill(102, 217, 128)
        triangle(660, 138, 720, 48, 780, 138)
        fill(230, 102, 153)
        quad(820, 48, 900, 62, 890, 138, 810, 120)

        // 輪郭 — 太さ・端点・角。**スタイルだけを積む**ので、ここで変えた端点・角・
        // 太さは外へ漏れない
        pushStyle()
        noFill()
        stroke(217, 230, 255)
        for (index, cap) in [StrokeCap.square, .round, .project].enumerated() {
            strokeCap(cap)
            strokeWeight(index * 6 + 6)
            line(60, 190 + index * 34, 300, 190 + index * 34)
        }
        strokeWeight(10)
        for (index, join) in [StrokeJoin.miter, .round, .bevel].enumerated() {
            strokeJoin(join)
            let x = 360 + index * 110
            beginShape()
            vertex(x, 280)
            vertex(x + 50, 180)
            vertex(x + 90, 280)
            endShape()
        }
        popStyle()

        // 変換を積む — **変換だけを積む**
        pushMatrix()
        translate(760, 235)
        for _ in 0..<12 {
            rotate(radians(30))
            scale(0.92, 0.92)
            stroke(255, 153, 76, 230)
            strokeWeight(3)
            noFill()
            rect(-60, -60, 120, 120)
        }
        popMatrix()

        // 混ぜ方 — 10 種を 5 つずつ 2 段。下地に明るい帯を通して、暗い所と明るい所の
        // 両方で混ざり方が読めるようにする
        noStroke()
        fill(51, 64, 89)
        rect(48, 330, 420, 160)
        fill(140, 160, 200)
        rect(48, 362, 420, 20)
        rect(48, 438, 420, 20)
        let ink = color(242, 128, 89, 217)
        let modes: [BlendMode] = [
            .blend, .add, .multiply, .screen, .difference,
            .subtract, .lightest, .darkest, .exclusion, .replace,
        ]
        for (index, mode) in modes.enumerated() {
            blendMode(mode)
            fill(ink)
            circle(98 + index % 5 * 80, 372 + index / 5 * 76, 64)
        }
        blendMode(.blend)

        // 頂点列 — 曲線と穴と切り抜き
        push()
        translate(560, 330)
        clip(560, 330, 360, 170)
        fill(115, 217, 191)
        stroke(26, 76, 76)
        strokeWeight(3)
        beginShape()
        vertex(20, 140)
        bezierVertex(60, 10, 200, 10, 250, 140)
        beginContour()
        vertex(90, 110)
        vertex(180, 110)
        vertex(135, 50)
        endContour()
        endShape(.close)
        pop()
        noClip()

        // 基準モード — 同じ 4 つの数の読み方を変える。楕円は中心から測るのが既定
        noStroke()
        fill(242, 115, 64)
        ellipse(90, 620, 80, 50)
        ellipseMode(.corner)
        fill(89, 191, 242)
        ellipse(150, 595, 80, 50)
        ellipseMode(.center)
        rectMode(.corners)
        fill(242, 217, 89)
        rect(330, 660, 250, 580)  // 対角の 2 つの角。前後を入れ替えても同じ矩形になる
        rectMode(.radius)
        fill(153, 128, 230)
        rect(380, 620, 30, 40)
        rectMode(.corner)

        // 点 — 大きさは輪郭の太さで決まる。角度は度で数えて弧度へ直す
        stroke(217, 230, 255)
        for (index, degree) in stride(from: Float(0), to: degrees(2 * .pi), by: 30).enumerated() {
            strokeWeight(2 + index)
            let angle = radians(degree)
            point(520 + cos(angle) * 55, 620 + sin(angle) * 55)
        }

        // 斜め変形・行列を直接掛ける・変換を捨てる
        noStroke()
        push()
        translate(630, 585)
        shearX(radians(25))
        fill(102, 217, 128)
        rect(0, 0, 50, 70)
        pop()
        push()
        translate(700, 575)
        shearY(radians(20))
        fill(230, 102, 153)
        rect(0, 0, 50, 60)
        pop()
        push()
        translate(800, 650)
        var step = Transform.identity
        step.translate(x: 34, y: -22)
        step.rotate(by: radians(18))
        step.scale(x: 0.85, y: 0.85)
        for index in 0..<5 {
            fill(89 + index * 30, 191 - index * 20, 242)
            square(-20, -20, 40)
            applyMatrix(step)
        }
        // どれだけ重ねていても 1 回で素の座標へ戻る — 右下の隅に、傾かずに出る
        resetMatrix()
        fill(242, 217, 89)
        square(900, 660, 36)
        pop()
    }
}
