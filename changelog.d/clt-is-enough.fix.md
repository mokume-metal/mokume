<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチを作って走らせるのに、Xcode も Metal Toolchain も要らなくなった。シェーダは実行時に組むので、ビルドに使うのは Homebrew を入れるときに一緒に入る Command Line Tools (26 以降) だけになる。`mokume bundle` で `.app` を作るときも同じ。[README](https://github.com/mokume-metal/mokume#必要な環境) の「必要な環境」をこれに合わせて改め、`mokume doctor` も `Shader compiler` の行と Metal Toolchain の入れ方を出さなくなった。
