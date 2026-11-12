<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、`Package.swift` から消した・改名した target の資材の包みを、`.build` に古いものが残っている限り配布用の `.app` に入れ続けていたのを直した。束ねる置き場は `swift build` / `swift test` と共有なので、消す前に組んだ包みが隣に残っていた。いまのパッケージ名で始まり、いまの宣言のどの target のものでもなく、依存のパッケージの名前でも説明できない包みは入れず、入れなかったものは束ねた後の報せに `Left out:` の行で 1 つずつ挙げる。依存のパッケージの包みはこれまでどおり入れ、どちらのものか決められない包み (自分のパッケージ名が依存のパッケージ名で始まるときなど) と、依存の一覧を道具立てから読めない回は、除かずに入れる。`Package(name:)` を改名する前の名前で始まる包みと、`Package.swift` から外した依存の包みは、これまでどおり入る。
