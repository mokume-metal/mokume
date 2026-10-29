<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**断片が、前のフレームの絵を読めるようにした (`ShaderSurface.previousFrame`)。** 残像やフィードバック (前の絵を少し薄めて、回して、描き足す) が、描き場所 2 枚を毎フレーム入れ替えずに書ける。`surfaces: ["last": .previousFrame]` と宣言した断片の中で `mokume_sample(surfaces.last, in.place)` と読む。

「前の絵」は、その面が次のフレームへ持ち越す絵である。フレームの終わりの `effects()` を通す前の絵で (効果を 2 度掛けしない)、`noLoop()` の後の `redraw()` では最後に描いた枚、1 枚目は透明になる。先に `background()` で消してから読んでよい。描き場所で当てれば、その描き場所の前の絵を読む。

払うのは、宣言した断片を当てた面だけで、面と同じ大きさの写し 1 枚と、毎フレーム全面の写し 1 回である。宣言しない面は何も変わらない。参照スケッチは `echo-and-feedback`。
