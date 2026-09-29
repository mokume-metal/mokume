<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchRuntime.advance()` を main actor を譲らないループで回したとき (窓を出さない書き出しや検査のループ)、`draw` の中で書き換えた `@Param` の値が、次の起動へ持ち越す保存 (`.mokume/state/params.json`) にもつまみの区画の応答 (`.mokume/params/report.json`) にも届かなかったのを直した ([#1704](https://github.com/mokume-metal/mokume/issues/1704))。窓で回すときと同じく、保存は手が止まってから書き、閉じるときにはまとめている途中の値も書き切り、区画は次のフレームで応答を書き直す。

**そのため、窓を出さずに `SketchRuntime(sketch:gpu:)` で回す書き出しのループでも、`setup` や `draw` で `@Param` の値を変えるスケッチは `.mokume/state/params.json` を書くようになる** (窓で回すときと同じ振る舞い)。撮る経路が保存を持つべきかは [#1832](https://github.com/mokume-metal/mokume/issues/1832) で決める。

あわせて、同じ中身の書き直しを止めた。外からの書き込みに応えた後、保存が静かになってからもう 1 度同じ中身を書き、応答も次のフレームで同じ中身を書き直していた。起動した直後の応答も、次のフレームで同じ中身のまま番号 (`revision`) だけを進めて書き直していた。どちらも窓で回すときから起きていた。閉じるときには、最後のフレームで変えた値を区画の応答にも書き切るようにした。
