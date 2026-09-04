# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 手元の実行の報告に使う commit status の context の綴り (#785)。
#
# 読み手は 2 つあり、**役割が逆向き**である:
#
#   打つ側  scripts/render-status.sh — この名前で status を post する (#304)
#   探す側  scripts/render-status.sh の covered_fingerprint() と
#           scripts/catch-up.sh    — この名前の status を commit から探す
#
# 綴りを片方だけ変えると、**打つ側は新しい名前で打ち、探す側は古い名前を探し続ける**。
# 症状は「手元で make ci-check を通して報告を打ち直しても覆いが見つからず、すべての
# 描画 PR が常時弾かれる」で、原因が綴りの割れだとは読めない (render-status.sh の
# local_drawing_fingerprint が、別の文脈でまさにこの壊れ方を警告している)。だから
# **綴りの出どころをここ 1 つ**に保つ (ADR-0001 原則 9)。
#
# **.github/rulesets/main-protection.json からは読まない。** あちらが必須チェックの
# 正本 (ADR-0006) だが、required_status_checks には ci-gate と local-render の 2 件が
# 並んでいて、**どちらが手元の描画報告かは綴りそのものでしか区別できない**。
# protected-paths.sh が required_reviewers[].file_patterns という構造的な位置で引ける
# のとは事情が違い、読みに行っても結局綴りを持つか「N 番目」に頼ることになる。
# 綴りを変えるときは、ここと定義ファイルの両方を動かす (ADR-0006 決定 3 の順序 —
# 必須チェックを消す・改名するときは --apply が先である)。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/render-context.sh"
#   gh api "repos/$repo/statuses/$sha" -f context="$RENDER_CONTEXT" …
#
# テストは scripts/tests/render_status_test.py と scripts/tests/catch_up_test.py が、
# それぞれの読み手を通して行う (別の綴りを指して、打つ側と探す側が揃うことを見る)。

# 報告の context。テストは別の綴りを指す。**readonly にしない** — 他の共有ファイルと
# 同じく、二重に source されても壊れないため
RENDER_CONTEXT=${RENDER_CONTEXT:-local-render}
