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
/// 下の帯の稜線は 1 次元の `noise(x)` で引いてある。その上に乗る粒は `random()` で置き、
/// `randomSeed()` を置いてあるので、走らせるたびに同じ並びが出る。粒の向きは稜線の
/// 傾きから `atan2` で求め、明るさは 3 つ目の座標に時刻を渡した `noise(x, y, z)` で
/// 移ろわせている — **動くのはこの明るさだけ**で、ほかは何フレーム目でも同じ絵になる。
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
    private let early = color(209, 163, 112)
    private let late = color(117, 76, 46)
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
        background(23, 23, 28)
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

        // 下: 1 次元の揺らぎで引いた稜線。**近い x には近い高さ**が返るので、
        // 4 画素ごとに引いて結んでも線は途切れない
        stroke(209, 163, 112, 140)
        strokeWeight(1.5)
        var previous = (x: Float(20), y: ridge(20))
        for x in stride(from: Float(24), through: 940, by: 4) {
            line(previous.x, previous.y, x, ridge(x))
            previous = (x, ridge(x))
        }
        noStroke()

        // 稜線に乗る粒。種を決めてあるので、走らせるたびに同じ並びが出る
        randomSeed(7)
        for _ in 0..<60 {
            let x = 20 + random(920)
            let y = ridge(x)
            let size = random(6, 18)
            // 太さの割合。0…1 の値を引いて、使いたい幅へ移す
            let thickness = lerp(0.55, 0.85, random())
            // 稜線の傾きを向きに直し、粒を稜線に沿って寝かせる
            let slope = atan2(ridge(x + 1) - ridge(x - 1), 2)
            // 3 つ目の座標に時刻を渡すと、同じ粒の明るさが**瞬かずに**移ろう
            // (毎フレーム `random()` で選び直すと瞬く)。揺らぎは 0.5 のまわりに
            // 寄るので、広げてから使う
            let glow = constrain(map(noise(x * 0.02, y * 0.02, time * 0.8), 0.3, 0.7, 0, 1), 0, 1)
            fill(.display(red: lerp(0.45, 1, glow), green: lerp(0.3, 0.85, glow), blue: lerp(0.2, 0.5, glow)))
            push()
            translate(x, y)
            rotate(slope)
            ellipse(0, 0, size * 1.6, size * thickness)
            pop()
        }
    }

    /// 下の帯の稜線の高さ。**1 次元の揺らぎ**で、同じ x には何度呼んでも同じ高さが返る。
    private func ridge(_ x: Float) -> Float { lerp(448, 532, noise(x * 0.014)) }

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
            premultipliedRed: lerp(early.red, late.red, lateness) + fibre,
            green: lerp(early.green, late.green, lateness) + fibre,
            blue: lerp(early.blue, late.blue, lateness) + fibre,
            alpha: 1)
    }

    // 断片の側にあるものを Swift で書いたもの。**式を揃えるためだけに置いてある**
    // (断片の `mix` / `clamp` にあたるものは `lerp` / `constrain` がそのまま使え、
    // `smoothstep` は断片と同じ名前・同じ式のものがある)
    private func fract(_ value: Float) -> Float { value - value.rounded(.down) }
}
