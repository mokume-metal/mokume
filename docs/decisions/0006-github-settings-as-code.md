# ADR-0006: ブランチ保護の正本をリポジトリの定義ファイルに置く

## 状態

採用 (2026-08-27)

## 文脈

[#6](https://github.com/mokume-metal/mokume/issues/6) でブランチ保護と merge queue を適用し、三本のルールセット (`main-protection` / `signed-commits` / `release-tags`) が main と タグを守っている。適用したときの内容と根拠は Issue のログに残した。

残っていないのは**設定そのもの**である。正本は GitHub の管理画面の状態だけで、リポジトリにあるのは [ADR-0003](0003-agent-identity-separation.md) の散文 — 「App を bypass list に加えない」「`required_approving_review_count` は 0 のままにする」— にすぎない。ADR は「なぜそうしたか」を持つが、「いま何が適用されているか」は持たない。

この状態には四つの綻びがある。

**1. 差分が見えない。** 誰かが UI から 1 項目変えても、レビューも記録も残らない。変更の履歴として辿れるのは GitHub の audit log だけで、リポジトリの履歴には現れない。

**2. 再現できない。** 同じ保護を別のリポジトリに組み立て直す手順が、どこにも無い。

**3. 根拠と設定が離れている。** ADR-0003 が守っている「App を bypass list に入れない」は、実設定を人が開いて見るまで確かめられない。

**4. 「正典の在処」から外れている。** AGENTS.md は設計判断を ADR に、経過を Issue / PR に置くと決めている。この設定だけが例外として管理画面に住んでいる。

[ADR-0001](0001-founding-principles.md) 原則 8「検証は規約でなく構造で」に照らせば、**誰でも 1 項目変えられて誰も気づかない状態は、構造になっていない**。

### 実測でわかった三つの前提

設計の分岐点になったので記録する (2026-08-27 時点)。

| 事実 | 影響 |
| --- | --- |
| public repo のルールセットは**匿名でも読める**が、**`bypass_actors` だけは認証が要る** | ADR-0003 が最も守っている項目だけが、token 無しの検査からは見えない |
| リポジトリの Actions secrets / variables は 0 件 | CI から App の token を得る経路が存在しない |
| エージェントの App は `Administration: No access` (ADR-0003 決定 1) | **適用はメンテナの認証でしか通らない** |

## 決定

### 1. 正本を `.github/rulesets/*.json` に置く

ルールセットの定義をリポジトリに持ち、GitHub 側の状態はその写しとして扱う。ファイル名は `name` と一致させる (どのファイルが何を定義しているかがディレクトリから読める)。

### 2. 表現は rulesets API の正規形 JSON

API の応答をそのまま持つ。読みやすい YAML から生成する案は採らない — 往復の実装が増えるだけで、得るものは字面の好みしかない。

GET の応答から次の鍵を落としたものを正規形とする: `id` / `node_id` / `_links` / `created_at` / `updated_at` / `source` / `source_type` / `current_user_can_bypass`。いずれも環境ごとに決まる識別子か GitHub 側の派生値で、定義ファイルが持つと別の org へ持って行った瞬間に嘘になる。

**`bypass_actors` は空でも省略しない。** ADR-0003 決定 1 の「App を bypass list に入れない」は、書かれていて初めて検査できる。

### 3. 適用主体はメンテナ

適用は `scripts/apply-rulesets.sh` で行い、**既定は dry-run**、実際に書き換えるのは `--apply` を明示したときだけとする。main の保護を書き換える操作だからである。定義に無いルールセットの**削除はしない** (存在を知らせるに留める)。

エージェントの App に `Administration` を与えないという ADR-0003 決定 1 の帰結として、この操作は**エージェントの token では通らない**。定義ファイルは通常どおり Issue → PR で回り、適用だけが人の手に残る。

**ただしこれは暗号的な分離ではない。** [ADR-0003](0003-agent-identity-separation.md) 決定 6 が承認について述べている制約が、適用にもそのまま及ぶ — 同じマシンにメンテナの認証が残っている限り、エージェントがそちらを使って適用する経路は理屈上残る。実際、[#98](https://github.com/mokume-metal/mokume/issues/98) の完了確認ではメンテナの明示的な許可のもとでエージェントが適用を実行している。得られるのは次の二つであり、それ以上を主張しない。

- **意図しない適用が起きない** — App の権限の既定として不可能になる
- **誰が適用したかが残る**

より強い分離が要るようになったら、答えは ADR-0003 決定 6 と同じ — エージェントの実行環境をメンテナの認証情報から隔離する — であって、権限表の書き換えではない。

### 4. 検査は二層に分ける

| 層 | 契機 | token | 見るもの |
| --- | --- | --- | --- |
| 形の検査 | PR (`make ci-check` 経由で `ci-gate` の下) | 不要 | 定義が API に投げられる形か (必須の鍵・落とすべき鍵・`target` / `enforcement` の値・ファイル名と `name` の一致) |
| ドリフト検査 | `schedule` + `workflow_dispatch` | 検査専用 App | 定義と実設定の差分 (`bypass_actors` を含む) |

**ルールセットの状態は PR の内容と独立に変わる。** 誰かが管理画面で 1 項目変えることが、この仕組みが拾いたい事象である。PR ごとに実設定を照合しても意味が薄く、fork からの PR には secret も渡らない (外部コントリビュータの PR が token 取得で落ちる)。契機を分ける。

照合では、`rules` と ref_name の `include` / `exclude` を並べ替えてから比較する (API が返す順に保証が無く、順序差だけで赤くしないため)。

### 5. ドリフト検査は検査専用の第二の App で行う

権限は `Administration: Read` + `Metadata: Read` のみの App を別に作り、その鍵だけを Actions secret に置く。使う契機は `schedule` / `workflow_dispatch` に限る。

エージェント用の App に `Administration: Read` を足してその鍵を CI に置く案は却下した。その App は `Contents: write` と `Workflows: write` を持ち、**`pull_request` トリガのジョブは同一リポジトリのブランチからの PR でブランチ側のワークフロー定義が動き、secret も渡る**。エージェントは App の identity で push できるので、細工したワークフローを載せた PR を開けば、メンテナの承認前にその run で鍵を読める (CODEOWNERS は merge を止めるが run は止めない)。書き込み権限を持つ鍵を CI に置くことは、それ自体が新しい露出面になる。

scheduled workflow はデフォルトブランチの定義しか実行されないため、この経路は `schedule` 限定の使用と最小権限の組み合わせで塞がる。ドリフト検出時の Issue 起票は `GITHUB_TOKEN` 側で行い、検査 App に `Issues: write` を持たせない。

### 6. ADR-0003 決定 1 の権限表は改訂しない

決定 5 の帰結として、エージェントの App は `Administration: No access` のままでよい。「エージェントは自分を縛るルールセットを外せない」という ADR-0003 の主張は、そのまま生きる。

### 7. 当面の対象はルールセット三本に限る

[#6](https://github.com/mokume-metal/mokume/issues/6) で同時に適用したリポジトリ設定 (squash only・delete-branch-on-merge・auto-merge 許可・secret scanning・Actions の既定権限) は対象外とする。これらは依然 GitHub 側が正本である。必要になったら同じ形で足せる。

### 8. 既製ツールには乗らない

Terraform GitHub provider は state の置き場が増える。Probot safe-settings は別の App の常駐と `Administration: write` の付与を要し、自動適用は決定 3 と衝突する。やることは JSON 三本の PUT と差分比較だけで、どちらとも釣り合わない。

## 影響

- ルールセットの変更は PR を通る。レビューと履歴が残り、`.github/` は CODEOWNERS の対象なのでメンテナ承認も要る
- メンテナの手が要る場面が一つ増える (定義を merge した後の `--apply`)。一方で「管理画面で直接いじる」経路は、規約の上では閉じる
- GitHub App が二つになる (作業用と検査用)。用途と権限が分かれるので、鍵が漏れたときの被害範囲も分かれる
- 検査専用 App と scheduled のドリフト検査が入るまでの間、実設定との照合は手元で `bash scripts/check-rulesets.sh` を打つ運用になる ([#99](https://github.com/mokume-metal/mokume/issues/99))
- リポジトリ設定・セキュリティ設定は当面 GitHub 側が正本のまま残る。ここだけ二重基準になるが、範囲を広げるより先に、三本で仕組みが回ることを確かめる
