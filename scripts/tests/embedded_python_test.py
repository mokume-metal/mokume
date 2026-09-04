#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""shell の骨に Python の本体を埋めないことを見る (#817)。

**heredoc の中は誰も見ない。** shellcheck は shell として読まないし、Python の道具は
そこにコードがあることを知らない。#817 の時点で 4 つあり、合計 144 行が lint も
unittest も型検査も通らないまま置かれていた:

    check-observation-roundtrip.sh   60 行   要求を N 回置いて数える
    measure-frame-rate.sh            20 行   要求を置き続ける
    measure-frame-rate.sh            33 行   fps の判定 (純関数)
    check-reuse-encoding.sh          31 行   雛形の生成と自己検査

**とくに前 2 つは画面と GPU が要るので `make ci-check` に入っていない。** 手元で誰かが
打つときだけ動き、壊れていても誰も気付かなかった。`.py` へ出せば、偽の応答を相手に
GPU 無しで経路を通せる (`scripts/tests/observe_lib_test.py` がそうしている)。

## 線引き

**禁じるのは heredoc で流し込む「本体」だけ**で、`python3 -c '<1 式>'` は対象外である。
1 行に収まって目に見え、shellcheck が引用の対応も見る。いま該当するのは
`apply-rulesets.sh` の JSON から名前を 1 つ読む行で、これを `.py` へ出すと**呼び出しの
ほうが長くなる。**

境目は「複数行になるか」であって行数の閾値ではない — 閾値は必ず議論になるが、
「heredoc を開いたか」は綴りから機械的に決まる。

**一覧は数え上げない。** `scripts/*.sh` を glob するので、次に埋めた人がここを
直さなくても掛かる (`bash_invocation_test.py` が検査ファイル全体を glob して
`/bin/bash` を見張っているのと同じ構え)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"

# `python3 - … <<'PY'` の形。`-` は「本体は標準入力から」の意味で、heredoc がそれを
# 埋める。python / python3 / インタプリタへのパスのどれでも拾う
EMBEDDED = re.compile(r"\bpython3?\b[^|;&]*\s-\s[^|;&]*<<")


class EmbeddedPythonTest(unittest.TestCase):
    def scripts(self):
        found = sorted(SCRIPTS.glob("*.sh"))
        # 対象が 0 件の緑は、通っていることに意味が無い (置き場の移動を緑のまま
        # 見逃さないため。check-file-modes.sh と同じ構え)
        self.assertTrue(found, f"検査対象の *.sh が 1 つも無い ({SCRIPTS})")
        return found

    def test_no_script_feeds_python_a_here_document(self):
        found = []
        for path in self.scripts():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if EMBEDDED.search(line):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(
                "shell に Python の本体を埋めている箇所がある:\n"
                + "\n".join(found)
                + "\n\n直し方: scripts/<名前>.py へ出して引数で渡す。\n"
                "heredoc の中は shellcheck も Python の道具も見ないので、そこに置いた\n"
                "コードは lint も unittest も通らない (#817)。画面や GPU が要る手順なら\n"
                "なおさら — CI で一度も動かないまま壊れる。"
            )

    def test_a_one_line_expression_is_not_a_body(self):
        """線引きが逆向きに効いていないこと — `python3 -c '<1 式>'` は禁じない。"""
        self.assertIsNone(EMBEDDED.search("""name=$(python3 -c 'import json; print(1)' "$f")"""))
        self.assertIsNotNone(EMBEDDED.search("""python3 - "$WORK" <<'PY'"""))
        self.assertIsNotNone(EMBEDDED.search("""  python3 - "$a" "$b" <<'JUDGE' &"""))


if __name__ == "__main__":
    unittest.main()
