<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**保存したつまみの値 (`.mokume/state/params.json`) に読めない値が 1 件あっても、その 1 件だけを捨て、残りは戻すようになりました。** これまでは知らない `type`・`1e400` のような大きすぎる数・整数でない `int` が 1 件あるだけで保存全体を捨てて既定値から始まり、`.mokume/params/report.json` の最初の応答の `discarded` にも何も載りませんでした。

いまは読めなかった 1 件を名前と理由 (`typeMismatch` / `notFinite`) つきで `discarded` に載せ、標準エラーにも 1 行で言います (宣言が変わったせいとは言いません)。保存が在るのにそのものが読めない (ファイルとして開けない・JSON でない・`values` が配列でない) ときは、名前の無い `typeMismatch` を 1 件載せます。
