<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Package.resolved` の mokume の版・改訂が、版・改訂の形でない文字列 (`../../x` のように `/` や `..` を含むもの) のとき、API 一覧の取り置きやビルドの置き場の名前に使わなくなりました。これまでは、手で書き換えた・壊れた `Package.resolved` で、取り置きの名前が `.mokume/reference/` の外や入れ子のパスを指して書き込みえました。いまはその pin を壊れたものとして扱い、`mokume mcp` の API 一覧は共通名の `mokume-api.md` を案内して何も書き込みません。普通の版 (`1.2.3`・`0.5.0-beta.1`・`1.0.0+build5`) と 16 進数の改訂の扱いは変わりません。
