<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchRuntime.advance()` を main actor を譲らないループで回したとき (窓を出さない書き出しや検査のループ)、`draw` の中で書き換えた `@Param` の値が、次の起動へ持ち越す保存 (`.mokume/state/params.json`) にもつまみの区画の応答 (`.mokume/params/report.json`) にも届かなかったのを直した ([#1704](https://github.com/mokume-metal/mokume/issues/1704))。窓で回すときと同じく、保存は手が止まってから書き、閉じるときにはまとめている途中の値も書き切り、区画は次のフレームで応答を書き直す。窓で回すときの振る舞いは変わらない。
