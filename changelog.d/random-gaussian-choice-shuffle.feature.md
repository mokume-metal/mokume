<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

乱数の口を Processing・p5.js の名前で 3 つ足した。`randomGaussian()` は平均 0・標準偏差 1 の正規分布の値で、`randomGaussian(mean, sd)` は平均と標準偏差を決められる (中心へ寄せて散らす: `circle(width / 2 + randomGaussian() * 120, height / 2, 8)`)。`random(palette)` は配列から 1 つ選び、空の配列なら `nil` を返す。`shuffle(cards)` は並べ替えた新しい配列を返し、渡した配列は変えない (結果を捨てると警告が出る)。

どれも `random()` と同じ列から引くので、`randomSeed()` を決めれば何度走らせても同じ値・同じ並びになる。Swift の `randomElement()`・`shuffled()` は種に従わず、走らせるたびに変わる。`SketchPart` を名乗った自分の型の中からも呼べる。
