<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描く画素で 1 画素より細い平面の線 (細かさ 0.5 の既定の `strokeWeight(1)` など) を引く時間が、頂点の多い輪郭で大きく減った。頂点 1 万の `beginShape()` の輪郭は、細かさ 0.5 で 1 フレーム 29 ms ほどかかっていたのが、細かさ 1 と同じ桁になる。細い線も 1 つの図形の線全体を 1 回だけ混ぜるようになり、自己交差の交点が濃く出なくなった。
