<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

粒を奥行きも含めた全方位へ撒けるようにした。`emit` の飛ぶ向きを、面内の角度の幅 `angle:` から、出る場所 (`Emitter`) と対になる `toward:` (`Heading`) で渡す形に替えた。`emit(dust, from: .point(x, y, z), toward: .sphere, rate: 600)` と書くと、1 点から球面上のどの向きへも同じ確からしさで吹き出す。これまでは初速の奥行きの成分が常に 0 で、横から見ると粒は 1 枚の面の上にしか撒けなかった。

`toward` を省くと、これまでの `angle` の既定と同じ「画面の面内のどの向きへも」(`.plane(0...(2 * Float.pi))`) になり、種を決めた絵は 1 画素も変わらない。

**移行**: `angle:` を渡していた呼び出しは組めなくなる。`angle: a...b` を `toward: .plane(a...b)` に書き換え、**`from:` のすぐ後ろ (`rate:` の前) へ移す** — `emit(dust, from: .point(x, y), rate: 600, angle: 0...1)` は `emit(dust, from: .point(x, y), toward: .plane(0...1), rate: 600)` になる。同じ幅を渡せば、出る粒の値は前と同じである。
