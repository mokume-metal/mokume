// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 曲がる帯に模様を留める。**絵を貼らずに、頂点に書いた座標から縞を作る。**
///
/// 帯の頂点に `u` = 頭から尾・`v` = 上の縁から下の縁 を書き、断片はその 2 つだけを見て
/// 縞を決める。**貼る絵は束ねていない** — 書いた位置は割られずに `in.uv` へ届く
/// ([#1140](https://github.com/mokume-metal/mokume/issues/1140))。
///
/// **帯がうねる。** 模様が帯に留まっていることは、動いて初めて読める。右の帯だけ
/// `in.place` (画面の中の位置) で塗ってあり、**同じ形・同じうねり方で、模様の留まり方
/// だけが違う** ([SurfaceAndGrain] の平面版)。
///
/// [SurfaceAndGrain]: SurfaceAndGrain
final class BandAndPattern: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "band and pattern")

    /// 縞の作り。**縞の作り方は 2 つで共有し、どの座標から作るかだけを変える。**
    private static func stripes(from source: String) -> String {
        """
        float4 paint(Fragment in, Values values) {
            float spot = \(source);
            // 7 本の縞。縁の暗さは**両方とも `in.uv.y` から作る** — v も頂点ごとに届く
            float band = step(0.5, fract(spot * 7.0));
            float rim = smoothstep(0.0, 0.3, in.uv.y) * smoothstep(1.0, 0.7, in.uv.y);
            float3 tint = mix(values.base.rgb, values.mark.rgb, band);
            return float4(tint * mix(0.55, 1.0, rim) * in.color.rgb, in.color.a);
        }
        """
    }

    private var values: [String: ShaderValue] {
        [
            "base": .color(color(240, 232, 214)),
            "mark": .color(color(214, 72, 40)),
        ]
    }

    /// 頂点に書いた座標から作る縞。**うねっても帯に留まる。**
    private var riding: Shader?
    /// 画面の中の位置から作る縞。**うねると帯の上を滑る。**
    private var slipping: Shader?

    func setup() {
        riding = try? makeShader(Self.stripes(from: "in.uv.x"), values: values)
        // 帯の長さ (360) が面の幅 (960) に占める割合で、同じ縞の細かさに揃える
        slipping = try? makeShader(
            Self.stripes(from: "in.place.x * 960.0 / 360.0"), values: values)
    }

    func draw() {
        background(24, 28, 36)
        noStroke()
        fill(255, 255, 255)

        for (index, painted) in [riding, slipping].enumerated() {
            if let painted { shader(painted) }
            band(centerX: width * 0.28 + Float(index) * width * 0.44, centerY: height * 0.5)
            resetShader()
        }

        fill(225, 225, 214)
        textFont("Helvetica")
        textSize(18)
        textAlign(.center)
        text("uv — 縞が帯に留まる", width * 0.28, height * 0.86)
        text("place — 縞が画面に貼り付く", width * 0.72, height * 0.86)
    }

    /// 頭を左に向けた帯を、三角形の帯で描く。**背骨ごと曲がり、横へも泳ぐ。**
    ///
    /// 背骨は向きを尾へ向けて積み上げて作る — 曲がると頂点の画面の位置と `u` の対応が
    /// 崩れるので、`u` から作った縞と画面の位置から作った縞の違いが読める。
    private func band(centerX: Float, centerY: Float) {
        let length: Float = 360
        let segments = 48
        let step = length / Float(segments)
        // 背骨の点と向き。振れは頭で小さく尾で大きい。時計はフレーム番号から導くので、
        // 何度撮っても同じ動き
        var spine: [(x: Float, y: Float, heading: Float)] = []
        var (x, y): (Float, Float) = (0, 0)
        for index in 0...segments {
            let u = Float(index) / Float(segments)
            let heading = sin(u * 4.5 - time * 3) * (0.15 + 0.85 * u)
            spine.append((x, y, heading))
            x += cos(heading) * step
            y += sin(heading) * step
        }
        // 背骨の真ん中を置き場所へ合わせ、左右へゆっくり泳がせる
        let middle = spine[segments / 2]
        let shiftX = centerX - middle.x + sin(time * 0.9) * 50
        let shiftY = centerY - middle.y

        beginShape(.triangleStrip)
        for (index, point) in spine.enumerated() {
            let u = Float(index) / Float(segments)
            // 太さは頭の後ろで最大、尾へ向けて細る
            let half = 45 * sin(Float.pi * (0.12 + 0.88 * u)) + 4
            let (nx, ny) = (-sin(point.heading), cos(point.heading))
            vertex(point.x + shiftX - nx * half, point.y + shiftY - ny * half, u, 0)
            vertex(point.x + shiftX + nx * half, point.y + shiftY + ny * half, u, 1)
        }
        endShape()
    }
}
