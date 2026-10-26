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
#   scripts/review-gate.sh            AGENTS.md に触れているのに「触れていない」と読み、
#                                     増分の宣言の検査が素通りする (#1668)
#   scripts/check-drawing-evidence.sh 描画のパスに触れているのに「触れていない」と読み、
#                                     絵の証跡の要求が外れる (#306 が黙って効かなくなる)
#
# **一覧そのものは GitHub が持ち、それを取る口はここ 1 つに保つ。** drawing-paths.sh が
# 「一覧は drawing-paths.txt が持ち、読む照合はここ 1 つ」と書いているのと同じ形で、
# あちらが守っている照合の手前 (材料の取得) がこれである
# ([ADR-0001](../docs/decisions/0001-founding-principles.md) 原則 9)。
#
# **照合ライブラリの中には置けない。** 材料は複数の読み手へ流れる — review-gate は
# AGENTS.md の増分へ、他は drawing-paths.sh へ渡す。どれかに置くと、他から見て他人の
# 責務になる (ADR-0008 決定 5 の段を順に見て、既存の族に倣った 1 本を足した)。
# (かつて review-gate の側は、承認が要るパスの照合 protected-paths.sh へ渡していた。
# ADR-0044 が承認のゲートごと外した — #2108)
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
#   files=$(pr_files "$repo" "$number") || …   # 読めなかったときの逃がしは呼び出し側
#
# **この形以外で呼ばない。** `pr_files … | touches_drawing` のようにパイプラインの
# 左辺へ置くと、`if` の条件では**取得の失敗と「触れていない」が同じ偽になる**
# (`set -o pipefail` の下でも、条件としての非 0 は分岐の偽にしかならない)。#1303 では
# その形が 3 箇所に残っていて、`render-status.sh` は 502 を掴んだ描画 PR に
# `local-render: success` を打っていた — 上の落ち方 (#793) と同じく、**どれも赤く
# ならずに緩む方向**である。
#
# **PR の材料を 1 回で取る事前取得を読む** (#3261)。pr-gate は 3 つの判定が同じ PR の
# メタデータと変更ファイルを別々に取っていた (PR のメタデータ 3 回・一覧 2 回)。先頭の
# pr-snapshot step が 1 回ずつ取って `MOKUME_PR_SNAPSHOT_DIR` の下へ置き (`files-<番号>.txt`・
# `view-<番号>.json`)、以降はここが読む。**置き場が未設定なら今までと同じ**で、手元から単体で
# 呼んだときの使い方は変わらない。
#
# **事前取得が欠けても緩む方向へは倒さない。** 置き場が設定されているのに、その PR のファイルが
# 無い・読めない・形が合わないときは、警告を出して従来の自前取得に戻る (取得 step が落ちた回は
# job が赤で、後ろの判定は環境変数が無いまま走る = 自前取得になる)。番号を名前に含めるので、
# 別の PR の事前取得を読むこともない。
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
  if [ -n "${MOKUME_PR_SNAPSHOT_DIR:-}" ]; then
    local snapshot="$MOKUME_PR_SNAPSHOT_DIR/files-$number.txt"
    # **同じ PR のメタデータ (view-<番号>.json) も揃っているときだけ読む。** pr-snapshot は
    # 一時の名前へ書いて、files を先に・view を後に置く。view が無いのは、途中で落ちた回の
    # 半端な files であり、空のファイルを「変更ファイル 0 件」と読むと、絵や AGENTS.md の検査が
    # 黙って外れる
    if [ -r "$snapshot" ] && [ -r "$MOKUME_PR_SNAPSHOT_DIR/view-$number.json" ]; then
      cat "$snapshot"
      return
    fi
    echo "pr-files: 事前取得 $snapshot が揃っていない — 自分で取り直す" >&2
  fi
  [ -n "$repo" ] || repo='{owner}/{repo}'
  gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename'
}

# PR のメタデータを JSON で stdout へ。読めなければ非 0。`gh pr view --json` の代わり。
#   $1 = owner/repo (**空でよい** — 空なら -R を付けず、gh が解く)
#   $2 = PR 番号
#   $3 = --json の欄 (カンマ区切り)
#
# 事前取得 (view-<番号>.json) が**番号と欄を満たすときだけ**それを返す。欄が足りない・値が null の
# ものを返すと、読み手の jq が null を「無い」と読んで黙って緩む。満たさなければ警告して gh を呼ぶ。
pr_view_json() { # $1=owner/repo (空可) $2=PR 番号 $3=--json の欄
  local repo=${1:-} number=${2:?PR 番号が必要} fields=${3:?--json の欄が必要}
  if [ -n "${MOKUME_PR_SNAPSHOT_DIR:-}" ]; then
    local snapshot="$MOKUME_PR_SNAPSHOT_DIR/view-$number.json"
    if [ -r "$snapshot" ] && jq -e --argjson n "$number" --arg fields "$fields" \
      '.number == $n and (. as $o | $fields | split(",") | all(. as $k | $o[$k] != null))' "$snapshot" >/dev/null 2>&1; then
      cat "$snapshot"
      return
    fi
    echo "pr-files: 事前取得 $snapshot が無い・読めない・番号か欄が合わない — 自分で取り直す" >&2
  fi
  local args=("$number" --json "$fields")
  if [ -n "$repo" ]; then args+=(-R "$repo"); fi
  gh pr view "${args[@]}"
}
