// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 図形・基準モード・輪郭・変換・混ぜ方・頂点列。
final class ShapesAndStyle: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "shapes and style")

    func draw() {
        background(.display(red: 0.07, green: 0.08, blue: 0.10))

        // 図形をひととおり
        noStroke()
        fill(.display(red: 0.95, green: 0.45, blue: 0.25))
        rect(48, 48, 140, 90)
        rectMode(.center)
        fill(.display(red: 0.35, green: 0.75, blue: 0.95))
        rect(280, 93, 120, 80)
        rectMode(.corner)
        fill(.display(red: 0.95, green: 0.85, blue: 0.35))
        circle(430, 93, 90)
        fill(.display(red: 0.6, green: 0.5, blue: 0.9))
        arc(560, 93, 100, 100, 0.4, 4.2)
        fill(.display(red: 0.4, green: 0.85, blue: 0.5))
        triangle(660, 138, 720, 48, 780, 138)
        fill(.display(red: 0.9, green: 0.4, blue: 0.6))
        quad(820, 48, 900, 62, 890, 138, 810, 120)

        // 輪郭 — 太さ・端点・角
        noFill()
        stroke(.display(red: 0.85, green: 0.9, blue: 1))
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
        for index in 0..<12 {
            rotate(.pi / 6)
            scale(0.92, 0.92)
            stroke(.display(red: 1, green: 0.6, blue: 0.3, alpha: 0.9))
            strokeWeight(3)
            noFill()
            rect(-60, -60, 120, 120)
        }
        pop()

        // 混ぜ方
        noStroke()
        fill(.display(red: 0.2, green: 0.25, blue: 0.35))
        rect(48, 330, 420, 160)
        let ink = LinearRGBA.display(red: 0.95, green: 0.5, blue: 0.35, alpha: 0.85)
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
        fill(.display(red: 0.45, green: 0.85, blue: 0.75))
        stroke(.display(red: 0.1, green: 0.3, blue: 0.3))
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
