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
///
/// ## 状態と出来事の両方を出す
///
/// 上半分に出るのは**いまの状態** (`mouseX` / `isMousePressed` / `dragX` / `key`)、
/// 下に溜まるのは**起きた出来事** — 押した点・引きずった線・打った文字である。
/// 出来事はコールバックの中で記録していて、`draw()` は描くだけである。
///
/// **この違いは、状態からは作れない絵で分かる。** 1 フレームに押下と解放が収まると
/// `isMousePressed` は `false` のままだが、点はちゃんと 1 つ増える
/// ([#723](https://github.com/mokume-metal/mokume/issues/723))。窓を人が触るぶんには
/// 起きないので、確かめるには外から送る:
///
/// ```
/// {"id":"a1","events":[{"type":"mouseDown","x":480,"y":300},
///                      {"type":"mouseUp","x":480,"y":300}]}
/// ```
final class PointerAndKeys: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "pointer and keys")

    /// スクロールで積み上がる大きさ。フレームを越える。
    var size: Float = 120

    /// 押された点。**出来事として溜める**ので、1 フレームに収まった押下も残る。
    var pressed: [(x: Float, y: Float)] = []
    /// 引きずった線。1 件ぶんの量から、どこからどこへ動いたかを組み立てる。
    var dragged: [(fromX: Float, fromY: Float, toX: Float, toY: Float)] = []
    /// 打たれた文字。**打鍵だけが増やす**ので、矢印キーでは伸びない。
    var typed = ""
    /// 最後に動いたキーの符号。押しても離しても入れ替わる。
    var lastKeyCode: Int?

    /// 溜める上限。触り続けても際限なく伸びないようにする。
    static let keepAtMost = 40

    func mousePressed() {
        pressed.append((mouseX, mouseY))
        if pressed.count > Self.keepAtMost { pressed.removeFirst() }
    }

    /// 押したまま動いた 1 件を、線分として残す。
    ///
    /// **引数が「その 1 件で動いた量」なので、引き算で始点が出る** ([#807])。`dragX` は
    /// フレームの合計なので、ここから読むと部分累計になって線がつながらない。
    ///
    /// [#807]: https://github.com/mokume-metal/mokume/issues/807
    func mouseDragged(deltaX: Float, deltaY: Float) {
        dragged.append((mouseX - deltaX, mouseY - deltaY, mouseX, mouseY))
        if dragged.count > Self.keepAtMost { dragged.removeFirst() }
    }

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

    /// **文字を生むキーだけが呼ぶ。** 矢印やファンクションキーではここへ来ない。
    func keyTyped() {
        typed.append(key)
        if typed.count > 24 { typed.removeFirst() }
    }

    /// どのキーが動いたかを覚える。**打った文字とは別の問い**なので、矢印でも入る。
    func keyPressed() {
        lastKeyCode = keyCode?.rawValue
    }

    func draw() {
        background(15, 18, 23)

        // 描く解像度の縁。窓をどう変えてもここが動かないことが、座標系が
        // 独立していることの見え方になる
        noFill()
        stroke(76, 87, 107)
        strokeWeight(4)
        rect(2, 2, width - 4, height - 4)

        // 引きずった線。出来事 1 件が線分 1 本で、押したまま動いた道筋になる
        stroke(242, 217, 89, 179)
        strokeWeight(3)
        for segment in dragged {
            line(segment.fromX, segment.fromY, segment.toX, segment.toY)
        }

        // 押した点。1 フレームに収まった押下も、ここには残る
        noStroke()
        fill(242, 120, 89, 204)
        for point in pressed {
            circle(point.x, point.y, 14)
        }

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

        // 打った文字と、動いたキー。**別の問いなので別の行に出す** — 矢印キーでは
        // 左が伸びずに右だけ変わる
        text("キー \(key.isEmpty ? "—" : key)   符号 \(lastKeyCode.map(String.init) ?? "—")", 24, 172)
        text("打った \(typed.isEmpty ? "—" : typed)", 24, 204)

        // 溜まっている出来事の数。状態ではなく、起きたことの数である
        fill(150, 165, 190)
        textSize(18)
        text("押した点 \(pressed.count)   引きずった線 \(dragged.count)", 24, height - 28)
    }
}
