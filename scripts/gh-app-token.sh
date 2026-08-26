#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# GitHub App の installation token を発行して標準出力に出す (#49 / ADR-0003)。
#
#   export GH_TOKEN="$(bash scripts/gh-app-token.sh)"
#
# 設定は環境変数 (MOKUME_APP_ID / MOKUME_APP_INSTALLATION_ID と、鍵は
# MOKUME_APP_PRIVATE_KEY か MOKUME_APP_PRIVATE_KEY_CMD)。詳細は AGENTS.md。
# 秘密鍵の中身も、その在処もリポジトリには書かない。
#
# ここの説明を長くしないこと — reuse がヘッダの走査を途中で打ち切り、
# 先頭の SPDX タグを見落とす (#50)。
set -euo pipefail

fail() { # $1=理由 $2=次にすること
  echo "gh-app-token: $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

missing=()
[ -n "${MOKUME_APP_ID:-}" ] || missing+=("MOKUME_APP_ID")
[ -n "${MOKUME_APP_INSTALLATION_ID:-}" ] || missing+=("MOKUME_APP_INSTALLATION_ID")
[ -n "${MOKUME_APP_PRIVATE_KEY_CMD:-}" ] || [ -n "${MOKUME_APP_PRIVATE_KEY:-}" ] ||
  missing+=("MOKUME_APP_PRIVATE_KEY または MOKUME_APP_PRIVATE_KEY_CMD")

if [ ${#missing[@]} -gt 0 ]; then
  fail "App の設定が足りない: ${missing[*]}" \
       "AGENTS.md の「エージェントの identity」を見て環境変数を揃える"
fi

for cmd in openssl gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd が見つからない" "$cmd を入れる (make setup が前提を確かめる)"
done

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
