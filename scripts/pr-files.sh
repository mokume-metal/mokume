# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「この PR が触ったファイル」の取り方 (#793)。
#
# 以前は取り方が 2 通りあり、**片方だけがページングしていた**。
#
#   gh api "repos/…/pulls/N/files" --paginate   … 全件
#   gh pr view --json files                     … GraphQL の files 接続。上限がある
#
# 後者に `--paginate` に相当する口は無いので、**大きな PR では後半のファイルが一覧から
# 落ちる**。落ちた先で起きることは、どれも赤くならずに緩む方向である:
#
#   scripts/review-gate.sh            保護パスに触れているのに「触れていない」と読み、
#                                     誰も承認できない PR を作らない検査が素通りする
#                                     (ADR-0007 の不変条件を守る側)
#   scripts/check-drawing-evidence.sh 描画のパスに触れているのに「触れていない」と読み、
#                                     絵の証跡の要求が外れる (#306 が黙って効かなくなる)
#   scripts/catch-up.sh               描画 PR を「触れない」と判定して断る
#
# **一覧そのものは GitHub が持ち、それを取る口はここ 1 つに保つ。** drawing-paths.sh が
# 「一覧は drawing-paths.txt が持ち、読む照合はここ 1 つ」と書いているのと同じ形で、
# あちらが守っている照合の手前 (材料の取得) がこれである
# ([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。
#
# **照合ライブラリの中には置けない。** 材料は 2 つの照合へ流れる — review-gate は
# protected-paths.sh へ、他は drawing-paths.sh へ渡す。どちらかに置くと、他方から見て
# 他人の責務になる (ADR-0008 決定 5 の段を順に見て、既存の族に倣った 1 本を足した)。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
#   files=$(pr_files "$repo" "$number") || …   # 読めなかったときの逃がしは呼び出し側
#
# テストは scripts/tests/pr_files_test.py。

# PR の変更ファイルのパスを 1 行 1 件で stdout へ。読めなければ非 0 で、何も出さない。
#   $1 = owner/repo (**空でよい** — gh の {owner}/{repo} プレースホルダに倒す)
#   $2 = PR 番号
#
# `$1` を空で呼べるようにしてあるのは、check-drawing-evidence.sh が
# GITHUB_REPOSITORY の無い手元から走るためである。ここで倒さないと、呼び出し側が
# `gh repo view` でリポジトリ解決を 1 回増やすことになる。
#
# **判定はしない。** 描画のパスか・保護パスかを見るのは照合ライブラリの仕事で、
# ここは材料を渡すだけである。
pr_files() { # $1=owner/repo (空可) $2=PR 番号
  local repo=${1:-} number=${2:?PR 番号が必要}
  [ -n "$repo" ] || repo='{owner}/{repo}'
  gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename'
}
