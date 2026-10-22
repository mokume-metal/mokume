# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# GitHub へ持ち出す本文から、秘密情報らしき文字列を探す (#819)。
#
# **プランに固有の機構ではない。** 以前は `plan-record.sh` の 4 つの CLI 口の 1 つとして
# あちらに埋まっていたが、問うているのは「この本文を GitHub へ出してよいか」であって
# プランかどうかとは関係がない。テストも `plan_record_test.py` (リポジトリ最大) の中に
# しか無かった。
#
# ## 2 段で答える
#
#   BLOCK  見つかったら**投稿用ファイルを作らない** (秘密情報)
#   WARN   投稿は止めないが、エージェントに読ませて判断させる (個人情報・環境固有)
#
# 出力は 1 件 1 行のタブ区切り: `<種別>\t<説明>\t行 <番号,番号>`
#
# **中身は出さない。** 秘密情報を出力へ再掲したら守った意味が無いので、場所 (行番号)
# だけを伝えて本文へ誘導する。
#
# **検出漏れより過検出のほうが安全。** BLOCK は行番号を示すだけ、WARN は判断を委ねるので、
# 広めに取っても行き止まりにならない。
#
# ## 配線の範囲
#
# **plan-record は BLOCK で止める。** `comment.sh` / `edit-body.sh` は**止めずに名乗るだけ**
# (`secret_notice`、#3075): 本文を作るのは人かエージェントで、混入に気付いて直せば足りる。
# 止めると正当な `localhost` の言及で連投が止まり、ADR-0008 が避ける「実害の無い行き止まり」
# になる。`comment.sh` の宛先の近況 (#1327) と同じ作法で、stderr に 1 件 1 行を出すだけ。
#
# **「持ち出せる形に整える」は別の問い。** 絶対パスとホームディレクトリを畳むのは
# `plan-record.sh` の sanitize が持つ。見つけるのと整えるのを 1 つにすると、畳む前と
# 同じ形 (2 つの責務) に戻る。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/secret-scan.sh"
#   findings=$(secret_scan "$body")
#   blocks=$(printf '%s\n' "$findings" | grep '^BLOCK' | cut -f2,3)
#
# テストは scripts/tests/secret_scan_test.py。

# 1 種類ぶんの検出。当たらなければ何も出さない。
#   $1=種別 $2=説明 $3=本文 $4=検出パターン $5=除外パターン (省略可)
secret_emit() {
  local kind="$1" label="$2" body="$3" pattern="$4" exclude="${5:-}" hits
  # 大文字小文字は区別しない。GITHUB_TOKEN= のような書き方を取りこぼすため。
  #
  # **パターンは -e で渡す。** `-----BEGIN … PRIVATE KEY-----` のように `-` で始まる
  # パターンを素で渡すと grep がオプションと解釈して exit 2 で落ち、下の `|| return 0`
  # が飲み込む — **秘密鍵の検出は一度も発火していなかった** (#819 で切り出して単体の
  # 検査を書いたときに露見した)。落ちたことが「見つからなかった」と同じ形になるのが
  # 危ないので、除外の側も同じ形で渡す
  hits=$(printf '%s' "$body" | grep -inE -e "$pattern" 2>/dev/null) || return 0
  [ -n "$exclude" ] && hits=$(printf '%s' "$hits" | grep -viE -e "$exclude")
  [ -n "$hits" ] || return 0
  printf '%s\t%s\t行 %s\n' "$kind" "$label" \
    "$(printf '%s' "$hits" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
}

# 本文を検める。**引数で受ける** — 以前は stdin を読んでいたが、そうすると読み方
# (待ちの上限・最後の行の拾い方) まで持つことになり、呼び出し側と二重になる。
#   $1=本文
secret_scan() { # $1=本文 → 1 件 1 行のタブ区切り
  local body="${1:-}"
  [ -n "$body" ] || return 0

  secret_emit BLOCK 'GitHub のトークン' "$body" 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}'
  secret_emit BLOCK 'API キー' "$body" 'sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{32,}'
  secret_emit BLOCK 'AWS のアクセスキー' "$body" 'AKIA[0-9A-Z]{16}'
  secret_emit BLOCK 'Slack のトークン' "$body" 'xox[baprs]-[A-Za-z0-9-]{10,}'
  secret_emit BLOCK '秘密鍵' "$body" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  # 値が実体を持つものだけ。$VAR / <your-token> / **** のような伏せ字は対象外。
  # 値は ASCII の英数記号に限る — 日本語を許すと「token は環境変数で渡す」のような
  # 説明文まで秘密情報として拾ってしまい、投稿を止める判断が信用できなくなる
  secret_emit BLOCK '秘密情報らしき代入' "$body" \
    '(password|passwd|secret|token|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{8,}'

  # noreply は GitHub が公開用に配るアドレスなので、伏せる意味が無い
  secret_emit WARN 'メールアドレス' "$body" \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'noreply'
  secret_emit WARN '1Password の参照 (vault の構造が漏れる)' "$body" 'op://[^[:space:]]+'
  secret_emit WARN '畳めなかった絶対パス' "$body" '/(Users|home)/[A-Za-z0-9._-]+'
  secret_emit WARN 'ローカルのポート番号' "$body" 'localhost:[0-9]+|127\.0\.0\.1:[0-9]+'
}

# 投稿の直前に、検出した種別と行番号だけを stderr に 1 行ずつ名乗る (#3075)。止めない・
# 中身は出さない・検出が無ければ何も出さない。呼び出し側の set -e を落とさない。
#   $1=本文
secret_notice() {
  local body="${1:-}" kind label where
  while IFS=$'\t' read -r kind label where; do
    [ -n "$kind" ] || continue
    printf '本文に %s らしきものがあります (%s)。残してよいか確認してください\n' "$label" "$where" >&2
  done < <(secret_scan "$body" || true)
  return 0
}
