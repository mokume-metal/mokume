#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# merge queue の render が専用機の前検査で落ちたことを発信する (#2588)。
#
#   report-runner-environment.sh <前検査の理由>
#
# 理由は scripts/runner-preflight.sh が $GITHUB_OUTPUT に書いた `reason` の 1 行で、
# render.yml が job の出力として渡す。
#
# **塞ぐのは「専用機が壊れていることが誰にも届かない」である。** 2026-10-12 に表の GUI
# セッションが替わって (#2507)、merge queue の render が 14 回続けて落ちたが、どれも
# PR の赤に見えて、原因が分かったのは翌朝だった。壊れている間は queue に入った PR が
# 1 本ずつ弾かれ、直った後も誰かが予約を掛け直すまで止まる (当番の stall-watch は
# 外れた予約を名乗るだけで掛け直さない・#2614)。
#
# 対象は merge_group の render だけ。定期の run (schedule) で前検査が落ちたときは、
# scheduled-debug が赤になり、既存の scheduled-report が「専用機の定期の検査が落ちている」で
# 起票するので、同じ故障で 2 本立てない。
#
# 発信の実体 (重複して立てない・run の URL を足す) は scripts/report-check-failure.sh が持ち、
# ここが持つのは**固定タイトルと本文**だけ (report-scheduled-render.sh と同じ分け方)。
# 呼ぶのは render.yml の render-environment-report で、GitHub ホストのジョブである。
# 検査は scripts/tests/report_runner_environment_test.py。
set -euo pipefail

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む。
# 接頭辞が `fix(` なので triage.sh が Bug を付ける — 動いていたものが止まった事象である
readonly TITLE="fix(render): 専用機の環境が壊れていて、merge queue の render が前検査で落ちている"

# 引数を理由の値として読んで起票まで進む入口なので、`-` で始まる値 (慣習の `--help` や
# `-h`) を理由として読まない。読むと verify: triaged つきの偽の障害 Issue が立つ (#3047)。
# runner-preflight.sh が書く理由は `<名前>: …` で始まり、`-` では始まらない
[ $# -eq 1 ] && [ -n "$1" ] || {
  echo "使い方: report-runner-environment.sh <前検査の理由>" >&2
  exit 64
}
[[ "$1" != -* ]] || {
  echo "使い方: report-runner-environment.sh <前検査の理由> (- で始まる値は理由として読まない: $1)" >&2
  exit 64
}
REASON="$1"

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
trap 'rm -f "$body" "$log"' EXIT

printf '%s\n' "$REASON" > "$log"

cat > "$body" <<'BODY'
merge queue の必須チェック `render` が、専用機の前検査 (`scripts/runner-preflight.sh`) で落ちた。**PR の中身による赤ではない。** 専用機が直るまで、queue に入った PR は先頭から 1 本ずつ弾かれる。

## 対処

1. 下の「検査の出力」で、どの条件で落ちたかを読む
   - `console` — 専用機の表の GUI セッションが runner のユーザーではない。専用機の前で runner のユーザーへ切り替える (#2507)
   - `screens` — runner から画面が見えない。表のセッション・ディスプレイの接続と電源を見る
   - `metal` — Metal のデバイスが取れない。専用機を再起動する
   - `gpu-slot` — GPU の待ちが期限を越えた記録 (`wait-expired.json`) が専用機に残っていて、検査は gpu-slot が起こさずに止まる (終了コード 76・#2235)。記録は時間では下りない。**専用機の前で、画面が固まっていない・前の検査プロセスが残っていない (`bash scripts/orphan-processes.sh`)・GPU が答える、を人が確かめてから**、「検査の出力」にある記録のファイルを削除する。確かめる前に消すと、答えない GPU に新しい発行口を作って機械ごと止まりうる。記録の中身には、期限を越えた待ちと起動元がある
   - `orphan-load` — 前の job が専用機に残したプロセス (ppid=1 で CPU を使い続けている) がある。このまま走らせると後の job が黙って遅くなる (#3010)。何も止めていない。**専用機の前で、「検査の出力」にある PID の出所を `bash scripts/orphan-processes.sh` で確かめ、人が止める**
2. 直ったら、弾かれた PR の予約を手で掛け直す。当番 (stall-watch) は queue から弾かれた PR を `auto-merge-dropped` と名乗るだけで、掛け直さない (#2614)。名乗られた PR に打つ:

   ```
   bash scripts/stall-watch.sh
   gh pr merge <番号> --auto --squash
   ```

## 解消の判定

次の merge_group の `render` が前検査を通って緑になれば解消。**解消したらこの Issue を閉じる。** open な間は、次の故障は新しく立たずにこの Issue へ追記される (#2658)。閉じ忘れると、別の事象が前の事象の続きに見える。**閉じる前に、追記された分も同じ直しで解けたかを確かめる** — 別の原因なら、閉じる前に別の Issue へ起こす。
BODY

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --key-file "$log" \
  --source '.github/workflows/render.yml の render-environment-report が自動起票した (#2588)'
