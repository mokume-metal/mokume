<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# エージェントの開発環境

規約は [AGENTS.md](../AGENTS.md)。macOS / Apple Silicon 上で `make setup` を実行し、
不足する道具は出力に従って用意する。検証は `make ci-check` を使う。

## スキル

Claude Code は従来どおり `.claude/skills/` を読む。Codex は `.agents/skills/` の相対リンク
から同じ3本を読む。root・サブディレクトリ・worktree のいずれでもリポジトリ内で完結する。
リンクを含めて checkout する。別のエージェントでは AGENTS.md の「場面別の入口」から本文を
読む。スキルを個人ディレクトリへコピーしない。

## 認証と証跡

エージェントを起動する環境から `gh auth status` を確認する。PR 用の App 認証は AGENTS.md
「エージェントの identity」に従う。`MOKUME_APP_PRIVATE_KEY_CMD` と証跡用の
`MOKUME_GYAZO_TOKEN_CMD` は、利用する秘密管理から取得するコマンドを起動環境で渡す。
値や秘密の在処をリポジトリに書かない。署名の自動検出が効かない環境は
`MOKUME_AGENT_NAME` (必要なら `MOKUME_AGENT_URL`) を明示する。

絵・動きの確認はローカルの Mac で行う。[visual-evidence](../.claude/skills/visual-evidence/SKILL.md)
の前提を確かめ、窓を撮る場合の画面収録権限は利用するアプリに付与する。
利用できる MCP やブラウザの道具は製品ごとに異なる。手順を読めることと、その道具が接続済み
であることは別である。

## フック

Claude Code の接続は `.claude/settings.json`。他製品の設定として読み替えない。
フックを提供しない環境でも、Issue へのプラン記録・コメントのラッパー・App identity は
AGENTS.md に従って実行する。フックが黙っていることを検証済みの印にしない。
個人のプラグイン・モデル・権限設定はこのリポジトリから変更しない。
