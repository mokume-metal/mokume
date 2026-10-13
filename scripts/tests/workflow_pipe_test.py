#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""すべての workflow が `run:` を pipefail 付きの bash で走らせる検査 (#2609)。

`run:` は `shell:` を書かないと `bash -e {0}` で走り、pipefail が無い。検査の出力をパイプに
渡すと、パイプの結論は最後の段 (`tee` など) のものになり、検査が落ちても step が緑になる。
#2609 では専用機の `scheduled-release` が `make test-release-scheduled … | tee` の形で、`make` が
`Error 2` で終わった回も job は success、`scheduled-report` は skipped で、赤が誰にも届かなかった
(直近 10 回のうち 2 回)。

塞ぐ場所を step ではなく workflow の既定に置くのは、穴が `| tee` の 1 か所ではなく「既定の
シェルに pipefail が無い」ことにあるからである。step ごとに `shell: bash` を求める形だと、
`| xcbeautify`・`|& tee`・`| head` を足した step を形で拾いきれない (#2609 の反証)。
`defaults.run.shell: bash` は `bash --noprofile --norc -eo pipefail {0}` で走る。

ここで固定するのは 2 つ:

  1. `.github/workflows/` のすべての workflow が、トップの `defaults.run.shell: bash` を持つ
  2. job や step が `shell:` を bash 以外へ上書きしない — 上書きした所だけ pipefail が外れる

結論を受け直したいパイプは、`set +e` と `PIPESTATUS` で受けて後の step で落とす
(publication.yml・ruleset-drift.yml の形)。ワークフローの読み手 (split) は
render_workflow_test.py のものを使う (写しを持たない)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"


def problems(text):
    """pipefail が外れる理由の並び (空なら守られている)。"""
    top, _ = workflow.split(text)
    found = []
    if not re.search(r"(?m)^  run:\s*\n    shell:\s*bash\s*$", top.get("defaults", "")):
        found.append("トップに defaults.run.shell: bash が無い")
    body = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    for m in re.finditer(r"(?m)^\s*(?:- )?shell:\s*(.*?)\s*$", body):
        if m.group(1) != "bash":
            found.append(f"shell: {m.group(1)} で上書きしている")
    return found


GOOD = """\
on: schedule
defaults:
  run:
    shell: bash
jobs:
  scheduled-release:
    runs-on: [self-hosted, mokume-render]
    steps:
      - run: |
          make test-release-scheduled CI= 2>&1 | tee .build/test-log.txt
"""


class WorkflowPipeTest(unittest.TestCase):
    def test_すべての_workflow_が_pipefail_付きの_bash_で走る(self):
        paths = sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])
        # 読む先を取り違えて 1 本も見ないまま緑にならないように
        self.assertGreater(len(paths), 0)
        for path in paths:
            with self.subTest(workflow=path.name):
                self.assertEqual(problems(path.read_text(encoding="utf-8")), [])

    def test_既定がある形は通る(self):
        self.assertEqual(problems(GOOD), [])

    def test_既定が無ければ赤(self):
        # #2609 の形そのもの (既定なしで | tee に渡す)
        broken = GOOD.replace("defaults:\n  run:\n    shell: bash\n", "")
        self.assertEqual(problems(broken), ["トップに defaults.run.shell: bash が無い"])

    def test_既定がコメントだけなら赤(self):
        commented = GOOD.replace("defaults:\n  run:\n    shell: bash\n", "# defaults:\n#   run:\n#     shell: bash\n")
        self.assertEqual(problems(commented), ["トップに defaults.run.shell: bash が無い"])

    def test_既定が_bash_以外なら赤(self):
        self.assertEqual(problems(GOOD.replace("    shell: bash\n", "    shell: sh\n")), [
            "トップに defaults.run.shell: bash が無い",
            "shell: sh で上書きしている",
        ])

    def test_step_で_bash_以外へ上書きすれば赤(self):
        override = GOOD.replace("      - run: |\n", "      - shell: sh -e {0}\n        run: |\n")
        self.assertEqual(problems(override), ["shell: sh -e {0} で上書きしている"])

    def test_job_の_defaults_で_bash_以外へ上書きすれば赤(self):
        override = GOOD.replace(
            "    runs-on: [self-hosted, mokume-render]\n",
            "    runs-on: [self-hosted, mokume-render]\n    defaults:\n      run:\n        shell: sh\n",
        )
        self.assertEqual(problems(override), ["shell: sh で上書きしている"])

    def test_step_で_bash_を書き直すのは通る(self):
        again = GOOD.replace("      - run: |\n", "      - shell: bash\n        run: |\n")
        self.assertEqual(problems(again), [])


if __name__ == "__main__":
    unittest.main()
