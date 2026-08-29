#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# セッションが終わった後に残ったスケッチ・検証プロセスを、出所つきで一覧する (#454)。
#
# スケッチはセッションのシェルから起動されるので、そのシェルが終わってもプロセスは
# launchd に再親付けされて生き残る (ppid=1 の孤児)。並行セッションが常態なので、
# 後から見た人には**どの窓が誰のものか**が残らない — 片付けようとすると生きている
# 検証を壊しかねず、結局放置される。
#
# #454 の実測では、判別に 4 段の手数が要った。ps で ppid=1 を拾い、lsof -d cwd で
# cwd を引き、その scratchpad の世代を worktree ごとの最新と突き合わせ、さらに
# 生きているセッションへ 1 通ずつ問い合わせる。**この手数を 1 コマンドに畳む**のが
# このスクリプトである。
#
# ## 何をしないか
#
# **何も殺さない。** 落とすかどうかは人間が決める — そのために PID を出す。
# #454 で記録された実害は「残っていること」ではなく「片付けてよいか判別できないこと」
# だったので、判別だけを担う (ADR-0008 決定 1: 迷ったら足さない側へ倒す)。
#
# **持ち主の生死を断定しない。** 出せるのは scratchpad の世代と最終更新から見た
# 手掛かりだけで、静かに生きているセッションと終わったセッションは外から区別できない。
# 断定できないときは「判定できず」と名乗り、**生きている側に倒す** — 取り違えの代償が
# 非対称 (残す = 少し散らかる / 落とす = 進行中の検証が消える) だからである。
#
# **`~/.claude` を読まない。** エージェント支援はリポジトリ側で完結させる (ADR-0017)。
# 材料は git worktree list・ps・lsof・scratchpad の置き場だけで足りる。
#
# ## 使い方
#
#   bash scripts/orphan-processes.sh
#
# 環境変数:
#   MOKUME_SCRATCHPAD_ROOT  scratchpad の根を差し替える (既定 /private/tmp/claude-<uid>)
set -euo pipefail

# 「最近動いた」の境目。短すぎると考え込んでいるだけのセッションを死んだ側へ倒し、
# 長すぎると終わったセッションが延々と生きているように見える。#454 の実測では
# 生きている世代が 3〜6 分前・終わった世代が 3〜5 時間前で、間は広く空いていた
readonly FRESH_MINUTES=30

scratch_root="${MOKUME_SCRATCHPAD_ROOT:-/private/tmp/claude-$(id -u)}"
scratch_root="${scratch_root%/}"

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "git リポジトリの中で実行する (worktree の一覧から出所を引くため)" >&2
  exit 1
fi

# --- このリポジトリの worktree ------------------------------------------------
# scratchpad の置き場は worktree のパスから作られた slug で分かれている
# (/ と . が - になる)。slug を自前で組んで突き合わせることで、
# 「この scratchpad はどの worktree のものか」を外部の知識なしに引ける

worktrees=()
slugs=()
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      path="${line#worktree }"
      worktrees+=("$path")
      slugs+=("$(printf '%s' "$path" | tr '/.' '--')")
      ;;
  esac
done < <(git worktree list --porcelain)

# --- 表示の補助 ---------------------------------------------------------------

fold_home() { # $1=パス → ホームを ~ に畳んだパス
  local path="$1"
  if [ -n "${HOME:-}" ] && [ "${path#"$HOME"/}" != "$path" ]; then
    # 展開させたくない ~ をそのまま出す (人が読む縮め方であって、パスではない)
    # shellcheck disable=SC2088
    printf '~/%s' "${path#"$HOME"/}"
  else
    printf '%s' "$path"
  fi
}

# --- 出所の判定 ---------------------------------------------------------------

# 判定の結果はここに置く (bash 3.2 に連想配列も戻り値の構造体も無いため)
kind=""     # repo = このリポジトリ由来 / foreign = 対象外
worktree="" # repo のときの worktree 名
slug=""     # scratchpad の slug (引けたとき)
session=""  # scratchpad の世代 = セッション (引けたとき)

classify() { # $1=パス → 上の 4 変数を埋める
  local path="$1" rest index
  kind="foreign"
  worktree=""
  slug=""
  session=""

  # scratchpad 配下なら、パス自体が worktree とセッションを持っている
  if [ "${path#"$scratch_root"/}" != "$path" ]; then
    rest="${path#"$scratch_root"/}"
    slug="${rest%%/*}"
    rest="${rest#*/}"
    session="${rest%%/*}"
    for index in "${!slugs[@]}"; do
      if [ "${slugs[$index]}" = "$slug" ]; then
        kind="repo"
        worktree="$(basename "${worktrees[$index]}")"
        return
      fi
    done
    return
  fi

  # worktree 配下に建てられたもの (.build に直接ビルドした場合)
  for index in "${!worktrees[@]}"; do
    if [ "${path#"${worktrees[$index]}"/}" != "$path" ]; then
      kind="repo"
      worktree="$(basename "${worktrees[$index]}")"
      return
    fi
  done
}

cwd_of() { # $1=PID → cwd (引けなければ空)
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# --- 持ち主の手掛かり ---------------------------------------------------------

activity_of() { # $1=世代のディレクトリ → 最終活動の epoch
  # **世代のディレクトリ自身の mtime だけでは足りない。** そこが動くのは直下に
  # 出入りがあったときだけで、実際の書き込みは 1 つ下 (scratchpad/・tasks/) に
  # 集まる。実測では、生きているセッションの世代が 27 分前に見えていた
  local dir="$1" newest entry stamp
  newest="$(stat -f %m "$dir")"
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    stamp="$(stat -f %m "$entry")"
    if [ "$stamp" -gt "$newest" ]; then
      newest="$stamp"
    fi
  done
  printf '%s' "$newest"
}

owner_hint() { # $1=slug $2=session → 手掛かりの 1 行
  local slug="$1" session="$2" dir newest newest_mtime candidate candidate_mtime mtime age stamp

  if [ -z "$slug" ] || [ -z "$session" ]; then
    printf '持ち主は判定できず (どのセッションのものか引けなかった)'
    return
  fi

  dir="$scratch_root/$slug/$session"
  if [ ! -d "$dir" ]; then
    printf '持ち主は判定できず (セッションの跡が残っていない)'
    return
  fi

  mtime="$(activity_of "$dir")"
  age=$(( ( $(date +%s) - mtime ) / 60 ))
  stamp="$(date -r "$mtime" '+%m-%d %H:%M')"

  # 最近動いていれば、世代が新しいか古いかによらず誰かが居る
  # (同じ worktree で 2 つのセッションが並ぶことがあるため、世代だけで死を断定しない)
  if [ "$age" -le "$FRESH_MINUTES" ]; then
    printf '持ち主は生きている可能性が高い (最終活動 %s・%d 分前)' "$stamp" "$age"
    return
  fi

  # 同じ場所で最も新しい世代を探す。ls の出力を読まずに mtime で直に比べる
  newest=""
  newest_mtime=0
  for candidate in "$scratch_root/$slug"/*/; do
    [ -d "$candidate" ] || continue
    candidate_mtime="$(activity_of "$candidate")"
    if [ "$candidate_mtime" -gt "$newest_mtime" ]; then
      newest_mtime="$candidate_mtime"
      newest="${candidate%/}"
    fi
  done

  if [ -n "$newest" ] && [ "$newest" != "$dir" ]; then
    printf '持ち主は終わっている可能性が高い (最終活動 %s・同じ場所に新しい世代がある)' "$stamp"
    return
  fi

  printf '持ち主は判定できず (最終活動 %s・最新の世代だが動きが無い)' "$stamp"
}

# --- 一覧 ---------------------------------------------------------------------

found=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # 最後の変数に残り全部が入るので、空白を含む実行パスでも切れない
  read -r pid ppid etime command <<<"$line"

  # 孤児 = 親を失って launchd に引き取られたもの
  [ "$ppid" = "1" ] || continue

  # SwiftPM が建てたもの (.build) と scratchpad 配下だけを候補にする。
  # ppid=1 のプロセスは数百あり、その大半は OS の常駐である
  case "$command" in
    */.build/*) ;;
    "$scratch_root"/*) ;;
    *) continue ;;
  esac

  classify "$command"
  # worktree の .build から建てたものはパスに世代を持たない。cwd なら引けることがある
  if [ -z "$session" ]; then
    # lsof は引けないことがある (プロセスが消えた・権限が無い)。引けないのは
    # 想定の範囲なので、pipefail でここを落とさない
    cwd="$(cwd_of "$pid" || true)"
    if [ -n "$cwd" ]; then
      keep_kind="$kind"
      keep_worktree="$worktree"
      classify "$cwd"
      # cwd で出所が下がることはあっても上がらない扱いにする
      if [ "$keep_kind" = "repo" ] && [ "$kind" != "repo" ]; then
        kind="$keep_kind"
        worktree="$keep_worktree"
      fi
    fi
  fi

  if [ "$kind" = "repo" ]; then
    if [ -n "$session" ]; then
      origin="$worktree セッション ${session%%-*}"
    else
      origin="$worktree (セッションは引けず)"
    fi
  elif [ -n "$slug" ]; then
    origin="対象外 (別プロジェクトのセッション)"
  else
    origin="対象外 ($(fold_home "$command"))"
  fi

  if [ "$found" -eq 0 ]; then
    # 見出しは桁を揃えた literal で書く。printf の幅はバイト数で数えるので、
    # 全角を含む文字列を %-Ns に渡すと表示幅がその分だけ縮んで列がずれる
    printf 'PID      経過        バイナリ             出所 / 持ち主の手掛かり\n'
  fi
  found=$(( found + 1 ))
  printf '%-8s %-11s %-20s %s — %s\n' \
    "$pid" "$etime" "$(basename "$command")" "$origin" "$(owner_hint "$slug" "$session")"
done < <(ps -Ao pid=,ppid=,etime=,comm=)

if [ "$found" -eq 0 ]; then
  echo "スケッチ由来の孤児 (ppid=1) は見つからなかった"
  exit 0
fi

cat <<EOF

$found 件。**この一覧は何も殺さない** — 落としてよいと判断したら kill <PID> を打つ。
持ち主の手掛かりは scratchpad の世代と最終更新から見た推定であって、断定ではない。
判断が付かないものは残す (残しても散らかるだけだが、落とすと進行中の検証が消える)。
EOF
