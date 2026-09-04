# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「どのリポジトリか」の解き方 (#818)。
#
# 以前は 2 つの実装があり、**片方が他方の劣化版**だった。`render-status.sh` の
# `resolve_repo()` は `git@github.com:` と `https://github.com/` の 2 形しか落とさず、
# `ssh://` 形や ssh alias を通した origin を解けなかった:
#
#   ssh://git@github.com/owner/repo.git   → ssh://git@github.com/owner/repo  (解けていない)
#   git@github-work:owner/repo.git        → git@github-work:owner/repo       (解けていない)
#
# **害は「手元の実行の報告が黙って届かない」だった。** 劣化版は空を返さないので
# 「origin が無い」の逃がしにも掛からず、続く `gh api repos/<ごみ>/…` が失敗して
# local-render が付かない。描画 PR はそれが無いと merge できないので、そういう origin を
# 使っている機械では**理由の分からない足止め**になる。
#
# **`guard-lib.sh` から移してある。** あちらはフックが共有する読み方・返し方の置き場で
# (#825 でその責務が広がった)、リポジトリの解決はフックに限った話ではない。
#
# ## ここに無いもの
#
# **「gh はどこへ送るか」は別の問いである。** `catch-up.sh` が `gh repo view --json
# nameWithOwner` を使うのはそちらで、`gh repo set-default` や base-repo の解決を含む。
# 下の repo_of_dir は「origin は何を指すか」だけを答え、ローカルパスの remote は
# 意図的に拒む — 寄せると、origin が手元の bare である環境で解けなくなる。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
#   REPO="$(this_repo)"
#   target=$(repo_of_dir "$cwd") || …
#
# テストは scripts/tests/repo_slug_test.py。

# このリポジトリの owner/repo。**literal はここにしか無い。**
#
# CI は GITHUB_REPOSITORY を立てるので、既定が効くのは手元だけである。以前は 9 か所が
# 同じ literal を持っていた。
this_repo() {
  printf '%s' "${GITHUB_REPOSITORY:-mokume-metal/mokume}"
}

# ディレクトリの origin から owner/repo を取り出す (stdout)。解けなければ非 0。
#
# `-R` が無いとき gh が宛先にするのはカレントディレクトリのリポジトリなので、同じことを
# ここで近似する。`gh repo set-default` による上書きは見ない — ずれたときは「解けなかった」
# ではなく「別の宛先」と読む可能性があるが、その形は origin と既定が食い違うリポジトリに
# 限られ、このリポジトリでは起きない。
repo_of_dir() { # $1=ディレクトリ
  local url slug
  [ -n "${1:-}" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  # scheme://host/ と user@host: の 2 形を落とし、末尾の .git と / を落とす
  slug=$(printf '%s' "$url" |
    sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/##; s#^[^/@]+@[^:/]+:##; s#\.git$##; s#/$##')
  # **`:` が残っていたら解けていない。** 素の ssh alias (user@ を伴わない host:owner/repo)
  # は上の sed が落とせず、残った `alias:owner/repo` は下の `*/*` に当たってしまう —
  # つまり**誤った宛先を「解けた」として返していた**。曖昧なものを宛先として採らない、と
  # いうこの関数の方針をそこにも通す (#818)
  case "$slug" in *:*) return 1 ;; esac
  # owner/repo ちょうど 2 段でなければ解けなかったものとして扱う (ローカルパスの
  # remote などが該当する)。曖昧なものを宛先として採らない
  case "$slug" in
    */*/*) return 1 ;;
    */*) printf '%s\n' "$slug" ;;
    *) return 1 ;;
  esac
}
