<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**ブロック崩しの作例 `bricks-and-ball` を足した** (`swift run reference-sketches bricks-and-ball`)。矢印でパドルを動かし、球でブロックを消すとスコアが 10 ずつ増え、球を落とすと 1 秒 (60 フレーム) 置いて出直す。球は 3 つで、尽きるか全部消したら return で最初から。

ゲームの書き味に入れた口 — 図形の値 (`Rect`・`Circle`・`Vector2` と `intersects`)・`keyboard.isPressed` / `justPressed`・フレームの時計 (`SketchSettings(clock: .frames)`)・`Countdown` — だけで書いてあり、押下の印も当たり判定も自分では書いていない (壁も `Rect` で置いて当てる)。コードは教える順の 3 段 (関数で描く → 値で判定し、描くときは `fill()` に従わせる → 物体ごとに見た目を持たせる) に分けて `// MARK:` で段を名乗る。当たった音は `setup()` で作った合成音を使い回して鳴らす (当たるたびに作ると、作れる 64 個を使い切る)。
