// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 中心へ寄せて散らす・配列から選ぶ・並べ替える乱数 ([#2419])。
///
/// **見どころは、左の花畑が中心ほど密なこと。** 花の位置を `randomGaussian()` で引いているので、
/// 中心のまわりに寄って咲き、外へ向かうほど疎らになる (`random()` で引くと一様に散る)。花の色は
/// 3 色のパレットから `random(palette)` で選んでいる。
///
/// 右は同じ 12 本の棒を、上の段は低い順に、下の段は `shuffle()` で並べ替えて置いたもの。
///
/// 3 本とも `random()` と同じ列から引くので、`draw()` の頭で `randomSeed()` を置けば、何フレーム目
/// でも同じ花畑と同じ並びになる。Swift の `randomElement()`・`shuffled()` は種に従わず、走らせる
/// たびに絵が変わる ([#2418])。
///
/// [#2418]: https://github.com/mokume-metal/mokume/issues/2418
/// [#2419]: https://github.com/mokume-metal/mokume/issues/2419
final class ChanceAndChoice: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "chance and choice")
    }

    private let palette = [color(240, 90, 60), color(250, 200, 80), color(80, 140, 220)]
    /// 右の棒の高さ。低い順に並べてある。
    private let heights: [Float] = (1...12).map { Float($0) * 16 }

    func draw() {
        // 毎フレーム同じ列から引き直す。置かなければ列はフレームを越えて進み、花畑が毎回変わる
        randomSeed(3)
        background(245)
        noStroke()

        // 左: 中心へ寄って咲く花畑。横の散らばりを縦より広くして、横長の花畑にする
        for _ in 0..<300 {
            fill(random(palette) ?? color(0))
            circle(290 + randomGaussian() * 100, 270 + randomGaussian() * 60, random(6, 18))
        }

        // 右: 同じ棒を、上の段は低い順に、下の段は並べ替えて。渡した配列 (heights) は変わらない
        fill(150)
        for (i, h) in heights.enumerated() {
            rect(620 + i * 26, 250 - h, 20, h)
        }
        fill(80, 140, 220)
        for (i, h) in shuffle(heights).enumerated() {
            rect(620 + i * 26, 500 - h, 20, h)
        }
    }
}
