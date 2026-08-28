<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape()` から `endShape()` の間で `fill(_:)` を変えたときの意味が変わった。これまでは**形を閉じるときの塗り**が形全体に効いていたが、これからは**置いた時点の塗りが頂点ごとに乗り**、色は頂点の間でなめらかに移る。形の途中で塗りを変えていなければ絵は変わらない。線の色はこれまでどおり、形を閉じるときのものが形全体に効く。
