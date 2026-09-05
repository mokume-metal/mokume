// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 立体の表面に模様を留める。**断片が受け取る形自身の座標から木目を作る。**
///
/// **板が回る。** 模様が表面に留まっていることは、動いて初めて読める — 止まった絵では
/// 「画面に貼り付いた模様」と見分けが付かない ([#367](https://github.com/mokume-metal/mokume/issues/367))。
///
/// 右の板だけ `in.place` (画面の中の位置) で塗ってある。**同じ形・同じ回し方で、模様の
/// 留まり方だけが違う**ので、何が変わったのかがこの 1 枚で読める。
final class SurfaceAndGrain: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "surface and grain")

    /// 木目の作り。**縞の作り方は 2 つで共有し、どの座標から作るかだけを変える。**
    private static func wood(from source: String) -> String {
        """
        static inline float mokume_rings(float2 spot, float pitch) {
            // **年輪の中心は板の外**に置く。板の上を弧が横切る形になり、
            // 的のような同心円ではなく挽いた板らしい面になる
            float2 across = float2(spot.x * 0.34 - 62.0, spot.y);
            // 縞をわずかに蛇行させる。真円のままだと木というより等高線に見える
            float drift = sin(spot.y * 0.05) * 7.0;
            return 0.5 + 0.5 * sin((length(across) + drift) * pitch);
        }

        float4 paint(Fragment in, Values values) {
            float2 spot = \(source);
            float rings = mokume_rings(spot, values.pitch);
            float3 tint = mix(values.early.rgb, values.late.rgb, rings);
            // **`in.color` には光を当てた結果が入っている。** 掛けるだけで陰影が残る
            return float4(tint * in.color.rgb, in.color.a);
        }
        """
    }

    private var settingsForWood: [String: ShaderValue] {
        [
            "pitch": 0.26,
            "early": .color(color(209, 163, 112)),
            "late": .color(color(115, 74, 43)),
        ]
    }

    /// 形自身の座標から作る木目。**回しても板に留まる。**
    private var grain: Shader?
    /// 画面の中の位置から作る木目。**回すと板の上を滑る** (#367 の症状)。
    private var slipping: Shader?

    func setup() {
        grain = try? makeShader(
            Self.wood(from: "in.shapePosition.xz"), values: settingsForWood)
        // 画面の位置は 0…1 なので、同じ縞の細かさになるよう板の大きさへ合わせる
        slipping = try? makeShader(
            Self.wood(from: "(in.place - 0.5) * float2(520.0, 300.0)"), values: settingsForWood)
    }

    func draw() {
        background(.studio)
        surroundings(.studio)
        ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.12))
        directionalLight(color(255, 242, 224), -0.4, 0.7, -0.6)
        noStroke()

        // **同じ姿勢で 2 枚**。時計はフレーム番号から導かれるので、何度撮っても同じ動き
        let spin = time * 0.55
        for (index, painted) in [grain, slipping].enumerated() {
            push()
            translate(width * 0.28 + Float(index) * width * 0.44, height * 0.52, 0)
            rotateX(-0.45)
            rotateY(spin)
            if let painted { shader(painted) }
            // 断片は `in.color` を掛けて使う。白で塗っておくと、そこに光の強さだけが載る
            fill(255, 255, 255)
            box(300, 18, 190)
            resetShader()
            pop()
        }

        fill(235, 235, 224)
        textFont("Helvetica")
        textSize(18)
        textAlign(.center)
        text("shapePosition — 模様が板に留まる", width * 0.28, height * 0.86)
        text("place — 模様が画面に貼り付く", width * 0.72, height * 0.86)
    }
}
