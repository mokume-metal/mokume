#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/release.yml` の、版を出す前の関門の形の検査 (#2662)。

release でだけ出る赤は merge の前には止めない (merge queue から外した)。代わりに、版は
**下限 OS の release の検査 (`release-check`) が緑の SHA にだけ**打つ。ここで固定するのは:

  1. release は release-check を needs に持ち、自分の `if:` を持たない — needs の暗黙の
     success() で、release-check が赤・切れた・走らなかった回には版を出さない。release に
     `always()` などを書くと、赤のまま版が出る。release-check に `continue-on-error` を足しても
     同じ (赤が success に化ける)
  2. release-check は macos-26 (ADR-0009 の下限) で `make test-release` を走らせ、
     出すものが無い日も走る (版の判定より前に置く) — ホストの日次の検査を兼ねる。
     起動の可否 (release:now の PR だけ) は release-check の `if:` が持つ
  3. タグは release-check が検査した SHA に打ち、版にする HEAD と食い違えば打たない
  4. `issues: write` を持つのは起票のジョブ (release-check-report) だけで、release-check が
     落ちた (`failure`) か切れた (`cancelled`) ときだけ走る。`if:` は状態の関数を持つ —
     無ければ暗黙の success() で、赤の回に skipped になる
  5. release-check はテストのターゲットを WMO せずに組む (`MOKUME_TESTS_WITHOUT_WMO`・#2596。
     理由は Package.swift の mokumeTests)

ワークフローの読み手は render_workflow_test.py のものを使う。実行は make hooks-test。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
RELEASE = REPO / ".github" / "workflows" / "release.yml"


class ReleaseWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.jobs = workflow.split(RELEASE.read_text(encoding="utf-8"))

    def test_release_は_release_check_の緑を待ち_自分の_if_を持たない(self):
        release = self.jobs["release"]
        self.assertEqual(workflow.needs(release), {"release-check"})
        self.assertEqual(workflow.condition(release), "")

    def test_release_check_は下限_OS_で_make_test_release_を走らせる(self):
        check = self.jobs["release-check"]
        self.assertRegex(check, r"(?m)^    runs-on: macos-26\s*$")
        self.assertIn("make test-release", check)
        self.assertEqual(workflow.needs(check), set())
        # 版の判定 (release.py) より前に置く — 出すものが無い日も走る
        self.assertNotIn("release.py", check)

    def test_release_check_はテストを_WMO_せずに組む(self):
        # 外すと MokumeCoreTests の WMO が逐次に走り、ビルドが倍近く延びる (#2596)
        self.assertRegex(
            self.jobs["release-check"], r'(?m)^\s+MOKUME_TESTS_WITHOUT_WMO: "1"\s*$')

    def test_release_check_の赤を緑に化かさない(self):
        # continue-on-error があると、検査が赤でも release-check が success になり、版が出る
        self.assertNotIn("continue-on-error", self.jobs["release-check"])

    def test_release_check_は_release_now_の_PR_のときだけ_PR_の契機で走る(self):
        cond = workflow.condition(self.jobs["release-check"])
        self.assertIn("github.event_name != 'pull_request'", cond)
        self.assertIn("github.event.pull_request.merged", cond)
        self.assertIn("'release:now'", cond)

    def test_タグは検査した_SHA_に打ち_食い違えば打たない(self):
        release = self.jobs["release"]
        self.assertIn("CHECKED_SHA: ${{ needs.release-check.outputs.sha }}", release)
        self.assertIn('git tag "$VERSION" "$CHECKED_SHA"', release)
        self.assertRegex(release, r'"\$head" != "\$CHECKED_SHA"')
        self.assertIn("sha: ${{ steps.sha.outputs.sha }}", self.jobs["release-check"])

    def test_issues_write_は起票のジョブだけが持つ(self):
        holders = {name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)}
        self.assertEqual(holders, {"release-check-report"})

    def test_起票は落ちたか切れた回だけ走る(self):
        report = self.jobs["release-check-report"]
        self.assertEqual(workflow.needs(report), {"release-check"})
        cond = workflow.condition(report)
        self.assertTrue(cond.startswith("always()"), cond)
        self.assertIn("needs.release-check.result == 'failure'", cond)
        self.assertIn("needs.release-check.result == 'cancelled'", cond)
        self.assertIn("scripts/report-release-check.sh", report)


if __name__ == "__main__":
    unittest.main()
