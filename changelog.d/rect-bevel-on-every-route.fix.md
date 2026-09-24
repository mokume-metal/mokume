<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

絵を貼って塗る (`texture`) か断片 (`shader`) を効かせた `rect` / `square` を `strokeJoin(.bevel)` の太い輪郭で引くと、**角が削がれず `miter` と同じ尖った角になっていた**のを直しました。`StrokeJoin.bevel` の説明どおり、何も効かせない `rect` はもとから角を 45° で削いでいましたが、`texture` を 1 行足しただけで角の形が変わっていました。いまはどちらの描き方でも、矩形の角は同じ線 (角から太さの半分だけ離れた所を通る 45° の線) で削がれます。何も効かせない `rect` の絵と、`miter` / `round` で引いた絵は変わりません。`triangle` / `quad` / `beginShape` の折れ目は、これまでどおり正方形で埋めます ([#1506](https://github.com/mokume-metal/mokume/issues/1506))。
