// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// ファイルから読んだ書体と、太さ (`textWeight`)。
///
/// **書体のファイルはリポジトリに置けない** (`scripts/check-no-binaries.sh`) ので、この Mac に同梱の
/// ファイルを読む。`SFNS.ttf` は可変書体 (システムの書体で、太さの軸が 1 から 1000)、`Helvetica.ttc` は
/// 太さが 3 つしかない書体 (軽い面・標準・太字) である。
///
/// 上の見出しは、字ごとに時間差で太くなったり細くなったりする。**可変書体は軸を動かすので、太さが
/// 連続で変わる** — 字の幅も一緒に動くので、次の字は測った幅を足して置いている。中の 1 行は、同じ
/// 書体で 100 から 900 まで太さを並べたもの。
///
/// 下の段が可変でない書体で、**同じ 100 から 900 でも 3 通りにしか変わらない** — 最も近い太さの面が
/// 選ばれるので、100〜349 は軽い面、350〜549 は標準、550 から上は太字になる。ラベルの `W` が頼んだ太さ
/// (説明の小さな字だけは `noTextFont()` で既定の書体へ戻している)。
final class TypeAndWeight: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "type and weight")
    }

    /// 可変書体。読めなければ `nil` で、既定の書体のまま描く (読めない環境でも落ちない)。
    private var variable: Font?
    /// 太さが 3 つしかない書体。
    private var fixed: Font?

    func setup() {
        variable = try? loadFont("/System/Library/Fonts/SFNS.ttf")
        fixed = try? loadFont("/System/Library/Fonts/Helvetica.ttc")
    }

    func draw() {
        background(18, 20, 28)
        noStroke()
        textAlign(.left, .baseline)

        pulsingHeadline()
        weightRamp(font: variable, label: "SFNS.ttf (variable)", top: 250)
        weightRamp(font: fixed, label: "Helvetica.ttc (3 weights)", top: 400)
    }

    /// 字ごとに時間差で太さが脈打つ見出し。
    private func pulsingHeadline() {
        if let variable { textFont(variable) } else { noTextFont() }
        textSize(120)
        var x: Float = 60
        for (index, letter) in "mokume".enumerated() {
            textWeight(500 + 400 * sin(time * 2 + Float(index) * 0.6))
            fill(242, 242, 242)
            text(String(letter), x, 150)
            // 太さが動くと送り幅も動く。測った幅を足すと、字が重ならず間も開かない
            x += textWidth(String(letter))
        }
    }

    /// 太さを 100 から 900 まで並べた 1 行。
    private func weightRamp(font: Font?, label: String, top: Float) {
        noTextFont()
        textWeight(400)
        textSize(14)
        fill(130, 140, 160)
        text(label, 60, top)

        for (index, weight) in [100, 300, 500, 700, 900].enumerated() {
            let x = 60 + Float(index) * 180
            if let font { textFont(font) } else { noTextFont() }
            textSize(38)
            textWeight(weight)
            fill(242, 242, 242)
            text("Mokume", x, top + 70)

            noTextFont()
            textWeight(400)
            textSize(14)
            fill(89, 191, 242)
            text("W\(weight)", x, top + 96)
        }
    }
}
