#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# リポジトリ内の定義を GitHub のルールセットへ適用する (ADR-0006 / #98)。
#
#   apply-rulesets.sh            差分を見せるだけ (既定)
#   apply-rulesets.sh --apply    実際に適用する
#
# **メンテナが打つ**。エージェントの GitHub App は Administration 権限を持たない
# ため通らない (ADR-0003 決定 1 — 与えると自分を縛るルールセットを外せてしまう)。
#
# 既定を dry-run にしているのは、これが main の保護を書き換える操作だから。
# 定義に無いルールセットの削除はしない (破壊的操作は人の手に残す)。
#
# **送るのは「手元にチェックアウトされている定義」である** (#425)。古い版のツリーから
# 打つと、main の新しい定義を古い版で上書きする — 誤った緑を読む #311 と入口は同じだが、
# こちらは保護そのものが古い形に戻り、実設定に履歴は無い。だから照合 (名乗るだけ) と違い、
# **手元が古いと判定できたときは --apply を止める**。逃げ道は用意しない。直し方は 1 行で、
# 既定が dry-run である以上、打ち直せば済むからである。
#
# **適用の後に、承認が要るのに依頼の残っていない open な PR を名乗る** (#1758)。native の
# Team 宛て依頼は PR の作成と ready の時点でしか出ない (#1621) ので、その後の適用で
# required_reviewers の対象に入った PR は、Reviewers が空のまま承認待ちになる (#1731)。
# 稼働中の対象が変わる口はここ 1 つで、打つのは承認者本人だから、宛先・名義・権限を
# 新たに選ばずに目に入れられる。**依頼そのものは作らない** — App や GITHUB_TOKEN は Team へ
# 明示依頼できず、メンテナ自身の依頼は本人に通知されない (rerequest-review.sh 冒頭・#1621)。
# 名乗りを読んだ後に Approve するか Team へ依頼を出すかは人が決める。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"
DEFS=.github/rulesets

# REPO / DEFS を読むので、代入の後に置く
# shellcheck source=scripts/rulesets-freshness.sh
source scripts/rulesets-freshness.sh

# 「承認が要るパスに触れるか」の照合と、PR の変更ファイルの取り方 (#1758)。どちらも写しを
# 持たず既存の 1 か所を借りる (照合は review-gate と同じ読みになる)。**照合の相手は、
# いま送った定義** — 適用の直後なので稼働中と一致する。定義と稼働中がずれる適用前の窓での
# 読み手の扱い (#1991) には踏み込まない
RULESET_FILE="$DEFS/main-protection.json"
# shellcheck source=scripts/protected-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh"
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"

# 適用で承認が要るようになりうる open な PR を名乗る (#1758)。名乗るのは、承認が要る
# パスに触れ・承認者の承認が付いておらず・
#   - Draft でなければ、承認者宛ての依頼が残っていないもの
#   - Draft なら、依頼の有無を問わず別の行で (Draft には依頼が出ず、ready で出る — #1621)
# 依頼や承認で除けるものを先に除き、残りだけ変更ファイルを引く (PR 1 本につき 1 回)。
#
# **承認者は required_reviewers の宛先 (いまは maintainers の Team) に限る。** 誰かの承認・
# 誰か宛ての依頼で除くと、承認の対象を満たさない PR を黙って落とす。reviewDecision は
# 使えない — ルールセットの required_reviewers を映さず、承認済みの PR でも空で返る
# (2026-10-05 に #2085 ほかで実測)。だから承認は latestReviews の主が Team のメンバーか、
# 依頼は Team そのもの (gh の slug は org/slug) かメンバー宛ての User かで読む。Team の
# slug とメンバーは適用のたびに 1 回ずつ引く。
#
# **読めないものは名乗る側に倒す。** App の token では Team の依頼の中身が null で返る
# (rerequest-review.sh 冒頭の実測) ので、宛先を読めない依頼は承認者宛てと数えない。
# Team を引けなければ、承認も依頼も 1 件も数えずに全部を名乗り、そう断る。
#
# 一覧を引けない・読み解けないときは「確かめていない」と名乗って通す。適用はもう
# 済んでいて、ここで止めても戻すものが無い。黙って「無い」と言わないことだけを守る
name_unrequested_prs() {
  echo
  echo "== 承認が要るのに依頼の無い open な PR =="

  # 承認者の Team (slug は gh pr list の表記に揃えて org/slug) とメンバー
  local ids id slug teams='[]' members='[]' logins
  ids=$(jq -r '
    .rules[]? | select(.type == "pull_request")
    | .parameters.required_reviewers[]? | select(.reviewer.type == "Team") | .reviewer.id
  ' "$RULESET_FILE")
  for id in $ids; do
    if slug=$(gh api "teams/$id" --jq '"\(.organization.login)/\(.slug)"') &&
        logins=$(gh api "teams/$id/members" --paginate --jq '.[].login'); then
      teams=$(jq -c --arg s "$slug" '. + [$s]' <<<"$teams")
      members=$(jq -Rn --argjson m "$members" '$m + [inputs | select(. != "")]' <<<"$logins")
    else
      echo "注意: 承認者の Team (id $id) の maintainers を引けず、承認と依頼の主を確かめていない — どれも数えずに名乗る"
    fi
  done

  local list rows
  if ! list=$(gh pr list --repo "$REPO" --state open --limit 1000 \
      --json number,isDraft,baseRefName,latestReviews,reviewRequests); then
    echo "注意: open な PR を引けず、確かめていない。手で見る: gh pr list --state open"
    return 0
  fi
  # 読み解けない一覧 (jq の失敗) を「無い」と読まない。プロセス置換の中に置くと失敗が見えない
  if ! rows=$(jq -r --argjson teams "$teams" --argjson members "$members" '
      .[]
      | select([.latestReviews[]?
                | select(.state == "APPROVED")
                | (.author.login // "") as $l | select($members | index($l))]
               | length == 0)
      | select(.isDraft or ([(.reviewRequests // [])[]
                | select((.__typename == "Team" and ((.slug // "") as $s | $teams | index($s)))
                      or (.__typename == "User" and ((.login // "") as $l | $members | index($l))))]
               | length == 0))
      | [.number, .isDraft, .baseRefName] | @tsv
    ' <<<"$list" 2>&1); then
    echo "注意: open な PR の一覧を読み解けず、確かめていない ($rows)。手で見る: gh pr list --state open"
    return 0
  fi

  local number draft base files suffix found=0 unread=0
  while IFS=$'\t' read -r number draft base; do
    [ -n "$number" ] || continue
    if ! files=$(pr_files "$REPO" "$number"); then
      echo "注意: #$number の変更ファイルを引けず、確かめていない"
      unread=1
      continue
    fi
    printf '%s\n' "$files" | touches_protected_path || continue
    suffix=""
    [ "$base" = main ] || suffix=" (base は ${base}。承認が要るのは main へ移ってから)"
    if [ "$draft" = true ]; then
      echo "#$number Draft — 承認が要る。ready にすると Team 宛ての依頼が出る$suffix"
    else
      echo "#$number 承認が要るのに依頼が無い (承認者の Team・メンバーのどちら宛ても残っていない)$suffix"
    fi
    found=1
  done <<<"$rows"

  if [ "$found" = 1 ]; then
    echo "上の PR は承認者の承認も依頼も無いまま待っている。Approve するか、Team へ依頼を出す"
  elif [ "$unread" = 0 ]; then
    echo "無い (承認が要る open な PR は、どれも承認済みか依頼が残っている)"
  fi
}

apply=false
case "${1:-}" in
  --apply) apply=true ;;
  "") ;;
  # usage は 64 (sysexits の EX_USAGE) で揃える (#820)
  *) echo "使い方: apply-rulesets.sh [--apply]" >&2; exit 64 ;;
esac

# 壊れた定義を GitHub へ送らない
python3 scripts/rulesets_lib.py shape "$DEFS"

# 差分より先に、これから送る定義がどの版かを言う (#425)。末尾の check-rulesets.sh では
# 遅い — 差分が空なら「適用するものは無い」でそこへ届かず、差分があれば書き込んだ後になる
report_tree_freshness

# 古いツリーからの適用だけは止める。編集中・判定できずは通す — 手元だけが違うのは定義を
# 編集している間の正常な状態で、止めれば押し通すための逃げ道が要る (#425)
if $apply && [ "$RULESET_TREE_FRESHNESS" = stale ]; then
  echo "NG: 手元のツリーが古いまま適用すると、main の定義を古い版で上書きする (#425)" >&2
  exit 1
fi

live=$(mktemp -d)
trap 'rm -rf "$live"' EXIT

# 実設定を引く。引き方は rulesets-freshness.sh が持つ (#820) —
# check-rulesets.sh と同じ 2 段 (一覧 → id ごとに GET) だったので畳んだ。
# **name→id の表は $live/index.tsv に置かれる** (連想配列で返せない理由はあちらの解説)
fetch_live_rulesets "$live" || true

echo "== 定義と実設定の差分 =="
diff_status=0
python3 scripts/rulesets_lib.py diff "$DEFS" "$live" || diff_status=$?

if [ "$diff_status" -eq 0 ]; then
  echo "適用するものは無い (定義と実設定は一致している)"
  exit 0
fi

if ! $apply; then
  echo
  echo "上の差分を実設定へ反映するには --apply を付けて実行する:"
  echo "  bash scripts/apply-rulesets.sh --apply"
  exit 0
fi

echo
echo "== 適用 =="
# 1 本が断られても残りは試みる。断られた定義と無関係な差分まで巻き添えで止めない
rejected=()
# 承認の対象を持つ main-protection を送れたか。送れたなら、他が断られても名乗りは要る
protection_sent=false
for f in "$DEFS"/*.json; do
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  # 表から id を引く。**タブで区切って名前の完全一致を見る** — 名前に空白が入りうる
  id=$(awk -F'\t' -v want="$name" '$1 == want { print $2 }' "$live/index.tsv")

  # 断られたときの理由は応答の本文 (stdout) にしか無い。捨てると「Validation Failed」しか
  # 残らず、何が通らなかったのかを打ち直して調べることになる (#2075)
  failed=0
  if [ -n "$id" ]; then
    verb=更新 out=$(gh api -X PUT "repos/$REPO/rulesets/$id" --input "$f" 2>&1) || failed=1
  else
    verb=作成 out=$(gh api -X POST "repos/$REPO/rulesets" --input "$f" 2>&1) || failed=1
  fi
  if [ "$failed" = 1 ]; then
    echo "NG: $name の${verb}を API が断った。応答:" >&2
    echo "$out" >&2
    rejected+=("$name")
    continue
  fi
  echo "${verb}: $name${id:+ (id $id)}"
  [ "$name" != main-protection ] || protection_sent=true
done

# 定義に無いルールセットが残っていても消さない。存在だけ知らせる
while IFS=$'\t' read -r name _; do
  [ -n "$name" ] || continue
  if [ ! -f "$DEFS/$name.json" ]; then
    echo "注意: 実設定の $name は定義に無い (このスクリプトは削除しない)" >&2
  fi
done < "$live/index.tsv"

if [ "${#rejected[@]}" -gt 0 ]; then
  echo "NG: 適用できなかった定義がある: ${rejected[*]} (理由は上の応答)" >&2
  # 稼働中の承認の対象はもう変わっている。断られた分とは無関係に、対象に入った PR は残る
  ! $protection_sent || name_unrequested_prs
  exit 1
fi

echo
echo "== 適用後の照合 =="
# 照合が赤でも名乗りは出す。適用はもう済んでいて、対象に入った PR は赤とは無関係に残る
check_status=0
bash scripts/check-rulesets.sh || check_status=$?

name_unrequested_prs
exit "$check_status"
