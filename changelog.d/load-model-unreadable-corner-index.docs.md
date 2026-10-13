<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` の説明と `Model.skippedLines` の説明に、OBJ の面の角で読み取り位置 (`vt`) の番号が数として読めない・範囲の外のとき、その角に `vt` を書いていないのと同じに読み、面は描いて読み飛ばした行には数えないことを書いた。読み方は変えていない (向き `vn` の番号の同じ読み方は、書いていない角の向きを直す #2342 の後に検査で固める)。
