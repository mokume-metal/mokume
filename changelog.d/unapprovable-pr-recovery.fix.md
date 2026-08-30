<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**誰も承認できない PR** ができたときの回復手順が、途中までしか書かれていなかったのを直した。close して作り直した後も、詰んだ側の run が付けた赤は同じコミットに残り続けるため、新しい PR の check が全部緑になっても `ci-gate` は赤のままになる。**新しい PR の側の run を rerun する**ところまでが回復であること、詰んだ側の run を rerun すると同じ赤を再生産することを、`review-gate` の差し戻し文言・[ADR-0007](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0007-approvability-invariant.md)・[AGENTS.md](https://github.com/mokume-metal/mokume/blob/main/AGENTS.md) に明記した。

あわせて、PR の作成主体を守るローカルフックの射程も実態に合わせた。フックは**そのセッションが主として開いたディレクトリ**の設定しか読まないので、別のリポジトリを主とするセッションがこのリポジトリの worktree で作業しても効かない。塞ぐ手が無いため、その前提で自衛することを書いた。
