#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 外に置いた資産の死活の赤を発信する (#1295)。
#
#   report-dead-assets.sh <死活検査の出力ファイル>
#
# 発信の実体は scripts/report-check-failure.sh が持ち、ここが持つのは**固定タイトルと
# 本文**だけである。ここを report-ruleset-drift.sh の写しにしないのが #1295 の要点で、
# 判断の在処は共有の置き場の冒頭にある。
#
# ## なぜ足したか
#
# publication の assets は **2026-09-15 から 7 日連続で赤**だったのに誰も拾わず、その間
# 「参照している視覚証跡 178 本がすべて 404」という事象が届かなかった (#1294)。
# .github/workflows/publication.yml の冒頭は「赤を見落とす事象が実際に起きたら、
# ruleset-drift.yml と同じ形で起票を足す」と予告していた — その日が来たので足した
# (ADR-0008 の順序: 実害 → Issue → 機構)。
#
# ## freshness は入れていない
#
# publication のもう 1 つのジョブ (公開が手元の main に追随しているか) は、**赤を見落とした
# 実害がまだ無い**。同じ理由で assets も長く起票を持たなかったので、ここでも順序を守る —
# 踏んだ日に、この形をそのまま写さず共有の置き場を呼ぶ 1 本を足せばよい。
#
# 呼び出しは .github/workflows/publication.yml、検査は scripts/tests/dead_assets_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む。
# 接頭辞が `fix(` なので triage.sh が Bug を付ける — 動いていたものが読めなくなった事象で、
# AGENTS.md の「迷ったら Bug > Design > Docs > Task」に従う
readonly TITLE="fix(docs): 外に置いた視覚証跡が引けない"

LOG="${1:?死活検査の出力ファイルが必要}"
[ -f "$LOG" ] || { echo "死活検査の出力ファイルが無い: $LOG" >&2; exit 66; }

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# Issue 本文の相対リンクは解決されないので、ADR へは絶対 URL で張る
base="${GITHUB_SERVER_URL:-https://github.com}/$REPO/blob/main"

{
  printf '定期の死活検査で、**外に置いた視覚証跡が引けなくなっている**ことを検出した (引けなかった指し先は下の「検査の出力」)。\n\n'
  printf '[ADR-0027](%s/docs/decisions/0027-readable-surfaces.md) 決定 2 により、実行結果の絵はリポジトリに入らず外部ホスティングに置かれ、説明文に残るのはそれを指す 1 行だけである。指し先はこちらの都合と無関係に消えうるので、**壊れる瞬間はどの PR とも一致しない** — 日次で引くしかなく、この起票がその追跡単位である。\n\n' "$base"
  printf '重いのは、描画に影響する変更の検証記録が**貼られた絵しかない**ことである ([AGENTS.md](%s/AGENTS.md) の「描画に影響する変更」)。squash merge でブランチが消えた後には足せないので、読めなくなった絵はそのぶんの検証記録ごと失われている。\n' "$base"
  cat <<'BODY'

## 対処

1. **1 本か、全部か**をまず見る。個別の消失と、置き場の側で起きた事象では手が違う (全滅は #1294 で 1 度起きている)
2. 撮り直しの手順は `.claude/skills/visual-evidence/` が持つ。参照の面の絵は `make example-shots` で撮り直せる
3. 撮り直したら、**指している行の URL を差し替える** (ADR-0027 決定 2)。どの行が指しているかは下の出力が出所付きで名乗る

## 解消の判定

`python3 scripts/check-external-assets.py` が緑になれば解消。指し先が 1 本も拾えない状態は赤なので、**参照を消して緑にすることはできない**。

**解消したらこの Issue を閉じる。** open な間は重複起票を抑えるので、残したままにすると次に指し先が切れたときに起票されない。
BODY
} > "$body"

bash "$(dirname "${BASH_SOURCE[0]}")/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$LOG" \
  --body-file "$body" \
  --source '.github/workflows/publication.yml が自動起票した (#1295)'
