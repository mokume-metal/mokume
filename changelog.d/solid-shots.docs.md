<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体の 7 口 (`box` ×2 / `sphere` / `plane` / `cylinder` / `cone` / `torus`) と 3D の変換 5 口 (`translate` / `rotateX` / `rotateY` / `rotateZ` / `scale` の奥行きつき) に、引数を 1 つずつ動かした例と絵を 15 枚付けた。`detail` を持つ口は割り方を落とした絵を並べ、回転の 3 口は 3 段階を 1 枚に並べてある。絵を付けられないモデルの 3 口 (`loadModel` / `requestModel` / `model`) には、付けられない理由を説明文に書いた。

あわせて `rotateX` / `rotateY` の説明を直した。「横幅は変わらない」「高さは変わらない」と書いていたが、傾けた板は回転の軸に沿った辺も**遠近のぶんだけ広がる** (実測で 15 % ほど)。
