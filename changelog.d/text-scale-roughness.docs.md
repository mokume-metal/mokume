<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`textSize()` と `text()` の説明に、`scale()` で伸ばした字は焼いた画素の拡大になって縁がぼけること、大きく鮮明に出すなら伸ばさずに `textSize()` を上げることを書きました。`textSize(16)` を `scale(20, 20)` で伸ばした `a` は、`textSize(320)` の `a` とほぼ同じ大きさに出ますが、墨の色まで届く画素がほとんど残りません。大きさの種類を絞るための「同じ大きさで書いて `scale()` で伸ばす」という助言にも、この代償を並べました。

`textOutline()` の説明に、曲線の細かさは `textSize()` の寸法で決まり、`scale()` などの変換では変わらないことを書きました。拡大して描く輪郭は `textSize()` を大きくして取り出すほうが細かく、既定の書体の `a` では `textSize(320)` で取り出すと `textSize(16)` の 5 倍あまりの点になります。
