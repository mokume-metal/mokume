#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""SwiftPM を通さずに型検査するときの、`swiftc` の呼び方 (#820)。

同じ呼び方が 2 実装あった。**しかも片方だけが macro の plugin 名を動的に解いていた:**

    check-examples.py            置き場の `*-tool` を glob して名前を導く
    check-param-declarations.sh  `MokumeMacros-tool` と `#MokumeMacros` を直書き

macro の的を改名すると `examples` は追随し、**`params` だけが落ちる** — しかも
落ち方は `external macro implementation … could not be found` で、改名が原因だとは
読めない。

## 旗はここが正典

`-swift-version 6 -default-isolation MainActor` は `Package.swift` の
`SwiftSetting.mokume` と揃える。SwiftPM を通さないので写しになるが、食い違えば
「本体では通るのに例だけ落ちる」で気付く (逆は起きない)。

**利用者のパッケージと同じ言語設定で見る**のが要点で、揃っていないと利用者の手元では
出ない食い違いを検査が拾ってしまう。

使い方:
  import (Python から)      from swift_typecheck import typecheck
  口 (shell から)           python3 scripts/swift_typecheck.py <ソース> <モジュール置き場>
                            → error を 1 行 1 件で stdout へ。落ちたら非 0

テストは scripts/tests/swift_typecheck_test.py。
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

# Package.swift の SwiftSetting.mokume と揃える (上の「旗はここが正典」)
SWIFT_FLAGS = ["-swift-version", "6", "-default-isolation", "MainActor"]


def plugin_flags(modules: pathlib.Path) -> list[str]:
    """macro を使う例のために、組み上がった plugin を渡す。

    **名前は決め打ちしない。** SwiftPM は macro の的を `<的の名前>-tool` という実行
    ファイルにするので、置き場を見て拾う — Package.swift の写しを持たない (原則 9)。
    渡さないと、macro を使う例は `external macro implementation … could not be found`
    で落ちる。SwiftPM を通さずに型検査する代償で、ここだけは手で繋ぐ必要がある。
    """
    flags: list[str] = []
    for path in sorted(modules.parent.glob("*-tool")):
        if path.is_file() and os.access(path, os.X_OK):
            flags += ["-load-plugin-executable", f"{path}#{path.name.removesuffix('-tool')}"]
    return flags


def command(source: pathlib.Path, modules: pathlib.Path) -> list[str]:
    """組み立てた `swiftc` の呼び出し。**呼び方の正典はこの 1 本。**"""
    return [
        "swiftc",
        "-typecheck",
        *SWIFT_FLAGS,
        *plugin_flags(modules),
        "-I",
        str(modules),
        str(source),
    ]


def typecheck(source: pathlib.Path, modules: pathlib.Path) -> list[tuple[int, str]]:
    """`(行, 言い分)` の並び。**error だけを拾う。**"""
    result = subprocess.run(command(source, modules), capture_output=True, text=True)
    reported = re.compile(rf"^{re.escape(str(source))}:(\d+):\d+: error: (.*)$")
    found = [
        (int(match[1]), match[2])
        for line in result.stderr.splitlines()
        if (match := reported.match(line))
    ]
    if not found and result.returncode != 0:
        # 型検査が例のせいでなく落ちた (成果物が無い・道具が壊れている)。黙って
        # 緑にしないよう、そのまま見せる
        raise SystemExit(f"swiftc が落ちた:\n{result.stderr.strip()}")
    return found


def main(argv: list[str]) -> int:
    """shell から使う口。**error を出して、あったら非 0。**

    `check-param-declarations.sh` が pass / fail の期待と語の照合を自分で持つので、
    ここは診断をそのまま渡すだけにする。
    """
    if len(argv) != 3:
        print(f"usage: {pathlib.Path(argv[0]).name} <ソース> <モジュール置き場>", file=sys.stderr)
        return 64
    source, modules = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    found = typecheck(source, modules)
    for line, message in found:
        print(f"{source}:{line}: error: {message}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
