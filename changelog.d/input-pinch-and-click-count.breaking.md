<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

トラックパッドのピンチと押した回数 (ダブルクリック) が、スケッチへ届くようになった。ピンチはフレームの合計を `pinch` で読める (開くと正、閉じると負で、0.1 は「1.1 倍に開いた」)。`orbitControl()` は、ピンチで寄り (開いた倍率の分、距離が `1 / (1 + pinch)` 倍) 、左ボタンのダブルクリックで、最初に `orbitControl()` を呼んだフレームの視点 (`setup()` で `orbit` に書いた視点か、既定の視点) へ戻る。戻すと慣性の速さも 0 になる。外から送る線は `{"type": "pinched", "amount": 0.1}` と、押下の `clickCount` (省くと 1) を運べる。

**公開の `InputEvent` を広げたので、破壊的な変更である。** `InputEvent` に場合 `pinched(amount:)` を足し、`mouseDown` に押した回数 `clickCount` を足した。**移行**: `InputEvent` を網羅して `switch` していたなら、`.pinched` の場合を足す。`.mouseDown(let x, let y, let button)` と位置で取り出していたなら、`.mouseDown(let x, let y, let button, _)` と書くか、欄の名前で取り出す。値を組み立てる側は、`clickCount` の既定が 1 なので書き換えなくてよい。
