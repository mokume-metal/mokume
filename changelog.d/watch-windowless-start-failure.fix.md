<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が、窓を出せない環境で起こしたスケッチや、道具の窓へ差し出せず自分の窓に倒れたスケッチが、最初の絵を出す前に失敗で終わったとき、「自分で消えた (絵は止まった場所のまま)」ではなく「起動できなかった」と名乗るようになりました。端末の行と `build_status` (`.mokume/build/status.json`) の言葉は、窓のあるときの起動失敗と同じです。スケッチは起動の頭で区画 `build` に印を置き、最初の絵を出したら消します。印が残ったまま終わったものを、見張りは最初の絵の前に終わったと読みます。
