// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// トゥーンの球。**光を通す前の色 (`baseColor`) と世界の位置 (`worldPosition`) から、光の当たり方を断片で
/// 書き直す** ([#3573](https://github.com/mokume-metal/mokume/issues/3573)・作例は #2458)。
///
/// 上の段は向きの決まった光で、球が 4 段の明暗に塗り分けられる。光の向きは時間とともに回り、つまみ
/// (`turn`) でずらすと段の境目が動く。下の段は世界の位置に置いたランプからの向きで段を付けるので、
/// 球ごとに光の来る側が違う (小さな白い球がランプ)。
///
/// **`noLights()` で光を切らない。** `lights()` の下では `in.color` に光を通した後の色が入るが、
/// `in.baseColor` は塗った色 (`fill()`) のまま届く。段の数は値 (`bands`) で渡す。
final class ToonAndBands: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 640, title: "toon and bands")
    }

    /// 光の向きを回す量 (ラジアン)。時間で回る向きに足す。
    @Param(-3.2...3.2) var turn: Float = 0

    /// 段の数。
    @Param(2...8) var bands: Int = 4

    private var toon: Shader?
    private var lamp: Shader?

    /// 球の色。左から橙・青・緑。
    private static let tints: [(Float, Float, Float)] = [(240, 150, 70), (80, 140, 230), (110, 200, 120)]

    func setup() throws {
        // #2458 の作例のまま。光の向きは世界の座標で、球の面の向き (`worldNormal`) と比べる
        toon = try createShader(
            """
            float4 paint(Fragment in, Values values) {
                float n = max(dot(in.worldNormal, normalize(values.light)), 0.0);
                float band = floor(n * values.bands) / values.bands;
                return float4(in.baseColor.rgb * (0.3 + 0.7 * band), in.baseColor.a);
            }
            """,
            values: ["light": .vector3(Vector3(0, 0, 1)), "bands": 4])
        // 光の向きを、ランプの位置と面の位置 (どちらも世界の座標) の差から作る
        lamp = try createShader(
            """
            float4 paint(Fragment in, Values values) {
                float3 toLamp = normalize(values.lamp - in.worldPosition);
                float n = max(dot(in.worldNormal, toLamp), 0.0);
                float band = floor(n * values.bands) / values.bands;
                return float4(in.baseColor.rgb * (0.3 + 0.7 * band), in.baseColor.a);
            }
            """,
            values: ["lamp": .vector3(Vector3(0, 0, 0)), "bands": 4])
    }

    func draw() {
        background(24, 24, 28)
        // **平行に写す。** 透視だと端の球が横へ伸び、段の形の違いが写し方から来るのか光から来るのかが
        // 読めなくなる (`facing-and-view` と同じ理由)
        ortho()
        lights()
        noStroke()

        // 上の段: 向きの決まった光。時間で回り、つまみでずらす
        let angle = time * 0.5 + turn
        let light = Vector3(sin(angle), -0.5, cos(angle))
        toon?.set("light", light)
        toon?.set("bands", bands)
        for (index, tint) in Self.tints.enumerated() {
            push {
                translate(width * (0.2 + 0.3 * Float(index)), height * 0.27, 0)
                fill(tint.0, tint.1, tint.2)
                if let toon { shader(toon) }
                sphere(92)
                resetShader()
            }
        }

        // 下の段: 世界の位置に置いたランプ。3 つの球の上を左右に往復する
        let lampAt = Vector3(width * (0.5 + 0.38 * sin(time * 0.7)), height * 0.58, 160)
        lamp?.set("lamp", lampAt)
        lamp?.set("bands", bands)
        for (index, tint) in Self.tints.enumerated() {
            push {
                translate(width * (0.2 + 0.3 * Float(index)), height * 0.74, 0)
                fill(tint.0, tint.1, tint.2)
                if let lamp { shader(lamp) }
                sphere(92)
                resetShader()
            }
        }
        // ランプの目印。光を受けない白で描く
        push {
            noLights()
            fill(255, 250, 230)
            translate(lampAt.x, lampAt.y, lampAt.z)
            sphere(8)
        }

        // 字は画面に貼り付けて読みたいので、光を切ってから書く
        noLights()
        fill(235, 235, 224)
        textFont("Helvetica")
        textSize(18)
        textAlign(.center)
        text("向きの決まった光 — in.worldNormal と values.light", width / 2, height * 0.5)
        text("世界に置いたランプ — values.lamp − in.worldPosition", width / 2, height * 0.97)
    }
}
