<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

有限だが巨大な `textSize` (`1e20` など) で `text` を描くと、プロセスごと落ちていたのを直しました。`textOutline` も、位置に数でない値や無限を渡すと空を返し、巨大な大きさでも落ちなくなりました。

あわせて、`textSize` と `textLeading` の受け取り方を揃えました。数でない値・無限は 0 として、`1e18` を越える値は `1e18` として扱い、1 度だけ知らせます。これまでは、無限や極端に大きな値を渡すと、`textAscent()`・`textWidth()` が無限を返したり、矩形へ流し込む `text` が高さ NaN の行を置いたと答えたり、下揃え・中央揃えの輪郭が NaN の点を返したりしていました。巨大な字や原点から遠い位置の輪郭で、穴 (`isHole`) がすべて外周として返っていたのも直しました。
