<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ビルドの置き場に残った、いまの `Package.swift` に無い資材の包みを、`mokume bundle` が `.app` に入れなくなり、`mokume run`・`watch`・`render`・`replay` で走らせたスケッチが資材を探さなくなった。

これまでは、`Package(name:)` を改名する前の名前の包み・`Package.swift` から外した依存の包みが `.app` に入り続けた。`run` などは実行ファイルの隣の包みを名前の順に全部探すので、改名する前の包みや、共有の置き場に並ぶ別のスケッチの包みが同じ相対パスの資材 (`assets/logo.png` など) を持つと、いまのスケッチの資材ではなくそちらを読んでいた。いまは、いまの宣言の target と依存のパッケージの名前で始まる包みだけを入れ・探し、外した包みは `bundle` が `Left out:` で、`run` などが起動の 1 行で名乗る。`Package.swift` の直接の依存の identity で説明できない包みが並ぶときだけ、依存の名前を `swift package show-dependencies` に聞くので、起動の道具立ての呼び出しが 1 回増える (依存が mokume だけのスケッチでは増えない。`watch` は宣言と包みの並びが変わった回だけ)。聞けなかったときは何も外さない。外した包みにしか無い資材を読もうとして見つからなかったときは、その包みの名前を 1 度知らせる。依存の中の古い包み (依存の版を上げて消えた target の包み) は、名前の頭までしか絞れないので入り続ける。
