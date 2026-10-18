<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**断片の入口 (`paint`・`effect`・計算の `kernel void`) の名前や引数を書き違えたとき、理由の 2 行目で期待する入口の形を言うようになり、計算ではプロセスが落ちなくなりました。** これまで塗りと効果は `Undefined symbol(s)` と `_Z5paint8Fragment6Values` のような内部の記号の名前だけで、書いた断片のどこも指しませんでした。いまは `shader: error: the fragment does not define its entry point float4 paint(Fragment in, Values values). …` の 1 行が先に出て、Metal の文面はその下に残ります。`surfaces:` を渡したのに 2 引数の `paint` を書いた (またはその逆の) ときは、要る引数の形を言います。計算は `name:` (ファイルならファイル名) と同じ名前の `kernel` 関数が断片に無いと、作るときも保存して差し替えるときもプロセスごと落ちていましたが、いまはその名前の入口が無いという理由で失敗として返ります。

**`values:`・`surfaces:` に断片の中で書けない名前を渡すと、組み立ての前に名指しで断るようになりました。** 受けるのは文字か `_` で始まり、文字・数字・`_` が続く名前で、`波` のような ASCII の外の文字も今までどおり使えます。これまで `"tint color"` のような名前は `mokume/Values:2:15: error: expected ';'` と本体の前置きの名で出て、空の名前や `;` を含む名前は誤りにならずに組み上がり、断片が別の値を読んでいました。いまは `shader: error: the name "tint color" in values: …` の 1 行で、渡した口と名前を言います。字の並びは通っても Metal で使えない名前 (`half`・`float` のような予約語や型、本体のマクロの `MOKUME_SURFACES` など) も、組み立ての誤りの前に `shader: error: the name "half" in values: cannot be used in Metal …` と名指しします。`$` を含む名前など、これまで Metal が通していた記号入りの名前も断ります。
