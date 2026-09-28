<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginShape(.triangles)` / `.triangleStrip` / `.triangleFan` で多くの三角形を並べる形が、さらに軽くなりました。三角形 1 枚ごとに、分ける必要の無い 3 点を三角形分割へ通し、番号の配列を作り直していたためです。3D の `beginShape(.triangles)` 20 万三角形は 1 フレーム 55 ms → 38 ms になります。絵は 1 画素も変わりません。
