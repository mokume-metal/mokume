---
name: verify
description: 振る舞いを変える変更を、テストに加えて、スケッチを実際に動かして確かめる。mokume-cli の watch と mcp で起動し、input で操作して observe で状態と絵を読み、その記録を PR の確認方法に載せる。Use when a change touches public API behaviour, input handling, watch / mcp / CLI behaviour, or anything unit tests pass but the running sketch might still get wrong; before opening such a PR, or 動かして確かめて / 実走して.
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 動かして確かめる

規律は 1 行である — **振る舞いを変える PR は、テストが緑でも、スケッチを実際に動かして `input` → `observe` で確かめ、送ったものと返ったものを PR の確認方法に載せる。**

単体テストは、テストが組んだ条件でしか見ていない。`watch` が組み直したスケッチに、窓と同じ入口から入力を送ると、テストが組まなかった経路 (起動の順・区画の有無・作り直しの後の状態) を通る。人の手は要らない (#2819)。

撮って PR / Issue に貼るのは [visual-evidence](../visual-evidence/SKILL.md) の経路 A の仕事で、ここは**操作して確かめる**ところだけを持つ。描画の正しさを示す絵はそちらで撮る。

## 1. いつ使うか

- 公開 API の振る舞い (入力の口・状態・時計・資源の読み込み) に触った
- `watch`・`mcp`・`run` など CLI の振る舞いに触った
- 「テストは通るが、実際のスケッチでは届かないかもしれない」と思った

純粋な計算 (テストが入力と出力を直接押さえている) や、文書だけの変更には要らない。

## 2. 組む

PR の枝の worktree で組む。**`swift run` を JSON-RPC の口に使わない** — 組み立ての出力が標準出力に混ざる。組んでから実行ファイルを直に呼ぶ:

```bash
swift build --product mokume-cli
CLI="$(swift build --show-bin-path)/mokume-cli"
```

## 3. 確かめるスケッチを作る

置き場はセッションの scratchpad (リポジトリの中に作らない)。`--local` で、いまの worktree の本体に依存させる:

```bash
"$CLI" new <名前> --path <scratchpad> --local <worktree の絶対パス>
```

できた `Sources/` の本体に、確かめたい口だけを書く。止めたまま押したいなら `setup()` で `noLoop()` を呼ぶ。

**起動の前に区画を作る。** `.mokume/observe` と `.mokume/input` は、スケッチが起動した瞬間にディレクトリがあるときだけ働く (`FrameObserver.makeIfEnabled`・`InputInbox.makeIfEnabled`)。後から作っても、起動し直すまで届かない:

```bash
mkdir -p <スケッチ>/.mokume/observe <スケッチ>/.mokume/input
```

## 4. 起動する

`watch` は背景で起こす (Claude Code なら Bash の `run_in_background`)。ログは後で読めるようにファイルへ残す:

```bash
"$CLI" watch <スケッチ> > <scratchpad>/watch.log 2>&1
```

起動できたかは、次の段の `build_status` で `ok` と `launched` が真になったことで見る (ログの `Rebuilt:` の行でも分かる)。窓は 1 枚出る。

## 5. 操作して読む

別のプロセスで `"$CLI" mcp <スケッチ>` を起こし、標準入出力に 1 行 1 メッセージの JSON-RPC を流す:

1. `initialize` → 応答を待つ → 通知の `notifications/initialized`
2. `tools/list` で道具と引数の形を読む。**入力の種類と欄は、ここの `input` の説明と [Schemas/input-request.schema.json](../../../Schemas/input-request.schema.json) が正本**で、このスキルには写さない
3. `tools/call` で `input` (`{"events": [...]}`) を送り、続けて `observe` で読む。`observe` の応答は `Image: <パス>` の後ろに JSON の内訳が続くので、最初の `{` から読む
4. 内訳 (フレーム番号・スケッチが渡した値・`warnings`・`stamp`) で、期待した変化が起きたかを確かめる

`build_status` は直前の組み立ての結果を返す。思った絵にならないときは、まずここで新しい版が起動しているかを見る。

**1 度だけ載るもの** (次の観測の `warnings` に 1 度だけ出る値など) は、同じプロセスで一度試すと状態が残る。ソースに触れて `watch` に作り直させた直後の状態で通す。

## 6. 片付ける

`pkill` で名前を指して止めない — 同じ機械で他のセッションが `watch` を走らせている。自分が起こした `watch` と、その子のスケッチの PID を確かめてから止める:

```bash
ps -eo pid,ppid,pgid,command | grep -F '<スケッチ>'
kill -INT <スケッチの PID> <watch の PID>
```

背景で起こした `watch` は、起こした側の道具で止めてもよい (Claude Code なら TaskStop)。消えたことを `ps` で見てから終える。止められなかったものは `bash scripts/orphan-processes.sh` で一覧し、止めるかは人に任せる。

## 7. 記録する

PR 本文の確認方法 (完了条件との対応表) に、次を載せる:

- 確かめた口と、スケッチの要点 (数行。全文は要らない)
- 送った `input` の `events` と、`observe` の内訳のうち判定に使った値 (`stamp` を含める — どの版を動かしたかの出所になる)
- 絵で示すものがあれば visual-evidence で撮った URL

動かせなかったなら、そう書いて理由を残す (GPU が使えない・窓が出ない など)。動かしていないのに「確かめた」と書かない。
