<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginContour` の穴が、別の穴の辺の途中に頂点で T 字に触れるとき、離れた穴がもう 1 つあると塗りが大きく欠ける形を直した。三角形に分ける途中で止まり、穴の外の広い範囲が塗られなくなっていた。穴どうしが触れ合う形を 8000 通り試して、誤りは 0 になった。
