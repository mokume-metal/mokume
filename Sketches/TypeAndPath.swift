// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 字の輪郭を道にして、等間隔の粒を回し、ポインタが字の墨の上に入ったかを問う ([#2426])。
///
/// **`Path(textOutline(…))` は、字の輪郭を道として持つ。** 道は長さを測り (`length`)・弧長で点を引き
/// (`point(at:)`)・内側かを問える (`contains(_:)`)。
///
/// - 橙の粒は、`point(at: t)` に等間隔の `t` を渡した点。道は周を並んだ順に繋いだ 1 本として辿るので、
///   粒は `m` の外周を回った後、`o` の外周と穴、`e` の外周と穴へ渡っていく。`t` に時間を足すだけで、
///   全部の粒が同じ速さで輪郭に沿って流れる
/// - 字の明るさは `contains([ポインタ])`。回り数が 0 でない所が内側なので、`o` と `e` の穴は外側で、
///   ポインタが穴に入ると字は暗いまま
/// - 粒の間隔を揃えるための点の取り直しは、道に持たせていない。要るのは `t` を等間隔にすることだけ
///
/// ## 操作
///
/// ポインタを動かすまでは、面の中を回る点が字の中を通り抜ける。動かしてからは、ポインタが探る点になる。
///
/// [#2426]: https://github.com/mokume-metal/mokume/issues/2426
final class TypeAndPath: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "type and path")
    }

    /// 字の輪郭を繋いだ道。書体と大きさを決めてから、1 度だけ作る。
    private var word: Path?

    /// 最初に見たポインタの位置。ここから動いたら、ポインタを探る点にする。
    private var restingX: Float?
    private var restingY: Float?
    private var pointerMoved = false

    /// 輪郭を回る粒の数。
    private let grains = 240

    func setup() {
        textFont("Helvetica")
        textStyle(.bold)
        textSize(200)
        textAlign(.center, .baseline)
        word = Path(textOutline("mokume", width / 2, 350))
    }

    func draw() {
        background(14, 16, 24)
        guard let word else { return }

        // ポインタが動くまでは、触らなくても内外が変わるのが見えるよう、字を横切る点を探る
        if restingX == nil {
            restingX = mouseX
            restingY = mouseY
        } else if mouseX != restingX || mouseY != restingY {
            pointerMoved = true
        }
        let probe =
            pointerMoved
            ? Vector2(mouseX, mouseY)
            : Vector2(width / 2 + cos(time * 0.9) * 280, 290 + sin(time * 1.4) * 50)
        let inside = word.contains(probe)

        // 字。墨の上に探る点があれば明るい
        noStroke()
        fill(inside ? color(255, 244, 222) : color(66, 74, 98))
        shape(word)

        // 輪郭を回る粒。`t` を等間隔に並べて、時間の分だけ全部をずらす
        fill(255, 160, 60)
        for index in 0..<grains {
            let t = (Float(index) / Float(grains) + time * 0.04).truncatingRemainder(dividingBy: 1)
            Circle(center: word.point(at: t), radius: 3).draw()
        }

        // 探る点
        noFill()
        stroke(120, 220, 255)
        strokeWeight(2)
        Circle(center: probe, radius: 9).draw()

        noTextFont()
        textStyle(.normal)
        textSize(14)
        textAlign(.left, .baseline)
        noStroke()
        fill(160, 168, 190)
        text("word.contains(probe) → \(inside)", 40, 60)
        text("word.length = \(Int(word.length)) px, \(grains) grains at point(at: t)", 40, 82)
    }
}
