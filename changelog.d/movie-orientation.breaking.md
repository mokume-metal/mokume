<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createVideo(_:)` で開いた動画が、縦に撮った動画 (iPhone など) を正しい向きで映すようになりました ([#2451](https://github.com/mokume-metal/mokume/issues/2451))。動画ファイルが持つ回転の印 (`preferredTransform`) を当てるので、これまで横倒しで映っていた縦の動画が起き上がり、`Movie.width`・`Movie.height`・`Movie.image` の大きさも、当てた後の値 (縦と横が入れ替わったもの) になります。90° 刻みの回転と左右・上下の反転を当て、斜めの回転など向きとして読めない印は、これまでどおり記録された向きのまま映します。

| | これまで | これから |
| --- | --- | --- |
| 縦に撮った動画 (1920×1080 に 90° の印) | 横倒しで映る。`width` は 1920・`height` は 1080 | 起きて映る。`width` は 1080・`height` は 1920 |
| 印の無い動画 | そのまま | 変わらない |

移行: 動画の向きを自分で直していた (`rotate` を掛ける、`width`/`height` を入れ替えて使う、など) スケッチは、その補正を外してください。外さないと二重に回ります。
