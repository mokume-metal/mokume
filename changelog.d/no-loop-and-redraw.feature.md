<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチの中から進行を止める `noLoop()`、戻す `loop()`、止めたまま 1 枚だけ描き直す `redraw()` を追加しました。これまでは `draw()` が必ず毎フレーム呼ばれ、「1 度だけ描いて止まる」絵を書く手立てがありませんでした。

**`setup()` で `noLoop()` を呼んでも、`draw()` は 1 度だけ呼ばれます。** 止まっている間は絵もフレーム番号も変わらず、続けて書き出した絵は同じバイト列になります。

**止まっていても入力は届きます。** `mousePressed()` から `redraw()` や `loop()` を呼べば、押したそのフレームで描き直されます。観測の要求にも、フレームを進めずに応えます。

ホストが `SketchRuntime.pause()` / `resume()` で止めて再開しても、スケッチが `noLoop()` で止めた状態は覆りません。
