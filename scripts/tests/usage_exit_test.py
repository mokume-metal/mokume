#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""CLI の usage が同じ終了コードで返ることを見る (#820)。

使い方を間違えたときの終了コードが **64 と 2 に割れていた**。打つ人には見えないが、
呼ぶ側 (Makefile・別の script・CI) が「使い方の誤りだったのか、判定が落ちたのか」を
区別できない。

## なぜ 64 か

`sysexits.h` の `EX_USAGE` である。2 でも間違いではないが、**このリポジトリには
2 を別の意味で使う場所が既にある** — Claude Code のフックは 2 で差し戻しを表すので
(`plan-record.sh` の `capture` / `guard` がそれ)、CLI の usage も 2 にすると
「差し戻し」と「使い方の誤り」が同じ数字になる。

## 見ているもの

**usage を出して終わる口だけ。** 引数を間違えたときに使い方を出す script を実際に
起動して、64 で返ることを確かめる。判定が落ちたときの 1 や、フックの差し戻しの 2 は
対象外である (その線をここに書いておく)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"

# usage を出して終わる口と、それを引き出す引数。
#
# **フックの口 (capture / guard) は入れない** — あちらは stdin を待ち、差し戻しを 2 で
# 表す。usage の誤りとは別の話である
CLI_USAGE = {
    "render-status.sh": ["no-such-mode"],
    "check-rulesets.sh": ["--no-such-flag"],
    "apply-rulesets.sh": ["--no-such-flag"],
    "sub-issue.sh": ["1", "題", "--no-such-flag"],
    "comment.sh": ["no-such-kind"],
    "plan-record.sh": ["no-such-mode"],
}

EX_USAGE = 64


class UsageExitTest(unittest.TestCase):
    def run_script(self, name, argv):
        # 認証も gh も要らないところで落ちてほしいので、PATH は素のまま。
        # usage の判定は引数の解析だけで決まる。
        #
        # **黙らせの env は立てない。** `MOKUME_PLAN_RECORD=0` を立てると
        # `plan-record.sh` は引数を見る前に 0 で抜けるので、usage の口へ届かない
        # (最初にこの検査を書いたとき、まさにそれで空回りしていた)
        env = dict(os.environ)
        env.pop("MOKUME_PLAN_RECORD", None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPTS / name), *argv],
            capture_output=True,
            text=True,
            input="",
            cwd=REPO,
            env=env,
        )

    def test_every_cli_uses_the_conventional_code(self):
        for name, argv in CLI_USAGE.items():
            with self.subTest(script=name):
                proc = self.run_script(name, argv)
                self.assertEqual(
                    proc.returncode,
                    EX_USAGE,
                    f"{name} の usage が {proc.returncode} で返った "
                    f"(64 = sysexits の EX_USAGE に揃える)\n{proc.stderr}",
                )

    def test_the_usage_says_how_to_call_it(self):
        """**終了コードだけ揃えても意味が無い。** 使い方が出ていること。"""
        for name, argv in CLI_USAGE.items():
            with self.subTest(script=name):
                proc = self.run_script(name, argv)
                text = proc.stderr + proc.stdout
                self.assertRegex(text, r"使い方|usage", f"{name} が使い方を出していない")

    def test_the_hook_block_code_is_not_confused_with_usage(self):
        """フックの差し戻しは 2 のままである (Claude Code 側の要求)。

        ここを 64 に揃えてはいけない — 揃えると差し戻しが効かなくなる。**この検査は
        「揃えない」ことの記録**でもある。
        """
        text = (SCRIPTS / "plan-record.sh").read_text(encoding="utf-8")
        self.assertIn("exit 2", text, "差し戻しの 2 が消えている")


if __name__ == "__main__":
    unittest.main()
