<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

有限だが巨大な `textSize` (`1e20` など) で `text` を描くと、プロセスごと落ちていたのを直しました。焼き場に入らない大きさとして「大きすぎる」を 1 度知らせ、字を置かずに通ります。`textOutline` も、位置に数でない値や無限を渡すと空を返し、巨大な大きさでは落ちずに大きい字と同じ細かさの輪郭を返します。`textSize` に無限を渡したときは、NaN や負の値と同じく大きさ 0 として扱います (これまでは `textAscent()` などが無限を返していました)。
