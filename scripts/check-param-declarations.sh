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

cd "$(dirname "$0")/.."

readonly BUILD_DIR=".build/debug"
readonly MODULES="$BUILD_DIR/Modules"
readonly PLUGIN="$BUILD_DIR/MokumeMacros-tool"

if [[ ! -d "$MODULES" || ! -x "$PLUGIN" ]]; then
  echo "check-param-declarations: 組み上げたものが見つからない ($MODULES / $PLUGIN)" >&2
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
  # 利用者のパッケージと同じ言語設定で見る (ひな形の Package.swift に揃える)。
  # ここが揃っていないと、利用者の手元では出ない食い違いを検査が拾ってしまう
  output="$(swiftc -typecheck -swift-version 6 -default-isolation MainActor \
    -I "$MODULES" \
    -load-plugin-executable "$PLUGIN#MokumeMacros" \
    "$file" 2>&1)"
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
