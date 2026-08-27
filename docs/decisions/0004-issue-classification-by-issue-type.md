# ADR-0004: Issue の分類を Issue Type へ移す

## 状態

採用 (2026-08-26)

## 文脈

[ADR-0002](0002-issue-lifecycle-and-merge-approval.md) は Issue のライフサイクル (起票 → 議論 → トリアージ完了 → 着手) を決めた。そこで扱ったのは `status: needs-triage` と `verify: machine|human` — **状態**と**完了条件の性質**である。もう一つの軸「この Issue は何の仕事か」は、当時 `type: bug|feature|design|docs|maintenance|question` の 6 ラベルで表現し、ADR には残していなかった。

GitHub には organization 単位の **Issue Type** がある。1 Issue に 1 型、org 横断、Issue 一覧・sub-issue ツリー・Projects の組み込みフィールド・検索 (`type:"Bug"`) に現れる。`mokume-metal` では既定の 3 型 (`Task` / `Bug` / `Feature`) が有効なまま、**一度も使われていなかった** (2026-08-26 時点で type を持つ Issue は 0 件)。

ラベルで代用してきた結果、三つの綻びが出ている。

**1. 分類が多値になる。** #68・#60 は `type: docs` と `type: maintenance` の両方、#53 は `type: bug` と `type: maintenance` の両方を持つ。ラベルは多値なので、付ける側が迷えば両方付けられてしまい、「何の仕事か」が一意に決まらない。Issue Type は 1 Issue 1 型なので、この曖昧さは構造的に生じない。

**2. 付与がタイトルの綴りに依存し、漏れる。** 自動付与は `.github/workflows/triage.yml` が Conventional Commits の prefix から推定している。prefix の無い #50・#48 は分類が付かないまま残った。

**3. 二つの軸が同じ面に並んでいる。** `status:` と `verify:` は互いに直交する属性で、多値でよい (実際 `status: in progress` と `verify: machine` は共存する)。単値であるべき `type:` が同じラベル面に並んでいると、どちらの性質なのかが見た目から判別できない。

使用実績は `maintenance` に強く偏る (約 35 件)。`docs` 3・`design` 3・`bug` 2 に対し、`feature` と `question` は 0 件だった。

## 決定

### 1. 「何の仕事か」は Issue Type、直交する属性は Label

|  | Issue Type | Label |
| --- | --- | --- |
| 表すもの | この Issue は**何の仕事か** | それ以外の直交する属性 |
| 多重度 | 1 Issue 1 型 | 多値 |
| スコープ | organization | repository |
| GitHub の扱い | 一覧・sub-issue ツリー・Projects の組み込みフィールド・`type:"Design"` で検索 | `label:` で検索 |
| このリポジトリでの例 | `Bug` `Feature` `Task` `Design` `Docs` | `status: *` `verify: *` `no-issue` |

分類の軸が一つに定まらない限り、どちらの機構を使っても曖昧さは消えない。**単値であるべきものを単値でしか表現できない機構に載せる**のが本決定の要点で、native 機能を使うこと自体が目的ではない。

### 2. 型は 5 つ。`type: question` は廃止する

| Issue Type | 移行元ラベル | 意味 |
| --- | --- | --- |
| `Bug` (既定) | `type: bug` | 期待と違う挙動 |
| `Feature` (既定) | `type: feature` | 新機能・拡張 |
| `Task` (既定) | `type: maintenance` | 保守・整備・CI・リファクタ |
| `Design` (新規) | `type: design` | 設計判断・ADR |
| `Docs` (新規) | `type: docs` | ドキュメント |

既定の 3 型は名前を変えずに使う。org 横断の語彙は、他の人・他の道具が既に知っている語のままのほうが安い。

`Design` を `Task` に畳まない理由は、このリポジトリの現在の主成果物が ADR だからである (設計フェーズであり、ライブラリのコードはまだ無い)。畳むと 30 件超の `Task` に設計判断が埋もれ、「どの設計を決めてきたか」を型で辿れなくなる。`Docs` も同様に、規約文書がこのリポジトリの実質的な成果物であるため独立させる。

`type: question` は使用実績が 0 で、そもそも「仕事の種類」ではない。型には持ち込まず、ラベルごと廃止する (質問が必要になったら普通に起票する)。

### 3. 型の定義の正典は本 ADR、org 設定はその写し

Issue Type は organization の設定であり、**このリポジトリの版管理の外にある**。生成物を持たず正典を 1 つに保つ (ADR-0001 原則 9) 方針からは、これは弱点である。次の形で扱う。

- **型の一覧・意味・移行元は本 ADR が正典**とし、org 設定はその写しとみなす
- 型の**作成・改名・削除には `admin:org` スコープが要る**。エージェントの token (`repo` / `read:org` / `workflow`) では通らず、実測でも `POST /orgs/{org}/issue-types` は 404 を返す。一方、既存の型を Issue に**付与する**のはリポジトリ側の権限 (`issues: write`) で足りる (実測済み)
- この非対称は [ADR-0003](0003-agent-identity-separation.md) が App に `Administration: No access` を与えたのと同じ性質を持つ。**エージェントは分類を使えるが、分類の語彙そのものは書き換えられない。** 望ましい非対称なので、埋めにいかない
- 型が org と ADR でずれる可能性は残る。型は 5 つで人の目が届くため、今は突き合わせの検査を作らない (実需が機能を駆動する — 原則 4)。ずれが実際に起きたら検査を入れる

### 4. 単値化は「より具体的な性質」を優先する

移行時に複数の `type:` ラベルを持つ Issue は、**`Bug` > `Design` > `Docs` > `Task`** の優先で 1 型に畳む。`Task` (保守) が最も一般的で、他のどの型にも「保守でもある」と言えてしまうため、最後に置く。以後も型に迷ったら同じ順で考える。

### 5. 自動付与の経路は変えず、付けるものだけを型に変える

分類を機械が下書きし、起票者には何も要求しない (ADR-0002 決定 1) 方針は維持する。経路は三つのまま:

| 経路 | 変更前 | 変更後 |
| --- | --- | --- |
| `.github/ISSUE_TEMPLATE/*.md` | front matter の `labels` | front matter の `type` |
| `.github/workflows/triage.yml` | タイトル prefix → `type: *` ラベル | タイトル prefix → `gh issue edit --type` |
| `scripts/sub-issue.sh` | 親の `type:` ラベルを継承 | 親の issueType を継承 |

prefix が無い起票は無分類のままにする。**推定できないものを機械が埋めない** — トリアージの議論で人が決める。

## 影響

- `type: *` ラベル 6 種をリポジトリから削除する。closed を含む既存 Issue には決定 2 の対応表と決定 4 の優先順で**遡及して型を付ける** (実施は #79)
- 検索の書き方が変わる: `label:"type: bug"` → `type:"Bug"`。旧来の `type:issue` / `type:pr` と綴りが衝突するため、**文書に書く例は引用符つきに統一する**
- ADR-0002 決定 1 のうち分類の表現に関する部分は本 ADR が上書きする。ライフサイクル (`verify:` の付与がトリアージ完了の印。当時併用していた `status: needs-triage` は [#156](https://github.com/mokume-metal/mokume/issues/156) で廃止した) と着手の条件は変更しない
- 型の追加・改名はメンテナの操作になる (決定 3)。エージェントは ADR に提案を書くところまでを担う
- `scripts/sub-issue.sh` の継承がラベルから型に変わる。`--test` で作る使い捨て Issue も親の型を継ぐ
- AGENTS.md の「進め方」「sub-issue の使い方」を本 ADR に接続する
