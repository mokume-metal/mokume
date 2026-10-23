// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 文字列を組版して描く (`shapedText`) と、スカラ 1 つずつ並べる (`text`) の比べ。
///
/// 3 段の左がスカラ 1 つずつ (`text`)、右が組版 (`shapedText`)。**絵文字は組版すると 1 字になる** —
/// 肌色の修飾子を付けた親指・国旗・ZWJ で繋いだ家族・異体字セレクタを付けた心・囲みを付けた 1 は、
/// 左では部品に分かれ、右では 1 字ずつ並ぶ。**結合文字は基の字の上に載る** (`e` と `x` と、アクセントを
/// 重ねた `o`)。**ラテンの字は詰まる** — `AV To Wa` は右のほうが狭い。
///
/// **測った値は線と枠にしてある。** 右の橙の下線が `shapedTextWidth()`、灰の枠が `shapedTextBounds()`
/// が返す墨の範囲で、どちらも右の組版した絵に合う。左の水色の下線は `textWidth()` で、スカラの幅の和なので、
/// 絵文字では部品の幅を足した分だけ長く、ラテンでは詰めを知らないぶん長い。書体は `Helvetica` にして
/// ある (絵文字は環境が持つ別の書体から引かれる)。説明の小さな字だけは `noTextFont()` で既定の書体へ戻している。
final class TypeAndShaping: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "type and shaping")
    }

    private let samples: [(label: String, string: String)] = [
        ("emoji", "👍🏽 🇯🇵 👨‍👩‍👧 ❤️ 1️⃣"),
        ("combining", "e\u{0301} x\u{0301} o\u{0308}\u{0301}"),
        ("kerning", "AV To Wa fi"),
    ]

    func draw() {
        background(18, 20, 28)
        textAlign(.left, .baseline)
        for (index, sample) in samples.enumerated() {
            row(sample.label, sample.string, base: 130 + Float(index) * 170)
        }
        noStroke()
        noTextFont()
        textSize(13)
        fill(153, 166, 191)
        text("text — スカラ 1 つずつ", 40, 30)
        text("shapedText — 組版", 500, 30)
    }

    /// 同じ文字列を、左にスカラ 1 つずつ・右に組版して描き、測った値を添える。
    private func row(_ label: String, _ string: String, base: Float) {
        noStroke()
        noTextFont()
        textSize(13)
        fill(153, 166, 191)
        text(label, 40, base - 70)

        textFont("Helvetica")
        textSize(40)
        fill(242, 235, 217)
        text(string, 40, base)
        shapedText(string, 500, base)

        // 測った幅 — 左は textWidth (スカラの幅の和)・右は shapedTextWidth (組版した幅)
        strokeWeight(3)
        stroke(89, 191, 242)
        line(40, base + 16, 40 + textWidth(string), base + 16)
        stroke(242, 140, 64)
        line(500, base + 16, 500 + shapedTextWidth(string), base + 16)

        // 組版した墨の範囲
        if let bounds = shapedTextBounds(string, 500, base) {
            noFill()
            stroke(153, 166, 191)
            strokeWeight(1)
            rect(bounds.x, bounds.y, bounds.width, bounds.height)
        }
    }
}
