<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` の `reference` が公開 API の一覧を取ってくるときの「10 秒で諦める」が、呼んでから返るまでの総時間で効くようになった ([#2407](https://github.com/mokume-metal/mokume/issues/2407))。これまでは要求に付けた期限が音沙汰の無い間しか数えなかったので、本文を少しずつ返し続ける応答 (遅い回線など) では 10 秒を越えても待ち続け、窓口は同期で答えるため MCP の応答ごと固まった。いまは 10 秒を越えたら受け取りを取り消し、`no complete answer came back within 10 seconds` を理由にした案内を返す。

期限より早く届く応答と、200 以外の状態を断る挙動は変わらない。
