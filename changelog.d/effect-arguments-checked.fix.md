<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

効果 (`effects()`) の引数に数でない値 (NaN) や無限が入ると、フレーム全体が壊れた画素 (多くの機械で黒や透明) になっていたのを直しました。`invert(amount: .nan)` 1 つでも、描き場所の面に掛けて貼った先でも起きていました。そうした効果はその 1 つだけを掛けずに初回だけ警告し、並びの他の効果はそのまま掛けます。`blur(radius: 1e30)` のように有限でも大きすぎる半径も、壊れずに掛かるようになりました。

`amount` は説明どおり 0…1 へ締めるようにしました。これまで 1 を越えた `amount` は 1 より強く効き、`invert` や `vignette` では負の光を作っていました。1 を越えた `amount` の絵は、1 のときと同じになります。
