<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0044: PR はメンテナ名義で作り、承認のゲートを置かない

## 状態

採用 (2026-10-05)

## 文脈

### 承認のゲートは、何も変えていなかった

[ADR-0003](0003-agent-identity-separation.md) は、エージェントが PR を開く主体を GitHub App (`mokume-agent[bot]`) に分け、重要パスに触れる PR にメンテナの native の Approve を 1 つ要求した。目的は、エージェントが自分を縛る柵 (`.github/`・`.claude/`・判定のスクリプト) を書き換えて自分で通すことを、構造で止めることだった。[ADR-0007](0007-approvability-invariant.md) は、その形で誰も承認できない PR が出ないように、承認可能性を不変条件として置いた。

直近に merge された 200 本 (#1600〜#2106) を数えた ([#2108](https://github.com/mokume-metal/mokume/issues/2108))。

| 介入点 | 母数 | 人が何かを変えた回数 |
| --- | --- | --- |
| PR の native Approve | メンテナがレビューした 62 本 | **0** (62 本すべて APPROVED。Changes requested 0、本文付きのレビュー 0) |
| 着手前のプラン | 08-31 以降の `ExitPlanMode` 108 回 ([ADR-0036](0036-unattended-issue-processing.md) の文脈) | **6** (すべて言葉つきの却下) |

承認は 62 回働いて、何も変えていない。人の言葉が実際に入っているのは、実装の前である。実装の後に diff を見せて「押してください」と求める形では、人が上乗せできることがほとんど無い。CI・テスト・反証役 ([ADR-0040](0040-bugs-as-broken-promises.md)) が既に見ているうえ、差し戻すには遅すぎる。

### 分離は、もともと強制になっていなかった

ADR-0003 決定 6 自身が書いているとおり、この分離は暗号的でない。エージェントは同じ機械でメンテナの `gh` の認証と署名鍵を持つので、`gh pr review --approve` もルールセットの適用・解除も打てる。それを止めていたのは、手元のフックと auto mode の分類器である。App の有無とは関係が無い。

### 維持のコストは大きかった

- 秘密鍵の配布 (`MOKUME_APP_PRIVATE_KEY_CMD`)。鍵が取れないと PR を作れずに止まる
- `gh-app-token.sh`・`pr-identity-guard.sh`・`rerequest-review.sh` とそのテストで、合わせて約 2,250 行
- 「token の発行から gh までを `&&` で 1 本につなぐ」作法と、それを見張るフック
- App の token では workflow を rerun できない
- squash merge で bot が author、メンテナが `Co-authored-by` になる。vigilant mode を有効にしたメンテナの画面では、すべてのコミットが「Partially verified」と出る (API 上は `verified: true`)

### 外の手法も、1 人と手元のエージェントでは同じ強さにしかならない

| 手法 | この構成での評価 |
| --- | --- |
| エージェントに別名義 + 人が 1 承認 (GitHub Copilot coding agent の型) | クラウド側で認証が分かれていることが前提。手元で認証を共有する構成では、今の形と同じ |
| ルールセットの bypass (`pull_request` モード) でメンテナが迂回して merge | エージェントも同じ認証で `--admin` を打てる |
| push ruleset (パス単位で push を禁止) | private / internal 専用で、public のこのリポジトリでは使えない |
| Environments の required reviewers | 1 人では「自分で承認できる」か「誰も承認できない」かの二択 |
| Copilot に承認させる (2026-09 のプレビュー) | 機械が承認者になるだけで、目的に合わない |

## 決定

### 1. PR はメンテナ名義で作る

エージェントは PR を、メンテナの `gh` の認証のまま作る。GitHub App は使わない。コミットの author と署名がメンテナであることは変わらない (ADR-0003 決定 7)。squash のコミットは author がメンテナになり、共著者の行が付かないので、画面上も Verified と出る。

### 2. native の承認を要求しない

ルールセットの `required_reviewers` を空にし、`required_approving_review_count` は 0 のままにする。承認を要する PR は無くなる。merge の条件は、必須チェックの `ci-gate` と `render` だけになる。

`require_extra_approval_for_unattributed_changes` と `dismiss_stale_reviews_on_push` は、承認数 0 では効かないので定義に残す。消すと GitHub が既定の値で埋め直しうる (ADR-0003 決定 4 の未確認点 3)。

### 3. 人の目は、実装の前と後の振り返りに置く

重要パスを含め、人の判断を受け取る場所は次の 2 つとする。

- **着手前**: プランと、意味・代償を新たに選ぶときの問い ([ADR-0036](0036-unattended-issue-processing.md) 決定 2・8)。実測で人の言葉が入っているのはここである
- **後から**: 変更を束ねた報告と、絵の一覧 (ADR-0036 決定 7)。人の介入点の再設計は [#2109](https://github.com/mokume-metal/mokume/issues/2109) が扱う

柵の変更 (`.github/`・`.claude/`・判定のスクリプト) を承認で止めることはしない。柵を動かす変更は、着手前のプランに書く。

### 4. 移行は 2 段で行う

承認が要る今の柵の中で移るので、順序に制約がある ([#2108](https://github.com/mokume-metal/mokume/issues/2108))。

1. **承認のゲートを外す。** この ADR と、`required_reviewers` を空にした定義を、App 名義・承認 1 の PR で入れる。定義を読んでいた判定も同じ PR で外す — `review-gate.sh` の承認可能性の節・`stall-watch.sh` の承認待ちの読み分け・`pr-identity-guard.sh` の Draft の判定・`apply-rulesets.sh` の承認待ちの名乗り・`protected-paths.sh`・`rerequest-review.sh` と `review-request.yml` である。merge の後にメンテナが `scripts/apply-rulesets.sh --apply` で適用する
2. **App identity を外す。** 適用の後に、メンテナ名義・承認なしの PR で、`gh-app-token.sh`・`pr-identity-guard.sh` (名義の判定)・`guard-lib.sh` の token の見立てと、AGENTS.md の「エージェントの identity」節を外す。この PR が承認なしで通ること自体が、新しい流れの確認になる
3. 最後に、リポジトリの外で App をアンインストールし、秘密鍵を失効させる

1 は #2111、2 は #2112 で入った。3 だけが残り、[#2108](https://github.com/mokume-metal/mokume/issues/2108) が追う。

### 5. 採らなかった案

- **現状維持**: 守りの実効性は手元の層と同じで、コストだけを払い続ける
- **手元のフックで、重要パスの PR の merge を `ask` で人へ返す**: 流れ作業の承認を手元に作り直すだけになる。押すだけの確認を増やすと、本当に見るべき 1 回まで反射で押すようになる
- **エージェントにメンテナの認証を触らせない** (別の macOS ユーザーで動かす、メンテナの token を生体認証の奥に置く): GitHub 側で本当に強制できる唯一の形だが、今より重く、署名の主体も分け直す必要がある。強制が要る実害が出たときに改めて検討する
- **App だけを外し、`required_reviewers` を残す**: メンテナ名義の PR はメンテナ自身が承認できないので、重要パスの PR が誰にも承認できなくなる ([#88](https://github.com/mokume-metal/mokume/issues/88) と同じ詰み)

## 影響

- **柵の変更も、他の PR と同じく必須チェックだけで merge される。** 守りは文書の規約と着手前のプラン、後からの振り返りだけになる。フックの効かない環境 (Codex など) でも同じである
- **`review-gate` を既定ブランチの版で走らせる仕組みの脱出口 ([ADR-0031](0031-triage-as-the-single-gate.md) 決定 2 の 2026-10-03 改訂) が、前提を失う。** PR が `ci.yml` の `ref` の行を外せば、自分の版の判定で通せる。突くには `ci.yml` を意図して書き換える必要があり、それは PR の diff と着手前のプランに現れるので、代償として受け入れる
- **dependabot の PR も、他の PR と同じく必須チェックだけで入る。** [ADR-0005](0005-pr-labels-as-machine-input.md) 決定 4 が根拠にしていた「`.github/workflows/` を触るので毎回承認が入る」は成り立たなくなる
- **ルールセットの適用・解除は、エージェントにもできる操作として認める。** 実態は ADR-0003 の頃から同じで、文書が実態に揃う。適用は引き続き定義ファイルの PR から行う ([ADR-0006](0006-github-settings-as-code.md))
- auto mode の分類器は、メンテナのユーザー設定が「ゲートが green なら merge まで」を明示的に許しているので、承認なしの auto-merge で止まらない
