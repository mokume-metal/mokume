<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# エージェントの開発環境

規約は [AGENTS.md](../AGENTS.md)。macOS / Apple Silicon 上で `make setup` を実行し、
不足する道具は出力に従って用意する。検証の入口は `make ci-check` (手元で回す範囲は AGENTS.md「コミット・PR の規約」)。

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

Claude Code の接続は `.claude/settings.json`。Codex の接続は `.codex/config.toml`。
どちらもコメント・PR identity の同じスクリプトを呼ぶ。各製品の設定を読み替えない。

Codex はプロジェクトを信頼し、さらにフックを確認して信頼した場合にだけ動かす。
CLI では `/hooks` で読込元と信頼状態を確認する。変更後のフックも再確認が必要になる。
未信頼のプロジェクトの設定は読み込まれない。一時的な `projects.trust_level` の CLI 指定で
導入済みとは扱わず、製品の信頼操作を使う。個人設定をこのリポジトリから書き換えない。

Codex CLI 0.158.0-alpha.2.1 のシェル実行 (`exec_command`) とコード実行 (`exec` 内の
`tools.exec_command`) は `Bash` としてフックへ届く。入力は `tool_input.command` であり、
既存ガードを直接呼べる。MCP 経由の投稿や任意の外部 API 全体を覆うものではない。
コマンドの認識は Claude Code と同じスクリプトが持つので、判定の範囲も同じである。
`gh` の手前の予約語・リダイレクト・環境変数の代入・`env`・パスや引用・行継続
(`for …; do gh`・`PATH=… gh`・`/opt/homebrew/bin/gh`・`gh \`) も認識し、前置の
`GH_TOKEN` / `GH_REPO` / `env -u` / `env -i` と、`gh` より前に置いた token の発行・export・
unset は名義と宛先の判定に渡す (#1729)。token は、発行の成功と export が `gh` の時点で必ず
済んでいるときだけ installation token と見立てる。並びは bash の結合の順 (パイプと
`{ …; }`・`( … )` などの複合コマンドは `&&` より強い) で読み、置換の中の発行は置換の終了コードが
発行の成否を伝えるときだけ数える。`gh` より前に文としての `cd`・`pushd`・`popd`、
`GH_REPO` を変える文 (`export GH_REPO=`・`unset GH_REPO`・`read GH_REPO`・`for GH_REPO in …` など)、
git がリポジトリを探し remote を読むのに効く変数 (`GIT_DIR`・`GIT_COMMON_DIR`・`GIT_CONFIG_GLOBAL`
など) があれば、宛先は値を追わずに「決められない」として止める側へ倒す (`builtin` / `command` の
後ろも読む。ループの本体では gh の後ろの文も効くものとして読む)。値が実行時に決まる `-R "$X"` も
同じく止める側である。逃げ道は `-R owner/repo` の明示である (#1823)。
`sudo` など別のコマンドを起動するコマンドの後ろの `gh` と、`$GH` のように実行時に
決まる語は追わない (範囲の線は `scripts/guard-lib.sh` の冒頭)。
別の版では読込と実際の発火を確かめる。
フックを提供しない環境でも、Issue へのプラン記録・コメントのラッパー・App identity は
AGENTS.md に従って実行する。フックが黙っていることを検証済みの印にしない。
個人のプラグイン・モデル・権限設定はこのリポジトリから変更しない。

## プランの明示登録

Codex では、実装前に対象 Issue と完了条件の現況を含むプラン本文を一時ファイルへ書き、
次を実行する。`CODEX_THREAD_ID` が空なら実際のセッションIDを確認する。代用のIDを作らない。

```bash
bash scripts/plan-record.sh register --agent codex --session "$CODEX_THREAD_ID" --body-file /tmp/plan.md
```

説明を読み、表示された `scripts/comment.sh` で投稿する。終了コード2は投稿の指示にも
入力の差し戻しにも使うため、成功と決めつけない。投稿そのものをフックは代行しない。
有効な Stop フックは同じworktree・Codexセッションで登録された未投稿のプランを確認する。
未登録のプランは検出しない。Claude の ExitPlanMode と capture/guard は従来どおりである。

他のエージェントは `--agent` と `--session` を明示し、作業終了時に `check` を実行する。
Codex でもフック非対応・未信頼なら同じ確認を手で行う。

```bash
bash scripts/plan-record.sh check --agent codex --session "$CODEX_THREAD_ID"
```

記録はworktree・agent・sessionごとに分離する。再開は同じID、別のセッションへの引き継ぎは
GitHub の投稿を読む。入力・終了コードの詳細は `bash scripts/plan-record.sh --help` を参照する。

明示登録の投稿前の一時材料は `.build/mokume-plan-records/` に置く。`.git` の保護を緩める
必要はない。`.build` を消した場合は再登録する。経過の正典は投稿先の GitHub であり、
ローカルの記録だけを引き継ぎに使わない。

<!-- throwaway-1956-a: 承認の挙動の切り分け用。merge しない -->
<!-- throwaway-1956-a: 2 回目 (メンテナ名義) -->
