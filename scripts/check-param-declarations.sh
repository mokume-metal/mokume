#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# つまみの宣言の書き間違いが、走らせる前に止まることを確かめる (#519)。
#
# 名前の重なりと、型を書き忘れた宣言は、どちらもビルドで止まる約束になっている
# (ADR-0030 決定 5)。止まることは実行して確かめられないので、実際に型検査を通して
# 「通るはずのものが通り、止まるはずのものが止まる」を見る。
#
# 組み上げ済みのモジュールと macro の実装を使うので、先に swift build が要る
# (make ci-check では build が先に走る)。**テストの中で package を組み直さない** —
# 検査どうしが CPU を奪い合い、時間の上限を持つ別の検査を巻き添えにするため。
set -euo pipefail

# **自分の隣を基準にする。** `$0` は source されると呼び出し側を指し、cwd にも依存する
# (#820)。`BASH_SOURCE` はこのファイル自身の場所で、`pwd -P` が symlink も解く
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

readonly BUILD_DIR=".build/debug"
readonly MODULES="$BUILD_DIR/Modules"

if [[ ! -d "$MODULES" ]]; then
  echo "check-param-declarations: 組み上げたものが見つからない ($MODULES)" >&2
  echo "次にすること: swift build を先に走らせる (make ci-check なら自動で先に走る)" >&2
  exit 1
fi

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

# $1=見出し $2=期待 (pass|fail) $3=止まったときに出るはずの語 $4=ソース
check() {
  local title="$1" expectation="$2" expected_message="$3" source="$4"
  local file="$workspace/snippet.swift" output status
  printf '%s\n' "$source" > "$file"
  set +e
  # **型検査の呼び方は scripts/swift_typecheck.py が持つ** (#820)。以前はここが
  # macro の plugin 名 (`MokumeMacros-tool` / `#MokumeMacros`) を直書きしており、
  # 的を改名すると examples は追随して params だけが落ちる状態だった。言語設定
  # (利用者のパッケージに揃える) もあちらが正典
  output="$(python3 scripts/swift_typecheck.py "$file" "$MODULES" 2>&1)"
  status=$?
  set -e

  if [[ "$expectation" == "pass" ]]; then
    if [[ $status -ne 0 ]]; then
      echo "check-param-declarations: $title — 通るはずの宣言が止まった" >&2
      echo "$output" >&2
      exit 1
    fi
  else
    if [[ $status -eq 0 ]]; then
      echo "check-param-declarations: $title — 止まるはずの宣言が通った" >&2
      exit 1
    fi
    if ! grep -qF "$expected_message" <<<"$output"; then
      echo "check-param-declarations: $title — 止まったが、理由が \"$expected_message\" ではない" >&2
      echo "$output" >&2
      exit 1
    fi
  fi
  echo "ok: $title"
}

check "宣言した値は組み上がる" pass "" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) var radius: Double = 80
    @Param(choices: ["circle", "square"]) var shape: String = "circle"
    @Param(name: "ink") var color: LinearRGBA = .display(red: 1, green: 0, blue: 0)
}'

check "同じ名前を二度宣言すると止まる" fail "invalid redeclaration" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) var radius: Double = 80
    @Param(name: "radius") var thickness: Double = 2
}'

check "型を書き忘れた宣言は、どう書くかを名指しして止まる" fail "@Param を付ける値には型を書く" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) var radius = 80.0
}'

check "let に付けると、var に直すよう名指しして止まる" fail "@Param は var に付ける" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) let radius: Double = 80
}'
