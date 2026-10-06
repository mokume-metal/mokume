<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`background` の説明に、**本体の面を半透明にしても、窓では後ろが透けない**ことを書きました。窓は面を黒の下地に重ねた色で出すので、`background(0, 20)` は黒一色に、`background(255, 20)` は暗い灰色に見え、窓の後ろにある別の窓は見えません。

不透明度を保つのは、書き出した画像・動画のほうです。出口ごとの不透明度の扱いは [ADR-0023](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md) 決定 4 の表にあります。
