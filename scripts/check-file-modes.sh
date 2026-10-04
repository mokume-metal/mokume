# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 追跡ファイルに実行ビットが付いていないことを検査する (#272)。
#
# このリポジトリのスクリプトの呼び口は `bash scripts/x.sh` /
# `python3 scripts/release.py` に一本化されている (Makefile・workflow・
# .claude/settings.json のフックすべて)。`./scripts/x.sh` と直接実行している
# 箇所は 1 つも無い。にもかかわらず実行ビットの有無がファイルごとに割れていると、
# 付いているファイルで一度成功した後、付いていないファイルで初めて
# permission denied を踏む — 原因の分かりにくい失敗だけが残る。
#
# 実行ビットを付ける側に揃えても呼び口は増えないので、外す側に揃える。
# source される library (scripts/guard-lib.sh) や shebang を持たないファイル
# (scripts/check-schemas.sh) もあり、「#! があるなら実行可能に」という規則は
# そもそも成り立たない。
#
# 100644 以外を一律に弾く形にはしない。symlink (120000) や submodule (160000) は
# 実行ビットの話ではなく、この検査が縛る理由が無い。
#
# **見る範囲は「git add -A したときに CI の木になるもの」** (#2072・#2015 の兄弟)。
# 見るものは 2 つある:
#
#   - index のモード (追跡済み)。index に 100755 で載っていれば、作業ツリーがどうで
#     あれそのまま push される
#   - 作業ツリーの実行ビット (追跡 + 未追跡 − 無視)。`chmod +x` してまだ `git add`
#     していないファイルは、index だけを見ると手元で緑になり、`git add -A` して
#     push した後の CI で初めて赤になる。未追跡の新しいファイルがその典型
#
# **`core.fileMode` が `false` のクローンでは作業ツリーの側を見ない。** その設定の下では
# `git add` が作業ツリーの実行ビットを index に載せない (新しいファイルは 100644 で載り、
# 追跡済みのモードは変わらない) ので、作業ツリーに +x があっても CI の木には届かない。
# 見ると、届かないものを赤にする (ファイルシステムが実行ビットを持たない環境では、
# 全ファイルが +x に見えることもある)。その設定の下で CI の木を決めるのは index の
# モードだけで、それは上の 1 つ目が見ている。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# core.quotePath の既定では非 ASCII の名前が C 引用符つきで返り、外し方の行に貼っても
# 実在するファイルを指さない。名前はそのまま出させる
entries="$(git -c core.quotePath=false ls-files -s)"

# 検査対象が 0 件なら、通っていることに意味が無い (git の出力形式が変わった、
# cd に失敗した等)。緑のまま何も見ていない状態を作らないために落とす
if [ -z "$entries" ]; then
  echo "追跡ファイルが 1 つも見つからない — 検査が成立していない" >&2
  exit 1
fi

# 経路はタブ区切りの 2 列目以降。awk の $4 で取ると空白を含む経路で切れる
in_index="$(awk '$1 == "100755"' <<<"$entries" | cut -f2-)"

# 外し方の行へ並べる経路を、空白を含んでもそのまま貼れる形に引用する。printf の %q は
# 使わない — macOS の /bin/bash (3.2) は非 ASCII の名前をバイト単位で崩して出す
shell_words() {
  local path q="'"
  while IFS= read -r path; do
    case "$path" in
      *[!A-Za-z0-9._/+-]*) printf " '%s'" "${path//$q/$q\\$q$q}" ;;
      *) printf ' %s' "$path" ;;
    esac
  done
}

# 未設定なら git の既定 (true) に倣う
file_mode="$(git config --type=bool core.fileMode || echo true)"

# 作業ツリーの側。名前は -z で割る (非 ASCII の名前は C 引用符つきで返り、実在する
# ファイルを見失う)。index にだけ残る旧パス (git rm していない削除) は -f で落ちる。
# symlink は add -A で 120000 として載り実行ビットの話ではないので落とす (-x は先を見る)
in_worktree=""
untracked_count=""
if [ "$file_mode" != "false" ]; then
  in_worktree="$(
    git ls-files -z --cached --others --exclude-standard |
      while IFS= read -r -d '' path; do
        if [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ]; then
          printf '%s\n' "$path"
        fi
      done
  )"
  untracked_count="$(git ls-files -z --others --exclude-standard | tr -cd '\0' | wc -c | tr -d ' ')"
fi

if [ -n "$in_index" ] || [ -n "$in_worktree" ]; then
  echo "実行ビットの付いたファイルがある (呼び口は bash scripts/x.sh に一本化する):" >&2
  if [ -n "$in_index" ]; then
    echo "" >&2
    echo "index に 100755 で載っている:" >&2
    sed 's/^/  /' <<<"$in_index" >&2
    # chmod -x だけでは足りない。ここで見ているのは index のモードで、
    # core.fileMode = false のクローンでは作業ツリーの chmod が index に届かない
    echo "外し方 (index のモードを直接書き換える):" >&2
    echo "  git update-index --chmod=-x$(shell_words <<<"$in_index")" >&2
  fi
  if [ -n "$in_worktree" ]; then
    echo "" >&2
    echo "作業ツリーで実行ビットが付いている (git add -A すると 100755 で載り、CI で赤になる):" >&2
    sed 's/^/  /' <<<"$in_worktree" >&2
    echo "外し方:" >&2
    echo "  chmod -x$(shell_words <<<"$in_worktree")" >&2
  fi
  exit 1
fi

checked="$(wc -l <<<"$entries" | tr -d ' ')"
if [ "$file_mode" = "false" ]; then
  echo "ok: 実行ビットの付いたファイルなし (追跡 ${checked} ファイル検査・core.fileMode=false なので作業ツリーは見ない)"
else
  echo "ok: 実行ビットの付いたファイルなし (追跡 ${checked}・未追跡 ${untracked_count} ファイル検査)"
fi
