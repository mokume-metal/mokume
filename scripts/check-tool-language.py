#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`Sources/` の Swift で、コメントの外に日本語が無いことを見る (#1160)。

**守っているのは [ADR-0038](../docs/decisions/0038-language-of-the-tool.md) 決定 1 —
道具が話す言葉は英語、読み物は日本語 — の線である。** 線は読み手で引かれているが、
機械には読み手が分からないので、ここでは「コメントの中か外か」で近似する。

**塞ぐのは「日本語の文言が、誰にも壊れて見えないまま `main` に残る」である。** この
リポジトリの書き手と読み手は日本語を読めるので、日本語の文言を見ても壊れているとは
感じない。困るのは届いた先の利用者で、そこから戻ってくる経路が無い。実際に 9 段の
移行が「日本語 0 件」と報告したまま 18 通を残し、数え直しもさらに 1 通を取り逃した
(#1156) — 行単位の grep が `\"\"\"` の本文を数えていなかった。

**文字列リテラルに限らず、コメントの外すべてを見る。** 識別子は元から英語なので同じ
規則で済む。加えて、**字句の境界を読み違えたときに見逃しへ倒れる形が狭まる。** 文字列
だけを集める形では、文字列をコードと読み違えるとその中身を見ない。外すべてを見る形では
コードと読んでも中身は見るので、見逃すのは「文字列の中の `//` や `/*` をコメントと
読み違えた」ときだけになる — 検査の検査 (`scripts/tests/tool_language_test.py`) が押さえて
いるのはその形である。

**例外の一覧は持たない。** 一覧は規則の写しで、足すたびに判断が要り、足した行は誰も
見直さない。`mokume new` が書き出す読み物は `Sources/MokumeCLI/Templates/` のファイルに
置く (`.swift` ではないので対象外になる)。除くのは `frame-rate-probe` のディレクトリだけで、
これは ADR-0038 決定 1 が対象外と決めている (配布物に入らない)。

**対象が 0 件なら落とす。** 置き場を動かしたときに「見るものが無いので緑」へ倒れないため
(`scripts/check-publish-trigger.py` と同じ理由)。

字句で扱うもの: `//` と入れ子の `/* */`・`"` / `\"\"\"` と raw 文字列 (`#"…"#`)・エスケープ・
文字列補間 (`\\(…)` / `\\#(…)`) とその中の文字列。正規表現リテラルは扱わない
(`Sources/` に 1 つも無い。足した日に誤読すれば、上の理由で赤の側へ倒れる)。

使い方: python3 scripts/check-tool-language.py [ルート (既定 Sources)]
"""

import re
import sys
from pathlib import Path

JAPANESE = re.compile(r"[぀-ヿ㐀-䶿一-鿿豈-﫿ｦ-ﾟ]")
STRING_OPENING = re.compile(r'(#*)("""|")')
EXCLUDED_DIRECTORIES = {"frame-rate-probe"}


def blank_comments(text):
    """コメントを空白で塗りつぶした写しを返す。改行は残すので行番号は変わらない。"""
    out = list(text)

    def blank(start, end):
        for index in range(start, end):
            if out[index] != "\n":
                out[index] = " "

    # 積むのは ("code", 補間の括弧の深さ または None) と ("string", # の数, 複数行か)
    stack = [("code", None)]
    i, n = 0, len(text)
    while i < n:
        state = stack[-1]
        char = text[i]
        if state[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end == -1 else end
                blank(i, end)
                i = end
                continue
            if text.startswith("/*", i):
                depth, end = 0, i
                while end < n:
                    if text.startswith("/*", end):
                        depth += 1
                        end += 2
                    elif text.startswith("*/", end):
                        depth -= 1
                        end += 2
                        if depth == 0:
                            break
                    else:
                        end += 1
                blank(i, end)
                i = end
                continue
            opening = STRING_OPENING.match(text, i) if char in '#"' else None
            if opening:
                stack.append(("string", len(opening.group(1)), opening.group(2) == '"""'))
                i = opening.end()
                continue
            depth = state[1]
            if depth is not None and char == "(":
                stack[-1] = ("code", depth + 1)
            elif depth is not None and char == ")":
                if depth == 1:
                    stack.pop()
                else:
                    stack[-1] = ("code", depth - 1)
            i += 1
            continue

        _, hashes, multiline = state
        closing = ('"""' if multiline else '"') + "#" * hashes
        if char == "\\" and text.startswith("#" * hashes, i + 1):
            after = i + 1 + hashes
            if after < n and text[after] == "(":
                stack.append(("code", 1))
                i = after + 1
            else:
                i = after + 1  # エスケープした 1 文字を飛ばす (複数行の行継ぎの改行も含む)
            continue
        if text.startswith(closing, i):
            stack.pop()
            i += len(closing)
            continue
        if char == "\n" and not multiline:
            stack.pop()  # 閉じない 1 行の文字列はコンパイルが通らない。行で打ち切って読み続ける
        i += 1
    return "".join(out)


def findings(root):
    """(見た Swift の数, [(パス, 行番号, 行)])。"""
    files = sorted(
        path for path in root.rglob("*.swift")
        if not EXCLUDED_DIRECTORIES.intersection(path.relative_to(root).parts))
    found = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        original = text.splitlines()
        for number, line in enumerate(blank_comments(text).splitlines(), 1):
            if JAPANESE.search(line):
                found.append((path, number, original[number - 1].strip()))
    return len(files), found


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else "Sources")
    count, found = findings(root) if root.is_dir() else (0, [])
    if count == 0:
        print(f"tool-language: {root} の下に Swift のファイルが 1 つも無い"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    if not found:
        print(f"tool-language: {count} 個の Swift を見た。コメントの外に日本語は無い")
        return 0
    print(f"tool-language: コメントの外に日本語がある ({len(found)} 行)。"
          "道具が話す言葉は英語 (ADR-0038 決定 1・#1160)", file=sys.stderr)
    for path, number, line in found:
        print(f"  {path}:{number}: {line}", file=sys.stderr)
    print("次にすること: 利用者へ出す文言なら英語にする。`mokume new` が書き出す読み物なら"
          " Sources/MokumeCLI/Templates/ のファイルへ移す (.swift ではないので対象外)",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
