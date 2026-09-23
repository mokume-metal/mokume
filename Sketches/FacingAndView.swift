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
/// **下の段は、同じ箱を動かない視点から見たもの。** 最初のフレームの視点を値で取って
/// おき (`currentCamera`)、毎フレーム当て直す (`setCamera`)。写し方だけは既定の透視へ
/// 戻してある (`perspective()`) — 色は向きだけで決まるので、写し方を変えても色は変わらない。
/// 左と中は上下の段で同じ色のまま、右だけが視点の回り込みにつれて上の段とずれていく。
///
/// 右が p5.js の `normalMaterial()` に当たる塗りである。
final class FacingAndView: Sketch {
    var settings = SketchSettings(width: 960, height: 640, title: "facing and view")

    /// 向きの欄の名前と、絵の下に出す説明。
    private static let fields = [
        ("shapeNormal", "shapeNormal — 回しても色が留まる"),
        ("worldNormal", "worldNormal — 回すと変わる"),
        ("viewNormal", "viewNormal — 視点が動くと変わる"),
    ]

    private var painters: [Shader?] = []

    /// 最初のフレームの視点。**視点はフレームを越えない**ので、持ち続けたいものは値で持つ。
    private var resting: Camera?

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
        // 向きの欄の違いなのか見え方の違いなのかが読めなくなる。範囲は面の 1.2 倍に広げて
        // 上の段を縮め、下の段を置く余白を作る (縦軸は下向きなので、上端のほうが小さい数)
        let reach: Float = 1.2
        ortho(
            -width / 2 * reach, width / 2 * reach, height / 2 * reach, -height / 2 * reach,
            distance / 10, distance * 10)
        // 最初のフレームで効いている視点 (位置と写し方の組) を、値として取っておく
        if resting == nil { resting = currentCamera }

        let spin = time * 0.6
        drawBoxes(y: height * 0.36, size: 120, spin: spin)

        // 下の段。**取っておいた視点を当て直す** — ここまでに置いた上の段は、置いた時点の
        // 視点のまま描き切られる。写し方は既定の透視へ戻す (視点の位置は動かない)
        if let resting { setCamera(resting) }
        perspective()
        drawBoxes(y: height * 0.76, size: 64, spin: spin)

        // 字は画面に貼り付けて読みたいので、視点を戻してから書く
        camera()
        fill(235, 235, 224)
        textFont("Helvetica")
        textSize(18)
        textAlign(.center)
        for (index, (_, caption)) in Self.fields.enumerated() {
            text(caption, width * (0.2 + 0.3 * Float(index)), height * 0.6)
        }
        textSize(14)
        text("下の段: 動かない視点・透視で見た同じ箱", width / 2, height * 0.94)
    }

    /// 3 つの向きの欄で、同じ形を同じ回し方で並べる。
    private func drawBoxes(y: Float, size: Float, spin: Float) {
        for (index, painter) in painters.enumerated() {
            push()
            translate(width * (0.2 + 0.3 * Float(index)), y, 0)
            rotateX(spin * 0.7)
            rotateY(spin)
            if let painter { shader(painter) }
            box(size)
            resetShader()
            pop()
        }
    }
}
