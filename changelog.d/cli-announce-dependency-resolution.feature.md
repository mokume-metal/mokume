<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**作ったばかりのスケッチを初めて `mokume run` / `render` / `watch` するとき、依存を取りに行く間に `Resolving the sketch's dependencies… (the first one takes a while)` と 1 行名乗るようになった。** これまでは `Tool:` の行の後、数秒のあいだ何も出ず、止まったように見えていた。名乗るのは依存の解決を始める回だけで、`Package.resolved` がある 2 回目以降の出力は変わらない。`watch` では、走らせている作品の速さの行を消してから書く。
