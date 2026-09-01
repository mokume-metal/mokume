<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

変換の口で唯一残っていた `applyMatrix` に、例と絵が付きました。渡す `Transform` は `Transform.identity` から積み上げて作ります。

`translate` や `rotate` を並べて呼ぶのと**結果は同じ**で、違うのは一連の変換を**値として持てる**ことです。移動・回転・縮小をまとめた 1 つの値を作り、図形を描くたびに重ねる例を並べて、その差が絵で見えるようにしました。

`Transform` 型の説明にも、組み立ての起点が `identity` であることを書きました。
