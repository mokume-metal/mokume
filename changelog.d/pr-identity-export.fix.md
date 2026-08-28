<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

PR を作る identity のガードが、token を発行しただけで `export` していない形を素通ししていたのを直した。素の代入はそのシェルの変数を作るだけで子プロセスの `gh` には渡らないため、`GH_TOKEN="$(...)" && git push && gh pr create ...` は「発行に失敗したら止まる」条件を満たしていながらメンテナの認証で走り、**誰も承認できない PR** ができていた。渡っていることまで確かめる。
