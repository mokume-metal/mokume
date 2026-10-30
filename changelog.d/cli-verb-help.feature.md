<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**どの口でも `--help` (`-h`) と `help <口>` で、その口の使い方だけが読めるようになった。** `mokume render --help` は、これまで `Unknown option: --help` と 60 行の全体の使い方を出して 1 で終わっていた。いまは render の使い方だけを標準出力に書いて 0 で終わる。`new`・`examples`・`run`・`watch`・`render`・`mcp`・`bundle`・`doctor` のどれも、ヘルプを頼まれたらビルド・診断・窓口の待ち受け・ファイルの作成をしない (`doctor --help` は診断を走らせない)。`run . --help` のように場所の後ろでも効く。口のヘルプは全体の使い方と同じ説明から作るので、2 つがずれない。

**使い方を誤ったときは、誤りの文と `See mokume help <口> for what <口> takes.` の 1 行だけを出す。** これまで誤りのたびに全体の使い方 (約 60 行) が付いていた。知らない口は `Unknown command: <綴り>` と `See mokume help for the commands.` の 2 行になる。`--x=値` を受けない決まりと、その案内の文は変わらない。

**`help` と `version` が、後ろの引数を黙って捨てなくなった。** `help <知らない口>` は全体を黙って出さず `Unknown command` で断り、`help run extra` や `version extra` は余りを名指して 1 で終わる。`help <口>` はその口の使い方を出す。
