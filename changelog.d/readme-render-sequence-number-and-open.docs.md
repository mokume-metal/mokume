<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**README の「動画に書き出す」の詳しい挙動に、連番の番号と `frameCount` の対応と、書き出してすぐ開く書き方を足しました。** 連番の番号は 0 から振るので、`N` 番目のフレーム (`frameCount == N`) は番号 `N - 1` のファイルです (`--fps 60 --seconds 2 --out shots/f-####.png` の最後の `shots/f-0119.png` が `frameCount == 120` の絵)。`mokume render` は書き出しを確かめてから 0 で終わるので、`mokume render … --out motion.mov && open motion.mov` と続ければ、書けたときだけ開けます。
