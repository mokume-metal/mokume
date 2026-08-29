// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 種から同じ値が出る乱数と揺らぎ。
///
/// **見どころは、左右に同じ木目が出ること。** 左は CPU の `noise()` を 4 画素ごとに
/// 引いて置いたもの (だから四角い)、右は断片の `mokume_noise()` で塗ったもの。
/// `noiseSeed()` を `setup()` で 1 度呼ぶだけで**両方に効く**ので、断片へ種を値として
/// 渡してはいない ([#366])。
///
/// **木目の式のほうは、わざと 2 度書いてある** — 見比べるための同じ絵を、別々の場所で
/// 組み立てて見せるためである。揃っているのは揺らぎのほうで、そこが揃っているから
/// 同じ模様になる。
///
/// 下の粒は `random()`。`randomSeed()` を置いてあるので、走らせるたびに同じ並びが出る。
///
/// [#366]: https://github.com/mokume-metal/mokume/issues/366
final class NoiseAndSeed: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "noise and seed")

    /// 木目を見せる 2 枚の板の置き場 (左が CPU・右が断片)。
    private let panel = (x: Float(20), y: Float(20), width: Float(440), height: Float(420))
    private let gap: Float = 480
    /// 板 1 枚に何周ぶんの木目を写すか。
    private let span: Float = 6
    /// 早材と晩材の色。
    private let early = LinearRGBA.display(red: 0.82, green: 0.64, blue: 0.44)
    private let late = LinearRGBA.display(red: 0.46, green: 0.30, blue: 0.18)
    /// CPU 側を引く刻み (画素)。細かくするほど右に近づく。
    private let cell: Float = 4

    private var grain: Shader?

    func setup() {
        // 種と細かさはここで 1 度決める。**CPU 側と断片側の両方に効く**
        noiseSeed(20260829)
        noiseDetail(5, 0.5)

        // 断片の側。`mokume_noise` は前置きされているので宣言も配線も要らない
        grain = try? makeShader(
            """
            float4 paint(Fragment in, Values values) {
                // 板の中での位置 (0…1)。左の CPU 側と同じ座標を作るため、
                // 画面の中の位置ではなく板からの位置で引く
                float2 local = (in.position - values.origin) / values.extent;
                float2 p = local * values.span;

                float drift = (mokume_noise(in, p * 0.6) - 0.5) * 0.9;
                float radius = length(p - float2(values.span * 0.5, values.span * 1.6)) + drift;
                float ring = fract(radius * 0.9);
                float late = smoothstep(0.72, 0.9, ring) * (1.0 - smoothstep(0.94, 1.0, ring));
                float fibre = (mokume_noise(in, float2(p.x * 2.0, p.y * 26.0)) - 0.5) * 0.14;

                return float4(mix(values.early.rgb, values.late.rgb, late) + fibre, 1.0);
            }
            """,
            values: [
                "origin": .pair(panel.x + gap, panel.y),
                "extent": .pair(panel.width, panel.height),
                "span": .number(span),
                "early": .color(early),
                "late": .color(late),
            ])
    }

    func draw() {
        background(.display(red: 0.09, green: 0.09, blue: 0.11))
        noStroke()

        // 左: CPU の揺らぎ。同じ座標には何度呼んでも同じ値が返るので、
        // フレームをまたいでも模様は動かない
        var y = panel.y
        while y < panel.y + panel.height {
            var x = panel.x
            while x < panel.x + panel.width {
                // 四角の真ん中で引く (右の断片が画素の真ん中で引くのに合わせる)
                let local = (
                    (x + cell / 2 - panel.x) / panel.width,
                    (y + cell / 2 - panel.y) / panel.height
                )
                fill(wood(local.0 * span, local.1 * span))
                rect(x, y, cell, cell)
                x += cell
            }
            y += cell
        }

        // 右: 断片の揺らぎ。**種も細かさも渡していない**
        if let grain {
            shader(grain)
            rect(panel.x + gap, panel.y, panel.width, panel.height)
            resetShader()
        }

        // 下: 乱数。種を決めてあるので、走らせるたびに同じ並びが出る
        randomSeed(7)
        for _ in 0..<60 {
            fill(.display(red: random(0.5, 1), green: random(0.4, 0.8), blue: random(0.2, 0.5)))
            circle(random(20, 940), random(475, 515), random(6, 18))
        }
    }

    /// 木目 1 点ぶんの色。**上の断片と同じ式**を Swift で書いたもの。
    private func wood(_ px: Float, _ py: Float) -> LinearRGBA {
        let drift = (noise(px * 0.6, py * 0.6) - 0.5) * 0.9
        let dx = px - span * 0.5
        let dy = py - span * 1.6
        let radius = (dx * dx + dy * dy).squareRoot() + drift
        let ring = fract(radius * 0.9)
        let lateness = smoothstep(0.72, 0.9, ring) * (1 - smoothstep(0.94, 1.0, ring))
        let fibre = (noise(px * 2, py * 26) - 0.5) * 0.14
        return LinearRGBA(
            premultipliedRed: mix(early.red, late.red, lateness) + fibre,
            green: mix(early.green, late.green, lateness) + fibre,
            blue: mix(early.blue, late.blue, lateness) + fibre,
            alpha: 1)
    }

    // 断片の側にあるものを Swift で書いたもの。**式を揃えるためだけに置いてある**
    private func fract(_ value: Float) -> Float { value - value.rounded(.down) }
    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
