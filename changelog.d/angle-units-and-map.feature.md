<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

角度の単位を直す `radians()` / `degrees()` と、値を別の範囲へ写す `map()` を追加した。度で考えた絵はそのまま書けるようになり (`rotate(radians(45))`)、面の座標から個数や大きさを出すのに毎回割り算を書かなくてよくなる (`map(mouseX, 0, width, 6, 60)`)。

どれも `Sketch` の外からも呼べる。**単位を切り替える状態は持たない** — `angleMode()` は無く、単位は呼んだ 1 行から読める。`map()` は範囲の外を丸めずそのまま伸ばし、写す元の幅が 0 のときや数でない値が混じったときだけ、写した先の下端を返して 1 度だけ注意を言う (絵へ NaN を通さないため)。
