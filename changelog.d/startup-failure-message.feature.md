<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチが起動できなかったときに出る文面が、**何が足りないかと、次に何をすればよいか**を書くようになりました。これまでは内部の名前をそのまま印字した 1 行 (`shaderSourceMissing(name: "Shapes.metal")`) だけで、読んでも次の一手が分かりませんでした。とくに束ねて配ったものが同梱の資源を欠いている場合は、包みの中で `mokume_MokumeCore.bundle` を探す場所まで示します。
