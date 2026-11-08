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

# **swiftmodule の置き場は道具立ての版で違う。** Swift 6.3 までは `<置き場>/Modules/`
# に並んでいたが、Swift 6.4 の既定のビルドシステムは置き場そのものへ並べる
# (https://github.com/mokume-metal/mokume/issues/1276)。**版で分岐せず、在るほうを使う。**
MODULES=""
for candidate in "$BUILD_DIR/Modules" "$BUILD_DIR"; do
  if [[ -f "$candidate/mokume.swiftmodule" || -d "$candidate/mokume.swiftmodule" ]]; then
    MODULES="$candidate"
    break
  fi
done
readonly MODULES

if [[ -z "$MODULES" ]]; then
  echo "check-param-declarations: 組み上げたものが見つからない ($BUILD_DIR)" >&2
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

check "型を書き忘れた宣言は、どう書くかを名指しして止まる" fail "write the type on a value you put @Param on" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) var radius = 80.0
}'

check "let に付けると、var に直すよう名指しして止まる" fail "@Param goes on a var" 'import mokume

final class Tunables: Sketch {
    @Param(0...200) let radius: Double = 80
}'

# struct の中の @Param は止まる (#3876)。置き場 (ParamBox) は class なので、struct を写すと
# 写しどうしが同じ値を指し、そのうえつまみにも出ない。入れ子は最も内側の型で判定するので、
# スケッチの class の中に入れた struct も止まる
check "struct の部品に書くと、スケッチの class に置くよう名指しして止まる" fail "@Param goes on the sketch class" 'import mokume

struct Brush: SketchPart {
    @Param(1...80) var size: Float = 12
}'

check "スケッチの class に入れ子にした struct に書いても止まる" fail "@Param goes on the sketch class" 'import mokume

final class Painting: Sketch {
    struct Brush {
        @Param(1...80) var size: Float = 12
    }
    var left = Brush()
}'

check "関数の中の局所の struct に書いても止まる" fail "@Param goes on the sketch class" 'import mokume

final class Painting: Sketch {
    func draw() {
        struct Stamp {
            @Param(1...80) var size: Float = 12
        }
        _ = Stamp()
    }
}'

# class の部品と基底クラスは今までどおり組める。class の部品はつまみには出ないが、構文からは
# スケッチの class と区別できない (準拠を extension で書ける) ので止めない (#3876)
check "class の部品と基底クラスに書いた宣言は組み上がる" pass "" 'import mokume

final class Brush: SketchPart {
    @Param(1...80) var size: Float = 12
}

class Base: Sketch {
    @Param(0...1) var opacity: Float = 1
    required init() {}
}

final class Painting: Base {
    @Param(0...200) var radius: Double = 80
    var brush = Brush()
}'

# 複数の束縛と独自の get / set は、専用の診断で止まる (#3301)。型検査が落ちるだけでは足りず、
# **mokume の診断の文言が出ている**ことまで見る — 一般のコンパイル失敗に化けても、利用者へ
# 「どう書くか」が届かないため。期待の語は ParamMacro.Problem の message の固有の部分
check "束縛を複数並べると、1 宣言に 1 つと名指しして止まる" fail "@Param takes one value per declaration" 'import mokume

final class Tunables: Sketch {
    @Param var a: Int = 0, b: Int = 0
}'

check "独自の get / set を持つ値に付けると、保存する値に付けるよう名指しして止まる" fail "@Param cannot go on a property with its own get or set" 'import mokume

final class Tunables: Sketch {
    @Param var a: Int { 1 }
}'

# enum を宣言できること (#2438)。型の側に ParamRepresentable を書かない。刻みは実数の範囲に付く
check "String を生の値に持つ CaseIterable の enum は、型に何も書かずに宣言でき、刻みも書ける" pass "" 'import mokume

enum Palette: String, CaseIterable { case ember, tide, moss }

final class Tunables: Sketch {
    @Param var palette: Palette = .ember
    @Param(0...1, step: 0.05) var density: Double = 0.4
    @Param(name: "drift") var offset: Palette = .tide
}'

check "CaseIterable でない enum は、候補を作れないので止まる" fail "conform to 'CaseIterable'" 'import mokume

enum Palette: String { case ember, tide }

final class Tunables: Sketch {
    @Param var palette: Palette = .ember
}'

check "生の値が String でない enum は、面に出せないので止まる" fail "be equivalent" 'import mokume

enum Level: Int, CaseIterable { case low, high }

final class Tunables: Sketch {
    @Param var level: Level = .low
}'
