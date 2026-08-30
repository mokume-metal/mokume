#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""アンブレラが名指しで通した語彙が、面の入口にも同じだけ並んでいるかを見る (#569)。

`import mokume` の 1 行で通る語のうち、**アンブレラが名指しで再エクスポートしたもの**は
面に記号のページを持たない — 面へ渡しているのは実体のシンボルグラフで、標準ライブラリの
記号はそこに居ないためである。だから入口が文で述べるしかなく、**同じ一覧が 2 か所に書かれる**。

[ADR-0001](../../docs/decisions/0001-founding-principles.md) 原則 9 が禁じているのは
同じ内容の二重管理で、ここは形の上でそれに当たる。正典は `Sources/mokume/Umbrella.swift`
(コンパイラが読む側) で、入口の文はその写しである。**写しが古くなっても誰も落ちない** —
面は組み上がり、警告も出ず、読者だけが「使えるはずの語が書かれていない」面を読む。

材料が両方ともソースにあり突き合わせるだけなので、新しい機構は要らない。ここに置く。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UMBRELLA = REPO / "Sources" / "mokume" / "Umbrella.swift"
ENTRY = REPO / "Documentation" / "mokume.docc" / "mokume.md"

# `@_exported import func Darwin.sin` — 宣言単位で名指しした再エクスポート
NAMED = re.compile(r"^@_exported import (?:func|var|let|struct|enum|class|protocol|typealias) \S+\.(\w+)$", re.MULTILINE)
# 入口の文の中で名前を出す形は、記号のページを持たないので素のコード引用になる
QUOTED = re.compile(r"`(\w+)`")


class SurfaceVocabularyTest(unittest.TestCase):
    def test_名指しで通した語が入口にも並んでいる(self):
        named = set(NAMED.findall(UMBRELLA.read_text(encoding="utf-8")))
        self.assertTrue(named, "アンブレラに名指しの再エクスポートが 1 本も無い")
        quoted = set(QUOTED.findall(ENTRY.read_text(encoding="utf-8")))
        missing = sorted(named - quoted)
        self.assertEqual(
            missing,
            [],
            f"アンブレラが通しているのに面の入口に出ていない: {', '.join(missing)}"
            f" ({ENTRY.relative_to(REPO)} の「`import mokume` で通る語彙」へ足す)",
        )


if __name__ == "__main__":
    unittest.main()
