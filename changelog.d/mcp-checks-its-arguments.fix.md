<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` が、ほかの口と同じく引数を検めてから窓口を立てるようになった ([#2321](https://github.com/mokume-metal/mokume/issues/2321))。`mokume mcp --help` は `Unknown option: --help` と使い方を、`mokume mcp a b` は `Only one directory: b` を、在らない場所は `No such directory: <道>` を標準エラーへ出して 1 で終わる。標準入力は読まず、標準出力にも何も書かない。これまでは最初の引数をそのまま場所にしたので、`--help` という場所の窓口として標準入力を待ち、余る引数や在らない場所も黙って受けていた。

在る場所なら `Package.swift` が無くても、これまでどおり受ける (`claude mcp add mokume -- mokume mcp` は打った場所で起こす)。
