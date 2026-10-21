<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**Release の tarball を展開した `mokume` が、自分の版を `0.30.0 (release e48a07f)` のように名乗るようになりました。** これまでは Homebrew の置き場でしか版が分からず、tarball から入れたものは `--version` も MCP の `serverInfo.version` も `local build (日時)` で、`doctor` は依存の版との食い違いを名指しできませんでした。版と commit は tarball に同梱の `mokume.release` から読むので、展開した場所を別のディレクトリへ移しても変わりません。Homebrew は同じ tarball を入れるため、`0.30.0 (Homebrew)` のまま名乗ります。手元でビルドしたものは今までどおり `local build` で、同梱のファイルが無い・壊れているときも同じです。
