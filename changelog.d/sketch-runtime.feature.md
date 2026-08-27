<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチを書けるようになりました。`Sketch` に準拠して `setup()` と `draw()` を実装すると、フレームごとに描画が呼ばれます。描画の関数は直接呼べて、`frameCount` / `time` / `deltaTime` も同じように読めます。時刻はフレーム番号から導く既定と、実際に流れた時間の 2 通りから選べます。前者では同じスケッチを 2 回走らせると同じ絵になります。
