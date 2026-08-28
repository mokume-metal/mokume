<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

立体を置けるようになった。`box` / `sphere` / `plane` / `cylinder` / `cone` / `torus` の 6 つで、`rotateX` / `rotateY` / `rotateZ` と `translate(x, y, z)` で向きと位置を決める。**何も指定しなければ画素の大きさで見える** — `box(120)` は 120 画素の箱として出る。奥行きは自動で解決されるので、手前のものが奥のものを隠す。平面の図形と立体は**書いた順のまま重なる**。光はまだ無いので、立体は塗り 1 色で描かれる。
