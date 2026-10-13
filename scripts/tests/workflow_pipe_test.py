#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""検査の結論をパイプの `tee` に飲ませない検査 (#2609)。

`run:` は `shell:` を書かないと `bash -e {0}` で走り、pipefail が無い。検査の出力を
`| tee` に渡すと、パイプの結論は最後の `tee` の 0 になり、検査が落ちても step が緑になる。
#2609 では専用機の `scheduled-release` がこの形で、`make` が `Error 2` で終わった回も job は
success、`scheduled-report` は skipped で、赤が誰にも届かなかった (直近 10 回のうち 2 回)。

ここで固定するのは、`.github/workflows/` のすべての step について、`run:` が `| tee` に
出力を渡すなら、結論を受け直す手立てがその step にあること:

  - `shell: bash` (`bash --noprofile --norc -eo pipefail {0}` で走る)。job か workflow の
    `defaults.run.shell: bash` でもよい
  - 本文の `set -o pipefail`
  - 本文の `PIPESTATUS` (publication.yml・ruleset-drift.yml のように `set +e` で受けて、
    後の step で落とす形)

対象を `tee` に絞るのは、`printf … | grep -q` のように最後の段の結論がそのまま意図である
パイプまで一律に赤くしないためである。ワークフローの読み手 (split) は render_workflow_test.py
のものを使う (写しを持たない)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"

TEE = re.compile(r"\|\s*tee\b")
SHELL_BASH = re.compile(r"(?m)^\s*(?:- )?shell:\s*bash\s*$")


def steps(job):
    """ジョブの本文を step ごとに切る (`steps:` の下の 6 字下げの `- `)。"""
    out, cur = [], None
    for ln in job.splitlines():
        if re.match(r"^      - ", ln):
            cur = [ln]
            out.append(cur)
        elif cur is not None and (ln.startswith("        ") or not ln.strip()):
            cur.append(ln)
        else:
            cur = None
    return ["\n".join(s) for s in out]


def defaults_bash(body):
    """`defaults:` の塊に `shell: bash` があるか (workflow かジョブの本文を渡す)。"""
    m = re.search(r"(?ms)^(\s*)defaults:\s*$(.*?)(?=^\1\S|\Z)", body)
    return bool(m and SHELL_BASH.search(m.group(2)))


def swallowing(text):
    """`| tee` に出力を渡しながら結論を受け直す手立てが無い step の (ジョブ名, 本文) の並び。"""
    top, jobs = workflow.split(text)
    if defaults_bash("defaults:\n" + top.get("defaults", "")):
        return []
    found = []
    for name, job in jobs.items():
        if defaults_bash(job):
            continue
        for step in steps(job):
            if not TEE.search(step):
                continue
            if SHELL_BASH.search(step) or "pipefail" in step or "PIPESTATUS" in step:
                continue
            found.append((name, step))
    return found


# #2609 の形そのもの。読み手が赤を拾えることを、いまの workflow とは独立に確かめる
BROKEN = """\
on: schedule
jobs:
  scheduled-release:
    runs-on: [self-hosted, mokume-render]
    steps:
      - uses: actions/checkout@v7
      - run: |
          mkdir -p .build
          make test-release-scheduled CI= 2>&1 | tee .build/test-log.txt
      - name: 落ちた検査の文面を要約へ書く
        if: failure()
        run: echo summary
"""


class WorkflowPipeTest(unittest.TestCase):
    def test_tee_に結論を飲ませる_step_が無い(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                found = swallowing(path.read_text(encoding="utf-8"))
                self.assertEqual(
                    [name for name, _ in found],
                    [],
                    f"{path.name}: `| tee` に出力を渡す step に pipefail が無い — `shell: bash` を書く (#2609)",
                )

    def test_読み手は_2609_の形を拾う(self):
        found = swallowing(BROKEN)
        self.assertEqual([name for name, _ in found], ["scheduled-release"])
        self.assertIn("make test-release-scheduled", found[0][1])

    def test_shell_bash_を書けば通る(self):
        fixed = BROKEN.replace("      - run: |\n          mkdir", "      - shell: bash\n        run: |\n          mkdir")
        self.assertEqual(swallowing(fixed), [])

    def test_shell_bash_が_run_の後ろでも通る(self):
        fixed = BROKEN.replace(
            "make test-release-scheduled CI= 2>&1 | tee .build/test-log.txt\n",
            "make test-release-scheduled CI= 2>&1 | tee .build/test-log.txt\n        shell: bash\n",
        )
        self.assertEqual(swallowing(fixed), [])

    def test_PIPESTATUS_で受け直せば通る(self):
        fixed = BROKEN.replace(
            "| tee .build/test-log.txt\n",
            "| tee .build/test-log.txt\n          status=${PIPESTATUS[0]}\n",
        )
        self.assertEqual(swallowing(fixed), [])

    def test_ジョブの_defaults_で_bash_にしても通る(self):
        fixed = BROKEN.replace(
            "    runs-on: [self-hosted, mokume-render]\n",
            "    runs-on: [self-hosted, mokume-render]\n    defaults:\n      run:\n        shell: bash\n",
        )
        self.assertEqual(swallowing(fixed), [])

    def test_別の_step_の_shell_bash_では通らない(self):
        # 後ろの step にだけ shell: bash があっても、tee の step の結論は飲まれたまま
        other = BROKEN.replace("        if: failure()\n", "        if: failure()\n        shell: bash\n")
        self.assertEqual([name for name, _ in swallowing(other)], ["scheduled-release"])

    def test_コメントの中の_tee_は数えない(self):
        commented = BROKEN.replace(
            "          make test-release-scheduled CI= 2>&1 | tee .build/test-log.txt\n",
            "          # 2>&1 | tee を使わない\n          make test-release-scheduled CI=\n",
        )
        self.assertEqual(swallowing(commented), [])


if __name__ == "__main__":
    unittest.main()
