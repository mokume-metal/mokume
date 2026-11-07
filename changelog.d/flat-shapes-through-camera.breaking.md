<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`rect`・`circle`・`text`・`image` などの 2D の図形も、`camera`・`orbitControl`・`perspective`・`ortho` の視点と、変換の奥行き (`translate(x, y, z)`・`rotateX`・`rotateY`) を通って描かれるようになりました ([#3830](https://github.com/mokume-metal/mokume/issues/3830))。Processing の P3D と同じで、奥行き 0 に置いた立体と同じ座標の 2D の図形は、視点を動かしても重なります。これまでは 2D の図形だけが視点を無視し、変換の奥行きも捨てて、画面の同じ位置に残っていました。

| 書き方 | これまで | これから |
| --- | --- | --- |
| `camera(...)` の後の `rect(100, 60, 60, 60)` | 画面の (100, 60) に残る | 同じ座標の `plane` と一緒に、視点に合わせて動く |
| `translate(0, 0, 60)` の後の `rect(...)` | 奥行きを捨てて同じ大きさ | 手前に出て大きく写る |
| `rotateY(HALF_PI)` の後の `rect(...)` | 横に潰れて線になる | 空間の壁に貼った板として、横からの視点で見える |
| 視点を指定しない・`camera()` で戻した後の、奥行き 0 の 2D | — | これまでと同じ絵 |
| 視点を決めた下の `screenX(x, y)`・`screenY(x, y)` | 変換の x・y | 奥行き 0 の点として視点を通した位置 (`screenX(x, y, 0)` と同じ) |

重なりはこれまでどおり呼び出し順で、2D の図形は立体の奥行きに隠れません (P3D とはここが違います)。切り抜き (`clip`) は、これまでどおり画面の上で効きます。視点を通る 2D の図形は、`save("….svg")` の線の書き出しには書かれず、書けなかったものとして名乗られます。

移行: 視点を決めた後に、得点や説明の文字・照準などを画面に重ねて描いているなら、重ねる前に視点を戻してください。

```swift
camera(400, 40, 300, 160, 120, 0, 0, 1, 0)
// …立体を描く…
camera()         // 視点を戻す
perspective()    // perspective(…) や ortho(…) で写し方も変えていたなら、写し方も戻す
text("score: 12", 20, 30)
```

`screenX(x, y, z)`・`screenY(x, y, z)` で立体の画面の位置を求めて、そこへ字を置いている書き方も同じで、位置を求めた後・字を描く前に `camera()` (写し方を変えていれば `perspective()` も) を書きます。

影 (`shadows(true)`) を使う作品では、HUD の前に視点を戻すと、影の位置がわずかに動くことがあります。影を焼く範囲の中心が、フレームの終わりの視点の注視点で決まるためです ([#3842](https://github.com/mokume-metal/mokume/issues/3842))。
