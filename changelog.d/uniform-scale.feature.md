<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

縦横と奥行きを同じ倍率で伸ばす `scale(s)` を追加した。`scale(2, 2)` や `scale(s, s, s)` と軸の数だけ同じ値を書かずに、Processing と同じ `scale(2)` や `scale(0.5)` で書ける。

`scale(s, s, s)` と同じ変換を積むので、平面だけを描いているときは `scale(s, s)` と同じ絵になり、立体を置くときは奥行きも一緒に伸びる。負の値は反転で、0 は潰れる。
