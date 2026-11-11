<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描いた画面を新しい `Image` にして取っておけるようになった。`get()` で画面の全体を、`get(x, y, w, h)` と `get(in: Rect)` で領域を取る (Processing の引数なしの `get()` と `get(x, y, w, h)` に当たる)。描き場所 (`createGraphics`) にも同じ形があり、描き終えた後でも読める。取った絵は画面と独立していて、後で描き足しても次のフレームになっても変わらないので、`image(shot, x, y)` で好きな所へ置き直せる。

領域と返す絵の大きさは座標の単位で数える。1 画素の `get(x, y)` は実際の画素で数えるので単位が違う。書き出しの倍率 (`mokume render --scale`) の下では細部が落ちる (光の量で平均して縮める) が、置き直せば元の位置と大きさに重なる。画面をはみ出す部分は透明になり、幅か高さが 1 を割る領域は `createImage` と同じく `ImageFailure.unplaceable` を投げる。3 つとも投げる API なので `try` を付けて呼ぶ (`setup()`・`draw()`・入力のコールバックの外では `ImageFailure.notRunning`)。
