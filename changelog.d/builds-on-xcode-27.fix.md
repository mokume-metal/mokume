<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

Xcode 27 (Swift 6.4) の機械でも mokume が組めるようになった。これまでは `swift build` がシェーダの断片を 1 つずつコンパイルしようとして必ず落ち、**スケッチを 1 本も走らせられなかった** (`mokume run` / `mokume watch` は利用者のパッケージを組むときに同じ道を通る)。

あわせて、名前の付いたキーの定数 (`Key.a` など) を隔離の外から読めるようにした。Swift 6.4 では、これが main actor に載っていると引数つきの検査が組めなくなっていた。利用者から見た綴りは変わらない。
