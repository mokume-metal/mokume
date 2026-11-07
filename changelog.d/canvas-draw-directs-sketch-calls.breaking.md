<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**スケッチの中の `pg.draw { … }` で素のまま書いた `circle(…)` などが、本体ではなく `pg` へ描かれるようになりました。** 同じ形の `draw(into: pg) { … }` と同じ絵になり、取り違えても絵が黙って割れません。揺らぎの種・時刻・粒の刻みも `draw(into:)` と同じくスケッチのものを読みます ([#3866](https://github.com/mokume-metal/mokume/issues/3866))。

変わらないもの: `pg.circle(…)` と指して書いた呼び出し、`pg.draw` が描き切りの失敗を投げること、`beginDraw()` 〜 `endDraw()` の間の素の呼び出し (本体のまま)、本体の面の `canvas.draw { }`、スケッチの外で `Canvas` を直に使う場合。

移行: `pg.draw { }` の中から素の呼び出しで本体へ描いていたなら、その呼び出しを閉包の外へ出してください。
