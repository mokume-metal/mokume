<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

円周率の定数 `PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` を追加した。Processing・p5.js と同じ綴りで、`rotate(HALF_PI)` や `map(i, 0, 12, 0, TWO_PI)` が `import mokume` だけで書ける。

数を受ける口は型を決めないので、`.pi` だけでは `ambiguous use of 'pi'` で組めない。これらは `Float` の定数で、型を名乗らずに渡せる。`Float.pi` もこれまでどおり使える。自分で `let PI` と宣言すれば、その範囲では自分の宣言が使われる。
