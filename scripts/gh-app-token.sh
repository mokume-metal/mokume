#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# GitHub App の installation token を発行して標準出力に出す (#49 / ADR-0003)。
#
#   GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …
#
# 代入から始めること。export を先頭に付けると終了コードが export のもの (0) になり、
# 発行に失敗しても後段が走って空の GH_TOKEN で gh がメンテナの認証へ落ちる (#122)。
#
# 必ず要る設定は鍵の読み出しコマンド (MOKUME_APP_PRIVATE_KEY_CMD。値そのものを渡す
# MOKUME_APP_PRIVATE_KEY でもよい) の 1 つだけ。App ID とインストール ID は秘密ではない
# 識別子なので、未設定ならインストール先の org から自分で引く (#71)。明示したいときは
# MOKUME_APP_ID / MOKUME_APP_INSTALLATION_ID で上書きできる。詳細は AGENTS.md。
# 秘密鍵の中身も、その在処もリポジトリには書かない。
set -euo pipefail

fail() { # $1=理由 $2=次にすること
  echo "gh-app-token: $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

for cmd in openssl gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd が見つからない" "$cmd を入れる (make setup が前提を確かめる)"
done

# --- App の identity --------------------------------------------------------
# ID 2 つは秘密ではなく、インストール先の org に問い合わせれば引ける。未設定なら自分で
# 引くことで、手で揃える設定は「鍵をどう読むか」の 1 つだけになる (#71)。
# 引くには org を読める人間の gh 認証が要る (App の installation token では引けない) ので、
# 引けなくても即座には失敗させず、下の「足りないものを名指しする」検査に合流させる —
# 鍵も足りないときに、必要なもの全てが 1 回のメッセージで出る

app_slug="${MOKUME_APP_SLUG:-mokume-agent}"
owner=""

if [ -z "${MOKUME_APP_ID:-}" ] || [ -z "${MOKUME_APP_INSTALLATION_ID:-}" ]; then
  owner=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null) || owner=""
  pair=""
  if [ -n "$owner" ]; then
    pair=$(gh api "orgs/$owner/installations" \
      --jq ".installations[] | select(.app_slug == \"$app_slug\") | \"\(.app_id) \(.id)\"" \
      2>/dev/null) || pair=""
  fi
  # 一意に定まったときだけ採用する。複数の App が入っている org で当てずっぽうに選ぶと、
  # 「なぜか別の App の token が出る」という最も追いにくい失敗になる
  if [ "$(printf '%s' "$pair" | grep -c .)" = "1" ]; then
    MOKUME_APP_ID="${MOKUME_APP_ID:-${pair%% *}}"
    MOKUME_APP_INSTALLATION_ID="${MOKUME_APP_INSTALLATION_ID:-${pair##* }}"
  fi
fi

missing=()
[ -n "${MOKUME_APP_ID:-}" ] || missing+=("MOKUME_APP_ID")
[ -n "${MOKUME_APP_INSTALLATION_ID:-}" ] || missing+=("MOKUME_APP_INSTALLATION_ID")
[ -n "${MOKUME_APP_PRIVATE_KEY_CMD:-}" ] || [ -n "${MOKUME_APP_PRIVATE_KEY:-}" ] ||
  missing+=("MOKUME_APP_PRIVATE_KEY または MOKUME_APP_PRIVATE_KEY_CMD")

if [ ${#missing[@]} -gt 0 ]; then
  next="AGENTS.md の「エージェントの identity」を見て環境変数を揃える"
  if [ -z "${MOKUME_APP_ID:-}" ] || [ -z "${MOKUME_APP_INSTALLATION_ID:-}" ]; then
    # ここに来たのは自動解決が効かなかったとき。次の一手をそのまま貼れる形で出す
    next="${next}。ID 2 つは自分で引こうとしたが取れなかった (org=${owner:-不明} app_slug=$app_slug) — 手で引く:
  gh api orgs/${owner:-<org>}/installations --jq '.installations[] | select(.app_slug==\"$app_slug\") | {app_id, id}'
この API は org を読める人間の gh 認証 (read:org) が要る。App の installation token では引けない"
  fi
  fail "App の設定が足りない: ${missing[*]}" "$next"
fi

# --- 秘密鍵 -----------------------------------------------------------------
# openssl はファイル経由でしか鍵を受け取らないので一時ファイルを作る。作った瞬間から
# 消えるまでの間だけ他人に読めないよう、umask を絞ってから mktemp する

umask 077
key_file=$(mktemp) || fail "一時ファイルを作れない" "TMPDIR の書き込み権限を確かめる"
trap 'rm -f "$key_file"' EXIT

if [ -n "${MOKUME_APP_PRIVATE_KEY_CMD:-}" ]; then
  # サブシェルに閉じ込める。eval は現在のシェルで走るので、コマンドが exit を含むと
  # このスクリプト自体が黙って終わり、鍵が読めなかったことが誰にも伝わらない。
  # stderr は捨てる — 秘密管理ツールが鍵を出力に混ぜても外へ漏らさない
  if ! ( eval "$MOKUME_APP_PRIVATE_KEY_CMD" ) > "$key_file" 2>/dev/null; then
    fail "MOKUME_APP_PRIVATE_KEY_CMD が失敗した" \
         "そのコマンドを手で実行して確かめる (出力は PEM だけである必要がある)"
  fi
else
  printf '%s\n' "$MOKUME_APP_PRIVATE_KEY" > "$key_file"
fi
[ -s "$key_file" ] || fail "秘密鍵が空" "設定した参照が正しい鍵を指しているか確かめる"

# 鍵の保管先が値を壊すことは珍しくない (1 行のフィールドに貼って改行が消える・長さの
# 上限で切られる)。そのまま openssl に渡すと一般的な暗号エラーになり、原因から最も遠い
# 形で出るので、PEM の体をなしているかを先に見る。中身は一切出さない (#57)
[ "$(head -c 10 "$key_file")" = "-----BEGIN" ] ||
  fail "秘密鍵が PEM ではない" \
       "参照が鍵そのものを指しているか確かめる (別のフィールドや説明文を読んでいないか)"

grep -q -- "-----END" "$key_file" ||
  fail "秘密鍵が途中で切れている (END 行が無い)" \
       "保管先が長さの上限で値を切っていないか確かめる。1Password ならファイル添付にすると壊れない"

[ "$(tr -cd '\n' < "$key_file" | wc -c | tr -d ' ')" -gt 1 ] ||
  fail "秘密鍵に改行が無い (1 行に潰れている)" \
       "保管先が改行を落としている。1 行のフィールドではなくファイル添付かノート欄に置く"

# --- JWT --------------------------------------------------------------------
# GitHub の App 認証は RS256 の JWT。exp は最大 10 分で、iat は時計ずれを見込んで
# 60 秒過去に置く (少しでも未来だと GitHub が弾く)

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
iat=$((now - 60))
exp=$((iat + 540))

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$MOKUME_APP_ID" | b64url)

# openssl の stderr は捨てる — 失敗の詳細より、鍵の断片が出ないことを優先する
if ! signature=$(printf '%s.%s' "$header" "$payload" |
  openssl dgst -sha256 -sign "$key_file" -binary 2>/dev/null | b64url); then
  fail "JWT に署名できない" "秘密鍵が App の PEM (RSA 秘密鍵) であることを確かめる"
fi
[ -n "$signature" ] || fail "JWT に署名できない" "秘密鍵が App の PEM (RSA 秘密鍵) であることを確かめる"

jwt="$header.$payload.$signature"

# --- installation token -----------------------------------------------------

# Authorization は Bearer で送る。gh は GH_TOKEN を "token <値>" として送る作りで、
# App の JWT をその形で渡すと GitHub が復号できず 401 になる (#53)。ヘッダを明示して
# 上書きし、GH_TOKEN 自体は gh が「認証が設定されていない」と言わないために置く
if ! token=$(GH_TOKEN="$jwt" GITHUB_TOKEN="$jwt" gh api -X POST \
  -H "Authorization: Bearer $jwt" \
  "app/installations/$MOKUME_APP_INSTALLATION_ID/access_tokens" --jq .token 2>&1); then
  fail "installation token を発行できなかった: $token" \
       "App ID とインストール ID の対応、鍵が失効していないかを確かめる (App の設定画面)"
fi
[ -n "$token" ] && [ "$token" != "null" ] ||
  fail "応答に token が無い" "App がこのリポジトリにインストールされているかを確かめる"

printf '%s\n' "$token"
