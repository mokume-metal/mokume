<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shadows(true)` のまま向きを持つ光 (`directionalLight()`) が 1 本も無い状態でフレームを終えると、影が黙って消えていたのを、初回だけ警告で知らせるようにしました。影はフレームの終わりに 1 度だけ、そのときに置かれている光から焼くので、手元の表示を描く前置きとして `draw()` の末尾で `noLights()` を呼ぶと、それより前に置いた立体の影まで丸ごと消えます。`shadows(_:)` と `noLights()` の説明にもこのことを書き足しました。
