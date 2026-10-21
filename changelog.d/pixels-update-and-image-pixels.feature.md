<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画素の面 `pixels` に、全画素を 1 つの関数で書き換える `pixels.update { x, y, color in … }` を追加した。閉包は位置と元の色を受けて、書く色を返す。書いてよいかの判定と GPU の決着を入口で 1 回しか行わないので、`pixels[x, y]` の 2 重ループで同じことを書くより速い。意味は添字と同じで、置いてよい区間の外と形の組み立ての中では、閉包を呼ばずに 1 度注意して何もしない。

`Image` にも `pixels` を追加した。`Canvas.pixels` と同じ `Pixels` を返すので、カメラの絵を `camera.image.pixels.update { … }` で書き換えられる (`Image` は参照型なので、書き換えは同じ 1 枚を変える。取っておくなら先に `copy()` する)。
