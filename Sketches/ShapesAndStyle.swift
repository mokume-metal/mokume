// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 図形・基準モード・輪郭・変換・混ぜ方・頂点列。
final class ShapesAndStyle: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "shapes and style")

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

        // 輪郭 — 太さ・端点・角
        noFill()
        stroke(217, 230, 255)
        for (index, cap) in [StrokeCap.square, .round, .project].enumerated() {
            strokeCap(cap)
            strokeWeight(Float(index) * 6 + 6)
            line(60, 190 + Float(index) * 34, 300, 190 + Float(index) * 34)
        }
        strokeWeight(10)
        for (index, join) in [StrokeJoin.miter, .round, .bevel].enumerated() {
            strokeJoin(join)
            let x = 360 + Float(index) * 110
            beginShape()
            vertex(x, 280)
            vertex(x + 50, 180)
            vertex(x + 90, 280)
            endShape()
        }

        // 変換を積む
        push()
        translate(760, 235)
        for _ in 0..<12 {
            rotate(.pi / 6)
            scale(0.92, 0.92)
            stroke(255, 153, 76, 230)
            strokeWeight(3)
            noFill()
            rect(-60, -60, 120, 120)
        }
        pop()

        // 混ぜ方
        noStroke()
        fill(51, 64, 89)
        rect(48, 330, 420, 160)
        let ink = color(242, 128, 89, 217)
        for (index, mode) in [BlendMode.blend, .add, .multiply, .screen, .difference].enumerated() {
            blendMode(mode)
            fill(ink)
            circle(110 + Float(index) * 80, 410, 110)
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
    }
}
