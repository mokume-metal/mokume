#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""本体の超越関数を `RuntimeMath` を通さずに直に呼んでいないかを見る (#2751)。

**塞ぐのは「足した本人にも、merge の前の検査にも壊れて見えない」形の再発である** (#1736)。
最適化 (`-O`) は、同じ角度の `sin` と `cos` の対を畳んだり、定数を渡した呼び出しを組むときに
計算したりして、release でだけ値を 1 ULP 動かす。そのため本体は超越関数を、1 関数ずつ
`@inline(never)` で包んだ `RuntimeMath` から呼ぶ (ADR-0025 決定 7)。ところがこの規律は
`RuntimeMath.swift` の冒頭と ADR の散文にしか無く、`sin(…)` を直に書き足しても、
debug の検査は緑のまま、release の台帳は専用機の定期の検査でしか回らず (merge queue の
`render` は debug だけ)、見本の場面の画素が動いたときにしか気付けない。

**だからここで、直の呼び出しを数える。** 組み上げは要らない — 字句だけを読む
(`scripts/check-isolated-deinit.py` と同じ形)。

## 見るもの

- 対象は `Sources/MokumeCore` と `Sources/MokumeAudio` の Swift。音の側も含めるのは、
  合成と解析の値が `sound.level` などを経て絵に出るから (#2750 の決定 B・#2752)。
  `RuntimeMath.swift` 自身は除く (中で Foundation の関数を呼ぶのが仕事)
- **範囲の外**: シェーダ (`.metal`) と、ほかの target (`MokumeCamera` など)。
  `.metal` は GPU の関数で `RuntimeMath` を通せず、ほかの target は #1736 の対象にしていない
- **包む関数の名前は `RuntimeMath.swift` の `static func` から読む。写しを持たない。**
  関数を足せば検査も追随する。1 つも読めなければ落とす (置き場や書き方を動かしたときに
  「見るものが無いので緑」へ倒れない)
- 数えるのは自由関数の呼び出し: `sin(x)`、`Foundation.sin(x)`、`Darwin.sin(x)`、`Glibc.sin(x)`
  (修飾しても `RuntimeMath` を通っていない)。数えないもの: メンバの呼び出し
  (`x.sin(…)`・`RuntimeMath.sin(…)`)・`.pi`・`func sin(` の宣言・コメントと文字列の中
  (`tan(fov/2)` や `"pow(x, 2)"`)。文字列補間 `"\\(sin(x))"` の中はコードなので数える

字句の読みは `scripts/check-tool-language.py` の `blank_comments` を取り込んで使う (写さない。
文字列の中身も塗る引数 `strings` を #2751 で足した)。**読み違えたときの向き**: 閉じない文字列や
正規表現リテラルを誤読すると、見逃す側にも誤検出の側にも倒れうる。`Sources/` に正規表現
リテラルは無い。足した日に誤読して赤くなれば、目に見える側である。

**見るのは作業ツリーで、git の木ではない** (#2016)。無視されたファイル (手元の書き捨て)
も読むので、手元だけ赤になりうる。CI の木 (`git add -A` した木) は作業ツリーの部分集合
なので、逆向き (手元で緑・CI で赤) にはならない。害がうるさい側だけなので、列挙を
CI の木に揃えない。

使い方: python3 scripts/check-runtime-math.py [Sources のルート (既定 Sources)]
"""

import importlib.util
import re
import sys
from pathlib import Path

TARGETS = ("MokumeCore", "MokumeAudio")
# 検査する Sources のルートからの相対。正本であり、検査の対象からも外す
CANON = "MokumeCore/Math/RuntimeMath.swift"
CANON_FROM_REPO = "Sources/" + CANON

WRAPPED = re.compile(r"\bstatic\s+func\s+(\w+)\s*\(")
QUALIFIERS = "Foundation|Darwin|Glibc"


def _blank_comments():
    """check-tool-language.py の字句の読みを取り込む (ファイル名にハイフンがあるので importlib)。"""
    path = Path(__file__).resolve().parent / "check-tool-language.py"
    spec = importlib.util.spec_from_file_location("check_tool_language", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.blank_comments


blank_comments = _blank_comments()


def wrapped_names(canon):
    """RuntimeMath.swift が包んでいる関数の名前。読み取れなければ空。"""
    text = blank_comments(canon.read_text(encoding="utf-8"), strings=True)
    return sorted(set(WRAPPED.findall(text)))


def call_pattern(names):
    """直の呼び出し。前が `.` や識別子の文字ならメンバ・別の名前なので当たらない。"""
    alternatives = "|".join(re.escape(name) for name in names)
    # `func sin(` の宣言は呼び出しではない。先に宣言を食べて、名前の側を当てさせない
    return re.compile(
        rf"(?<![\w.])(?P<declaration>func\s+)?(?:(?:{QUALIFIERS})\.)?(?P<name>{alternatives})\s*\(")


def findings(root, names):
    """(見た Swift の数, [(パス, 行番号, 名前, 行)])。"""
    canon = root / CANON
    pattern = call_pattern(names)
    files = sorted(
        path for target in TARGETS if (root / target).is_dir()
        for path in (root / target).rglob("*.swift")
        if path != canon)
    found = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        original = text.splitlines()
        blanked = blank_comments(text, strings=True)
        for match in pattern.finditer(blanked):
            if match.group("declaration"):
                continue
            number = blanked.count("\n", 0, match.start()) + 1
            found.append((path, number, match.group("name"), original[number - 1].strip()))
    return len(files), found


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else "Sources")
    canon = root / CANON
    if not canon.is_file():
        print(f"runtime-math: {canon} が無い — 包む関数の名前の正本を読めないまま緑にはしない",
              file=sys.stderr)
        return 1
    names = wrapped_names(canon)
    if not names:
        print(f"runtime-math: {canon} から包む関数 (static func) を 1 つも読めなかった"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    count, found = findings(root, names)
    if count == 0:
        print(f"runtime-math: {root} の {' / '.join(TARGETS)} の下に Swift のファイルが 1 つも無い"
              " — 見るものが無いまま緑にはしない", file=sys.stderr)
        return 1
    if not found:
        print(f"runtime-math: {count} 個の Swift を見た。"
              f"RuntimeMath が包む {len(names)} 個の関数 ({', '.join(names)}) の直の呼び出しは無い")
        return 0
    print(f"runtime-math: RuntimeMath を通さない超越関数の呼び出しがある ({len(found)} 箇所)。"
          "最適化で値が 1 ULP 動き、release でだけ絵がずれる (#1736)", file=sys.stderr)
    for path, number, name, line in found:
        print(f"  {path}:{number}: `RuntimeMath.{name}` を使う (#1736・ADR-0025 決定 7): {line}",
              file=sys.stderr)
    first = found[0][2]
    print(f"次にすること: `{first}(…)` を `RuntimeMath.{first}(…)` に置き換える。"
          f"理由の正典は {CANON_FROM_REPO} の冒頭が持つ", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
