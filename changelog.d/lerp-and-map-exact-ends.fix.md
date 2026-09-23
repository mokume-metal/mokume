<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`lerp()` と `map()` が、端をちょうど返さなかったり、有限の値から数でない値を返したりしていたのを直しました。** `lerp(1e8, 1, 1)` が 1 ではなく 0 を返し、ふつうの値でも `lerp(571.23236, 44.24578, 1)` が 44.24579 になるなど、`amount` が 1 でも `stop` に戻らないことがありました。`map()` も同じで、元の範囲の上端を写しても写した先の上端に戻らないことがありました。また端の差が `Float` で表せない組 (`lerp(-3e38, 3e38, 0.5)` や `map(0, 0, 1, -3e38, 3e38)`) では ∞ や NaN が返り、絵が黙って消えることがありました。いまは `amount` が 0 なら `start`、1 なら `stop` が**ちょうど**返り、端が有限で `amount` が 0…1 なら、いつでも有限の値が端の間で返ります (`map()` も元の範囲の中の値なら同じ)。0…1 の外は今までどおり締めず、伸びた先が `Float` を越えたときだけ ±∞ になります。端以外のふつうの値は 1 ビットも変わりません ([#1453](https://github.com/mokume-metal/mokume/issues/1453)・[#1476](https://github.com/mokume-metal/mokume/issues/1476))。
