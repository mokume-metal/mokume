// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 窓を触った操作。**触って確かめるための参照スケッチ。**
///
/// 他の参照スケッチと違って、これは絵を書き出しても意味を持たない — 見たいのは
/// 「触ると効くか」で、静止した 1 枚には現れない。窓を開いて動かすためにある。
///
/// 窓の大きさを変えても、読める座標は**描く解像度の座標系のまま**である。帯 (窓と
/// 縦横比が合わないときに出る余白) の上へカーソルを出すと、座標は面の外を指して
/// **範囲外の値になる** — 丸めていないので、面の外を面の外として表せる。
final class PointerAndKeys: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "pointer and keys")

    /// スクロールで積み上がる大きさ。フレームを越える。
    var size: Float = 120

    /// スクロールされた 1 件ぶんで大きさを積む。
    ///
    /// **`draw()` の中で `scrollY` を読む形から移した。** あちらはフレームの合計なので、
    /// 1 フレームに 3 件届くと部分累計を 3 回足し込むことになる ([#807]) — 窓を人が
    /// 触るぶんには 1 フレームに 1 件しか入らないので、ここを間違えても気付けない。
    ///
    /// [#807]: https://github.com/mokume-metal/mokume/issues/807
    func mouseWheel(deltaX: Float, deltaY: Float) {
        size = min(max(size + deltaY * 4, 20), 400)
    }

    func draw() {
        background(15, 18, 23)

        // 描く解像度の縁。窓をどう変えてもここが動かないことが、座標系が
        // 独立していることの見え方になる
        noFill()
        stroke(76, 87, 107)
        strokeWeight(4)
        rect(2, 2, width - 4, height - 4)

        // 指した場所へ十字と円。押している間は色が変わる
        noStroke()
        fill(
            isMousePressed
                ? color(242, 217, 89, 230)
                : color(89, 191, 242, 153))
        circle(mouseX, mouseY, size)

        stroke(217, 230, 255, 128)
        strokeWeight(1)
        line(mouseX, 0, mouseX, height)
        line(0, mouseY, width, mouseY)

        // 読めている値をそのまま出す。範囲外になったことも、ここに出る
        fill(230, 237, 255)
        noStroke()
        textSize(22)
        text("x \(Int(mouseX))   y \(Int(mouseY))", 24, 44)
        text("押している \(isMousePressed ? "はい (釦 \(mouseButton))" : "いいえ")", 24, 76)
        text("引きずった \(Int(dragX)), \(Int(dragY))", 24, 108)
        text("スクロール \(String(format: "%.1f", scrollY))   大きさ \(Int(size))", 24, 140)
        text("キー \(key.isEmpty ? "—" : key)", 24, 172)
    }
}
