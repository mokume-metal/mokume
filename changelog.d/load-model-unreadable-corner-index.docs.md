<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` の説明と `Model.skippedLines` の説明に、OBJ の面の角で読み取り位置 (`vt`) や向き (`vn`) の番号が数として読めない・範囲の外のとき、その角にその番号を書いていないのと同じに読み、面は描いて読み飛ばした行には数えないことを書いた。向きの番号が読めない角は、向きを書かない角と同じく形から求めた向き (両面) になる。読み方は変えていない。
