<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `mokume watch` の端末に出る速さの行が、直近 30 秒の推移を 1 秒 1 文字で添えるようになった。`Rate: 60.0 fps ██▆▆█·█ (release)` のように、現在値の直後に低下と回復が読める。縦軸の上端はスケッチが宣言した `frameRate` で、`noLoop()` や止まっている間の秒は棒にならず `·` で示す。行は 1 行のままで、窓口 (`mokume mcp`) から起こしたスケッチの出力は変わらない。推移はライブラリが描くので、古い版の mokume に固定したスケッチでは出ない。
