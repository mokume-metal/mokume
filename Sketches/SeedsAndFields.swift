// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 値として持つ乱数源 (`RandomSource`) と揺らぎ (`NoiseField`) ([#2418])。
///
/// **見どころは、左の 200 本の花が、背景の塵が点いたり消えたりしても 1 本も動かないこと。** 花は
/// 1 本ずつ自分の乱数源 (`RandomSource(seed: 7, index: i)`) で位置と色を決めるので、スケッチの列
/// (`random()`) を何回引いても影響されない。塵は 1 秒ごとに点いて消え、スケッチの列
/// (`randomSource`) で引くので、点くたびに別の場所に出る。Swift 標準の `Float.random(in:using:)`・
/// `randomElement(using:)` に乱数源を渡しているので、`using:` を省いたときのように走らせるたびに
/// 絵が変わることもない。
///
/// 右の 4 枚の板は、板ごとに別の種の `NoiseField` で木目を引いたもの。スケッチの `noiseSeed()` には
/// 触れない。
///
/// [#2418]: https://github.com/mokume-metal/mokume/issues/2418
final class SeedsAndFields: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "seeds and fields")
    }

    /// 1 本の花。検査が位置と色を読むので、`private` にしない。
    struct Flower: Equatable {
        let x: Float
        let y: Float
        let tint: Color
    }

    private let palette = [color(240, 90, 60), color(250, 200, 80), color(80, 140, 220)]
    private(set) var flowers: [Flower] = []
    /// 板ごとの揺らぎ。種だけが違う。
    private let planks = (0..<4).map { NoiseField(seed: 100 + $0) }

    func setup() {
        flowers = (0..<200).map { i in
            var r = RandomSource(seed: 7, index: i)  // 花ごとに独立した列
            return Flower(
                x: Float.random(in: 20..<460, using: &r),
                y: Float.random(in: 20..<520, using: &r),
                tint: palette.randomElement(using: &r)!)
        }
    }

    func draw() {
        background(245)
        noStroke()

        for flower in flowers {
            fill(flower.tint)
            circle(flower.x, flower.y, 14)
        }
        // 塵は 1 秒おきに点いて消える。スケッチの列で引くので、点くたびに別の場所に出るが、
        // 花は自分の列で決まっているので動かない
        if frameCount % 120 < 60 {
            fill(60, 60, 70, 160)
            for _ in 0..<50 {
                circle(
                    Float.random(in: 0..<480, using: &randomSource),
                    Float.random(in: 0..<height, using: &randomSource), 3)
            }
        }

        // 右: 板ごとの種で、木目を引く。板どうしの種だけが違う
        for (i, plank) in planks.enumerated() {
            let top = 30 + Float(i) * 125
            for x in stride(from: Float(520), to: 940, by: 4) {
                for y in stride(from: top, to: top + 110, by: 4) {
                    let grain = plank.value((x - 520) * 0.012, (y - top) * 0.09)
                    fill(150 + grain * 90, 100 + grain * 60, 60 + grain * 30)
                    rect(x, y, 4, 4)
                }
            }
        }
    }
}
