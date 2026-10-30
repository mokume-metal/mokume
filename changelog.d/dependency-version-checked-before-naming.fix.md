<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Package.resolved` の mokume の版・改訂が、版・改訂の形でない文字列 (`../../x` のように `/` や `..` を含むもの・128 字を超えるもの) のとき、API 一覧の取り置きやビルドの置き場の名前に使わなくなりました。これまでは、手で書き換えた・壊れた `Package.resolved` で、取り置きの名前が `.mokume/reference/` の外や入れ子のパスを指して書き込みえました。いまは `mokume mcp` の API 一覧が「mokume の pin が名前に使える形でない」ことと受ける形 (版は先頭が数字で数字・英字・`.`・`-`・`+` だけ、改訂は 16 進数だけ) を答え、弾いた値は第三者のリポジトリの文字列なので答えに出さず、`mokume doctor` だけが (制御文字などを逃がして) 値を名乗ります。`mokume run` / `watch` も、共有の置き場を使わないこと・`mokume doctor` で値を見られることを名乗ります。案内する手は、mokume の pin の行を直すこと (手で、または `swift package update mokume`) で、`Package.resolved` ごと消す手は他の依存の固定も外れると添えて二の次にします。API 一覧は共通名の `mokume-api.md` を案内して何も書き込みません。普通の版 (`1.2.3`・`0.5.0-beta.1`・`1.0.0+build5`) と 16 進数の改訂の扱いは変わりません。
