<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`setup()` と、`noLoop()` で止まっている間の入力のコールバックで、`translate()` などの変換と、`push { }`・`pushMatrix()` / `popMatrix()`・`pushStyle()` / `popStyle()` の積み降ろしが効くようになった。`setup()` で `translate(100, 100)` してから `circle(0, 0, 40)` を置くと、円は (100, 100) に出る (これまでは警告して変換を無視し、原点に出ていた)。Processing の `Basics/Color/ColorVariables`・`Basics/Form/PointsLines` のように `setup()` で位置をずらして描く例が、そのまま書ける。

変換は、区間の中で置いたものに焼き付き、**呼び出しを抜けるときに戻る**。`draw()` へも次のコールバックへも持ち越さない (`setup()` で `translate()` だけ書いて何も置かないと、そう言って 1 度知らせる)。光・視点・材質・切り抜きなどは、`setup()` でもこれまでどおり警告して無視する。

**いま `setup()` で変換を書いている作品は、絵が動く。** これまでは毎回 `translate()` の警告を受けながら、変換の無い絵が出ていた。警告は出なくなり、書いたとおりの位置に出る。位置が意図と違って見えたら、`setup()` の中の `translate()`・`rotate()`・`scale()` を見直す。

ループ中 (と `redraw()` を頼んだ後) の入力のコールバックは、フレームの内側で配られるので、書いた変換が同じフレームの `draw()` に漏れる。これは以前からの振る舞いで、この版では変えていない。揃えるかは別の課題として扱う。`setup()` や止まっている間のコールバックで `canvas.draw { }` を開いて閉じた後も、区間で書いた変換と積み履歴は続く。
