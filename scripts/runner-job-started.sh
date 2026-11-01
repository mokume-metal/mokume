#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の self-hosted runner で、ジョブの始まりに作業ディレクトリを空にする (#878)。
#
# runner はリポジトリ単位で 1 度だけ登録した常駐のもので、ジョブの間でファイルシステムが
# 残る (ADR-0019 決定 7)。前のジョブが作業ディレクトリに残したもの (ビルドの成果物・
# 追跡外のファイル) の上で次のジョブが走ると、merge_group の結論 (必須チェック) が
# 前のジョブに左右されうる。**ビルドの成果物は持ち越さない** (メンテナの判断・
# 2026-09-28)。
#
# actions/checkout の clean も作業ツリーを掃除するが、あちらは checkout が成功した後の
# 話で、掃除するものも git の見える範囲に限る。ここはジョブの最初に、中身を問わず空にする。
#
# ## 専用機への置き方
#
# runner は PR の木ではなく、専用機に写したこのファイルを実行する。**リポジトリの版を
# 直したら、専用機の写しも置き直す。**
#
# docs/render-runners.md の「ジョブ開始時の掃除を設定する」に従い、runner ごとに配置して
# .env の ACTIONS_RUNNER_HOOK_JOB_STARTED をその写しの絶対パスにする。再起動は対象の
# runner のディレクトリで ./svc.sh stop → ./svc.sh start とし、複数の plist を glob で選ばない。
#
# ## 使い方
#
#   bash scripts/runner-job-started.sh     (runner が GITHUB_WORKSPACE を渡して呼ぶ)
#
# **消している最中に前の job の書き手が中へ書くと、`rm -rf` は「Directory not empty」で落ちる**
# (#3616。merge queue が走っている job を取り消した直後に、次の job の掃除が走った)。落ちて
# 終えると PR と関係なく render が赤になり、queue から外れるので、期限 (既定 60 秒) までは
# 間隔をあけて打ち直す。期限を越えても空にならない、または空にした後も作業場所の下を
# 開いている・作業ディレクトリに置いているプロセスが残るなら、その PID・ppid・経過・コマンドを
# 名乗って赤で終える。**何も止めない** (止めるのは人。#3095 の `orphan-load` と同じ)。
# 期限と間隔は JOB_STARTED_DEADLINE_SEC・JOB_STARTED_RETRY_SEC で変えられる (検査のため)。
#
# **消すのは runner の作業場所の中だけ。** GITHUB_WORKSPACE が空か、`_work/<名前>/<名前>`
# の形でなければ何も消さずに赤で終える — 渡し間違いでホームを消さないため。
# テストは scripts/tests/runner_job_started_test.py。
set -euo pipefail

ws="${GITHUB_WORKSPACE:-}"
case "$ws" in
  */_work/*/*) ;;
  *)
    echo "runner-job-started: 作業ディレクトリが runner の作業場所の形でないので、何も消さない: '${ws}'" >&2
    exit 1
    ;;
esac

if [ ! -d "$ws" ]; then
  echo "runner-job-started: 作業ディレクトリはまだ無い (初回のジョブ): $ws"
  exit 0
fi

deadline=${JOB_STARTED_DEADLINE_SEC:-60}
interval=${JOB_STARTED_RETRY_SEC:-2}

# 作業場所の下を開いている・作業ディレクトリに置いているプロセスの pid。lsof +D は作業ディレクトリが
# 作業場所そのもの (または下) のプロセスも拾う。自分と親 (runner) は除く。見つからなければ空
writers_of() {
  { "$lsof_bin" -Fp +D "$ws" 2>/dev/null || true; } | sed -n 's/^p//p' | sort -u | { grep -vx -e "$$" -e "$PPID" || true; }
}

# 書き手 1 本を `名前 (pid N, ppid N, 経過 E)` で名乗る
describe() {
  local pid=$1 ppid etime comm
  if read -r ppid etime comm < <(ps -p "$pid" -o ppid=,etime=,comm= 2>/dev/null); then
    printf '%s (pid %s, ppid %s, 経過 %s)' "${comm##*/}" "$pid" "$ppid" "$etime"
  else
    printf '? (pid %s、ps で引けなかった)' "$pid"
  fi
}

# 書き手の一覧 ($1 は pid を改行で並べたもの) を `名前 (pid …), …` で名乗る。最大 5 本
describe_all() {
  local list="" count=0 pid
  for pid in $1; do
    count=$((count + 1))
    [ "$count" -le 5 ] || continue
    list+="${list:+, }$(describe "$pid")"
  done
  [ "$count" -le 5 ] || list+=" ほか $((count - 5)) 本"
  printf '%s' "$list"
}

# lsof は PATH に無くても macOS の標準の在処 (/usr/sbin) にある。runner の PATH に /usr/sbin がある保証は無い。
# 在処は JOB_STARTED_LSOF_FALLBACK で差し替えられる (検査のため)
lsof_bin=$(command -v lsof 2>/dev/null || true)
if [ -z "$lsof_bin" ] && [ -x "${JOB_STARTED_LSOF_FALLBACK:-/usr/sbin/lsof}" ]; then
  lsof_bin=${JOB_STARTED_LSOF_FALLBACK:-/usr/sbin/lsof}
fi
if [ -z "$lsof_bin" ]; then
  echo "runner-job-started: 書き手を探す lsof が PATH にも ${JOB_STARTED_LSOF_FALLBACK:-/usr/sbin/lsof} にも無いので、作業場所に前の job の書き手が残っていないか確かめられない" >&2
  exit 1
fi

start=$SECONDS
retries=0
# 打ち直しの間に最初に見えた書き手。打ち直しで緑になった回の成功の行に名乗る (次に出た名前を #3616 に書くため)。
# 見えた周に引く — 緑になるころには書き手のプロセスは消えている
seen=""
while :; do
  rm_status=0
  # rm の「Directory not empty」は stderr に出たままにして、ログに残す
  find "$ws" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || rm_status=$?
  left=$(find "$ws" -mindepth 1 -maxdepth 1 2>/dev/null | sed -n '1p')
  writers=$(writers_of)
  if [ -n "$writers" ] && [ -z "$seen" ]; then
    seen=$(describe_all "$writers")
  fi
  if [ "$rm_status" -eq 0 ] && [ -z "$left" ] && [ -z "$writers" ]; then
    break
  fi
  waited=$((SECONDS - start))
  if [ "$waited" -ge "$deadline" ]; then
    if [ -n "$writers" ]; then
      echo "runner-job-started: 作業場所に前の job の書き手が残っている (${waited} 秒待って打ち直し ${retries} 回): $(describe_all "$writers")。何も止めていない。出所を確かめて人が止める: $ws" >&2
    else
      echo "runner-job-started: 作業場所を空にできなかった (${waited} 秒待って打ち直し ${retries} 回)。書き手は見つからなかった (lsof +D で開いているファイルも作業ディレクトリも無い)。何も止めていない。出所を確かめて人が止める: $ws" >&2
    fi
    exit 1
  fi
  retries=$((retries + 1))
  sleep "$interval"
done

if [ "$retries" -eq 0 ]; then
  echo "runner-job-started: 作業ディレクトリを空にした: $ws"
else
  echo "runner-job-started: 作業ディレクトリを空にした (打ち直し ${retries} 回・待った $((SECONDS - start)) 秒・打ち直しの間に見えた書き手: ${seen:-見えなかった}): $ws"
fi
