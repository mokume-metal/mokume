<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) が、道具の実行中でも `ping` に速やかに答え、`notifications/cancelled` で実行中の道具を取り消せるようになった。いままでは窓口が 1 行ずつ読んで答えを待っていたので、`observe` を `count`・`every` の上限いっぱいで頼むと最長で約 4 分、届いた `ping` に答えられなかった。読み取りを別の手に分け、`ping` は読んだその場で空の結果を返し、取り消しは区画を待っている `observe`・`input` の待ちを切る。取り消された要求には答えを返さない (MCP の取り消しの扱い)。道具は今までどおり届いた順に 1 本ずつ実行する。
