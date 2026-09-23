// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 文字を測る・揃える・枠を渡って流す・輪郭の穴を見分ける。
///
/// **測った値は、そのまま線と枠として描いてある。** 左上の 4 語は `textStyle()` の
/// 4 通りで、橙の下線が `textWidth()`、灰の枠の上辺と下辺が `textAscent()` と
/// `textDescent()` — 字が枠からはみ出していなければ、測った値が絵と合っている。
///
/// **下の 3 つの枠は 1 つの文を流したもの。** 入り切らなかった `remainder` を次の枠へ
/// 渡しているので、文は枠を渡って続く。枠の下の数字が `lineCount`、「続く」と
/// 「ここまで」の出し分けが `isTruncated`。折り返しは `textWrap(.character)` なので、
/// 行末が枠の右辺で揃う代わりに語の途中で折れる。
///
/// 右下の輪郭は `TextContour.isHole` で塗り分けている — 外周が橙、穴が水色。書体は
/// `Helvetica` にしてある (既定の書体は字を重なった部品で持つので、穴として返らない
/// 字がある)。説明の小さな字だけは `noTextFont()` で既定の書体へ戻している。
final class TypeAndMeasure: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "type and measure")

    /// 枠を渡って流す文。3 つ目の枠で終わる長さにしてある。
    private let passage =
        "Text poured into a box wraps at its width and keeps only the lines that fit "
        + "its height. Whatever does not fit comes back as the remainder, so the rest "
        + "can carry on into the next box, and then the next, until nothing is left."

    func draw() {
        background(18, 20, 28)
        textAlign(.left, .baseline)
        textWrap(.word)

        measuredStyles()
        verticalAlignment()
        flowAcrossBoxes()
        contoursAndHoles()
    }

    /// 太さと傾きの 4 通りを、測った幅と高さの枠に入れて並べる。
    private func measuredStyles() {
        let left: Float = 150
        for (index, style) in [TextStyle.normal, .bold, .italic, .boldItalic].enumerated() {
            let base = 80 + Float(index) * 58
            textFont("Helvetica")
            textStyle(style)
            textSize(40)
            let word = "Mokume"
            // **測るのは、描くときと同じ設定のまま。** 太さと傾きで幅が変わる
            let wide = textWidth(word)
            let rise = textAscent()
            let sink = textDescent()

            // 枠 — 上辺が基準線から上へ ascent、下辺が下へ descent
            noFill()
            stroke(64, 76, 102)
            strokeWeight(1)
            rect(left, base - rise, wide, rise + sink)
            // 基準線
            stroke(89, 97, 115)
            line(left - 12, base, left + wide + 12, base)
            noStroke()
            fill(242, 235, 217)
            text(word, left, base)
            // 測った幅の下線
            stroke(242, 140, 64)
            strokeWeight(3)
            line(left, base + sink + 5, left + wide, base + sink + 5)

            // 説明の字は既定の書体へ戻して描く
            noStroke()
            noTextFont()
            textStyle(.normal)
            textSize(13)
            fill(153, 166, 191)
            text("\(style)", 40, base)
            text("w \(Int(wide.rounded()))", left + wide + 20, base)
        }
    }

    /// 縦の揃え方を、1 本の横線に対して並べる。
    private func verticalAlignment() {
        let rule: Float = 150
        stroke(89, 191, 242)
        strokeWeight(1)
        line(520, rule, 920, rule)
        noStroke()
        textFont("Helvetica")
        textStyle(.normal)
        textSize(30)
        fill(242, 235, 217)
        // 次の語を置く位置も、測った幅から決める
        var x: Float = 530
        for vertical in [VerticalTextAlign.top, .center, .baseline, .bottom] {
            textAlign(.left, vertical)
            text("\(vertical)", x, rule)
            x += textWidth("\(vertical)") + 24
        }
        textAlign(.left, .baseline)
        noTextFont()
        textSize(13)
        fill(153, 166, 191)
        text("同じ 1 本の線へ、上端・中央・基準線・下端を合わせる", 520, 230)
    }

    /// 1 つの文を 3 つの枠へ、残りを渡しながら流す。
    private func flowAcrossBoxes() {
        textFont("Helvetica")
        textStyle(.normal)
        textSize(16)
        textLeading(22)
        textWrap(.character)
        var rest = passage
        for index in 0..<3 {
            let x = 40 + Float(index) * 160
            let top: Float = 310
            noFill()
            stroke(64, 76, 102)
            strokeWeight(1)
            rect(x, top, 140, 120)
            noStroke()
            fill(217, 224, 242)
            let flow = text(rest, x, top, 140, 120)
            // **続きを自分で数え直さない。** 残りをそのまま次の枠へ渡す
            rest = flow.remainder

            noTextFont()
            textSize(13)
            fill(flow.isTruncated ? color(242, 140, 64) : color(115, 217, 128))
            text("\(flow.lineCount) 行・\(flow.isTruncated ? "続く →" : "ここまで")", x, top + 145)
            textFont("Helvetica")
            textSize(16)
        }
        textWrap(.word)
    }

    /// 字の輪郭を、外周と穴で塗り分ける。
    private func contoursAndHoles() {
        textFont("Helvetica")
        textStyle(.bold)
        textSize(150)
        strokeWeight(2)
        for contour in textOutline("Bog8", 540, 440) {
            if contour.isHole {
                stroke(89, 191, 242)
                fill(89, 191, 242, 90)
            } else {
                stroke(242, 140, 64)
                fill(242, 140, 64, 40)
            }
            beginShape()
            for point in contour.points { vertex(point.x, point.y) }
            endShape(.close)
        }
        textStyle(.normal)
        noStroke()
        noTextFont()
        textSize(13)
        fill(153, 166, 191)
        text("外周は橙・穴は水色 (isHole)", 540, 510)
    }
}
