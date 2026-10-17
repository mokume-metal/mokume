#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Issue / PR の本文を、読んだ後に誰かが書き換えていたら書き込まずに止まる形で書き換える (#2615)。
#
# 素の `gh issue edit --body-file` は、手元の写しを読んだ後に本文が変わっていても黙って上書きする。
# #2610 では、別のエージェントが判断ごとの採択状態を書き直した 21 秒後に、古い写しを土台にした
# 書き込みがその改訂を丸ごと消した (経緯は #2615 の本文)。同じ Issue の本文を複数のエージェントが
# 直す運用 (棚卸し・再検討・判断の記録) では、後から書いた側が先の改訂を消す。
#
# 使い方:
#   scripts/edit-body.sh {issue|pr} <番号> --fetch <ファイル>
#       本文を <ファイル> へ書き出し、土台を <ファイル>.base.json に控える
#   scripts/edit-body.sh {issue|pr} <番号> --body-file <ファイル> [--base <土台>] [--dry-run]
#       書き込む直前に本文を取り直し、土台 (既定 <ファイル>.base.json) の本文と比べる。
#       変わっていれば誰がいつ変えたかと差分を示して止まる (終了コード 1)。変わっていなければ書き込む
#     --dry-run : 照合までして、gh を呼ばずに書き込むコマンドを stdout に出す
#
# 環境変数:
#   GITHUB_REPOSITORY  宛先のリポジトリ (既定は scripts/repo-slug.sh)
#
# **土台は本文の内容で比べる。** updatedAt はラベル・コメント・担当の変更でも動くので、本文に
# 触れていない変化まで止めてしまう。ハッシュでも比べられるが、内容を控えておけば「土台から
# 最新へ何が変わったか」を差分で見せられ、直し直す側がそれを読める。「誰がいつ」は GraphQL の
# lastEditedAt と editor から名乗る。editor はトークンの持ち主なので、同じメンテナのトークンで
# 動く複数のエージェントは同じ login に見える (分かるのはアカウントまで)。
#
# **土台は使い切り。** 書き込んだら控えを消す。GitHub が本文を整える (末尾の改行など) ことが
# あり、書いた内容を次の土台に流用すると、それとの食い違いで誤って止まるか、逆に整え直しを
# 土台に取り込む手当てが要る。続けて直すときは --fetch で取り直す。
#
# **残る競合 (TOCTOU)。** 取り直しと書き込みの間 (1〜2 秒) に入った改訂は検知できない。
# GitHub の本文の更新には版を指定する条件付きの書き込みが無いため。#2610 で踏んだのは 21 秒の
# 開きで、読んでから書くまでの開きを塞ぐのがここの役目である。gh api で本文を PATCH する経路も
# 見ない (scripts/agent-comment-guard.sh がコメントの gh api を見ないのと同じ水準)。
#
# **Issue の本文は描画の証跡の照合も通す** (#2195)。素の gh issue edit は
# scripts/issue-evidence-guard.sh が見ていたが、エージェントの本文の書き換えは
# scripts/agent-comment-guard.sh がこのラッパーへ回すので、照合 (check-drawing-evidence.sh
# --issue-body) をここで行う。
#
# 案内は scripts/agent-comment-guard.sh、テストは scripts/tests/edit_body_test.py。
set -euo pipefail

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=scripts/repo-slug.sh
. "$here/repo-slug.sh"
REPO="$(this_repo)"

usage() {
  cat >&2 <<'EOF'
使い方: scripts/edit-body.sh {issue|pr} <番号> --fetch <ファイル>
        scripts/edit-body.sh {issue|pr} <番号> --body-file <ファイル> [--base <土台>] [--dry-run]

例:
  scripts/edit-body.sh issue 42 --fetch /tmp/42.md      # 本文を書き出し、土台を /tmp/42.md.base.json に控える
  (/tmp/42.md を直す)
  scripts/edit-body.sh issue 42 --body-file /tmp/42.md  # 土台の後に変わっていなければ書き込む
EOF
  exit 64
}

# --- 引数 -------------------------------------------------------------------

[ $# -ge 2 ] || usage
KIND="$1"; NUMBER="$2"; shift 2
case "$KIND" in issue | pr) ;; *) echo "種別は issue か pr: $KIND" >&2; usage ;; esac
case "$NUMBER" in '' | *[!0-9]*) echo "番号が数値でない: $NUMBER" >&2; usage ;; esac
NUMBER=$((10#$NUMBER))

FETCH='' BODY_FILE='' BASE='' DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) FETCH="${2:?--fetch に書き出し先が必要}"; shift 2 ;;
    --body-file | -F) BODY_FILE="${2:?--body-file にパスが必要}"; shift 2 ;;
    --base) BASE="${2:?--base に土台のパスが必要}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

if [ -n "$FETCH" ] && [ -n "$BODY_FILE" ]; then
  echo "--fetch と --body-file は同時に使えない" >&2; usage
fi
[ -n "$FETCH" ] || [ -n "$BODY_FILE" ] || { echo "--fetch か --body-file が必要" >&2; usage; }
if [ -n "$FETCH" ] && { [ -n "$BASE" ] || $DRY_RUN; }; then
  echo "--base と --dry-run は --body-file と使う" >&2; usage
fi

command -v jq >/dev/null 2>&1 || { echo "jq が無い (本文の取得に使う)" >&2; exit 1; }

# --- 本文の取得 -------------------------------------------------------------
# issue と pr を 1 つの問い合わせで引き、__typename で種別の取り違えを止める
# (gh issue view は PR の番号でも本文を返すので、取り違えに気付けない)

readonly QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { body lastEditedAt editor { login } }
      ... on PullRequest { body lastEditedAt editor { login } }
    }
  }
}'

# 宛先の本文を 1 つの JSON (repo / kind / number / body / lastEditedAt / editor) で stdout へ
snapshot() {
  local raw typename want
  raw=$(gh api graphql -f query="$QUERY" -f owner="${REPO%%/*}" -f name="${REPO#*/}" \
    -F number="$NUMBER") || { echo "$KIND #$NUMBER の本文を取得できなかった ($REPO)" >&2; return 1; }
  typename=$(jq -r '.data.repository.issueOrPullRequest.__typename // ""' <<<"$raw")
  case "$KIND" in issue) want=Issue ;; pr) want=PullRequest ;; esac
  if [ "$typename" != "$want" ]; then
    if [ -z "$typename" ]; then
      echo "$REPO に #$NUMBER が無い" >&2
    else
      echo "#$NUMBER は $KIND ではなく $typename (種別を取り違えている)" >&2
    fi
    return 1
  fi
  jq --arg repo "$REPO" --arg kind "$KIND" --argjson number "$NUMBER" '
    .data.repository.issueOrPullRequest as $n
    | {repo: $repo, kind: $kind, number: $number, body: ($n.body // ""),
       lastEditedAt: $n.lastEditedAt, editor: ($n.editor.login // null)}' <<<"$raw"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 取得して土台を控える ---------------------------------------------------

if [ -n "$FETCH" ]; then
  snapshot > "$work/snap.json"
  jq -j '.body' "$work/snap.json" > "$FETCH"
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {fetchedAt: $at}' "$work/snap.json" \
    > "$FETCH.base.json"
  cat >&2 <<EOF
$KIND #$NUMBER の本文を $FETCH に書き出し、土台を $FETCH.base.json に控えた。
直したら次で書き込む (土台の後に本文が変わっていれば止まる):

  bash scripts/edit-body.sh $KIND $NUMBER --body-file $FETCH
EOF
  exit 0
fi

# --- 土台と照合して書き込む -------------------------------------------------

[ -f "$BODY_FILE" ] || { echo "本文のファイルが無い: $BODY_FILE" >&2; exit 66; }
BASE=${BASE:-$BODY_FILE.base.json}
if [ ! -f "$BASE" ]; then
  cat >&2 <<EOF
土台が無い: $BASE

本文をどの版の上で直したかが分からないので、書き込まない。先に取得して土台を控える:

  bash scripts/edit-body.sh $KIND $NUMBER --fetch <ファイル>

取得した <ファイル> の上で直し直してから --body-file で書き込む (別のファイルで直したなら
--base <ファイル>.base.json で土台を指す)。
EOF
  exit 1
fi
base_target=$(jq -r '"\(.repo) \(.kind) #\(.number)"' "$BASE" 2>/dev/null) ||
  { echo "土台を読めない: $BASE" >&2; exit 1; }
if [ "$base_target" != "$REPO $KIND #$NUMBER" ]; then
  echo "土台は $base_target のもので、宛先 $REPO $KIND #$NUMBER と違う: $BASE" >&2
  exit 1
fi

jq -j '.body' "$BASE" > "$work/base.md"
snapshot > "$work/latest.json"
jq -j '.body' "$work/latest.json" > "$work/latest.md"

# 経過秒を「n 分前」へ (comment.sh の relative_age と同じ刻み)
relative_age() {
  if [ "$1" -lt 60 ]; then printf '%d 秒前' "$1"
  elif [ "$1" -lt 3600 ]; then printf '%d 分前' "$(($1 / 60))"
  elif [ "$1" -lt 86400 ]; then printf '%d 時間前' "$(($1 / 3600))"
  else printf '%d 日前' "$(($1 / 86400))"
  fi
}

if ! cmp -s "$work/base.md" "$work/latest.md"; then
  editor=$(jq -r '.editor // "(不明)"' "$work/latest.json")
  edited=$(jq -r '.lastEditedAt // ""' "$work/latest.json")
  fetched=$(jq -r '.fetchedAt // "(不明)"' "$BASE")
  when='(時刻不明)'
  if [ -n "$edited" ]; then
    age=$(jq -rn --arg t "$edited" '(now - ($t | fromdateiso8601)) | floor | if . < 0 then 0 else . end')
    when="$edited ($(relative_age "$age"))"
  fi
  {
    echo "書き込まない: 土台を取得した後に $KIND #$NUMBER の本文が変わっている。"
    echo
    echo "  変えた人: $editor"
    echo "  変えた時: $when"
    echo "  土台を取得した時: $fetched"
    echo
    echo "土台から最新への差分 (先頭 80 行):"
    echo
    diff -u "$work/base.md" "$work/latest.md" | sed '1,2d' | sed -n '1,80p' || true
    echo
    echo "この改訂を消さないよう、最新の本文を取り直し、その上で直し直してから書き込む:"
    echo
    echo "  bash scripts/edit-body.sh $KIND $NUMBER --fetch <新しいファイル>"
  } >&2
  exit 1
fi

if cmp -s "$work/base.md" "$BODY_FILE"; then
  echo "本文が土台から変わっていないので書き込まない ($KIND #$NUMBER)" >&2
  exit 0
fi

if [ "$KIND" = issue ]; then
  if ! out=$(bash "$here/check-drawing-evidence.sh" --issue-body "$BODY_FILE" 2>&1 >/dev/null); then
    printf '%s\n' "$out" >&2
    exit 1
  fi
fi

if $DRY_RUN; then
  echo "gh $KIND edit $NUMBER -R $REPO --body-file $BODY_FILE"
  exit 0
fi

gh "$KIND" edit "$NUMBER" -R "$REPO" --body-file "$BODY_FILE"
rm -f "$BASE"
echo "書き込んだ ($KIND #$NUMBER)。土台は使い切ったので、続けて直すときは --fetch で取り直す" >&2
