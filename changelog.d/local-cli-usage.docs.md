<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

手元のビルドで道具を使う方法を README に載せました。clone して `swift build -c release --product mokume-cli` すれば、リリースを待たずに `new` / `run` / `watch` が打てます (道具の名前は `mokume-cli` で、配布物の `mokume` と同じものです)。`mokume-cli new --local ../mokume` と場所を渡すと、作られるスケッチが公開済みの版ではなく手元のライブラリを引くので、ライブラリを触りながらスケッチで確かめられます — 渡す場所は生成される `Package.swift` の `.package(path:)` へそのまま入るため、作られるスケッチから見た相対で書きます。
