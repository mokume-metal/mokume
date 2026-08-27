# ADR-0005: PR のラベルは機械が読む入力に限る

## 状態

採用 (2026-08-27)

## 文脈

[ADR-0004](0004-issue-classification-by-issue-type.md) は Issue の分類を整理した — 「何の仕事か」は Issue Type、直交する属性 (`status: *` / `verify: *` / `no-issue`) は Label。決めたのは Issue の側だけで、**PR のラベルについては何も書いていない**。

実態は、PR にラベルが 1 枚も付いていない (2026-08-27 時点、#7〜#83 の全 PR で 0 件)。これが「付け忘れ」なのか「付けない設計」なのかはリポジトリのどこにも書かれておらず、次に PR を出す人 (や機械) が判断する根拠が無い。

ラベルを足す前に、PR が持つ属性それぞれについて、**既に正典があるか**を調べた。

| PR の属性 | 既にある正典 | 強制する機構 |
| --- | --- | --- |
| 何の仕事か (型) | PR タイトルの Conventional Commits | `.github/workflows/ci.yml` の `pr-title` ジョブ |
| 対象の Issue | 本文の `Closes #N` | `scripts/review-gate.sh` |
| 完了条件の性質 | 対象 Issue の `verify: *` ラベル | `scripts/review-gate.sh` |
| 重要パスに触れるか | `.github/CODEOWNERS` | GitHub native (Review required) |
| 進行状態 | Draft / Review / merge queue | GitHub native |

**すべて埋まっている。** しかも PR タイトルは squash merge でそのままコミットメッセージになるため、型は単なる分類ではなく**成果物そのもの**であり、機械が形式を検査している。ここへ型ラベルを重ねると、同じ内容が 2 か所に載り、ずれたときにどちらが正かを決める根拠が無くなる (ADR-0001 原則 9)。

Issue と同じ分類軸を PR に持ち込む道も無い。**GitHub の Issue Type は Issue 専用で、PR には付かない。** ADR-0004 が「単値であるべきものを単値でしか表現できない機構に載せる」ために選んだ機構は、PR 側には存在しない。

一方で、**ラベルが機構の入力として働いている例は既に 1 つある。** `no-issue` は `scripts/review-gate.sh` が読み、`Closes #N` を持たない PR を例外として通すために使われている ([ADR-0002](0002-issue-lifecycle-and-merge-approval.md) 決定 3)。このラベルは「分類」ではなく、**判定を変えるスイッチ**である。

そしてこの用法が言語化されていないために、穴が 1 つ空いている。`.github/dependabot.yml` は github-actions を週次で更新する設定になっているが、**dependabot の PR は `Closes #N` を書かない**。来た瞬間に `review-gate` が赤になり、人が手で `no-issue` を付けるまでマージできない。まだ 1 件も PR が来ていないため顕在化していないだけで、設定を書いた時点で確定していた故障である。

## 決定

### 1. PR に分類ラベルを付けない

型・対象・完了条件・重要パス・進行状態は、文脈の表のとおりすべて既に正典を持つ。PR ラベルでそれらを再表現しない。**「PR 一覧が色付きで見やすくなる」は理由にしない** — 見やすさのために正典を二重化した分だけ、後からずれる。

### 2. PR に付くラベルは、CI の判定を変えるものだけ

PR ラベルの唯一の役目は、**機構への入力**である。新しい PR ラベルを提案するときは、それを読むスクリプト (またはワークフロー) を同時に示す。読み手のいないラベルは足さない (原則 4: 実需が機能を駆動する)。

現時点で該当するのは `no-issue` の 1 種のみ。**ラベル語彙はこの決定によって増えない。**

この基準は将来の追加を禁じるものではない。「ラベルでしか表現できず、機械がそれを読んで判定を変える」ものが現れたら足す。判断の順序は逆にしない — ラベルを先に作って用途を後から探さない。

### 3. ラベルの欠落が黙って通る設計にしない

`no-issue` を付けるのは今も人である。それでよい理由は、**付け忘れが赤で止まるから**である (`review-gate` が「Issue に紐づいていない」と差し戻す)。ラベルの有無が判定を変える以上、欠落は必ず機構が捕まえる側に倒す (原則 8: 文書ルールでなく機構で塞ぐ)。

人が介在しない経路 — bot が開く PR — では、人の手付けを当てにできない。そこでは自動付与にする (決定 4)。

### 4. dependabot の PR は `no-issue` を自動で付ける

`.github/dependabot.yml` に `labels: ["no-issue"]` を書く。dependabot が既定で付ける `dependencies` ラベルはこの指定によって置き換えられ、付かなくなる — 読み手がいないラベルだからで、決定 2 の帰結である (bot の PR かどうかは author `dependabot[bot]` を見れば分かる)。

**bot が自らゲートを外しているように見えるが、そうではない。**

- `no-issue` は承認ゲートではなく、**Issue 紐づけの例外印**である。承認を担うのは CODEOWNERS と `verify: human` の判定で、そちらは動かない
- `.github/dependabot.yml` 自体が `.github/` 配下にあり、**CODEOWNERS によりメンテナの承認なしには変えられない**。この自己申告は人の承認を一度通った設定であって、bot が実行時に選べるものではない
- github-actions の更新は必ず `.github/workflows/` を触るため、**dependabot の PR は毎回 CODEOWNERS の承認を要求される**。Issue 紐づけを免除しても、人の目は必ず一度入る

`review-gate.sh` 側に「author が bot なら免除」を書く案は採らない。[ADR-0003](0003-agent-identity-separation.md) によりエージェント自身も GitHub App の identity (bot) で PR を作るため、bot 一般を免除するとエージェントの PR がすべて Issue 駆動から外れてしまう。`dependabot[bot]` を名指しする特例をスクリプトへ埋めるより、設定ファイル 1 行で宣言するほうが、読む場所も承認の経路も少ない。

### 5. 採らなかった案

同じ検討を繰り返さないために残す。

| 案 | 採らない理由 |
| --- | --- |
| `actions/labeler` による変更パスからの自動ラベル (`area: ci` 等) | 重要パスの扱いは CODEOWNERS が既に担う。ラベルはその写しで、読み手がいない |
| size ラベル (XS/S/M/L) | 変更行数は PR 一覧にも diff にも常に出ている情報の写し |
| リリースノート生成用の分類ラベル (Release Drafter 等) | このリポジトリの変更履歴は `changelog.d/` の断片が正典 (PR ではなくファイルが単位)。ラベルを情報源にすると正典が 2 つになる |
| `status: *` を PR にも共用する | 進行状態は Draft・Review・merge queue が native に持つ |
| PR の型ラベル (`type: *` の PR 版) | PR タイトルが squash 後のコミットメッセージそのもので、`pr-title` ジョブが形式を強制している |

## 影響

- ラベル語彙は変わらない (8 種のまま)。dependabot 既定の `dependencies` も作らない
- `.github/dependabot.yml` に `labels` を追加する。これにより dependabot の PR は `review-gate` の Issue 紐づけ判定を通り、CODEOWNERS の承認だけを待つ状態になる
- 自動付与の実測は、次の週次実行 (または Insights > Dependency graph > Dependabot の "Check for updates") を待つ。実測は sub-issue に切り、結果をそこに残す
- `scripts/review-gate.sh` の挙動は変えない。`no-issue` を読む判定は既にあり、本 ADR はその位置づけを言語化しただけである
- `.github/dependabot.yml` の YAML 妥当性は本 ADR を書いた時点でどの検査も見ていなかった (当時の `scripts/check-workflows-yaml.sh` の対象は `.github/workflows/*.yml`)。壊れた dependabot 設定は GitHub 上で黙って無効になるため別 Issue に切り、#87 で `scripts/check-github-yaml.sh` が `.github/` 配下の YAML すべてを対象にした
- AGENTS.md に「PR のラベル」節を追加し、`no-issue` の説明を「進め方」から接続する
