#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# .github/workflows/ を actionlint (+ shellcheck) で検証する (#89)。
#
# ワークフローの中身は per-PR の CI では誰も検証しておらず、YAML として妥当なまま
# 壊れていると「そのワークフローが次に走ったとき」まで気付けない。しかも失敗ではなく
# 空振りとして現れる — triage / parent-guard / close-cleanup / review-gate は
# 「動かなくても PR は緑」なので、機構側で見張らないと分からない。実際に 3 回踏んだ
# (#23 の parent-guard・#38 / #66 の run-name)。
#
# scripts/check-github-yaml.sh と役割を分ける。あちらは .github/ 配下の YAML すべての
# **構文**をファイルを名指しせず包み (#87)、こちらは workflows の**意味**を見る
# (式・イベント名・run: のシェル)。workflows で構文が二重に見られるのは「包む」設計の
# 副産物で、除外を書けば名指しに戻り、次に YAML が増えたとき #87 と同じ穴が空く。
#
# CI からもローカルからも同じバージョン・同じ検証範囲で走らせるため、実体はこの 1 本に
# まとめる (Makefile の workflows-lint がこれを呼び、CI は make ci-check を呼ぶだけ)。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# 更新は dependabot ではなく手動。lint の指摘が増減してある日突然 CI が赤くなるのを避ける。
#
# actionlint は shellcheck があると run: の中身も検証するが、GitHub の macOS ランナーには
# shellcheck が入っていない (ci-check は ADR-0009 により macos-latest で走る)。「あれば使う」
# にすると CI とローカルで検証範囲が変わり、CI が黙って緩くなるため**両方**をピンして落とす。
#
# 上げるときは SHA256 も一緒に差し替えること:
#   curl -fsSL https://github.com/rhysd/actionlint/releases/download/v<ver>/actionlint_<ver>_checksums.txt
#   curl -fsSL <shellcheck tarball url> | shasum -a 256
ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
SHELLCHECK_VERSION="0.11.0"
SHELLCHECK_SHA256="339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"

# .build/ は .gitignore 済み。check-no-binaries.sh は git ls-files を見るので、
# ここに実行ファイルが増えても検査には掛からない
TOOLS_DIR=".build/tools"

# mokume は macOS / Apple Silicon 専用 (ADR-0009) なので、落とす配布物も 1 種類でよい。
# 想定外の環境では黙って別物を落とさず、手で入れる道を示して止まる
require_darwin_arm64() {
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "このスクリプトは macOS / Apple Silicon 専用 (uname: $(uname -s) $(uname -m))" >&2
    echo "他の環境では actionlint ${ACTIONLINT_VERSION} と shellcheck ${SHELLCHECK_VERSION} を手で入れて PATH に通す" >&2
    exit 1
  fi
}

# fetch_tool <url> <期待する sha256> <tarball 内のパス> <strip-components> <置き場>
fetch_tool() {
  local url=$1 expected=$2 member=$3 strip=$4 dest=$5
  local tarball="${dest}.tar.gz"
  mkdir -p "$TOOLS_DIR"
  echo "取得中: $(basename "$dest")"
  # **一時的な失敗は取り直す** (#1195)。1 回きりだと GitHub 側の 504 で段ごと落ち、merge
  # queue の上では変更と無関係に PR が外される (#1190 / #1192 が 10 分の間に踏んだ)。
  # --retry 単独は 5xx・408・429・タイムアウトしか拾わず、接続断 (curl 56 など) を拾わない
  # ので --retry-all-errors を併せる。代償はピンの URL を誤ったとき (404) も数秒の取り直しを
  # 挟んでから落ちること。回数は有限 (既定の指数バックオフで待ちは合計 7 秒ほど)。
  # **照合の失敗は curl の外なので取り直さない** — 改竄を取り直しで押し通さない
  if ! curl -fsSL --retry 3 --retry-all-errors -o "$tarball" "$url"; then
    echo "$(basename "$dest") を取得できなかった (${url})" >&2
    rm -f "$tarball"
    exit 1
  fi
  # 落として即実行するので、配布物の改竄・取り違えはここで止める。set -e に頼らず
  # 明示的に分岐して、壊れた tarball を残さない
  if ! echo "${expected}  ${tarball}" | shasum -a 256 -c -; then
    echo "$(basename "$dest") のチェックサムが一致しない。配布物を破棄した" >&2
    rm -f "$tarball"
    exit 1
  fi
  tar -xzf "$tarball" -C "$TOOLS_DIR" --strip-components="$strip" "$member"
  mv "${TOOLS_DIR}/$(basename "$member")" "$dest"
  rm -f "$tarball"
}

# NOTE: resolve_* は結果をグローバル変数へ書いて返す。X="$(resolve_x)" と書くと関数が
# コマンド置換の**サブシェル**で走り、中の exit はそのサブシェルを終えるだけで呼び出し元は
# 止まらない — チェックサム不一致を検知しても後続が走ってしまう
SHELLCHECK=""
resolve_shellcheck() {
  local pinned="${TOOLS_DIR}/shellcheck-${SHELLCHECK_VERSION}"
  # 手元に入っているものがピンと同版ならそれを使う (brew install shellcheck を無駄にしない)
  if command -v shellcheck >/dev/null 2>&1 \
    && [ "$(shellcheck --version | awk '/^version:/ {print $2}')" = "$SHELLCHECK_VERSION" ]; then
    SHELLCHECK="$(command -v shellcheck)"
    return
  fi
  if [ ! -x "$pinned" ]; then
    require_darwin_arm64
    fetch_tool \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.darwin.aarch64.tar.gz" \
      "$SHELLCHECK_SHA256" \
      "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" 1 \
      "$pinned"
  fi
  SHELLCHECK="$pinned"
}

ACTIONLINT=""
resolve_actionlint() {
  local pinned="${TOOLS_DIR}/actionlint-${ACTIONLINT_VERSION}"
  if command -v actionlint >/dev/null 2>&1 \
    && [ "$(actionlint -version | head -1)" = "$ACTIONLINT_VERSION" ]; then
    ACTIONLINT="$(command -v actionlint)"
    return
  fi
  if [ ! -x "$pinned" ]; then
    require_darwin_arm64
    fetch_tool \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz" \
      "$ACTIONLINT_SHA256" \
      "actionlint" 0 \
      "$pinned"
  fi
  ACTIONLINT="$pinned"
}

# **source されたときは関数を定義するだけで止まる。** 検査が fetch_tool を手元の偽の
# サーバに向けて呼ぶためで、URL を差し替える口を本体に足すより実行経路を変えずに済む (#1195)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  resolve_shellcheck
  resolve_actionlint
  echo "shellcheck: ${SHELLCHECK} ($("$SHELLCHECK" --version | awk '/^version:/ {print $2}'))"
  echo "actionlint: ${ACTIONLINT} ($("$ACTIONLINT" -version | head -1))"

  exec "$ACTIONLINT" -oneline -shellcheck "$SHELLCHECK" "$@"
fi
