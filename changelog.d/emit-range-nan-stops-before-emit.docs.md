<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`emit` の説明に、幅 (`speed`・`angle`・`life`・`size`) の端に数でない値 (NaN) を書くか下端が上端を越えると、`emit` に届く前に Swift の `...` がプロセスごと止めることを書きました。これまでの説明は「幅の端が数でない値なら 1 個も出さない」と読めましたが、その値は mokume の受け口まで届きません。計算した値を端に使うときは、幅を作る前に `isFinite` と大小を確かめてください。`min(a, b)...max(a, b)` は逆順は防ぎますが NaN は防ぎません。

口の形 (`ClosedRange<Float>` で受ける) は変えません。判断は [ADR-0035](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md) 決定 5 の改訂にあります。
