#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`Sources/` の `isolated deinit` が、隔離を明示した型の中にあることを見る (#1083)。

**塞ぐのは「足した本人には壊れて見えない」形の再発である。** 明示の隔離を持たない
`isolated deinit` が入ると `make test-release`
(= `swift test -c release -Xswiftc -enable-testing`) がコンパイルできなくなるが、
`swift build -c release` (製品) も `swift test` (debug) も通る。気付くのは、次に
`make test-release` を打った人である。2 度起きた (#761 → #1021)。

**再発の経路は「散文で書いた作法が守られなかった」1 本である。** 作法の正典は #763 が
`Sources/MokumeCore/Rendering/RenderDevice.swift` の冒頭に置き、同じ形の型はそこを指す
2 行のコメントを持つ。#980 はそれを読まずに足した — 読ませる仕組みが無いからである。
**だからこの検査の本体は、赤が正典まで案内すること**にある (#1083 完了条件 3)。

**判定は不変条件の代理である。** 本物はコンパイラで、そちらを CI で回す話は #1096 が持つ。
ここが見るのは字句だけなので、コンパイラが別の形で同じことを言い出したら見落とす。
その代わり `make ci-check` の中で数十ミリ秒で止まり、赤が正典を指す。

## 読み方と、外れたときにどちらへ倒れるか

**`isolated deinit` は行頭 (インデントの直後) のものだけを見る。** コメントを消す処理を
持たない代わりで (`scripts/check-tool-language.py` の `blank_comments` は写さない —
ADR-0008 決定 6)、`Sources/` にある 10 箇所の
「`// `isolated deinit` を持つ型は隔離を明示する」のようなコメントは当たらない。
**外れる向きは赤側である** — ブロックコメントの中に行頭から `isolated deinit` と書けば
誤検出するが、それは目に見える。宣言は必ず行頭に来るので、見逃し側へは倒れない。

**囲みはインデントで探す。** `isolated deinit` の行より厳密に浅いインデントを持つ最初の
型宣言を囲みとする。**読み取れなければ赤にする** — 「囲みが分からないので緑」は、
この検査がいちばん避けたい倒れ方である。

使い方: python3 scripts/check-isolated-deinit.py [ルート (既定 Sources)]
"""

import re
import sys
from pathlib import Path

DEINIT = re.compile(r"^(?P<indent>[ \t]*)isolated[ \t]+deinit\b")

# 型宣言に付きうる修飾子。`@MainActor` も属性としてここに入る
MODIFIER = r"(?:@\w+(?:\([^()]*\))?|public|internal|private|fileprivate|package|open|final|nonisolated(?:\([^()]*\))?|dynamic|indirect)"
DECLARATION = re.compile(
    rf"^(?P<indent>[ \t]*)(?:{MODIFIER}[ \t]+)*(?P<kind>class|actor)[ \t]+(?P<name>\w+)")

# 属性だけの行。**宣言を兼ねる行 (`@MainActor final class Foo {`) は含めない** —
# 含めると外側の型の属性を内側の型のものと読み、見逃す側へ倒れる
ATTRIBUTE_LINE = re.compile(r"^[ \t]*(?:@\w+(?:\([^()]*\))?[ \t]*)+$")
# グローバルアクター属性。`@MainActor` のほか、自作のものも名前が Actor で終わる
GLOBAL_ACTOR = re.compile(r"@\w*Actor\b")

CANON = "Sources/MokumeCore/Rendering/RenderDevice.swift"


def width(indent):
    return len(indent.expandtabs(4))


def enclosing(lines, index):
    """index 行目を囲む型宣言を (行番号, match) で返す。読み取れなければ None。"""
    inner = width(DEINIT.match(lines[index]).group("indent"))
    for j in range(index - 1, -1, -1):
        found = DECLARATION.match(lines[j])
        if found and width(found.group("indent")) < inner:
            return j, found
    return None


def isolation(lines, index):
    """宣言の行と、その直前に連なる属性行を 1 つの文字列にして返す。"""
    text = lines[index]
    j = index - 1
    while j >= 0 and ATTRIBUTE_LINE.match(lines[j]):
        text = lines[j] + "\n" + text
        j -= 1
    return text


def findings(root):
    """(見た Swift の数, 見た isolated deinit の数, [(パス, 行番号, 説明)])。"""
    files = sorted(root.rglob("*.swift"))
    seen = 0
    found = []
    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if not DEINIT.match(line):
                continue
            seen += 1
            where = enclosing(lines, index)
            if where is None:
                found.append((path, index + 1, "囲む型の宣言を読み取れなかった"))
                continue
            declared, decl = where
            if decl.group("kind") == "actor":
                continue
            if GLOBAL_ACTOR.search(isolation(lines, declared)):
                continue
            found.append((
                path, index + 1,
                f"class {decl.group('name')} (宣言は {declared + 1} 行目) が隔離を明示していない"))
    return len(files), seen, found


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else "Sources")
    files, seen, found = findings(root) if root.is_dir() else (0, 0, [])
    if files == 0:
        print(f"isolated-deinit: {root} の下に Swift のファイルが 1 つも無い"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    if not found:
        print(f"isolated-deinit: {files} 個の Swift を見た。"
              f"isolated deinit は {seen} 箇所、すべて隔離を明示している")
        return 0
    print(f"isolated-deinit: 隔離を明示していない型に isolated deinit がある ({len(found)} 箇所)。"
          "release のテストビルド (make test-release) がコンパイルできなくなる (#761 / #1021)",
          file=sys.stderr)
    for path, number, reason in found:
        print(f"  {path}:{number}: {reason}", file=sys.stderr)
    print("次にすること: その型の宣言に @MainActor を明示する"
          " (アクターの中にあるなら、囲みが読める形へ直す)。", file=sys.stderr)
    print(f"理由の正典は {CANON} の冒頭が持つ"
          " — release のテストビルドでは、取り込み側が module を deserialize したときに"
          "暗黙の既定隔離を見失う", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
