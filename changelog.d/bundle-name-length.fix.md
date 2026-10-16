<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、`mokume-app.json` の `name` がファイル名に収まらない長さなら、ビルドの前に `The name in the identity is too long to be a file name` と長さ・上限 (239)・名乗りの場所を名指して止まるようになった ([#2501](https://github.com/mokume-metal/mokume/issues/2501))。`name` は `.app` と開き方の紙 (`How to open <name>.txt`) のファイル名にもなり、これまでは 240 以上の名前で release のビルドと署名を終えた後に紙が書けずに止まり、署名済みの `.app` が `bundle/` に残っていた。長さは macOS がファイル名を数える形で数えるので、アクセントや濁点の付いた字と絵文字は 2 になる (`が` は 120 字で上限を越える)。239 までの名前はこれまでどおり束ねられる — 越える名前はこれまでも束ね終えられなかったので、束ねられなくなる名前は無い。
