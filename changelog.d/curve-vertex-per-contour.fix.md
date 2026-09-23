<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginContour()` の中で `curveVertex` を使って描いた穴が、外周の点に引かれて欠けなくなりました。これまで通過点の曲線の並びは `beginShape` から `endShape` まで 1 本に続いていたので、穴の最初の 2 区間は外周の点を端点にして引かれ、穴の輪郭が外周の上から始まっていました (線を引くと、穴から外周まで伸びた線として出ていました)。外周に点がある形では、穴の中で最初に引く区間の始点 (2 つ目に置いた点) も穴に置かれず、閉じない曲線の穴の書き始めが欠けていました。

いまは**並びが `curveVertex` を続けて呼んでいる間だけ続き**、`vertex` / `bezierVertex` / `quadraticVertex` を挟むか、穴の境目 (`beginContour()` / `endContour()`) で切れます。次の区間はまた 4 つ揃ってから引かれるので、`curveVertex` を置いた後に `vertex` を挟んで `curveVertex` を足しても、前の曲線の点へ逆戻りする区間が出なくなりました。穴の中の曲線は外周と独立に始まり、穴を閉じた後に外周へ置いた `curveVertex` も穴の点を引き継ぎません。穴の最初に呼んだ `bezierVertex` / `quadraticVertex` は、外周の最後の点から曲線を引かず、形の中で手前に点が無いときと同じく何もしません。
