// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 面の向きを色にする。**断片が受け取る 3 つの向きを、同じ形・同じ回し方で並べる。**
///
/// 左から `shapeNormal` (形自身)・`worldNormal` (世界)・`viewNormal` (視点)。形が回ると、
/// 左は面ごとの色が留まり、中と右は色が入れ替わる。**視点も少しずつ回り込む**ので、
/// 中 (視点を動かしても変わらない) と右 (変わる) の違いも同じ絵の中で読める
/// ([#847](https://github.com/mokume-metal/mokume/issues/847))。
///
/// 右が p5.js の `normalMaterial()` に当たる塗りである。
final class FacingAndView: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "facing and view")

    /// 向きの欄の名前と、絵の下に出す説明。
    private static let fields = [
        ("shapeNormal", "shapeNormal — 回しても色が留まる"),
        ("worldNormal", "worldNormal — 回すと変わる"),
        ("viewNormal", "viewNormal — 視点が動くと変わる"),
    ]

    private var painters: [Shader?] = []

    func setup() {
        // 向きの成分は −1…1 なので、0…1 へ寄せてから色にする
        painters = Self.fields.map { field, _ in
            try? makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    return float4(in.\(field) * 0.5 + 0.5, 1.0);
                }
                """)
        }
    }

    func draw() {
        background(24, 24, 28)
        noStroke()

        // **視点をゆっくり回り込ませる。** 時計はフレーム番号から導かれるので、何度撮っても同じ動き
        let distance = (height / 2) / tan(Float.pi / 6)
        let orbit = sin(time * 0.4) * 0.5
        camera(
            width / 2 + distance * sin(orbit), height / 2 - distance * 0.25,
            distance * cos(orbit), width / 2, height / 2, 0, 0, 1, 0)
        // **平行に写す。** 透視だと 3 つの箱が置き場所ごとに違う角度から見え、色の差が
        // 向きの欄の違いなのか見え方の違いなのかが読めなくなる
        ortho()

        let spin = time * 0.6
        for (index, painter) in painters.enumerated() {
            push()
            translate(width * (0.2 + 0.3 * Float(index)), height * 0.46, 0)
            rotateX(spin * 0.7)
            rotateY(spin)
            if let painter { shader(painter) }
            box(120)
            resetShader()
            pop()
        }

        // 字は画面に貼り付けて読みたいので、視点を戻してから書く
        camera()
        fill(235, 235, 224)
        textFont("Helvetica")
        textSize(18)
        textAlign(.center)
        for (index, (_, caption)) in Self.fields.enumerated() {
            text(caption, width * (0.2 + 0.3 * Float(index)), height * 0.86)
        }
    }
}
