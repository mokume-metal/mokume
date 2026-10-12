<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run`・`watch`・`render` の `-c` (`--configuration`) に `debug` / `release` 以外 (`Release`・`DEBUG`・`bogus` など) を渡すと、組み立てを始める前に、受け付ける値を名指して止まるようになった ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。これまでは組み立てを始めてから SwiftPM の使い方を出し、最後に「`Package.swift` に実行ファイルが無い」と言っていた。綴りは `swift build` と同じ小文字で、大小を読み替えない。

ビルドの置き場を道具立てに聞いて答えが返らなかったときも、`Package.swift` を疑わせずに、打った `swift build --show-bin-path …` と終了コードを名乗るようになった。
