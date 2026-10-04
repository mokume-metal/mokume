<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) の `observe` に、上限 (`count` 120・`every` 60) を大きく越える枚数や間隔を渡すと、窓口のプロセスごと落ちることがあった。待ち時間を見積もる計算が丸める前の値で掛け算をして、整数が溢れていた。いまは撮る側と同じく上限へ丸めてから見積もるので落ちず、範囲の外の値は従来どおり上限へ丸めて撮り、丸めたことを警告で伝える。
