<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

断片 (`loadShader` ほか) と効果 (`makeEffect`) の案内に、`in.color`・`texel` は線形・アルファ乗算済みで、返す色も乗算済みで返す、という注意を足した。不透明度を変えるときは `in.color * 0.3` のように 4 成分に同じ数を掛ける。`float4(in.color.rgb, 0.3)` と書くと乗算済みの約束が崩れて、下地を越えて光る。`ShaderValue.color` と、`PixelBuffer.components` の説明にも同じ言い方で注意を書いた。名前と振る舞いは変わらない。
