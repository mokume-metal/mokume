#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# リポジトリ内の定義を GitHub のルールセットへ適用する (ADR-0006 / #98)。
#
#   apply-rulesets.sh            差分を見せるだけ (既定)
#   apply-rulesets.sh --apply    実際に適用する
#
#   apply-rulesets.sh --degraded [--apply]   縮退 (必須チェックから render を外す) の定義だけを適用する
#   apply-rulesets.sh --restore  [--apply]   縮退から戻す (同じ名前の定義を .github/rulesets/ から適用する)
#
# **縮退と復帰は専用機が止まったときの口である** (#2252)。手順と、発動してよい条件・失う保証・
# 復帰の条件は docs/runner-degraded-mode.md が持つ。縮退の定義は `.github/rulesets-degraded/` に
# あり、**既定の適用 (`.github/rulesets/` を丸ごと送る) では送られない**。この 2 つの口は、縮退の
# 定義にある名前 (main-protection) の保護だけを送り、ほかのルールセットには触れない。
# 既定の振る舞い (引数なし・--apply だけ) はこの口を足す前と同じである。
#
# **メンテナが打つ** (ADR-0006 決定 3)。エージェントもメンテナの認証で動くので打てて
# しまうが、適用は定義ファイルの PR が merge された後にメンテナが行う (ADR-0044 の影響)。
#
# 既定を dry-run にしているのは、これが main の保護を書き換える操作だから。
# 定義に無いルールセットの削除はしない (破壊的操作は人の手に残す)。
#
# **送るのは「手元にチェックアウトされている定義」である** (#425)。古い版のツリーから
# 打つと、main の新しい定義を古い版で上書きする — 誤った緑を読む #311 と入口は同じだが、
# こちらは保護そのものが古い形に戻り、実設定に履歴は無い。だから照合 (名乗るだけ) と違い、
# **手元が古いと判定できたときは --apply を止める**。逃げ道は用意しない。直し方は 1 行で、
# 既定が dry-run である以上、打ち直せば済むからである。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"
DEFS=.github/rulesets
# 縮退の定義 (#2252)。**ここは既定の適用では送られない** — DEFS だけが丸ごと送られる
DEGRADED=.github/rulesets-degraded

# REPO / DEFS を読むので、代入の後に置く
# shellcheck source=scripts/rulesets-freshness.sh
source scripts/rulesets-freshness.sh

apply=false
# all: 既定 (DEFS を丸ごと) / degraded: 縮退の定義だけ / restore: 縮退の定義にある名前だけを DEFS から
scope=all
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --degraded | --restore)
      want=${arg#--}
      if [ "$scope" != all ] && [ "$scope" != "$want" ]; then
        echo "使い方: --degraded と --restore は同時に付けられない" >&2
        exit 64
      fi
      scope=$want
      ;;
    # usage は 64 (sysexits の EX_USAGE) で揃える (#820)
    *) echo "使い方: apply-rulesets.sh [--apply] [--degraded | --restore]" >&2; exit 64 ;;
  esac
done

# 壊れた定義を GitHub へ送らない
python3 scripts/rulesets_lib.py shape "$DEFS"
if [ "$scope" != all ]; then
  python3 scripts/rulesets_lib.py shape "$DEGRADED"
fi

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
work=$(mktemp -d)
trap 'rm -rf "$live" "$work"' EXIT

# 実設定を引く。引き方は rulesets-freshness.sh が持つ (#820) —
# check-rulesets.sh と同じ 2 段 (一覧 → id ごとに GET) だったので畳んだ。
# **name→id の表は $live/index.tsv に置かれる** (連想配列で返せない理由はあちらの解説)
fetch_live_rulesets "$live" || true

# 送る定義 (SEND) と、それと突き合わせる実設定 (LIVE_VIEW)。既定は DEFS と実設定の全部。
# 縮退と復帰は、縮退の定義にある名前の保護だけを送るので、実設定の側も同じ名前に絞る —
# 絞らないと、送らないルールセットが「定義に無い」と差分に出る (#2252)
SEND=$DEFS
LIVE_VIEW=$live
# 縮退と復帰の対象を、実設定から名前で絞る。fetch の後でも再度呼ぶ (適用後の突き合わせ)
narrow_live() {
  rm -rf "$work/live-view"
  mkdir -p "$work/live-view"
  for f in "$SEND"/*.json; do
    local n i
    n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
    i=$(awk -F'\t' -v want="$n" '$1 == want { print $2 }' "$live/index.tsv")
    if [ -n "$i" ]; then cp "$live/$i.json" "$work/live-view/$i.json"; fi
  done
}
if [ "$scope" != all ]; then
  SEND=$work/send
  LIVE_VIEW=$work/live-view
  mkdir -p "$SEND"
  for f in "$DEGRADED"/*.json; do
    if [ "$scope" = degraded ]; then
      cp "$f" "$SEND/$(basename "$f")"
    else
      cp "$DEFS/$(basename "$f")" "$SEND/$(basename "$f")"
    fi
  done
  narrow_live
  if [ "$scope" = degraded ]; then
    echo "== 縮退: 必須チェックから render を外す定義を適用する (手順: docs/runner-degraded-mode.md) =="
  else
    echo "== 復帰: 縮退の定義にある名前の保護を、.github/rulesets/ の定義へ戻す =="
  fi
fi

echo "== 定義と実設定の差分 =="
diff_status=0
python3 scripts/rulesets_lib.py diff "$SEND" "$LIVE_VIEW" || diff_status=$?

if [ "$diff_status" -eq 0 ]; then
  echo "適用するものは無い (定義と実設定は一致している)"
  exit 0
fi

if ! $apply; then
  echo
  flag=""
  [ "$scope" = all ] || flag=" --$scope"
  echo "上の差分を実設定へ反映するには --apply を付けて実行する:"
  echo "  bash scripts/apply-rulesets.sh$flag --apply"
  exit 0
fi

echo
echo "== 適用 =="
# 1 本が断られても残りは試みる。断られた定義と無関係な差分まで巻き添えで止めない
rejected=()
for f in "$SEND"/*.json; do
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
done

# 定義に無いルールセットが残っていても消さない。存在だけ知らせる (縮退と復帰は一部だけを
# 送るので、残りを「定義に無い」とは言わない)
while IFS=$'\t' read -r name _; do
  [ -n "$name" ] || continue
  if [ "$scope" = all ] && [ ! -f "$DEFS/$name.json" ]; then
    echo "注意: 実設定の $name は定義に無い (このスクリプトは削除しない)" >&2
  fi
done < "$live/index.tsv"

if [ "${#rejected[@]}" -gt 0 ]; then
  echo "NG: 適用できなかった定義がある: ${rejected[*]} (理由は上の応答)" >&2
  exit 1
fi

echo
echo "== 適用後の照合 =="
if [ "$scope" = degraded ]; then
  # 縮退中は check-rulesets.sh (DEFS との照合) が render の 1 行のずれを言う。それが正しい状態なので、
  # 縮退の定義との突き合わせで確かめる。ずれが残るのは日次の ruleset-drift の起票として現れる
  fetch_live_rulesets "$live" || true
  narrow_live
  python3 scripts/rulesets_lib.py diff "$SEND" "$LIVE_VIEW"
  echo "縮退中。日次の ruleset-drift は render の 1 行のずれを起票する (docs/runner-degraded-mode.md)"
else
  bash scripts/check-rulesets.sh
fi
