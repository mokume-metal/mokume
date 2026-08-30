<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

利用者が書いた断片へ、**面を名前で渡せる**ようにした (`loadShader` / `makeShader` の `surfaces:`)。渡した面は断片から `surfaces.<名前>` で読め、読み方は組み込みと同じ規則の `mokume_sample(surfaces.grain, in.uv)` で書ける。これまで断片が読める面は「これから描く塗りに貼った 1 枚」だけだったので、**焼いた木目と汚しを掛け合わせる**ような塗りは書けず、断片の中で模様を作り直すしかなかった。

渡せるのは**読み込んだ絵 (`.image(_:)`) と、自分で描いた面 (`.graphics(_:)`) の両方**で、1 つの断片につき 4 枚まで。値と同じく名前は読み込むときに決め、面だけを後から差し替える (`shader.set("grain", .image(bark))` — 差し替えは列を閉じてから効くので、既に置いた図形が後の面で描かれることはない)。上限を超えた宣言は読み込みの時点で断る。

**面を宣言していない断片は 1 つも書き換えなくてよい。** これまでどおり `paint(Fragment, Values)` のまま動き、組み上がる原稿も絵も変わらない。

書ける形は参照スケッチ `surfaces-and-blend` にある (`swift run reference-sketches surfaces-and-blend`)。
