<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Vector2` に、向きだけを取り出す `normalized()` と、長さに上限を掛ける `limited(to:)` を追加した。マウスへ引き寄せられて速さの上限で回り込む点が `import simd` なしで書ける (`velocity = (velocity + (Vector2(mouseX, mouseY) - position).normalized() * 0.5).limited(to: 4)`)。Processing の `normalize()` と `limit()` に当たり、どちらも自分を書き換えず新しい値を返す。

`normalized()` は長さ 0 の値を変えずに返し、0 で割って数でない値を絵に流さない。**`limited(to:)` は上限が 0 以下なら `Vector2(0, 0)` を返す。** Processing の `limit()` は上限が負だと向きが反転するが、速さの上限に負の意味は無いので反転させない。どちらも `Sketch` の外 (通信の完了ハンドラなど) からも呼べる。
