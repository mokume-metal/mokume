<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new` が作るスケッチの色が、入口の例と同じ 0–255 の綴り (`background(15, 18, 23)` / `fill(242, 115, 51)`) で書かれるようになった。

これまではひな形だけが `.display(red: 0.95, green: 0.45, blue: 0.2)` の 0–1 の綴りで、README や公開サイトで `fill(242, 115, 51)` を読んだ人が最初に開くファイルの書き方が食い違っていた。見た目の色は変わらない。
