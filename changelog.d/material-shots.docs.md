<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

材質の 4 口 (`shininess` / `metalness` / `ambient` / `emissive`) と影の 6 口 (`shadows` / `shadowRange` / `shadowDetail` / `shadowBias` / `castShadow` / `receiveShadow`) に、引数を 1 つずつ動かした例と絵を 10 枚付けた。これで #526 の「立体と光」の 40 口がすべて埋まった。

`ambient` と `emissive` は、絵と説明を**対にして**置いた — 前者は暗い側だけを落として陰影を深くし、後者は明暗を問わず同じ量を足すので陰影を浅くする。`shadowRange` と `shadowDetail` の絵は、**粗さを決めるのが 範囲 ÷ 画素数の比**であることを示している (範囲 8000 と画素数 64 は同じ比で、影の塊も縁の飛びも一致した)。

あわせて `metalness(_:)` と `Material` の説明を直した。「いまは映り込む先が無いので底上げの光を映す」と書いていたが、`surroundings(_:)` が入った時点でこれは古い — 映る先は周囲で、無いときだけ底上げの光になる。
