// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 格子の補助線を、実線と破線で描き分ける ([#2835](https://github.com/mokume-metal/mokume/issues/2835)・
/// ADR-0043 決定 2 の作例)。
///
/// **見どころは、`strokeDash(_:_:)` で線のスタイルだけを変えて、同じ `line()` を引くこと。** 細かい
/// 目盛りは長さ 4・間隔 4 の破線で、太い補助線だけ `noStrokeDash()` で実線へ戻して引く。
///
/// 下の段は破線の振る舞いを並べる。端の形は破線の 1 つずつに付き (丸い端は長さの両側へはみ出す)、
/// 折れ線は曲がり角をまたいで模様が続き、曲線は弧の長さに沿って刻まれ、長さ 0 の破線は丸い端で
/// 点線になる。`pushStyle()` と `popStyle()` で破線の指定も戻るので、段ごとに指定を足しても
/// 外へ漏れない。
final class DashAndGrid: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 640, height: 480, title: "dash and grid")
    }

    func draw() {
        background(23, 26, 31)

        // 格子 — 細かい目盛りは破線、太い補助線は実線
        stroke(66, 74, 92)
        strokeWeight(1)
        strokeDash(4, 4)
        for x in stride(from: 0, through: 640, by: 20) { line(x, 0, x, 480) }
        for y in stride(from: 0, through: 480, by: 20) { line(0, y, 640, y) }
        noStrokeDash()
        stroke(120, 132, 158)
        for x in stride(from: 0, through: 640, by: 160) { line(x, 0, x, 480) }
        for y in stride(from: 0, through: 480, by: 160) { line(0, y, 640, y) }

        // 端の形 — 破線の 1 つずつに付く。同じ長さと間隔でも、丸い端は両側へはみ出して間が詰まる
        pushStyle()
        stroke(242, 115, 64)
        strokeWeight(10)
        strokeDash(24, 16)
        strokeCap(.square)
        line(40, 60, 280, 60)
        strokeCap(.round)
        line(40, 100, 280, 100)
        strokeCap(.project)
        line(40, 140, 280, 140)
        popStyle()

        // 点線 — 長さ 0 の破線は、丸い端なら丸い点が並ぶ
        pushStyle()
        stroke(89, 191, 242)
        strokeWeight(8)
        strokeCap(.round)
        strokeDash(0, 16)
        line(340, 60, 600, 60)
        strokeDash(0, 28)
        line(340, 100, 600, 100)
        popStyle()

        // 折れ線 — 模様は曲がり角をまたいで続く
        pushStyle()
        noFill()
        stroke(242, 217, 89)
        strokeWeight(6)
        strokeCap(.square)
        strokeJoin(.miter)
        strokeDash(30, 14)
        beginShape()
        vertex(40, 240)
        vertex(150, 190)
        vertex(240, 280)
        vertex(330, 200)
        vertex(420, 280)
        endShape()
        popStyle()

        // 曲線 — 弧の長さに沿って刻まれる。細い線、太い線の順
        pushStyle()
        noFill()
        stroke(102, 217, 128)
        strokeCap(.round)
        strokeDash(14, 10)
        strokeWeight(2)
        beginShape()
        vertex(40, 380)
        bezierVertex(120, 300, 200, 460, 300, 380)
        endShape()
        strokeWeight(8)
        beginShape()
        vertex(340, 380)
        bezierVertex(420, 300, 500, 460, 600, 380)
        endShape()
        popStyle()

        // 変換 — 長さと間隔は変換の前の単位で測るので、拡大すれば破線も伸びる
        pushStyle()
        pushMatrix()
        noFill()
        stroke(153, 128, 230)
        strokeWeight(3)
        strokeCap(.square)
        strokeDash(5, 5)
        translate(450, 240)
        line(0, 0, 150, 0)
        scale(2, 2)
        line(0, 10, 75, 10)
        popMatrix()
        popStyle()
    }
}
