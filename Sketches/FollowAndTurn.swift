// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// ポインタを追う目。**フレームの長さに依らず同じ硬さで追い、最短の向きへ回り、まぶたが往復する。**
/// 動きの 3 つの口 (`damp`・`lerpAngle`・`pingpong`) を、作者が書く形のまま並べた参照スケッチ
/// ([#2423])。
///
/// - `damp(目の位置, ポインタ, 6, deltaTime)` — `x += (mouseX - x) * 0.1` と書くと、フレームが
///   落ちると追従が遅れ、`frameRate` を変えると硬さも変わる。窓でも `mokume render` でも同じ
///   硬さで追う
/// - `lerpAngle(瞳の向き, ポインタの向き, 0.2)` — ±π をまたぐとき (ポインタが目の左側を
///   上から下へ横切るとき) も、1 周回らず短いほうへ回る
/// - `pingpong(time, 1)` — まぶたが 2 秒で開閉する。負の時刻へ戻っても崩れない
///
/// ## 操作
///
/// ポインタを動かすまでは、目は面の中を回る目標を追う。動かしてからは、ポインタを追う。
///
/// [#2423]: https://github.com/mokume-metal/mokume/issues/2423
final class FollowAndTurn: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "follow and turn")
    }

    var eyeX: Float = 480
    var eyeY: Float = 270
    /// 瞳の向き (ラジアン)。±π に畳まず、``lerpAngle(_:_:_:)`` が返した値をそのまま持つ。
    var look: Float = 0

    /// 最初に見たポインタの位置。ここから動いたら、ポインタを目標にする。
    private var restingX: Float?
    private var restingY: Float?
    private var pointerMoved = false

    func draw() {
        background(240)

        // ポインタが動くまでは、触らなくても動きが見えるよう、面の中を回る目標を追う
        if restingX == nil {
            restingX = mouseX
            restingY = mouseY
        } else if mouseX != restingX || mouseY != restingY {
            pointerMoved = true
        }
        let targetX = pointerMoved ? mouseX : width / 2 + cos(time * 0.9) * 320
        let targetY = pointerMoved ? mouseY : height / 2 + sin(time * 1.2) * 160

        eyeX = damp(eyeX, targetX, 6, deltaTime)
        eyeY = damp(eyeY, targetY, 6, deltaTime)
        look = lerpAngle(look, atan2(targetY - eyeY, targetX - eyeX), 0.2)
        let lid = pingpong(time, 1)  // 0 → 1 → 0 を 2 秒で
        let open = 0.3 + 0.7 * lid

        stroke(40, 46, 58)
        strokeWeight(4)
        fill(255)
        ellipse(eyeX, eyeY, 240, 240 * open)
        noStroke()
        fill(46, 84, 140)
        circle(eyeX + cos(look) * 60, eyeY + sin(look) * 60 * open, 60)
    }
}
