<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

字の輪郭から `Path` を作れるようにした。`Path(textOutline("mokume", 60, 320))` で、字の周を並んだ順に 1 本の道として持ち、`point(at:)` は外周を辿った後に穴へ渡り、`contains(_:)` は `o` や `e` の穴の中を外側、輪の上を内側と答える。既定の書体の `A` のように重なった外周で返る字も、重なりの中まで内側として読める。参照スケッチ `type-and-path` (`swift run reference-sketches type-and-path`) で、字の輪郭を等間隔の粒が回り、ポインタが字の墨の上に入ると字が明るくなる様子が見られる。
