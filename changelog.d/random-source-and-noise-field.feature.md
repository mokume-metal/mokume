<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**乱数の列を値として持てる `RandomSource` と、種と細かさを値として持つ揺らぎ `NoiseField` を追加し、Swift 標準の `randomElement()`・`shuffled()`・`Float.random(in:)` が種に従わないことを案内した** ([#2418](https://github.com/mokume-metal/mokume/issues/2418))。`RandomSource(seed: 7, index: i)` は花ごと・部品ごとに独立した列で、スケッチの `random()` を何回引いても動かない。`RandomNumberGenerator` に適合するので、Swift 標準の口に `using:` で渡せる。

```swift
flowers = (0..<200).map { i in
    var r = RandomSource(seed: 7, index: i)           // 花ごとに独立した列
    return Flower(x: Float.random(in: 0..<width, using: &r),
                  y: Float.random(in: 0..<height, using: &r),
                  tint: palette.randomElement(using: &r)!)
}
```

スケッチの列は `randomSource` として出る。`palette.randomElement(using: &randomSource)` は `randomSeed(_:)` と同じ列を引き、引いた分だけ次の `random()` が変わる。新しい乱数源を代入すると種を書いたのと同じで、形の組み立て (`createShape`) の中なら抜けると外へ残らない。**`using:` を省いた Swift 標準の口は、これまでどおり種に従わず、走らせるたびに絵が変わる。** 種の無い `init()` は置かない — 時刻から種を作る道を置くと、同じ入力から同じ絵にならず、記録した入力の再生でも再現できない。

`NoiseField(seed: 100, octaves: 4, falloff: 0.5).value(x, y)` は、同じ種と細かさのスケッチの `noise(x, y)` と同じ値を返し、スケッチの `noiseSeed(_:)` に触れない (板ごと・タイルごとに別の種で引ける)。断片の `mokume_noise` は、これまでどおりスケッチの種を読む。ドキュメントの「数の型」と、新しいスケッチに入る `AGENTS.md` に、種に従わない標準の口の案内を足した。参照スケッチ `seeds-and-fields` が、塵が点いたり消えたりしても 200 本の花が動かないことを示す。
