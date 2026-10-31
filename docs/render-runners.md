<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 専用機の render を 2 本並走させる

同じ Mac に runner を 2 本置き、既存の門番の `RENDER_TURN_SLOTS` を 2 にする
([#2252](https://github.com/mokume-metal/mokume/issues/2252))。GitHub の merge queue が
組む group の上限は 2 のまま。先頭が失敗して後続の group が組み直される場合は、
後続で済ませた処理を捨てる。この先行実行を最大 1 本に抑えて、成功が続くときの待ちを縮める。

## 専用機で行うこと

専用機は SSH で入れないので、ここはメンテナが画面とキーボードで操作する。
**既存 runner と同じ macOS ユーザーでログインし、その画面の Terminal を使う。**
別ユーザーへの切り替えや `sudo` は使わない。既存の `mokume-m4` は動かしたままでよい。

| 項目 | 既存 | 追加する runner |
| --- | --- | --- |
| 名前 | `mokume-m4` | `mokume-m4-2` |
| インストール先 | `~/actions-runner` | `~/actions-runner-2` |
| 作業場所 | 各 runner 内の `_work` | 各 runner 内の `_work` |
| 追加ラベル | `mokume-render` | `mokume-render` |
| ユーザーと画面 | 同じログイン中のユーザー | 同じログイン中のユーザー |

### 1. 2 本目をダウンロード・登録する

[runner の追加画面](https://github.com/mokume-metal/mokume/settings/actions/runners/new)を開き、
macOS / ARM64 を選ぶ。画面の Download のコマンドを使い、**作成するディレクトリと
移動先だけを `actions-runner-2` に替える**。ダウンロード・チェックサムの確認・展開は
表示された最新版のコマンドどおりに行う。既存 runner の設定ファイルはコピーしない。

Configure の `./config.sh --url … --token …` に、次の引数を追加して実行する。
token は同じ画面で発行されたものを専用機に直接入力する (有効期限は 1 時間)。

```text
--name mokume-m4-2 --labels mokume-render --work _work
```

まだ `./run.sh` は起動しない。先に次の hook を配置する。
登録の手順は [GitHub の公式手順](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)に従う。

### 2. ジョブ開始時の掃除を設定する

2 本目のディレクトリに [runner-job-started.sh](../scripts/runner-job-started.sh) を配置する。
下のコマンドは main のファイルを取得するので、リポジトリの clone は不要。

```bash
cd "$HOME/actions-runner-2"
curl -fL --output job-started.sh \
  https://raw.githubusercontent.com/mokume-metal/mokume/main/scripts/runner-job-started.sh
chmod 755 job-started.sh
```

`~/actions-runner-2/.env` を開き、次の 1 行を追加する。`<ユーザー名>` は実際の
ユーザー名に替える。`.env` の値はシェル展開されないので、`$HOME` や `~` は書かない。
既に同じキーがあれば追加せず、その行を直す。

```text
ACTIONS_RUNNER_HOOK_JOB_STARTED=/Users/<ユーザー名>/actions-runner-2/job-started.sh
```

GPU の枠は、両 runner が同じユーザーの
`~/Library/Caches/mokume/gpu-slots` を共有する (既定 3 枠)。両 runner の `.env` や
LaunchAgent に `MOKUME_GPU_SLOT_DIR`・`MOKUME_GPU_SLOTS` の指定が無ければ、
追加設定は不要。指定がある場合は両 runner と定期検査・診断の実行でパスと枠数を揃える。
runner ごとのディレクトリを GPU の枠の置き場にしない。

### 3. 画面のセッションの LaunchAgent として起動する

同じ Terminal で実行する。`svc.sh` は macOS 用の LaunchAgent をその runner の名前で
作るので、plist を glob で選ぶ必要はない。`sudo` は付けない。

```bash
cd "$HOME/actions-runner-2"
./svc.sh install
./svc.sh start
./svc.sh status
```

`Started` と表示されることを確かめる。ログイン中の同じユーザーの画面を使い続ける。
画面のユーザーを替えると窓の検査が走れなくなる。
詳しくは [GitHub のサービスの手順 (Mac)](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application?platform=mac)を参照する。

hook や `.env` を起動後に直した場合も、その runner のディレクトリで
`./svc.sh stop` → `./svc.sh start` とすれば対象を指定して再起動できる。
実行中の job を止めないよう、対象の runner が idle になってから行う。

## GitHub 側で確認・切り替えする

ここはメンテナの権限を持つ手元機からでも実行できる。

### 4. 2 本が online であることを確認する

[runner 一覧](https://github.com/mokume-metal/mokume/settings/actions/runners)で
`mokume-m4` と `mokume-m4-2` が online (Idle または Active) で、どちらにも
`mokume-render` が付いていることを確かめる。CLI なら次で確認できる。

```bash
gh api repos/mokume-metal/mokume/actions/runners \
  --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

片方が offline なら、変数を 2 にせず、その runner の `./svc.sh status` とログを確認する。

### 5. 門番を 2 本に切り替える

**2 本とも online になってから**実行する。

```bash
gh variable set RENDER_TURN_SLOTS --body 2 --repo mokume-metal/mokume
gh variable get RENDER_TURN_SLOTS --repo mokume-metal/mokume
date -u '+%Y-%m-%dT%H:%M:%SZ'
```

値が `2` であることを確かめ、切り替えの UTC 時刻を #2252 に記録する。
既に起動した門番は取り込んだ値で動き続けるので、新しく起動する門番から確認する。
queue に複数の PR があるとき、同時刻に 2 本の `render` が別々の runner で走り、
両方が前検査と検査を通ることを run の時刻と runner 名で確かめる。
`render-pr` はこれまでどおり、merge group が残っていれば見送る。

切り替え後 7 日の評価は #2252 の完了条件 4 に従う。開始待ち p50 が 5 分以下、
並走した回の所要が単独の +25% 以内、GPU の打ち切り・窓の検査の赤が増えないことを見る。
組み直しで捨てた実行時間と、時間あたりの merge 数も併記し、待ちだけの短縮を効果に数えない。
ほかの CI 改善と比較する際は、切り替え時刻と job の重なりで期間・並走の有無を分ける。

## 1 本へ戻す

```bash
gh variable set RENDER_TURN_SLOTS --body 1 --repo mokume-metal/mokume
gh variable get RENDER_TURN_SLOTS --repo mokume-metal/mokume
```

新しく起動する門番から、merge group を 1 本ずつ通す。実行中・待機中の job は
この変更だけでは止まらない。2 本目の runner 自体を止める場合は、変数を先に戻し、
既に 2 を取り込んだ門番と専用機に積まれた job が終わってから、専用機で実行する。

```bash
cd "$HOME/actions-runner-2"
./svc.sh stop
```

2 本目を再利用するときは `./svc.sh start` → 2 本が online か確認 → 変数を 2 の順。
専用機そのものが戻せないときの必須チェックの縮退は、
[別の手順](runner-degraded-mode.md)に従う。
