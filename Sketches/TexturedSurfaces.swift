// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 焼いた絵を平面と立体に貼る。
///
/// **絵は 1 度だけ焼く。** 板は動かないので毎フレーム作り直す必要が無く、焼いたものを
/// そのまま貼る — この形が書けることが #368 の要求だった。
///
/// **視点が回る。** 巻き方 (箱は面ごと・球は経度と緯度・円柱は側面の一周) は静止画では
/// 読めないので、参照スケッチの側で回してある。
final class TexturedSurfaces: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "textured surfaces")

    /// 焼いた木目。**初期化で 1 度だけ作る。**
    private var grain: Image?

    func setup() {
        let image = try? createImage(256, 256)
        for y in 0..<256 {
            for x in 0..<256 {
                // 年輪を歪めた縞。上下・左右が入れ替わったら分かるよう、
                // 上端を明るく・左端を赤くしておく
                let warp = sin(Float(y) * 0.05) * 12
                let ring = 0.5 + 0.5 * sin((Float(x) + warp) * 0.16)
                let top: Float = y < 16 ? 0.35 : 0
                let left: Float = x < 16 ? 0.4 : 0
                image?.set(
                    x, y,
                    .display(
                        red: min(1, 0.42 + ring * 0.36 + top + left),
                        green: min(1, 0.26 + ring * 0.28 + top),
                        blue: min(1, 0.14 + ring * 0.16 + top)))
            }
        }
        grain = image
    }

    func draw() {
        background(18, 18, 23)
        guard let grain else { return }

        let angle = time * 0.5
        camera(
            480 + sin(angle) * 420, 150, cos(angle) * 420,
            480, 300, 0,
            0, 1, 0)
        perspective(.pi / 3, width / height, 10, 2000)

        ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.24))
        directionalLight(.linear(red: 0.9, green: 0.86, blue: 0.78), -0.4, 0.8, -0.35)

        // MARK: 立体に貼る
        noStroke()
        texture(grain)

        // 箱は 6 面それぞれに 1 枚。陰影は残ったまま絵が乗る
        push()
        translate(300, 300, 0)
        rotateX(0.4)
        box(150)
        pop()

        // 球は経度と緯度に巻く
        push()
        translate(510, 290, 0)
        sphere(80)
        pop()

        // 円柱は側面が一周・蓋が円
        push()
        translate(700, 300, 0)
        rotateX(0.5)
        cylinder(60, 160)
        pop()

        // 自分で並べた面には、読み取り位置を書いて貼れる
        push()
        translate(480, 450, 0)
        rotateX(.pi / 2)
        beginShape()
        vertex(-260, -120, 0, 0, 0)
        vertex(260, -120, 0, Float(grain.width), 0)
        vertex(260, 120, 0, Float(grain.width), Float(grain.height))
        vertex(-260, 120, 0, 0, Float(grain.height))
        endShape(.close)
        pop()

        // MARK: 平面にも同じように効く
        //
        // **貼る絵は塗りにしか効かない。** 輪郭は線の色のまま出る
        rect(40, 40, 150, 110)

        stroke(242, 217, 102)
        strokeWeight(4)
        rect(210, 40, 150, 110)
        noStroke()

        // 塗りが色掛けになる
        fill(115, 204, 255)
        circle(440, 95, 110)
        fill(255, 255, 255)

        // 外せば、そのあとの図形には貼られない
        noTexture()
        fill(242, 102, 115)
        rect(520, 40, 150, 110)
        fill(255, 255, 255)
    }
}
