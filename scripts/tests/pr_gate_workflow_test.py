#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/pr-gate.yml` の、PR の作法の必須チェックの形の検査 (#2611・#2668)。

pr-gate は PR の作法 (タイトル・マージ判定・描画の絵) を、コードの検査の ci-gate と別の
必須チェックにまとめる。**どれも `if:` や 1 行の綴りが崩れると、run は緑のまま保証が外れる。**
ここで固定するのは次の 8 つ:

  1. 起動は pull_request (ready_for_review を含む)・pull_request_review・merge_group だけ。
     pull_request_target / workflow_dispatch / push を持たない
  2. pr-gate は merge_group でだけ skipped になる — merge_group で報告が無いと queue が期限まで
     待ち、PR の出来事 (Draft を含む) で skipped になると判定せずに必須を満たす。Draft を
     skipped にすると、ready の直後の数秒に判定していない skipped が最新として残る
  3. pr-gate は必須チェックに載っている (main-protection.json)
  4. 判定のスクリプトは既定ブランチの版で走らせる — PR の木 (head / merge ref / base) を
     checkout すると、同じ PR の中で自分を裁く検査を書き換えて通れる (#2001)
  5. 権限は読むだけ (contents / issues / pull-requests の read)。秘密を持たない
  6. ペイロードの可変な欄 (title / body / labels) を読まない — rerun が古い値を再生しない (#699)
  7. 3 つの判定はどの起動でも走り、前が赤でも後ろが走る。continue-on-error で赤を化かさない
  8. タイトルの照合は API で読んだタイトルに当たり、Conventional Commits の type だけを通す。
     落ちたときの文面は、直せば付け直されると言い、新しいコミット (空コミット) を案内しない —
     作法の検査が ci.yml の ci-gate から外れた (#2669) ので、古い赤を外す手は要らない

PR と queue で実際に結論が返ることは、使い捨ての Draft PR で確かめる (#2668 の PR 本文)。
ワークフローの読み手 (split / condition) は render_workflow_test.py のものを使う (写しを持たない)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
GATE = REPO / ".github" / "workflows" / "pr-gate.yml"
RULESET = REPO / ".github" / "rulesets" / "main-protection.json"

CHECKS = ("pr-title (Conventional Commits)", "review-gate", "drawing-evidence")


def steps(body):
    """ジョブの steps を、step ごとの本文 (先頭の `- ` を外したもの) の並びで返す。"""
    found, current = [], None
    in_steps = False
    for ln in body.splitlines():
        if re.match(r"^    steps:\s*$", ln):
            in_steps = True
            continue
        if not in_steps:
            continue
        if re.match(r"^    \S", ln):
            break
        m = re.match(r"^      - (.*)$", ln)
        if m:
            current = [m.group(1)]
            found.append(current)
        elif current is not None:
            current.append(ln)
    return ["\n".join(s) for s in found]


def step_named(body, name):
    for s in steps(body):
        if re.search(rf"(?m)^(name: |\s+name: ){re.escape(name)}\s*$", s):
            return s
    raise KeyError(name)


def run_block(step):
    """step の `run: |` の中身 (字下げを外したもの)。"""
    m = re.search(r"(?ms)^        run: \|\n(.*)", step)
    if not m:
        raise ValueError("run: | が無い")
    return textwrap.dedent(m.group(1))


class PrGateWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = GATE.read_text(encoding="utf-8")
        cls.top, cls.jobs = workflow.split(cls.text)
        cls.gate = cls.jobs["pr-gate"]

    def test_起動は_PR_とレビューと_merge_group_だけ(self):
        triggers = set(re.findall(r"^  ([a-z_]+):", self.top["on"], re.M))
        self.assertEqual(triggers, {"pull_request", "pull_request_review", "merge_group"})
        types = re.search(r"(?m)^    types: \[(.*)\]\s*$", self.top["on"]).group(1)
        self.assertEqual(
            {t.strip() for t in types.split(",")},
            {"opened", "edited", "synchronize", "reopened", "labeled", "unlabeled", "ready_for_review"},
        )

    def test_merge_group_でだけ_skipped_になる(self):
        self.assertEqual(workflow.condition(self.gate), "github.event_name != 'merge_group'")

    def test_必須チェックに載っている(self):
        rules = json.loads(RULESET.read_text(encoding="utf-8"))["rules"]
        required = next(r for r in rules if r["type"] == "required_status_checks")
        contexts = {c["context"] for c in required["parameters"]["required_status_checks"]}
        self.assertIn("pr-gate", contexts)
        # ci-gate はコードの検査の必須として残る (#2669 で外したのは作法の検査だけ)
        self.assertIn("ci-gate", contexts)

    def test_判定は既定ブランチの版で走らせる(self):
        checkouts = [s for s in steps(self.gate) if s.startswith("uses: actions/checkout@")]
        self.assertEqual(len(checkouts), 1)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", checkouts[0])
        self.assertEqual(steps(self.gate)[0], checkouts[0], "checkout より前に何かを走らせている")
        for bad in ("pull_request.head", "pull_request.base", "github.sha", "github.head_ref", "github.ref }}"):
            self.assertNotIn(bad, self.gate, bad)

    def test_権限は読むだけで秘密を持たない(self):
        self.assertRegex(self.top["permissions"], r"^\s*contents:\s*read\s*$")
        perms = re.search(r"(?ms)^    permissions:\n((?:      .*\n)+)", self.gate + "\n").group(1)
        granted = dict(re.findall(r"(?m)^      ([a-z-]+):\s*(\w+)", perms))
        self.assertEqual(granted, {"contents": "read", "issues": "read", "pull-requests": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotIn("pull_request_target", self.top["on"])

    def test_ペイロードの可変な欄を読まない(self):
        body = "\n".join(ln for ln in self.text.splitlines() if not ln.lstrip().startswith("#"))
        for field in ("title", "body", "labels"):
            self.assertNotIn(f"github.event.pull_request.{field}", body, field)

    def test_3_つの判定はどの起動でも走り_前が赤でも後ろが走る(self):
        names = [m for s in steps(self.gate) for m in re.findall(r"(?m)^\s*name: (.+?)\s*$", s)]
        self.assertEqual(names, list(CHECKS))
        self.assertNotIn("continue-on-error", self.gate)
        for name in CHECKS[1:]:
            self.assertRegex(step_named(self.gate, name), r"(?m)^        if: \$\{\{ !cancelled\(\) \}\}$", name)
        # 判定の step は起動の種類で絞らない (1 つの check に束ねるので、絞った起動の緑が
        # ほかの赤を隠す)
        for name in CHECKS:
            self.assertNotIn("event_name", step_named(self.gate, name), name)
        self.assertIn("bash scripts/review-gate.sh", step_named(self.gate, "review-gate"))
        self.assertIn("bash scripts/check-drawing-evidence.sh", step_named(self.gate, "drawing-evidence"))

    def test_古い_run_を止める(self):
        self.assertIn("group: pr-gate-${{ github.ref }}", self.top["concurrency"])
        self.assertRegex(self.top["concurrency"], r"(?m)^  cancel-in-progress: true\s*$")


class TitleCheckTest(unittest.TestCase):
    """タイトルの照合の step を、API の代わりの gh を置いて実際に走らせる。"""

    @classmethod
    def setUpClass(cls):
        _, jobs = workflow.split(GATE.read_text(encoding="utf-8"))
        cls.script = run_block(step_named(jobs["pr-gate"], CHECKS[0]))

    def check(self, title):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "gh"
            # 引数を記録し、API の返すタイトルを出す
            fake.write_text('#!/bin/bash\necho "$*" >"$FAKE_LOG"\nprintf "%s\\n" "$FAKE_TITLE"\n')
            fake.chmod(0o755)
            log = Path(tmp) / "log"
            env = dict(
                os.environ,
                PATH=f"{tmp}:{os.environ['PATH']}",
                FAKE_TITLE=title,
                FAKE_LOG=str(log),
                GITHUB_REPOSITORY="owner/repo",
                PR_NUMBER="42",
            )
            r = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", self.script],
                env=env,
                capture_output=True,
                text=True,
            )
            return r, log.read_text() if log.exists() else ""

    def test_API_で読んだタイトルを照合する(self):
        r, log = self.check("ci: pr-gate を足す")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("repos/owner/repo/pulls/42", log)

    def test_type_と_scope_と_破壊的変更の印を通す(self):
        for title in ("feat(audio): 入力を足す", "fix!: 戻す", "build(deps)!: 上げる", "perf: 速くする"):
            with self.subTest(title=title):
                r, _ = self.check(title)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_誤ったタイトルを落とす(self):
        for title in ("Initial commit", "design: 方針", "feat:要約に空白が無い", "feat(): 空の scope", "style: 整形", "ci:"):
            with self.subTest(title=title):
                r, _ = self.check(title)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("Conventional Commits ではない", r.stderr)

    def test_落ちた文面は付け直されると言い_新しいコミットを案内しない(self):
        r, _ = self.check("Initial commit")
        self.assertEqual(r.returncode, 1, r.stdout)
        squash = lambda t: re.sub(r"\s+", "", t)  # noqa: E731
        self.assertIn(squash("pr-gate はその run で付け直される (打ち直しも新しいコミットも要らない)"), squash(r.stderr))
        for gone in ("空コミット", "ci-gate", "新しいコミットを push"):
            self.assertNotIn(gone, r.stderr, gone)


class StepsReaderTest(unittest.TestCase):
    """読み手そのものの検査 — 壊れた読み手は、上の検査を黙って緑にする。"""

    def test_step_を切り_次のキーで止まる(self):
        body = (
            "    runs-on: x\n    steps:\n      - uses: a@v1\n        with:\n          ref: r\n"
            "      - name: b\n        run: |\n          echo b\n    outputs:\n      - name: c\n"
        )
        got = steps(body)
        self.assertEqual(len(got), 2)
        self.assertTrue(got[0].startswith("uses: a@v1"))
        self.assertEqual(run_block(step_named(body, "b")).strip(), "echo b")


if __name__ == "__main__":
    unittest.main()
