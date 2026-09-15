<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

単色化 (`.monochrome()`)・彩度の調整 (`.adjust(saturation:)`)・にじみのしきい値 (`.bloom(threshold:)`) が測る明るさを、作業空間の Display P3 の原色に合った重みで測るようにしました。これまでは sRGB の原色の重みを P3 の値に掛けていたため、彩度のある色ほど明るさがずれていました (たとえば `color(255, 0, 0)` を単色化すると、同じ明るさの灰色より少し暗く出ていました)。いまは、数で書いた色を単色化すると、その色の相対輝度どおりの灰色になります。

観測の報告の `meanLuminance` も同じ重みで数えるようになり、彩度のある色の絵では値がわずかに変わります。灰色 (赤・緑・青が等しい色) の結果は変わりません。
