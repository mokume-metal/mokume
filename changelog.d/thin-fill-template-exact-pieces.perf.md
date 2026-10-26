<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を付けた細い楕円を回転ばらばらに置く絵で、GPU のフレーム時間が、CPU で片を組み直す形とほぼ同じ (差 2% 以内) になりました ([#3178](https://github.com/mokume-metal/mokume/issues/3178))。雛形が持つ片の数を 8 片刻みの区間に丸めていたため、長さ 40 の楕円 (40〜41 片) が 48 片ぶんの頂点を流していた (使わない片も頂点関数と図形の組み立てを通る) のを、置き場所の片の数そのものにしました。release・1280×720・10,000 個で、長さ 40 の楕円は 2.63 ms から 2.45 ms、長さ 8 の楕円は 0.60 ms から 0.555 ms です。絵は変わりません。
