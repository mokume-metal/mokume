<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

窓の大きさを `var settings: SketchSettings { .size(800, 600) }` と、型の名前を繰り返さずに書けるようにした (`SketchSettings.size(_:_:frameRate:title:)`)。`.fullScreen()` と同じ書き方で、Processing の `size(w, h)` に当たる。

1 秒あたりのフレーム数と窓の題名は `.size(640, 360, frameRate: 30, title: "Waves")` と続けて渡せる。描く細かさや窓の倍率など、ここに無い設定は従来どおり `SketchSettings(…)` を使うか、返った値へ代入して変える。
