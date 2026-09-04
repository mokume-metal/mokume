// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 組み込みの立体 6 種・光 4 種・影。
///
/// **視点が回る。** 立体は静止画だと向きが読めないことがあるので、参照スケッチの側で
/// 回してある — 影がどの形から落ちているか、面のどちら側が光を受けているかは、
/// 動いて初めて読める。
final class SolidsAndLight: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "solids and light")

    /// 注視点。床も立体もこのまわりに固める。
    private var center: (x: Float, y: Float) { (width / 2, height / 2) }

    func draw() {
        background(15, 18, 23)

        // **注視点のまわりを回る。** 時計はフレーム番号から導かれるので、何度撮っても同じ動き
        let angle = time * 0.5
        let distance: Float = 470
        camera(
            center.x + sin(angle) * distance, center.y - 210, cos(angle) * distance,
            center.x, center.y + 110, 0,
            0, 1, 0)
        perspective(.pi / 3, width / height, 10, 2000)

        // 光を 4 種そろえて置く。縦軸は下向きなので、上から差す光の向きは +y
        ambientLight(.opaque(red: 0.16, green: 0.17, blue: 0.22))
        directionalLight(.opaque(red: 0.9, green: 0.86, blue: 0.78), -0.45, 0.85, -0.35)
        pointLight(.opaque(red: 0.25, green: 0.45, blue: 0.95), center.x - 260, center.y - 60, 220)
        spotLight(
            .opaque(red: 0.95, green: 0.35, blue: 0.4),
            center.x + 240, center.y - 300, 160,
            -0.35, 1, -0.25,
            angle: 0.5)

        shadows(true)
        noStroke()

        // 床。**受けるだけで落とさない** — 落とす側に入れると自分の影で暗くなる
        castShadow(false)
        fill(128, 128, 140)
        push()
        translate(center.x, center.y + 130, 0)
        rotateX(.pi / 2)
        plane(760, 760)
        pop()

        // 6 種を輪に並べる。**中心のまわりに固める** — 奥へ後退させると回したとき画面から溢れる
        castShadow(true)
        let radius: Float = 210
        for (index, solid) in solids.enumerated() {
            let around = Float(index) / Float(solids.count) * 2 * .pi
            fill(solid.color)
            push()
            translate(center.x + cos(around) * radius, center.y + 55, sin(around) * radius)
            // **視点から見て斜めを向かせる。** 正面を向いた箱や板は、静止画だと
            // ただの四角にしか見えず、輪の向こう側では真横になって消える
            rotateY(-around + solid.spin)
            rotateX(solid.tilt)
            solid.draw(self)
            pop()
        }
    }

    /// 並べる 6 種。**それぞれ違う色**にしてあるので、回っても見分けが付く。
    ///
    /// `spin` は輪の上での向き。**板だけ外を向かせる** (`.pi / 2`) — 他と同じ向きに
    /// すると、回っている間じゅう真横になって線に潰れる区間ができる。
    private var solids: [(color: LinearRGBA, tilt: Float, spin: Float, draw: (SolidsAndLight) -> Void)]
    {
        [
            (color(242, 115, 76), 0.3, 0.6, { $0.box(90) }),
            (color(102, 217, 128), 0, 0.6, { $0.sphere(52) }),
            (color(89, 153, 242), 0.5, .pi / 2, { $0.plane(120, 100) }),
            (color(230, 204, 51), 0.25, 0.6, { $0.cylinder(38, 96) }),
            (color(217, 102, 191), 0.25, 0.6, { $0.cone(44, 100) }),
            (color(102, 217, 230), 1.25, 0.6, { $0.torus(46, 17) }),
        ]
    }
}
