<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

座標を面と空間のあいだで行き来する 6 口 — `screenX(_:_:)` / `screenY(_:_:)` / `screenX(_:_:_:)` / `screenY(_:_:_:)` / `screenZ(_:_:_:)` / `spacePosition(screenX:screenY:depth:)` — と、切り抜きとスタイルの 4 口 — `clip(_:_:_:_:)` / `noClip()` / `pushStyle()` / `popStyle()` — に、引数を 1 つずつ動かした例と絵を 19 枚付けた。回した枠の角の読みを縦線・横線で見る、傾けた箱のまわりの点を面の位置と奥行きに写して戻す、`depth` だけを動かすと球の大きさが変わる、切り抜きの矩形が面の外へはみ出しても面の内側へ収まり縁の上の画素を通す、`popStyle()` は積んでいなければ何もしない、といった説明文の主張を、絵で見られる。
