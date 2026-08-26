# ADR-0002: Issue ライフサイクルとマージ承認

## 状態

採用 (2026-08-26)

## 文脈

このリポジトリの main へのマージは merge queue と required check (`ci-gate`) が機械的に守っている (ADR-0001 原則 8)。しかし CI が保証できるのは不変条件と回帰の不在であって、「その PR で Issue が解消したか」は別問題である。解消の判定が機械検査で表現できる場合 (テスト・lint・golden image) は green を根拠に自動でマージしてよいが、判断を含む場合 (設計の良し悪し・文書の質・API の手触り) は人間の確認を挟みたい。

一方で、Issue の起票は雑なメモ・思いつき・不確かな報告を歓迎したい。「解消条件が機械判定可能か」は起票時には分からないことが多く、事実確認と意図の議論を経て初めて決まる。分類を起票の条件にすると、気軽に積める文化を壊す。

また本 ADR を書いた時点では、メンテナと AI エージェントが**同一アカウント**で PR を作っていた。GitHub は自分の PR を自分で承認できないため、native の required approving reviews が使えなかった (有効化すると全 PR がデッドロックする)。この前提は [ADR-0003](0003-agent-identity-separation.md) が解消し、決定 4 は native 一本化へ改訂されている。

## 決定

### 1. Issue のライフサイクル — 分類は議論の成果物

```
起票 (無条件)  →  議論  →  トリアージ完了  →  着手
```

- **起票**: 書式・分類を要求しない。新規 Issue には `status: needs-triage` が自動付与される
- **議論**: 事実確認・意図のすり合わせをコメントで行い、「どうなれば解消と言えるか」が収束したら **Issue 本文に反映する** (本文が正典・経緯はコメントに残る)
- **トリアージ完了**: 完了条件の機械判定可否を判定し、`verify: machine` (どの検査で判定するかを本文に明記) または `verify: human` を付与して `needs-triage` を外す。**verify ラベルの付与がトリアージ完了の印**
- 自明な Issue は議論を省略し、起票直後にメンテナがラベルを付けてよい (fast path)

### 2. 着手の条件

`status: needs-triage` のままの Issue には着手しない。着手時のプラン (Issue へのコメント) は、合意済みの完了条件を引用して書く。

### 3. PR のルーティング — review-gate

required check `review-gate` が PR ごとに判定する:

| 状態 | 判定 |
|---|---|
| `Closes #N` が無く `no-issue` ラベルも無い | 赤 (Issue 駆動の徹底) |
| 対象 Issue に `verify:` ラベルが無い | 赤 (完了条件が未確定のまま実装に入っている) |
| `verify: human` | メンテナの Approve レビューが付くまで赤 |
| `verify: machine` | 検査群 (`ci-check` 等) のみで通過 |
| Changes requested が未解消 | 赤 |

**重要パスの承認要求は review-gate ではなく CODEOWNERS が担う** ([ADR-0003](0003-agent-identity-separation.md))。`.github/CODEOWNERS` に挙げたパス (`docs/decisions/`・`.github/`・`.claude/`) に触れる PR は、GitHub が自動でメンテナへレビューを要求し、承認が無ければマージできない。公開 API 面はコードが生まれた時点で CODEOWNERS に追加する。

`verify: human` だけは CODEOWNERS で表現できない (パスではなく Issue の性質で決まる) ため、review-gate に残している。

### 4. 人間の承認は native の Approve レビューに一本化する

承認の表現は **GitHub native の Approve レビュー**とする。帰属・push による stale 化の扱い・複数メンテナへの拡張・CODEOWNERS 連携が揃った専用機構だからである。Changes requested のレビューが未解消の場合は赤のまま。

当初はメンテナと PR 作成者が同一アカウントで、自分の PR を Approve できなかったため、`review: approved` ラベルを暫定の fallback として認めていた。**この fallback は廃止した。** ラベルはエージェント自身も付けられるため、承認ゲートを止めているのが仕組みではなくエージェントの自制でしかなかった。

出口は [ADR-0003](0003-agent-identity-separation.md) が実行した — エージェントに GitHub App の identity を与えて PR の作成者を分離し、**自分の PR は自分で承認できない**というプラットフォームの制約が効く状態にしたうえで、ラベルをリポジトリから削除した。重要パスの承認要求は CODEOWNERS へ移り、そこでは App の承認では要件を満たせない (CODEOWNERS にはユーザーとチームしか書けない)。

### 5. 機械クラスの領土を広げ続ける

`verify: human` は「機械検査がまだ無い」ことの表明でもある。テスト・golden image・schema 照合が充実するほど、同種の Issue を `verify: machine` へ移す。新しい検査を入れるときは、対象を意図的に壊して**赤くなることを確認してから**組み込む (壊しても緑の検査は検査ではない)。

## 影響

- ラベル体系に `verify: machine` / `verify: human` / `no-issue` を追加する (`review: approved` も一度は追加したが、identity 分離の完了に伴い削除した)
- review-gate の実装は独立した Issue で行う。実装までの間、本 ADR のルーティングは運用で守る
- AGENTS.md の「進め方」と「マージの判断基準」を本 ADR に接続する
- エージェントは `needs-triage` の Issue に着手できない。議論を経ずに merge へ到達する経路が構造的に消える
- ADR・workflows・`.claude/` の変更は常にメンテナの承認を要する。当初この効果は規約止まりだったが (ラベルはエージェント自身も付けられた)、[ADR-0003](0003-agent-identity-separation.md) の identity 分離と CODEOWNERS への移行によって**構造として成立した**
