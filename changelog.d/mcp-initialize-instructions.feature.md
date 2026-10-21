<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) が、繋がった時点の挨拶 (`initialize`) の `instructions` で、立てた場所とそこがスケッチかどうかを名乗るようになった。`Package.swift` の無い場所で起こした窓口は、その旨と `mokume mcp <スケッチのディレクトリ>` で起こし直す手を、最初の `observe` が答えるのを待たずに伝える。スケッチの場所で立てた窓口は、場所を言う 1 行だけを名乗る。`serverInfo` と `protocolVersion` は変わらない。
