<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

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
| public repo のルールセットは**匿名でも読める**が、**`bypass_actors` だけは認証が要る** | ADR-0003 が最も守っている項目だけが、token 無しの検査からは見えない (**この読みは不正確だった** — 実際には ruleset への *write access* が要る。決定 5 の改訂を見よ) |
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

### 4. 検査は二層に分ける (2026-08-29 改訂 — ドリフト検査の契機を増やした)

| 層 | 契機 | token | 見るもの |
| --- | --- | --- | --- |
| 形の検査 | PR (`make ci-check` 経由で `ci-gate` の下) | 不要 | 定義が API に投げられる形か (必須の鍵・落とすべき鍵・`target` / `enforcement` の値・ファイル名と `name` の一致) |
| ドリフト検査 | `schedule` + `push` (main の `.github/rulesets/**`) + `workflow_dispatch` | `GITHUB_TOKEN` | 定義と実設定の差分 (`bypass_actors` は**除く** — 決定 5 の改訂) |

**ルールセットの状態は PR の内容と独立に変わる。** 誰かが管理画面で 1 項目変えることが、この仕組みが拾いたい事象である。PR ごとに実設定を照合しても意味が薄く、fork からの PR には secret も渡らない (外部コントリビュータの PR が token 取得で落ちる)。契機を分ける。

**改訂 (2026-08-29) — 適用忘れは日次では遅い。** 当初の契機は日次と手動だけで、決定 3 が人の手に残した `--apply` が打たれたかを見る経路が無かった。[#308](https://github.com/mokume-metal/mokume/pull/308) の merge 後、定義だけが先行した状態が約 15 時間続いている ([#381](https://github.com/mokume-metal/mokume/issues/381))。cron は日次なので窓は merge の時刻次第で最大 24 時間、`schedule` の遅延と欠落を見込めば最悪 36 時間を超える。**定義が main に入った瞬間は分かっている**ので、そこを契機に足す — 上の「PR ごとに照合しても意味が薄い」はそのまま生きている。足したのは PR の内容ではなく、**定義が正典になった瞬間**である。

**push 契機では起票しない。** merge 直後に実設定が追いついていないのは正常な状態なので、起票すると定義を変えるたびに人が処理すべき Issue が積み増され、本物のドリフト (管理画面での直接変更) の起票まで反射で閉じられるようになる。催促は run の赤とその失敗通知が運び、見落として翌日まで残れば `schedule` が従来どおり起票する — 赤 → 翌日 Issue の段階的な上げ方になる。判断は `scripts/report-ruleset-drift.sh` が `GITHUB_EVENT_NAME` を見て下し、`scripts/tests/ruleset_drift_test.py` が両側から固定する。新しい workflow もラベルもスクリプトも増えない ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 5 の段 1)。

照合では、`rules` と ref_name の `include` / `exclude` を並べ替えてから比較する (API が返す順に保証が無く、順序差だけで赤くしないため)。

### 5. ドリフト検査に検査専用の App は使わない (2026-08-27 改訂)

**当初の決定**は「権限を `Administration: Read` + `Metadata: Read` に絞った第二の App を作り、その鍵だけを Actions secret に置き、使う契機を `schedule` / `workflow_dispatch` に限る」だった。[#99](https://github.com/mokume-metal/mokume/issues/99) で実装して実地確認したところ、**その根拠になっていた読みが二つとも誤りだった**ので撤回する。

**実測 1 — `bypass_actors` は read-only では見えない。** GitHub のドキュメントに明記がある: 「情報の漏洩を防ぐため、`bypass_actors` は API を叩く者が ruleset への **write access** を持つ場合にのみ返る」。`Administration: Read` では返らない。当初の決定が確かめていたのは「匿名では見えない」「メンテナ認証では見える」の二点だけで、その中間 (read-only の App) を確かめないまま設計に組み込んでいた。**read-only の検査 App は、匿名読み取りと同じものしか見られない。**

**実測 2 — `schedule` 限定という前提が成り立たない。** 「scheduled workflow は既定ブランチの定義しか実行しない」は正しいが、この workflow は `workflow_dispatch` も持つ。`workflow_dispatch` は**選んだ ref の定義を実行し、リポジトリ secret をそのまま渡す** ([run 33041322529](https://github.com/mokume-metal/mokume/actions/runs/33041322529) で実測。使い捨てのブランチに「秘密の長さだけを出す」定義を置いて確かめた)。GitHub のドキュメントは既定ブランチの定義が使われるとも読める書き方をしているが、実際は違う。

`Administration: Write` へ上げる案は採らない。この権限は粒度が分かれておらず、同じ鍵でリポジトリの削除・移管、collaborator と team の追加削除、**ルールセットの削除**、Actions・runner・webhook・Environment の設定変更まで通る。エージェントは `contents: write` と `workflows: write` を持ち、決定 3 と [ADR-0003](0003-agent-identity-separation.md) 決定 6 が認めるとおり同じマシンにメンテナの認証がある以上、細工したブランチを dispatch すれば鍵に手が届く。**ADR-0003 決定 1 の「エージェントは自分を縛るルールセットを外せない」が、権限表を一文字も変えないまま迂回される。** Environment secret のブランチ制限でこの経路は塞げるが、塞いだ後も「リポジトリを消せる鍵の常設」は残り、保証は「権限として不可能」から「ポリシーが守っている」へ格下げされる。[ADR-0008](0008-mechanism-needs-demonstrated-harm.md) が要求する実害 — 誰かが bypass を足した事実 — はまだ無い。

したがって:

- **検査専用 App は作らない。** 作ったものは削除する
- ドリフト検査は `GITHUB_TOKEN` で行い、`bypass_actors` **以外**を照合する
- **緑が何を意味するかは照合の出力が名乗る** (`--without-bypass-actors`)。「読めないまま一致とは言わない」という筋は、黙って通すのではなく**見ていない項目を明示する**形で保つ。このフラグは「読めなかったときに許す」であって「常に無視する」ではない — 読める認証で付けても bypass の追加は赤になる
- `bypass_actors` はメンテナが手元で `scripts/check-rulesets.sh` を引数なしで打つときに見る (読めなければ赤)。ADR-0003 決定 1 が最も守っている項目だけは、当面 人の手に残る
- 機械で見張るなら `repository_ruleset` webhook を受ける先が要る。実害が出てから足す (ADR-0008)

ドリフト検出時の起票を `GITHUB_TOKEN` で行う点は当初のまま変わらない。

### 6. ADR-0003 決定 1 の権限表は改訂しない

決定 5 の帰結として、エージェントの App は `Administration: No access` のままでよい。「エージェントは自分を縛るルールセットを外せない」という ADR-0003 の主張は、そのまま生きる。

### 7. 当面の対象はルールセット三本に限る

[#6](https://github.com/mokume-metal/mokume/issues/6) で同時に適用したリポジトリ設定 (squash only・delete-branch-on-merge・auto-merge 許可・secret scanning・Actions の既定権限) は対象外とする。これらは依然 GitHub 側が正本である。必要になったら同じ形で足せる。

### 8. 既製ツールには乗らない

Terraform GitHub provider は state の置き場が増える。Probot safe-settings は別の App の常駐と `Administration: write` の付与を要し、自動適用は決定 3 と衝突する。やることは JSON 三本の PUT と差分比較だけで、どちらとも釣り合わない。

## 影響

- ルールセットの変更は PR を通る。レビューと履歴が残り、`.github/` は CODEOWNERS の対象なのでメンテナ承認も要る
- メンテナの手が要る場面が一つ増える (定義を merge した後の `--apply`)。一方で「管理画面で直接いじる」経路は、規約の上では閉じる。**打ち忘れは merge のその場で赤くなる** (決定 4 の改訂) ので、忘れたことが翌日まで見えない状態は無くなった
- **GitHub App は作業用の一つのままでよい** (決定 5 の改訂)。CI には鍵を置かないので、鍵が漏れる面が増えない
- **`bypass_actors` の照合だけは自動化されない。** 日次のドリフト検査が拾うのはそれ以外の全項目で、`bypass_actors` はメンテナが手元で `bash scripts/check-rulesets.sh` を打ったときに見る。この検査の緑は「`bypass_actors` を除いて一致」を意味し、出力自身がそう名乗る
- リポジトリ設定・セキュリティ設定は当面 GitHub 側が正本のまま残る。ここだけ二重基準になるが、範囲を広げるより先に、三本で仕組みが回ることを確かめる
