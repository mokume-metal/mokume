<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチが入力を読めるようになりました。`mouseX` / `mouseY` / `pmouseX` / `pmouseY` / `isMousePressed` / `mouseButton` / `scrollX` / `scrollY` / `isKeyDown(_:)` / `key` が `draw()` から使えます。値は外から送ることもでき、スケッチのディレクトリに `.mokume/input/` を作って `{"id":"...","events":[{"type":"mouseMoved","x":120,"y":80}]}` を `request.json` に置くと、**次のフレームの `draw()` から見えます**。応答には受け取った数・知らない種別で捨てた数・溜めきれずに捨てた数が入るので、「送ったのに効かない」の切り分けができます。
