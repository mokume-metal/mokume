#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""検査がスクリプトを起動するとき、`/bin/bash` を名指ししているかを見る (#702)。

macOS の PATH の `bash` は環境によって版が違う。**CI (macos-latest) の PATH では
`/bin/bash` (3.2) が選ばれ**、手元では Homebrew の 5.x が選ばれることが多い。
PATH の `bash` で検査を走らせると、**3.2 でだけ壊れる書き方が手元で素通りし、
CI で初めて落ちる**。

[#160](https://github.com/mokume-metal/mokume/issues/160) はこれで踏んだ。
`pr-identity-guard.sh` が 3.2 のパースに失敗して JSON を返さず、PreToolUse
フックとしては**素通しと同じ**になっていた — ガードが黙って効かなくなる形である。
あの Issue が原因として挙げた 2 つのうち 1 つが「テストは PATH の `bash` を使う」で、
#162 の修正で当時あった検査は `/bin/bash` へ寄せられた。その後 #499 で足した
`worktree-path-guard` の検査だけが PATH の `bash` のまま残っていた。

**塞いでいるのは、次に検査を足した人が同じ穴を持つことである。** 手当てが行き渡って
いるかは、書いた人が覚えていることに依存させない。

## 見方

**正規表現ではなく AST で見る。** 素朴な文字列照合では、この検査自身が持つパターン
文字列に当たってしまい、自分を除外する羽目になる — 除外すると、将来ここが `bash` を
起動したときに見逃す。AST なら「リテラルの並びの先頭要素か」で構造的に区別できるので、
**自分自身も検査対象に含めたまま**書ける。

同じ理由で、スタブの中の `FAKE_GH = \"\"\"#!/bin/bash` (7 箇所) にも当たらない。
あれは文字列定数であって、並びの先頭ではない。

呼び出しの形 (`subprocess.run([...])`) には縛らない。変数へ組み立ててから渡す形
(`cmd = ["bash", …]`) も同じ穴なので、**並びのリテラルすべて**を見る。

## ここに置く理由

**新しい検査 (Makefile の的) は足さない。** `make hooks-test` が `-p '*_test.py'` で
discover するので、ここに 1 ファイル置けば CI にも載る。材料がソースにあり突き合わせる
だけで新しい機構が要らないのは `surface_vocabulary_test.py` と同じで、ADR-0008
決定 5 段 1 (既存の責務を広げる) に当たる。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import ast
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent

# 起動してよい bash。**版を固定できる綴りだけを通す。** PATH 解決に任せる "bash" は、
# どの版で走るかが環境で決まってしまう
ALLOWED = "/bin/bash"


def path_bash_lines(source: str) -> list[int]:
    """並びのリテラルの先頭要素が PATH の bash になっている行を返す。"""
    found = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, (ast.List, ast.Tuple)) or not node.elts:
            continue
        head = node.elts[0]
        if isinstance(head, ast.Constant) and head.value == "bash":
            found.append(head.lineno)
    return sorted(found)


class BashInvocationTest(unittest.TestCase):
    def test_tests_name_bin_bash(self):
        files = sorted(TESTS.glob("*.py"))
        # 対象が 0 件の緑は、通っていることに意味が無い (glob の書き間違い・置き場の
        # 移動を、緑のまま見逃さないため。check-file-modes.sh と同じ構え)
        self.assertTrue(files, f"検査対象の .py が 1 つも無い ({TESTS})")

        violations = []
        for f in files:
            for line in path_bash_lines(f.read_text(encoding="utf-8")):
                violations.append(f"  {f.name}:{line}")

        if violations:
            self.fail(
                "PATH の bash を起動している箇所がある:\n"
                + "\n".join(violations)
                + f'\n\n直し方: ["bash", …] → ["{ALLOWED}", …]\n'
                "CI (macos-latest) の PATH では /bin/bash (3.2) が選ばれ、手元では\n"
                "Homebrew の 5.x が選ばれることが多い。PATH に任せると、3.2 でだけ\n"
                "壊れる書き方が手元で素通りし、CI で初めて落ちる (#160・#702)。"
            )


if __name__ == "__main__":
    unittest.main()
