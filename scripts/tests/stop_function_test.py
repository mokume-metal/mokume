#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""止まるときに「次にすること」を名乗る関数の作法を見る (#864)。

`scripts/` には同じ形の停止関数が 3 本ある (`catch-up.sh` の `stop`・
`gh-app-token.sh` と `review-gate.sh` の `fail`)。**これは畳まない** — 割れても変わるのは
出力の文面だけで、しかも終了コードは呼び出し側の契約である
([ADR-0008](../../docs/decisions/0008-mechanism-needs-demonstrated-harm.md) 決定 6)。

**畳まないなら、割れても直せる形をここに置く。** 実際に割れていたのは「次にすることを
省いた呼び出し」の扱いだった — `catch-up.sh` は `[ $# -lt 2 ] ||` で守って 1 引数の
呼び出しを 6 箇所で使っているのに、他の 2 本は素の `$2` を読んでいたので、`set -u` の
下で理由の行の直後に bash のエラーが並んでいた:

    review-gate: 差し戻し — 理由だけを渡した
    bash: line 5: $2: unbound variable

読める理由を出すための関数が、読めない出力を出していた。

## 見方

**一覧は数え上げない。** `scripts/*.sh` を glob し、「次にすること」に位置パラメータを
渡している関数を拾う。4 本目が同じ形で足されたら、そこで自動的に対象になる。

**形ではなく振る舞いを見る。** 関数の本体を取り出して `/bin/bash` に食わせ、実際に
1 引数で呼ぶ。守り方 (`[ $# -lt 2 ]` でも `${2:-}` でも) を検査が指定しないため、
書く側は好きな形を選べる。**終了コードは見ない** — それは各 script の契約である。

`/bin/bash` を名指しするのは `bash_invocation_test.py` の要求 (macOS の PATH の `bash` は
版が環境で変わる)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"

# `name() {` — 行末のコメントは許す (`fail() { # $1=理由 …` が実在する)
OPENS = re.compile(r"^([a-z_][a-z0-9_]*)\(\)\s*\{\s*(#.*)?$")
# 「次にすること」に位置パラメータを渡している行。リテラルの案内文は対象外
TAKES_POSITIONAL = re.compile(r"次にすること: \$\{?[0-9]")

REASON = "理由だけを渡した"
NEXT = "次にすることも渡した"


def stop_functions():
    """(スクリプト名, 関数名, 本体) の一覧。"""
    found = []
    for path in sorted(SCRIPTS.glob("*.sh")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            opened = OPENS.match(line)
            if not opened:
                continue
            # 閉じるのは桁 0 の `}`。scripts/ の書き方はこれに揃っている
            end = next((j for j in range(index + 1, len(lines)) if lines[j] == "}"), None)
            if end is None:
                continue
            body = "\n".join(lines[index : end + 1])
            if TAKES_POSITIONAL.search(body):
                found.append((path.name, opened.group(1), body))
    return found


class StopFunctionTest(unittest.TestCase):
    def setUp(self):
        self.functions = stop_functions()
        # 0 件の緑は、通っていることに意味が無い (書式が変わって拾えなくなった状態を
        # 「全部作法どおり」と同じ緑で表さない)
        self.assertTrue(self.functions, f"停止関数を 1 つも拾えていない ({SCRIPTS})")

    def run_function(self, body, name, *arguments):
        script = f"set -euo pipefail\n{body}\n{name}" + "".join(
            f' "${i + 1}"' for i in range(len(arguments))
        )
        return subprocess.run(
            ["/bin/bash", "-c", script, "bash", *arguments],
            capture_output=True,
            text=True,
            # bash のエラー文は翻訳される。C に固定して英語で照合する
            env={**os.environ, "LC_ALL": "C"},
        )

    def test_次にすることを省いても_bash_のエラーを出さない(self):
        for script, name, body in self.functions:
            with self.subTest(script=script, function=name):
                result = self.run_function(body, name, REASON)
                self.assertIn(REASON, result.stderr)
                self.assertNotIn("unbound variable", result.stderr)
                # 空の案内 (「次にすること: 」だけの行) も出さない
                self.assertNotIn("次にすること", result.stderr)

    def test_次にすることを渡せば添える(self):
        """守りを足したせいで普段の経路が黙る、という壊れ方を排す。"""
        for script, name, body in self.functions:
            with self.subTest(script=script, function=name):
                result = self.run_function(body, name, REASON, NEXT)
                self.assertIn(REASON, result.stderr)
                self.assertIn(f"次にすること: {NEXT}", result.stderr)


if __name__ == "__main__":
    unittest.main()
