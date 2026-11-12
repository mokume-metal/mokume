<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、`Package.swift` から消した・改名した target の資材の包みを、`.build` に古いものが残っている限り配布用の `.app` に入れ続けていたのを直した。束ねる置き場は `swift build` / `swift test` と共有なので、消す前に組んだ包みが隣に残っていた。いまの宣言に無い自分のパッケージの包みは入れない。依存のパッケージの包みはこれまでどおり入れ、どちらのものか決められない包み (自分のパッケージ名が依存のパッケージ名を頭に持つときなど) と、依存の名前が読めない回は、除かずに入れる。
