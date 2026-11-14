<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

断片が、立体の**世界の座標での位置**と、**光を通す前の色**を受け取れるようになった。`Fragment` の `worldPosition` (置き場所の変換を通した後・視点を通す前の位置で、光が当たる位置と同じ) と `baseColor` (`fill()`・頂点の色・置き場所の色を掛けた、光と材質を通す前の色。線形・アルファ乗算済み) がそれである。これまで立体の `in.color` には光を通した後の色しか届かなかったので、トゥーンや点光源風の陰影を自分で書くには `noLights()` で光を切り、色を値に詰めて渡す回避が要った — いまは `lights()` のまま `in.baseColor` と `in.worldNormal` から段を付けて書ける (作例はトゥーンの球 `toon-and-bands`)。`worldPosition` は平面の図形では 0、`baseColor` は光も周囲も効かない形 (平面・光も周囲も置いていない立体・立体の線と点) では `color` と同じ値になる (`noLights()` の下でも、周囲を置いた立体では違う)。立体の線と点の `worldPosition` は線の芯ではなく、画面の画素で広げた帯の上の位置なので、視点の奥行きや倍率で線の太さの程度だけ動く。`worldPosition` はスケッチの座標なので、書き出しの倍率 (`--scale`) でも変わらない。既存の断片と絵は変わらない。断片の `in.time` の説明に、長く走らせたときの刻みの上限 (約 1.5 日で約 15.6 ms) と、周期のある動きは `phase(period:)` の位相を値で渡すことを書いた。
