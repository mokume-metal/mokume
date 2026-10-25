<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

入力の要求の綴りの誤りを、応答の `warnings` で名乗るようになった。これまでは `{"type":"mouseDown","x":1,"y":2,"buton":1}` の `buton` が黙って捨てられ、左クリックとして通っていた ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。いまは同じように受け取ったうえで、`events[0]` の位置・知らない名前・読む鍵の一覧を `warnings` に載せる。要求の最上位の余りの鍵 (`evnts` など) も同じで、`events` が欠けて読めない要求でも名乗る。要求は失敗させず、出来事も `ignored` へ回さない。

知らない鍵の無い応答は、これまでと同じ形のまま (`warnings` の鍵ごと書かない)。`schemaVersion` は 1 のままである。出来事のスキーマには `additionalProperties: false` を足したので、スキーマで要求を検める書き手は、知らない鍵を送る前に弾ける。
